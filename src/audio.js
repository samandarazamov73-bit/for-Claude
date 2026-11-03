// Звук: всё синтезируется WebAudio, пока нет файлов. Если в assets/sounds лежит файл
// с нужным именем (см. assets.js), он используется вместо синтеза.
import { clamp } from './utils.js';

export class GameAudio {
  constructor() {
    this.ctx = null;
    this.volume = 0.8;
    this.muted = false;
    this.buffers = {};
    this.loops = {};
    this.birdTimer = 2;
  }

  // Вызывается по клику «Начать» (браузер не даёт играть звук без действия игрока).
  async init(buffersPromise) {
    if (this.ctx) return;
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return;
    this.ctx = new AC();
    const c = this.ctx;
    this.master = c.createGain();
    this.master.gain.value = this.volume;
    this.master.connect(c.destination);
    // Всё «уличное» идёт через фильтр: в салоне он глушит верхние частоты.
    this.outside = c.createBiquadFilter();
    this.outside.type = 'lowpass';
    this.outside.frequency.value = 900;
    this.outside.connect(this.master);
    this.noise = this.makeNoise();
    try {
      const raw = (await buffersPromise) || {};
      for (const [k, arr] of Object.entries(raw)) {
        try { this.buffers[k] = await c.decodeAudioData(arr.slice(0)); } catch { /* битый файл — синтез */ }
      }
    } catch { /* нет файлов — синтез */ }
    this.buildLoops();
  }

  makeNoise() {
    const c = this.ctx;
    const buf = c.createBuffer(1, c.sampleRate * 2, c.sampleRate);
    const d = buf.getChannelData(0);
    let last = 0;
    for (let i = 0; i < d.length; i++) { // «коричневатый» шум — мягче белого
      last = last * 0.97 + (Math.random() * 2 - 1) * 0.03;
      d[i] = last * 6 + (Math.random() * 2 - 1) * 0.15;
    }
    return buf;
  }

  loopSource(name, fallback, dest) {
    const c = this.ctx;
    const gain = c.createGain();
    gain.gain.value = 0;
    gain.connect(dest);
    if (this.buffers[name]) {
      const src = c.createBufferSource();
      src.buffer = this.buffers[name];
      src.loop = true;
      src.connect(gain);
      src.start();
      return { gain, src, file: true };
    }
    return { gain, ...fallback(gain) };
  }

  buildLoops() {
    const c = this.ctx;
    const noiseChain = (gain, type, freq, q = 0.7) => {
      const src = c.createBufferSource();
      src.buffer = this.noise;
      src.loop = true;
      const f = c.createBiquadFilter();
      f.type = type;
      f.frequency.value = freq;
      f.Q.value = q;
      src.connect(f).connect(gain);
      src.start();
      return { src, filter: f };
    };
    this.loops.engine = this.loopSource('engine', (gain) => {
      const o1 = c.createOscillator(), o2 = c.createOscillator();
      o1.type = 'sawtooth'; o2.type = 'square';
      const f = c.createBiquadFilter();
      f.type = 'lowpass'; f.frequency.value = 420;
      const g2 = c.createGain(); g2.gain.value = 0.5;
      o1.connect(f); o2.connect(g2).connect(f); f.connect(gain);
      o1.start(); o2.start();
      return { o1, o2, filter: f };
    }, this.master);
    this.loops.road = this.loopSource('road', (g) => noiseChain(g, 'bandpass', 250), this.outside);
    this.loops.interior = this.loopSource('interior', (g) => noiseChain(g, 'lowpass', 500), this.master);
    this.loops.city = this.loopSource('city', (g) => noiseChain(g, 'lowpass', 380), this.outside);
    this.loops.motor = this.loopSource('motor', (gain) => {
      const o = c.createOscillator();
      o.type = 'triangle';
      const f = c.createBiquadFilter();
      f.type = 'bandpass'; f.frequency.value = 600; f.Q.value = 1.2;
      o.connect(f).connect(gain);
      o.start();
      return { o1: o };
    }, this.master);
    if (this.buffers.birds) this.loops.birds = this.loopSource('birds', () => ({}), this.master);
    if (this.buffers.music) this.loops.music = this.loopSource('music', () => ({}), this.master);
  }

  setVolume(v) {
    this.volume = v;
    if (this.master) this.master.gain.setTargetAtTime(this.muted ? 0 : v, this.ctx.currentTime, 0.05);
  }

  toggleMute() {
    this.muted = !this.muted;
    this.setVolume(this.volume);
    return this.muted;
  }

  set(loop, value, rate = 0.15) {
    const l = this.loops[loop];
    if (l) l.gain.gain.setTargetAtTime(value, this.ctx.currentTime, rate);
  }

