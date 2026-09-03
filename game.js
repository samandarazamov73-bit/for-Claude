'use strict';

/* =========================================================================
   SPIDER SWING — a small arcade web-swinging endless runner.
   Pure Canvas2D + vanilla JS. No build step, no external assets.
   ========================================================================= */

/* ----------------------------- CONFIG ----------------------------------- */

const CFG = {
  GRAVITY: 1700,               // px/s^2
  BASE_SPEED_START: 250,       // px/s, forward auto-drift floor while airborne
  BASE_SPEED_MAX: 560,
  BASE_SPEED_RAMP: 2.4,        // px/s of floor gained per second survived
  MAX_FALL_SPEED: 1500,
  MAX_VX: 950,
  MAX_WEB_DISTANCE: 520,       // furthest anchor the web can reach
  MIN_ROPE_LENGTH: 70,
  GROUND_Y: 900,               // world y of the street surface (walkable ground)
  PLAYER_FOOT: 20,             // distance from player centre to feet, for ground contact
  WALK_SPEED: 230,             // px/s, direct WASD ground movement
  JUMP_SPEED: 640,             // px/s, upward impulse from a ground jump
  AIR_CONTROL_ACCEL: 500,      // px/s^2, light A/D steering while airborne
  PIXELS_PER_METER: 14,
  COMBO_WINDOW: 3.2,           // seconds allowed between release -> next attach
  PERFECT_RELEASE_FACTOR: 1.3, // vx must exceed baseSpeed * this for "perfect"
  LONG_SWING_TIME: 1.1,
  WEB_GROW_TIME: 0.14,
  PLAYER_START_X: 160,
};

const SCORE = { ATTACH: 10, LONG_SWING: 25, PERFECT: 50 };

/* ----------------------------- UTILITIES --------------------------------- */

const rand = (a, b) => a + Math.random() * (b - a);
const randInt = (a, b) => Math.floor(rand(a, b + 1));
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const lerp = (a, b, t) => a + (b - a) * t;
const dist = (x1, y1, x2, y2) => Math.hypot(x2 - x1, y2 - y1);
const choice = (arr) => arr[Math.floor(Math.random() * arr.length)];

/* ----------------------------- SOUND ------------------------------------- */
// Tiny procedural SFX via WebAudio — no external audio files needed.
class SoundEngine {
  constructor() {
    this.ctx = null;
    this.muted = false;
  }
  ensure() {
    if (!this.ctx) {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (AC) this.ctx = new AC();
    }
    if (this.ctx && this.ctx.state === 'suspended') this.ctx.resume();
  }
  tone(freq, duration, type = 'sine', vol = 0.18, glideTo = null) {
    if (this.muted || !this.ctx) return;
    const t0 = this.ctx.currentTime;
    const osc = this.ctx.createOscillator();
    const gain = this.ctx.createGain();
    osc.type = type;
    osc.frequency.setValueAtTime(freq, t0);
    if (glideTo) osc.frequency.exponentialRampToValueAtTime(Math.max(1, glideTo), t0 + duration);
    gain.gain.setValueAtTime(0.0001, t0);
    gain.gain.exponentialRampToValueAtTime(vol, t0 + 0.012);
    gain.gain.exponentialRampToValueAtTime(0.0001, t0 + duration);
    osc.connect(gain).connect(this.ctx.destination);
    osc.start(t0);
    osc.stop(t0 + duration + 0.02);
  }
  webShoot() { this.ensure(); this.tone(900, 0.08, 'triangle', 0.12, 1400); }
  webAttach() { this.ensure(); this.tone(320, 0.09, 'square', 0.1, 260); }
  webRelease() { this.ensure(); this.tone(500, 0.1, 'sine', 0.12, 720); }
  perfect() {
    this.ensure();
    this.tone(660, 0.12, 'triangle', 0.16, 990);
    setTimeout(() => this.tone(990, 0.14, 'triangle', 0.14, 1320), 60);
  }
  gameOver() { this.ensure(); this.tone(300, 0.5, 'sawtooth', 0.14, 70); }
  toggleMute() { this.muted = !this.muted; return this.muted; }
}

/* ----------------------------- PARTICLES ---------------------------------- */

class ParticleSystem {
  constructor() { this.list = []; }
  spawn(x, y, opts = {}) {
    const n = opts.count || 8;
    for (let i = 0; i < n; i++) {
      const angle = opts.angle !== undefined
        ? opts.angle + rand(-0.6, 0.6)
        : rand(0, Math.PI * 2);
      const speed = rand(opts.speedMin || 40, opts.speedMax || 180);
      this.list.push({
        x, y,
        vx: Math.cos(angle) * speed,
        vy: Math.sin(angle) * speed,
        life: opts.life || rand(0.3, 0.7),
        maxLife: opts.life || 0.6,
        size: opts.size || rand(1.5, 3.5),
        color: opts.color || '#eaf6ff',
        gravity: opts.gravity !== undefined ? opts.gravity : 400,
        streak: !!opts.streak,
      });
    }
  }
  update(dt) {
    for (let i = this.list.length - 1; i >= 0; i--) {
      const p = this.list[i];
      p.vy += p.gravity * dt;
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      p.life -= dt;
      if (p.life <= 0) this.list.splice(i, 1);
    }
  }
  draw(ctx, cam) {
    for (const p of this.list) {
      const a = clamp(p.life / p.maxLife, 0, 1);
      ctx.globalAlpha = a;
      ctx.fillStyle = p.color;
      const sx = p.x - cam.x, sy = p.y - cam.y;
      if (p.streak) {
        ctx.strokeStyle = p.color;
        ctx.lineWidth = p.size;
        ctx.beginPath();
        ctx.moveTo(sx, sy);
        ctx.lineTo(sx - p.vx * 0.03, sy - p.vy * 0.03);
        ctx.stroke();
      } else {
        ctx.beginPath();
        ctx.arc(sx, sy, p.size, 0, Math.PI * 2);
        ctx.fill();
      }
    }
    ctx.globalAlpha = 1;
  }
}