  // Каждый кадр: громкость/тон петель по состоянию игры.
  update(dt, s) {
    if (!this.ctx || this.ctx.state !== 'running') return;
    const t = this.ctx.currentTime;
    const v = s.busSpeed || 0;
    const throttle = clamp((s.busAccel || 0) / 0.9, 0, 1);
    const engineOn = s.busNear ? 1 : 0;
    const e = this.loops.engine;
    if (e) {
      const f = 34 + v * 2.4 + throttle * 9;
      if (e.o1) { e.o1.frequency.setTargetAtTime(f, t, 0.2); e.o2.frequency.setTargetAtTime(f * 0.5, t, 0.2); e.filter.frequency.setTargetAtTime(320 + throttle * 300 + v * 15, t, 0.2); }
      if (e.src && e.file) e.src.playbackRate.setTargetAtTime(0.8 + v / 25 + throttle * 0.1, t, 0.2);
      this.set('engine', engineOn * (0.05 + throttle * 0.035 + v * 0.0015) * (s.inside ? 1 : 0.8));
    }
    const road = this.loops.road;
    if (road?.filter) road.filter.frequency.setTargetAtTime(180 + v * 22, t, 0.3);
    this.set('road', engineOn * clamp(v / 12, 0, 1) * 0.11);
    this.set('interior', s.inside ? 0.018 : 0);
    this.set('city', s.inside ? 0.012 : 0.03, 0.6);
    this.outside.frequency.setTargetAtTime(s.inside && !s.doorsOpen ? 700 : 9000, t, 0.25);
    const m = this.loops.motor;
    if (m?.o1) m.o1.frequency.setTargetAtTime(150 + (s.chairSpeed || 0) * 110, t, 0.1);
    this.set('motor', clamp((s.chairSpeed || 0) / 1.6, 0, 1) * 0.03, 0.08);
    if (this.loops.birds) this.set('birds', s.outdoorCalm ? 0.3 : 0, 1);
    if (this.loops.music) this.set('music', 0.25, 1);
    if (s.outdoorCalm && !this.buffers.birds) {
      this.birdTimer -= dt;
      if (this.birdTimer <= 0) { this.chirp(); this.birdTimer = 1.5 + Math.random() * 3.5; }
    }
  }

  playFile(name, gain = 1) {
    if (!this.buffers[name]) return false;
    const src = this.ctx.createBufferSource();
    src.buffer = this.buffers[name];
    const g = this.ctx.createGain();
    g.gain.value = gain;
    src.connect(g).connect(this.master);
    src.start();
    return true;
  }

  tone(freq, start, dur, gain, type = 'sine', dest = this.master, glide = null) {
    const c = this.ctx;
    const o = c.createOscillator();
    const g = c.createGain();
    o.type = type;
    o.frequency.setValueAtTime(freq, start);
    if (glide) o.frequency.exponentialRampToValueAtTime(glide, start + dur);
    g.gain.setValueAtTime(0.0001, start);
    g.gain.exponentialRampToValueAtTime(gain, start + 0.01);
    g.gain.exponentialRampToValueAtTime(0.0001, start + dur);
    o.connect(g).connect(dest);
    o.start(start);
    o.stop(start + dur + 0.05);
  }

  // --- разовые звуки ---
  hiss() {
    if (!this.ctx || this.playFile('door')) return;
    const c = this.ctx, t = c.currentTime;
    const src = c.createBufferSource();
    src.buffer = this.noise;
    const f = c.createBiquadFilter();
    f.type = 'highpass'; f.frequency.value = 1800;
    const g = c.createGain();
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(0.5, t + 0.03);
    g.gain.exponentialRampToValueAtTime(0.0001, t + 0.9);
    src.connect(f).connect(g).connect(this.master);
    src.start(t);
    src.stop(t + 1);
  }

  beeps(n = 3) {
    if (!this.ctx || this.playFile('beep')) return;
    const t = this.ctx.currentTime;
    for (let i = 0; i < n; i++) this.tone(1450, t + i * 0.32, 0.16, 0.06, 'square');
  }

  ding() {
    if (!this.ctx || this.playFile('bell')) return;
    const t = this.ctx.currentTime;
    this.tone(1250, t, 1.2, 0.12);
    this.tone(2500, t, 0.7, 0.04);
  }

  chime() {
    if (!this.ctx || this.playFile('chime')) return;
    const t = this.ctx.currentTime;
    [660, 880, 990].forEach((f, i) => this.tone(f, t + i * 0.22, 0.6, 0.07));
  }

  tick() {
    if (!this.ctx || this.playFile('tick', 0.5)) return;
    this.tone(2200, this.ctx.currentTime, 0.02, 0.03, 'square');
  }

  rampMotor(seconds = 2) {
    if (!this.ctx || this.playFile('ramp')) return;
    const t = this.ctx.currentTime;
    this.tone(95, t, seconds, 0.05, 'sawtooth');
    for (let i = 0; i < seconds / 0.6; i++) this.tone(1800, t + i * 0.6, 0.12, 0.035, 'square');
  }

  chirp() {
    const t = this.ctx.currentTime;
    const base = 2600 + Math.random() * 1400;
    const n = 2 + Math.floor(Math.random() * 3);
    for (let i = 0; i < n; i++) this.tone(base, t + i * 0.13, 0.09, 0.018, 'sine', this.master, base * 1.35);
  }
}