/* ----------------------------- FLOATING TEXT ------------------------------ */

class TextPopups {
  constructor() { this.list = []; }
  spawn(x, y, text, color = '#fff', big = false) {
    this.list.push({ x, y, text, color, life: 1.0, big });
  }
  update(dt) {
    for (let i = this.list.length - 1; i >= 0; i--) {
      const p = this.list[i];
      p.y -= 40 * dt;
      p.life -= dt * 1.1;
      if (p.life <= 0) this.list.splice(i, 1);
    }
  }
  draw(ctx, cam) {
    for (const p of this.list) {
      ctx.globalAlpha = clamp(p.life, 0, 1);
      ctx.fillStyle = p.color;
      ctx.font = `900 ${p.big ? 22 : 15}px Segoe UI, Arial`;
      ctx.textAlign = 'center';
      ctx.shadowColor = 'rgba(0,0,0,0.8)';
      ctx.shadowBlur = 6;
      ctx.fillText(p.text, p.x - cam.x, p.y - cam.y);
      ctx.shadowBlur = 0;
    }
    ctx.globalAlpha = 1;
  }
}

/* ----------------------------- BUILDINGS ----------------------------------- */

const BUILDING_PALETTE = [
  '#1b1f3b', '#221a3d', '#171b33', '#26234a', '#1e2444', '#2a2050',
];
const NEON_COLORS = ['#ff3d9a', '#3df0ff', '#b06bff', '#ffe23d', '#3dff9e'];

let buildingUID = 1;

class Building {
  constructor(x, type, layer) {
    this.id = buildingUID++;
    this.x = x;
    this.type = type;
    this.layer = layer; // 'far' | 'mid' | 'near'
    this.color = choice(BUILDING_PALETTE);
    this.neon = Math.random() < 0.22 ? choice(NEON_COLORS) : null;

    switch (type) {
      case 'B': // narrow tall
        this.width = rand(46, 74);
        this.height = rand(360, 620);
        break;
      case 'C': // wide low
        this.width = rand(160, 240);
        this.height = rand(120, 220);
        break;
      case 'D': // antenna
        this.width = rand(90, 140);
        this.height = rand(240, 420);
        this.antenna = rand(50, 110);
        break;
      case 'E': // neon sign
        this.width = rand(100, 160);
        this.height = rand(200, 380);
        this.neon = choice(NEON_COLORS);
        break;
      default: // A normal
        this.width = rand(90, 150);
        this.height = rand(220, 420);
    }

    if (layer !== 'mid') {
      // decorative layers are visually simpler & taller/shorter per depth
      this.height *= layer === 'far' ? rand(1.1, 1.6) : rand(0.5, 0.8);
    }

    this.top = CFG.GROUND_Y - this.height;
    this.flicker = rand(0, Math.PI * 2);
    this.windows = [];
    if (layer === 'mid') this._buildWindows();
    this.anchors = layer === 'mid' ? this._buildAnchors() : [];
  }

  _buildWindows() {
    const margin = 10;
    const cellW = 14, cellH = 18;
    const cols = Math.max(1, Math.floor((this.width - margin * 2) / cellW));
    const rows = Math.max(1, Math.floor((this.height - margin * 2) / cellH));
    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        if (Math.random() < 0.32) continue; // gaps
        this.windows.push({
          ox: margin + c * cellW + cellW / 2,
          oy: margin + r * cellH + cellH / 2,
          lit: Math.random() < 0.72,
          phase: rand(0, Math.PI * 2),
        });
      }
    }
  }

  _buildAnchors() {
    const a = [];
    a.push({ ox: 10, oy: 6 });                       // top-left
    a.push({ ox: this.width / 2, oy: 6 });            // top-center
    a.push({ ox: this.width - 10, oy: 6 });           // top-right
    if (this.width > 120 && this.height > 200) {
      a.push({ ox: this.width * 0.25, oy: this.height * 0.35 }); // side
    }
    return a.map((p) => ({ x: this.x + p.ox, y: this.top + p.oy }));
  }

  get right() { return this.x + this.width; }

  draw(ctx, cam, factor, t) {
    const sx = this.x - cam.x * factor;
    const sy = this.top - cam.y * (this.layer === 'mid' ? 1 : factor);
    if (sx + this.width < -50 || sx > 3000) return;

    if (this.layer !== 'mid') {
      // silhouette buildings for depth. A small buffer (not the building's
      // full height again) keeps the base flush with the street even as
      // this layer's slower vertical parallax drifts slightly out of sync.
      ctx.fillStyle = this.layer === 'far' ? 'rgba(15,17,38,0.85)' : 'rgba(5,6,14,0.9)';
      ctx.fillRect(sx, sy, this.width, this.height + 70);
      if (this.neon && this.layer === 'far') {
        ctx.fillStyle = this.neon;
        ctx.globalAlpha = 0.25 + Math.sin(t * 2 + this.flicker) * 0.05;
        ctx.fillRect(sx + this.width * 0.2, sy + 10, this.width * 0.6, 6);
        ctx.globalAlpha = 1;
      }
      return;
    }

    // --- MID layer: full detail, interactive buildings ---
    // Drawn flush to exactly its real height so the base lands right on
    // the street surface instead of a big opaque slab bleeding past it.
    ctx.fillStyle = this.color;
    ctx.fillRect(sx, sy, this.width, this.height);

    // roof parapet
    ctx.fillStyle = 'rgba(0,0,0,0.25)';
    ctx.fillRect(sx, sy, this.width, 6);

    if (this.type === 'D' && this.antenna) {
      ctx.strokeStyle = '#555';
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(sx + this.width / 2, sy);
      ctx.lineTo(sx + this.width / 2, sy - this.antenna);
      ctx.stroke();
      const blink = 0.5 + Math.sin(t * 4) * 0.5;
      ctx.fillStyle = `rgba(255,60,60,${blink})`;
      ctx.beginPath();
      ctx.arc(sx + this.width / 2, sy - this.antenna, 3, 0, Math.PI * 2);
      ctx.fill();
    }

    // windows
    for (const w of this.windows) {
      const flick = 0.75 + Math.sin(t * 1.6 + w.phase) * 0.25;
      ctx.fillStyle = w.lit ? `rgba(255,214,120,${w.lit ? 0.55 * flick + 0.2 : 0})` : 'rgba(120,140,180,0.12)';
      ctx.fillRect(sx + w.ox - 3, sy + w.oy - 4, 6, 8);
    }

    // neon sign
    if (this.neon) {
      const glow = 0.55 + Math.sin(t * 3 + this.flicker) * 0.25;
      ctx.save();
      ctx.shadowColor = this.neon;
      ctx.shadowBlur = 14;
      ctx.fillStyle = this.neon;
      ctx.globalAlpha = glow;
      ctx.fillRect(sx + this.width * 0.15, sy + this.height * 0.28, this.width * 0.7, 8);
      ctx.restore();
      ctx.globalAlpha = 1;
    }
  }
}

/* ----------------------------- CITY GENERATOR ------------------------------ */

class CityLayer {
  constructor(name, factor) {
    this.name = name;
    this.factor = factor;
    this.buildings = [];
    this.nextX = -200;
    this.prevAnchor = null;   // used only by mid layer for reachability
    this.prevBuilding = null; // used only by mid layer to avoid overlap
  }

  reset(startX) {
    this.buildings.length = 0;
    this.nextX = startX;
    this.prevAnchor = null;
    this.prevBuilding = null;
  }

  spawnOne(difficulty) {
    const types = this.name === 'mid'
      ? ['A', 'A', 'B', 'C', 'D', 'E']
      : ['A', 'B', 'C'];

    if (this.name === 'mid') {
      // ---- reachability guard ------------------------------------------
      // Buildings never overlap (each starts strictly after the previous
      // one's right edge) and every candidate's nearest anchor is tested
      // against the previous anchor before it's accepted, so a reachable
      // swing path always exists (see isReachable()). Difficulty widens
      // the gap range over time without ever exceeding the safe distance.
      const baseGap = rand(30, 90 + Math.min(difficulty, 8) * 20);
      let chosen = null;
      for (let tries = 0; tries < 6 && !chosen; tries++) {
        const startX = this.prevBuilding ? this.prevBuilding.right + baseGap : this.nextX;
        const candidate = new Building(startX, choice(types), 'mid');
        if (!this.prevAnchor) { chosen = candidate; break; }
        if (candidate.anchors.some((a) => isReachable(this.prevAnchor, a))) chosen = candidate;
      }
      if (!chosen) {
        // fallback: a short, close building is always reachable
        const startX = this.prevBuilding ? this.prevBuilding.right + 30 : this.nextX;
        chosen = new Building(startX, 'C', 'mid');
        chosen.height = 160;
        chosen.top = CFG.GROUND_Y - chosen.height;
        chosen.anchors = chosen._buildAnchors();
      }
      this.prevBuilding = chosen;
      this.prevAnchor = chosen.anchors[Math.floor(chosen.anchors.length / 2)];
      this.nextX = chosen.right + rand(40, 90);
      this.buildings.push(chosen);
      return;
    }

    const b = new Building(this.nextX, choice(types), this.name);
    this.nextX = b.right + rand(20, 120);
    this.buildings.push(b);
  }

  update(camX, viewW, difficulty) {
    // Parallax layers render at sx = x - camX*factor, so spawning/pruning
    // must reason in that same scaled space, not raw world x, or a slow
    // layer's buildings would need world-x values far beyond the camera
    // and would never actually scroll into view.
    const refX = camX * this.factor;
    const lookahead = viewW * 2.2;
    while (this.nextX < refX + lookahead) this.spawnOne(difficulty);
    while (this.buildings.length && this.buildings[0].right < refX - viewW * 1.5) {
      this.buildings.shift();
    }
  }

  draw(ctx, cam, viewW, t) {
    for (const b of this.buildings) b.draw(ctx, cam, this.factor, t);
  }
}

function isReachable(anchorA, anchorB) {
  return dist(anchorA.x, anchorA.y, anchorB.x, anchorB.y) <= CFG.MAX_WEB_DISTANCE * 0.92;
}

class CityGenerator {
  constructor() {
    this.far = new CityLayer('far', 0.25);
    this.mid = new CityLayer('mid', 1.0);
    this.near = new CityLayer('near', 1.6);
    this.street = new Street();
  }
  reset() {
    this.far.reset(-300);
    this.mid.reset(CFG.PLAYER_START_X - 40);
    this.near.reset(-300);
    // guarantee a friendly first building right in front of the player
    const first = new Building(CFG.PLAYER_START_X + 160, 'A', 'mid');
    first.height = 260;
    first.top = CFG.GROUND_Y - first.height;
    first.anchors = first._buildAnchors();
    this.mid.buildings.push(first);
    this.mid.nextX = first.right + 70;
    this.mid.prevAnchor = first.anchors[1];
    this.mid.prevBuilding = first;
  }
  update(camX, viewW, difficulty) {
    this.far.update(camX, viewW, difficulty);
    this.mid.update(camX, viewW, difficulty);
    this.near.update(camX, viewW, difficulty);
  }
  draw(ctx, cam, viewW, viewH, t) {
    this.far.draw(ctx, cam, viewW, t);
    this.mid.draw(ctx, cam, viewW, t);
    this.street.draw(ctx, cam, viewW, viewH, t);
    this.near.draw(ctx, cam, viewW, t);
  }
  allAnchors() {
    const out = [];
    for (const b of this.mid.buildings) for (const a of b.anchors) out.push(a);
    return out;
  }
}

/* ----------------------------- STREET (walkable ground) --------------------- */

class Street {
  draw(ctx, cam, viewW, viewH, t) {
    const sy = CFG.GROUND_Y - cam.y;
    if (sy > viewH || sy + 4000 < 0) return; // fully off-screen

    // asphalt body
    const grad = ctx.createLinearGradient(0, sy, 0, sy + 160);
    grad.addColorStop(0, '#33323d');
    grad.addColorStop(1, '#1a1a22');
    ctx.fillStyle = grad;
    ctx.fillRect(0, sy, viewW, Math.max(viewH - sy, 200));

    // curb / sidewalk edge
    ctx.fillStyle = '#4a4a58';
    ctx.fillRect(0, sy, viewW, 4);
    ctx.fillStyle = 'rgba(255,255,255,0.06)';
    ctx.fillRect(0, sy + 4, viewW, 2);

    // dashed lane markings, scrolling with the world so they read as real ground
    ctx.strokeStyle = 'rgba(255,214,120,0.35)';
    ctx.lineWidth = 4;
    ctx.setLineDash([28, 26]);
    ctx.lineDashOffset = -cam.x;
    ctx.beginPath();
    ctx.moveTo(0, sy + 46);
    ctx.lineTo(viewW, sy + 46);
    ctx.stroke();
    ctx.setLineDash([]);

    // faint window-light glints on the wet asphalt
    ctx.fillStyle = 'rgba(255,214,120,0.05)';
    for (let i = 0; i < 6; i++) {
      const gx = ((i * 260 - cam.x * 0.6) % (viewW + 260) + (viewW + 260)) % (viewW + 260) - 130;
      ctx.beginPath();
      ctx.ellipse(gx, sy + 90, 60, 10, 0, 0, Math.PI * 2);
      ctx.fill();
    }
  }
}

/* ----------------------------- PLAYER --------------------------------------- */

class Player {
  constructor() {
    this.x = CFG.PLAYER_START_X;
    this.y = CFG.GROUND_Y - 340;
    this.vx = CFG.BASE_SPEED_START;
    this.vy = 0;
    this.attached = false;
    this.anchor = null;
    this.ropeLength = 0;
    this.attachTime = 0;
    this.webGrow = 0; // 0..1 visual attach animation
    this.legPhase = 0;
    this.lean = 0;
    this.squash = 1;
    this.grounded = false;
  }

  jump() {
    if (this.attached || !this.grounded) return;
    this.vy = -CFG.JUMP_SPEED;
    this.grounded = false;
    this.squash = 0.75;
  }

  handPos() {
    // approximate hand/web-shooter position just above the body centre
    return { x: this.x + 6, y: this.y - 6 };
  }

  attach(anchor) {
    this.attached = true;
    this.anchor = anchor;
    const hp = this.handPos();
    this.ropeLength = clamp(dist(hp.x, hp.y, anchor.x, anchor.y), CFG.MIN_ROPE_LENGTH, CFG.MAX_WEB_DISTANCE);
    this.attachTime = 0;
    this.webGrow = 0;
  }

  release() {
    this.attached = false;
    this.anchor = null;
    this.squash = 1.25;
  }

  update(dt, baseSpeed, input) {
    this.webGrow = clamp(this.webGrow + dt / CFG.WEB_GROW_TIME, 0, 1);
    this.squash = lerp(this.squash, 1, dt * 6);
    const dir = (input.right ? 1 : 0) - (input.left ? 1 : 0);
    this.legPhase += dt * (this.grounded ? 5 + Math.abs(this.vx) * 0.02 : 6);

    if (this.attached) {
      this.grounded = false;
      this.attachTime += dt;
      // --- pendulum swing via a simple distance constraint -------------
      // Free-fall the point under gravity, then clamp it back onto the
      // rope's circle around the anchor and strip the outward-radial
      // velocity component. What's left is pure tangential velocity,
      // which is exactly what makes this behave like a swinging rope
      // instead of a rubber band.
      this.vy += CFG.GRAVITY * dt;
      this.x += this.vx * dt;
      this.y += this.vy * dt;

      const dx = this.x - this.anchor.x;
      const dy = this.y - this.anchor.y;
      const d = Math.hypot(dx, dy) || 0.0001;
      if (d > this.ropeLength) {
        const nx = dx / d, ny = dy / d;
        this.x = this.anchor.x + nx * this.ropeLength;
        this.y = this.anchor.y + ny * this.ropeLength;
        const outward = this.vx * nx + this.vy * ny;
        if (outward > 0) {
          this.vx -= outward * nx;
          this.vy -= outward * ny;
        }
      }
      this.lean = clamp(this.vx * 0.0009, -0.5, 0.5);
    } else if (this.grounded) {
      // --- ground locomotion: direct WASD control, no gravity to fight ---
      if (dir !== 0) this.vx = dir * CFG.WALK_SPEED;
      else this.vx = lerp(this.vx, 0, clamp(10 * dt, 0, 1));
      this.x += this.vx * dt;
      this.lean = clamp(this.vx * 0.001, -0.15, 0.15);
    } else {
      // --- airborne free flight: gravity + gentle forward assist + A/D steer ---
      this.vy += CFG.GRAVITY * dt;
      if (this.vx < baseSpeed) this.vx += (baseSpeed - this.vx) * clamp(2.2 * dt, 0, 1);
      if (dir !== 0) this.vx += dir * CFG.AIR_CONTROL_ACCEL * dt;
      this.x += this.vx * dt;
      this.y += this.vy * dt;
      this.lean = clamp(this.vy * 0.0006, -0.6, 0.9);
    }

    // ground contact: land on the street instead of falling forever
    if (!this.attached) {
      const footY = this.y + CFG.PLAYER_FOOT;
      if (footY >= CFG.GROUND_Y) {
        this.y = CFG.GROUND_Y - CFG.PLAYER_FOOT;
        if (!this.grounded && this.vy > 200) this.squash = 1.3;
        this.vy = 0;
        this.grounded = true;
      } else {
        this.grounded = false;
      }
    }

    this.vy = clamp(this.vy, -2000, CFG.MAX_FALL_SPEED);
    this.vx = clamp(this.vx, -CFG.MAX_VX, CFG.MAX_VX);
  }

  draw(ctx, cam, t) {
    const sx = this.x - cam.x;
    const sy = this.y - cam.y;
    ctx.save();
    ctx.translate(sx, sy);
    ctx.rotate(this.lean);
    ctx.scale(1 / this.squash, this.squash);

    const bob = this.attached ? 0 : Math.sin(this.legPhase) * 2;

    // legs
    ctx.strokeStyle = '#12060a';
    ctx.lineWidth = 3.4;
    ctx.lineCap = 'round';
    const legSwing = this.attached ? Math.sin(t * 5) * 6 : Math.sin(this.legPhase) * 8;
    ctx.beginPath();
    ctx.moveTo(-3, 6); ctx.lineTo(-10 - legSwing * 0.3, 20 + bob);
    ctx.moveTo(3, 6); ctx.lineTo(9 + legSwing * 0.6, 21 - bob);
    ctx.stroke();

    // back arm (toward anchor if attached)
    ctx.beginPath();
    if (this.attached && this.anchor) {
      const ang = Math.atan2(this.anchor.y - this.y, this.anchor.x - this.x) - this.lean;
      ctx.moveTo(2, -8);
      ctx.lineTo(2 + Math.cos(ang) * 14, -8 + Math.sin(ang) * 14);
    } else {
      ctx.moveTo(-4, -6);
      ctx.lineTo(-14 - legSwing * 0.4, -2 + bob);
    }
    ctx.stroke();

    // body (mask + suit)
    ctx.fillStyle = '#8a0f24';
    ctx.beginPath();
    ctx.ellipse(0, -2, 10, 13, 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = '#12060a';
    ctx.lineWidth = 1.2;
    ctx.stroke();

    // web pattern lines (decorative, subtle)
    ctx.strokeStyle = 'rgba(10,4,6,0.55)';
    ctx.lineWidth = 0.8;
    ctx.beginPath();
    ctx.moveTo(-8, -8); ctx.lineTo(8, 6);
    ctx.moveTo(8, -8); ctx.lineTo(-8, 6);
    ctx.moveTo(0, -13); ctx.lineTo(0, 9);
    ctx.stroke();

    // head
    ctx.fillStyle = '#a3122c';
    ctx.beginPath();
    ctx.arc(0, -14, 7.2, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = '#12060a';
    ctx.lineWidth = 1;
    ctx.stroke();

    // eyes
    ctx.fillStyle = '#eaf6ff';
    const eyeTilt = clamp(this.vy * 0.0006, -0.5, 0.5);
    ctx.beginPath();
    ctx.ellipse(-3, -15 + eyeTilt, 2.6, 3.4, -0.2, 0, Math.PI * 2);
    ctx.ellipse(3.2, -15 + eyeTilt, 2.6, 3.4, 0.2, 0, Math.PI * 2);
    ctx.fill();

    // front arm
    ctx.strokeStyle = '#12060a';
    ctx.lineWidth = 3.4;
    ctx.beginPath();
    if (this.attached && this.anchor) {
      const ang = Math.atan2(this.anchor.y - this.y, this.anchor.x - this.x) - this.lean;
      ctx.moveTo(4, -8);
      ctx.lineTo(4 + Math.cos(ang) * 16, -8 + Math.sin(ang) * 16);
    } else {
      ctx.moveTo(5, -6);
      ctx.lineTo(15 + legSwing * 0.4, 0 - bob);
    }
    ctx.stroke();

    ctx.restore();
  }
}

/* ----------------------------- WEB VISUAL ----------------------------------- */

function drawWeb(ctx, cam, hand, anchor, growT, t) {
  const hx = hand.x - cam.x, hy = hand.y - cam.y;
  const ax = anchor.x - cam.x, ay = anchor.y - cam.y;
  const ex = lerp(hx, ax, growT);
  const ey = lerp(hy, ay, growT);

  const mx = (hx + ex) / 2;
  const my = (hy + ey) / 2;
  const perpX = -(ey - hy);
  const perpY = (ex - hx);
  const perpLen = Math.hypot(perpX, perpY) || 1;
  const sag = Math.sin(t * 9) * 3 * growT;
  const cx = mx + (perpX / perpLen) * sag;
  const cy = my + (perpY / perpLen) * sag;

  ctx.save();
  ctx.strokeStyle = 'rgba(230,246,255,0.85)';
  ctx.lineWidth = 1.6;
  ctx.shadowColor = 'rgba(180,220,255,0.9)';
  ctx.shadowBlur = 4;
  ctx.beginPath();
  ctx.moveTo(hx, hy);
  ctx.quadraticCurveTo(cx, cy, ex, ey);
  ctx.stroke();
  ctx.restore();
}

/* ----------------------------- CAMERA --------------------------------------- */

class Camera {
  constructor() { this.x = 0; this.y = 0; this.shake = 0; }
  follow(player, viewW, viewH, dt) {
    const targetX = player.x - viewW * 0.36;
    const targetY = player.y - viewH * 0.5;
    this.x = lerp(this.x, targetX, clamp(6 * dt, 0, 1));
    this.y = lerp(this.y, targetY, clamp(4 * dt, 0, 1));
    if (this.shake > 0) this.shake = Math.max(0, this.shake - dt * 3);
  }
  offsets() {
    if (this.shake <= 0) return { x: this.x, y: this.y };
    return {
      x: this.x + rand(-this.shake, this.shake) * 4,
      y: this.y + rand(-this.shake, this.shake) * 4,
    };
  }
}

/* ----------------------------- ATMOSPHERE ------------------------------------ */

class Atmosphere {
  constructor() {
    this.stars = [];
    for (let i = 0; i < 90; i++) {
      this.stars.push({ x: rand(0, 2000), y: rand(0, 500), r: rand(0.5, 1.8), phase: rand(0, 7) });
    }
    this.events = [];
    this.nextEventIn = rand(8, 16);
  }

  update(dt, camX, viewW) {
    this.nextEventIn -= dt;
    if (this.nextEventIn <= 0) {
      this.nextEventIn = rand(14, 26);
      const kind = choice(['heli', 'blimp', 'bird', 'lightning']);
      if (kind === 'lightning') {
        this.events.push({ kind, life: 0.15, x: 0, y: 0 });
      } else {
        this.events.push({
          kind,
          x: camX - 200,
          y: rand(40, 220),
          speed: kind === 'bird' ? rand(90, 140) : rand(30, 55),
          life: 30,
        });
      }
    }
    for (let i = this.events.length - 1; i >= 0; i--) {
      const e = this.events[i];
      if (e.kind === 'lightning') {
        e.life -= dt;
      } else {
        e.x += e.speed * dt;
        e.life -= dt;
        if (e.x > camX + viewW + 300) e.life = 0;
      }
      if (e.life <= 0) this.events.splice(i, 1);
    }
  }

  drawSky(ctx, cam, viewW, viewH, t) {
    const grad = ctx.createLinearGradient(0, 0, 0, viewH);
    grad.addColorStop(0, '#060714');
    grad.addColorStop(0.55, '#0c0f26');
    grad.addColorStop(1, '#171733');
    ctx.fillStyle = grad;
    ctx.fillRect(0, 0, viewW, viewH);

    // moon
    const moonX = viewW * 0.78 - cam.x * 0.05;
    const moonY = 110 - cam.y * 0.05;
    ctx.save();
    ctx.fillStyle = '#f4f0e2';
    ctx.shadowColor = 'rgba(244,240,226,0.6)';
    ctx.shadowBlur = 30;
    ctx.beginPath();
    ctx.arc(moonX, moonY, 38, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();

    // stars
    ctx.fillStyle = '#eaf6ff';
    for (const s of this.stars) {
      const twinkle = 0.5 + Math.sin(t * 2 + s.phase) * 0.5;
      const sx = ((s.x - cam.x * 0.08) % (viewW + 200) + (viewW + 200)) % (viewW + 200) - 100;
      ctx.globalAlpha = twinkle * 0.8;
      ctx.beginPath();
      ctx.arc(sx, s.y - cam.y * 0.05, s.r, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;

    // clouds (soft ellipses)
    ctx.fillStyle = 'rgba(255,255,255,0.04)';
    for (let i = 0; i < 4; i++) {
      const cx = ((i * 500 - cam.x * 0.1) % (viewW + 600) + (viewW + 600)) % (viewW + 600) - 300;
      ctx.beginPath();
      ctx.ellipse(cx, 90 + i * 40, 140, 26, 0, 0, Math.PI * 2);
      ctx.fill();
    }

    for (const e of this.events) this._drawEvent(ctx, cam, e, viewW);
  }

  _drawEvent(ctx, cam, e, viewW) {
    if (e.kind === 'lightning') {
      ctx.fillStyle = `rgba(255,255,255,${Math.min(0.25, e.life)})`;
      ctx.fillRect(0, 0, viewW, 2000);
      return;
    }
    const sx = e.x - cam.x * 0.3, sy = e.y - cam.y * 0.3;
    ctx.save();
    ctx.globalAlpha = 0.55;
    if (e.kind === 'heli') {
      ctx.fillStyle = '#0a0a12';
      ctx.fillRect(sx, sy, 22, 7);
      ctx.beginPath(); ctx.moveTo(sx - 12, sy + 3); ctx.lineTo(sx + 34, sy + 3); ctx.stroke();
      ctx.strokeStyle = '#0a0a12'; ctx.lineWidth = 1.5;
      ctx.beginPath(); ctx.moveTo(sx - 14, sy); ctx.lineTo(sx + 36, sy); ctx.stroke();
      ctx.fillStyle = 'rgba(255,60,60,0.8)';
      ctx.beginPath(); ctx.arc(sx + 22, sy + 3, 1.6, 0, Math.PI * 2); ctx.fill();
    } else if (e.kind === 'blimp') {
      ctx.fillStyle = '#141428';
      ctx.beginPath();
      ctx.ellipse(sx, sy, 40, 14, 0, 0, Math.PI * 2);
      ctx.fill();
      ctx.fillStyle = 'rgba(255,200,80,0.5)';
      ctx.fillRect(sx - 20, sy - 3, 40, 6);
    } else if (e.kind === 'bird') {
      ctx.strokeStyle = '#0a0a12';
      ctx.lineWidth = 1.4;
      ctx.beginPath();
      ctx.moveTo(sx - 6, sy); ctx.quadraticCurveTo(sx, sy - 5, sx + 6, sy);
      ctx.stroke();
    }
    ctx.restore();
  }
}

/* ----------------------------- MAIN GAME ------------------------------------- */

class Game {
  constructor() {
    this.canvas = document.getElementById('game-canvas');
    this.ctx = this.canvas.getContext('2d');
    this.viewW = 0; this.viewH = 0;
    this.resize();
    window.addEventListener('resize', () => this.resize());

    this.sound = new SoundEngine();
    this.state = 'MENU';
    this.best = parseInt(localStorage.getItem('spiderSwingBest') || '0', 10);
    this.hintSeen = localStorage.getItem('spiderSwingHintSeen') === '1';

    this._bindUI();
    this._bindInput();

    this.lastTime = performance.now();
    requestAnimationFrame((t) => this.loop(t));
  }

  resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    this.viewW = window.innerWidth;
    this.viewH = window.innerHeight;
    this.canvas.width = Math.round(this.viewW * dpr);
    this.canvas.height = Math.round(this.viewH * dpr);
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  _bindUI() {
    document.getElementById('menu-best').textContent = this.best;
    document.getElementById('btn-play').addEventListener('click', () => this.startGame());
    document.getElementById('btn-restart').addEventListener('click', () => this.startGame());
    document.getElementById('btn-resume').addEventListener('click', () => this.togglePause(false));
    document.getElementById('btn-pause').addEventListener('click', () => this.togglePause());
    document.getElementById('btn-mute').addEventListener('click', (e) => {
      const muted = this.sound.toggleMute();
      e.currentTarget.textContent = muted ? '🔇' : '🔊';
    });
  }

  _bindInput() {
    const down = (e) => {
      if (e && e.cancelable) e.preventDefault();
      if (this.state === 'PLAYING') this.inputDown = true;
    };
    const up = (e) => {
      if (e && e.cancelable) e.preventDefault();
      this.inputDown = false;
    };

    this.canvas.addEventListener('mousedown', down);
    window.addEventListener('mouseup', up);
    this.canvas.addEventListener('touchstart', down, { passive: false });
    window.addEventListener('touchend', up, { passive: false });
    window.addEventListener('touchcancel', up, { passive: false });

    window.addEventListener('keydown', (e) => {
      if (e.code === 'Space') { down(e); }
      if (e.code === 'Escape') { if (this.state === 'PLAYING' || this.state === 'PAUSED') this.togglePause(); }
      if (e.code === 'KeyA' || e.code === 'ArrowLeft') this.moveLeft = true;
      if (e.code === 'KeyD' || e.code === 'ArrowRight') this.moveRight = true;
      if ((e.code === 'KeyW' || e.code === 'ArrowUp') && !e.repeat && this.state === 'PLAYING') {
        this.player.jump();
      }
    });
    window.addEventListener('keyup', (e) => {
      if (e.code === 'Space') up(e);
      if (e.code === 'KeyA' || e.code === 'ArrowLeft') this.moveLeft = false;
      if (e.code === 'KeyD' || e.code === 'ArrowRight') this.moveRight = false;
    });
  }

  togglePause(force) {
    if (this.state !== 'PLAYING' && this.state !== 'PAUSED') return;
    const toPause = force !== undefined ? force : this.state === 'PLAYING';
    if (toPause) {
      this.state = 'PAUSED';
      document.getElementById('pause-screen').classList.remove('hidden');
    } else {
      this.state = 'PLAYING';
      document.getElementById('pause-screen').classList.add('hidden');
      this.lastTime = performance.now();
    }
  }

  startGame() {
    document.getElementById('menu-screen').classList.add('hidden');
    document.getElementById('gameover-screen').classList.add('hidden');
    document.getElementById('pause-screen').classList.add('hidden');
    document.getElementById('hud').classList.remove('hidden');
    if (!this.hintSeen) document.getElementById('hint').classList.remove('hidden');

    this.sound.ensure();

    this.player = new Player();
    this.camera = new Camera();
    this.city = new CityGenerator();
    this.city.reset();
    this.particles = new ParticleSystem();
    this.popups = new TextPopups();
    this.atmo = new Atmosphere();

    this.baseSpeed = CFG.BASE_SPEED_START;
    this.elapsed = 0;
    this.maxXReached = this.player.x;
    this.bonusMeters = 0;
    this.combo = 1;
    this.comboTimer = 0;
    this.swingStartTime = 0;
    this.inputDown = false;
    this.prevInputDown = false;
    this.moveLeft = false;
    this.moveRight = false;

    this.state = 'PLAYING';
    this.lastTime = performance.now();
  }

  distanceMeters() {
    return Math.max(0, Math.floor((this.maxXReached - CFG.PLAYER_START_X) / CFG.PIXELS_PER_METER + this.bonusMeters));
  }

  tryAttach() {
    const p = this.player;
    const hand = p.handPos();
    let best = null, bestScore = Infinity;
    for (const a of this.city.allAnchors()) {
      if (a.x < p.x - 30) continue; // don't grab things behind us
      const d = dist(hand.x, hand.y, a.x, a.y);
      if (d > CFG.MAX_WEB_DISTANCE) continue;
      if (a.y > p.y + 80) continue; // avoid anchors far below
      const heightBonus = (p.y - a.y) * 0.4; // prefer anchors above us
      const score = d - heightBonus;
      if (score < bestScore) { bestScore = score; best = a; }
    }
    if (!best) return false;

    p.attach(best);
    this.sound.webShoot();
    setTimeout(() => this.sound.webAttach(), 90);
    this.particles.spawn(hand.x, hand.y, { count: 10, color: '#eaf6ff', speedMin: 30, speedMax: 120, life: 0.35, gravity: 100 });
    this.popups.spawn(p.x, p.y - 26, 'WEB!', '#9fe8ff');
    this.swingStartTime = this.elapsed;

    if (this.comboTimer > 0) this.combo += 1; else this.combo = 1;
    this.comboTimer = CFG.COMBO_WINDOW;
    this._syncCombo();

    this.bonusMeters += SCORE.ATTACH / CFG.PIXELS_PER_METER;

    if (!this.hintSeen) {
      this.hintSeen = true;
      localStorage.setItem('spiderSwingHintSeen', '1');
      document.getElementById('hint').classList.add('hidden');
    }
    return true;
  }

  releaseWeb() {
    const p = this.player;
    if (!p.attached) return;
    const swingDuration = this.elapsed - this.swingStartTime;
    const speed = Math.hypot(p.vx, p.vy);
    p.release();
    this.sound.webRelease();
    this.particles.spawn(p.x, p.y, { count: 8, color: '#eaf6ff', speedMin: 20, speedMax: 90, life: 0.4, gravity: 200 });

    if (swingDuration >= CFG.LONG_SWING_TIME) {
      this.bonusMeters += SCORE.LONG_SWING / CFG.PIXELS_PER_METER;
      this.popups.spawn(p.x, p.y - 20, 'Long Swing +25', '#8fffb0');
    }

    if (p.vx > this.baseSpeed * CFG.PERFECT_RELEASE_FACTOR) {
      this.bonusMeters += SCORE.PERFECT / CFG.PIXELS_PER_METER;
      this.popups.spawn(p.x, p.y - 40, 'PERFECT RELEASE!', '#ffd23d', true);
      this.sound.perfect();
      this.particles.spawn(p.x, p.y, { count: 16, color: '#ffd23d', speedMin: 80, speedMax: 220, life: 0.5, gravity: 150 });
    }
  }

  update(dt) {
    if (this.state !== 'PLAYING') return;
    this.elapsed += dt;

    this.baseSpeed = Math.min(CFG.BASE_SPEED_MAX, CFG.BASE_SPEED_START + this.elapsed * CFG.BASE_SPEED_RAMP);

    // edge-triggered input -> jump (if grounded) / web attach / web release
    if (this.inputDown && !this.prevInputDown) {
      if (this.player.grounded) this.player.jump();
      else if (!this.player.attached) this.tryAttach();
    }
    if (!this.inputDown && this.prevInputDown && this.player.attached) {
      this.releaseWeb();
    }
    this.prevInputDown = this.inputDown;

    this.player.update(dt, this.baseSpeed, { left: this.moveLeft, right: this.moveRight });
    this.maxXReached = Math.max(this.maxXReached, this.player.x);

    if (this.comboTimer > 0) {
      this.comboTimer -= dt;
      if (this.comboTimer <= 0) { this.combo = 1; this._syncCombo(); }
    }

    this.camera.follow(this.player, this.viewW, this.viewH, dt);
    this.city.update(this.camera.x, this.viewW, this.elapsed / 20);
    this.particles.update(dt);
    this.popups.update(dt);
    this.atmo.update(dt, this.camera.x, this.viewW);

    // speed streak particles at high velocity
    if (Math.hypot(this.player.vx, this.player.vy) > this.baseSpeed * 1.6 && Math.random() < 0.6) {
      this.particles.spawn(this.player.x - 8, this.player.y, {
        count: 1, color: 'rgba(255,255,255,0.6)', speedMin: 0, speedMax: 0,
        life: 0.2, gravity: 0, streak: true, size: 2,
      });
    }

    // Falling just means landing on the street (see Player's ground contact
    // handling) -- there is no fall damage or death here, only a running
    // best-distance record, saved continuously as it's beaten.
    const d = this.distanceMeters();
    if (d > this.best) {
      this.best = d;
      localStorage.setItem('spiderSwingBest', String(this.best));
    }

    document.getElementById('hud-distance').textContent = d;
    document.getElementById('hud-best').textContent = this.best;
  }

  _syncCombo() {
    const el = document.getElementById('hud-combo');
    const val = document.getElementById('hud-combo-value');
    if (this.combo > 1) {
      val.textContent = this.combo;
      el.classList.remove('hidden');
      el.style.animation = 'none';
      requestAnimationFrame(() => { el.style.animation = 'comboPulse 0.35s ease'; });
      if (this.combo >= 3) this.popups.spawn(this.player.x, this.player.y - 50, `x${this.combo}!`, '#ff8a00', true);
    } else {
      el.classList.add('hidden');
    }
  }

  gameOver() {
    this.state = 'GAME_OVER';
    this.sound.gameOver();
    const d = this.distanceMeters();
    if (d > this.best) {
      this.best = d;
      localStorage.setItem('spiderSwingBest', String(this.best));
    }
    document.getElementById('final-distance').textContent = d;
    document.getElementById('final-best').textContent = this.best;
    document.getElementById('menu-best').textContent = this.best;
    document.getElementById('hud').classList.add('hidden');
    document.getElementById('hint').classList.add('hidden');
    setTimeout(() => document.getElementById('gameover-screen').classList.remove('hidden'), 120);
  }

  draw() {
    const ctx = this.ctx;
    ctx.clearRect(0, 0, this.viewW, this.viewH);

    if (this.state === 'MENU') {
      this._drawIdleBackdrop();
      return;
    }

    const cam = this.camera.offsets();
    const t = this.elapsed;

    this.atmo.drawSky(ctx, cam, this.viewW, this.viewH, t);
    this.city.draw(ctx, cam, this.viewW, this.viewH, t);
    this.particles.draw(ctx, cam);

    if (this.player.attached && this.player.anchor) {
      drawWeb(ctx, cam, this.player.handPos(), this.player.anchor, this.player.webGrow, t);
    }
    this.player.draw(ctx, cam, t);
    this.popups.draw(ctx, cam);
  }

  _drawIdleBackdrop() {
    // subtle animated backdrop behind the menu, purely decorative
    if (!this._menuAtmo) { this._menuAtmo = new Atmosphere(); this._menuCam = { x: 0, y: -60 }; this._menuT = 0; }
    this._menuT += 0.016;
    this._menuCam.x += 0.4;
    this._menuAtmo.drawSky(this.ctx, this._menuCam, this.viewW, this.viewH, this._menuT);
  }

  loop(now) {
    let dt = (now - this.lastTime) / 1000;
    dt = clamp(dt, 0, 1 / 30);
    this.lastTime = now;

    this.update(dt);
    this.draw();

    requestAnimationFrame((t) => this.loop(t));
  }
}

window.addEventListener('DOMContentLoaded', () => {
  window.__game = new Game();
});
