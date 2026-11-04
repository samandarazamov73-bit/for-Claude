// Генератор лоу-поли людей (Ташкент, 1975). Оси как в Godot: Y вверх, лицо смотрит в −Z, правая рука в +X.
// Сидящие: начало координат — верх подушки сиденья под человеком. Стоящие: пол между ступнями.
// Узлы в GLB: <имя> → Body (меш) + Head (точка поворота на шее) → HeadMesh.
import * as THREE from 'three';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';
import { GLTFExporter } from 'three/addons/exporters/GLTFExporter.js';

const V = (x, y, z) => new THREE.Vector3(x, y, z);
let rnd = mulberry(1);
function mulberry(a) { return () => { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }
const rr = (a, b) => a + (b - a) * rnd();

// ---------------------------------------------------------------- атлас -----
const CELLS = {
  head: [0, 0, 256, 256], hair: [256, 0, 128, 128], skin: [384, 0, 128, 128],
  top: [256, 128, 128, 128], sleeve: [384, 128, 128, 128],
  bottom: [0, 256, 128, 128], skirt: [128, 256, 128, 128], shoes: [256, 256, 128, 128], hat: [384, 256, 128, 128],
  legs: [0, 384, 128, 128], bag: [128, 384, 128, 128], scarf: [256, 384, 128, 128], paper: [384, 384, 128, 128],
};
class Atlas {
  constructor(size) {
    this.size = size; this.k = size / 512;
    this.canvas = document.createElement('canvas'); this.canvas.width = this.canvas.height = size;
    this.ctx = this.canvas.getContext('2d');
  }
  rect(name) { const [x, y, w, h] = CELLS[name]; const k = this.k; return [x * k, y * k, w * k, h * k]; }
  uv(name, u, v) { const [x, y, w, h] = this.rect(name), m = 3 * this.k; return [(x + m + u * (w - 2 * m)) / this.size, (y + m + v * (h - 2 * m)) / this.size]; }
}
const css = c => '#' + new THREE.Color(c).getHexString();
function shade(c, f) { const k = new THREE.Color(c); return '#' + k.multiplyScalar(f).getHexString(); }

function noiseFill(A, name, base, amt = 0.07, density = 1.0) {
  const [x, y, w, h] = A.rect(name), c = A.ctx;
  c.fillStyle = css(base); c.fillRect(x, y, w, h);
  const n = Math.floor(w * h * 0.25 * density);
  for (let i = 0; i < n; i++) {
    const f = 1 + rr(-amt, amt); c.fillStyle = shade(base, f);
    c.fillRect(x + Math.floor(rnd() * w), y + Math.floor(rnd() * h), 1, 1);
  }
}
function fabric(A, name, base, { weave = true, folds = 4, amt = 0.08 } = {}) {
  noiseFill(A, name, base, amt);
  const [x, y, w, h] = A.rect(name), c = A.ctx;
  if (weave) { c.globalAlpha = 0.07; c.strokeStyle = '#000'; for (let i = 0; i < h; i += 2 * A.k) { c.beginPath(); c.moveTo(x, y + i); c.lineTo(x + w, y + i); c.stroke(); } c.globalAlpha = 1; }
  for (let i = 0; i < folds; i++) {      // мягкие складки
    const fx = x + rnd() * w, g = c.createLinearGradient(fx - 6 * A.k, 0, fx + 6 * A.k, 0);
    g.addColorStop(0, 'rgba(0,0,0,0)'); g.addColorStop(0.5, 'rgba(0,0,0,0.13)'); g.addColorStop(1, 'rgba(0,0,0,0)');
    c.fillStyle = g; c.fillRect(fx - 6 * A.k, y, 12 * A.k, h);
  }
}
function stripes(A, name, colors, width) {      // полосатый чапан
  const [x, y, w, h] = A.rect(name), c = A.ctx; let i = 0;
  for (let px = 0; px < w; px += width * A.k) { c.fillStyle = css(colors[i++ % colors.length]); c.fillRect(x + px, y, width * A.k, h); }
  c.globalAlpha = 0.25; noiseOver(A, name); c.globalAlpha = 1;
}
function noiseOver(A, name) { const [x, y, w, h] = A.rect(name), c = A.ctx; for (let i = 0; i < w * h * 0.2; i++) { c.fillStyle = rnd() > 0.5 ? '#000' : '#fff'; c.fillRect(x + rnd() * w, y + rnd() * h, 1, 1); } }
function ikat(A, name) {                  // хан-атлас: вертикальные «рваные» полосы
  const [x, y, w, h] = A.rect(name), c = A.ctx, cols = ['#c2185b', '#fbc02d', '#1e88e5', '#43a047', '#f4f1e8', '#7b1fa2'];
  c.fillStyle = '#6a1b4d'; c.fillRect(x, y, w, h);
  let px = 0, i = 0;
  while (px < w) {
    const bw = rr(5, 11) * A.k, col = cols[i++ % cols.length];
    c.fillStyle = col;
    for (let py = 0; py < h; py += 3 * A.k) { const j = Math.sin(py * 0.25 / A.k + i) * 2 * A.k + rr(-1, 1) * A.k; c.fillRect(x + px + j, y + py, bw, 3 * A.k); }
    px += bw + rr(1, 3) * A.k;
  }
  c.globalAlpha = 0.15; noiseOver(A, name); c.globalAlpha = 1;
}

// ---------------------------------------------------------------- геометрия -
// Трубка по сглаженной линии с эллиптическим сечением. pts — точки, rad — [боковой, передний] радиус в каждой.
function tube(A, cell, pts, rad, { segs = 8, per = 4, ref = V(0, 0, -1), cap0 = true, cap1 = true, vRange = [0, 1] } = {}) {
  const curve = new THREE.CatmullRomCurve3(pts, false, 'centripetal');
  const nRings = (pts.length - 1) * per + 1, P = [], N = [], U = [], I = [];
  let Nprev = null;
  const rings = [];
  for (let i = 0; i < nRings; i++) {
    const t = i / (nRings - 1), C = curve.getPoint(t), T = curve.getTangent(t).normalize();
    let Nv;
    if (!Nprev) { Nv = ref.clone().sub(T.clone().multiplyScalar(ref.dot(T))); if (Nv.lengthSq() < 1e-6) Nv = V(0, 1, 0).sub(T.clone().multiplyScalar(T.y)); Nv.normalize(); }
    else { Nv = Nprev.clone().sub(T.clone().multiplyScalar(Nprev.dot(T))).normalize(); }
    Nprev = Nv;
    const B = T.clone().cross(Nv);
    const f = t * (pts.length - 1), j = Math.min(Math.floor(f), pts.length - 2), w = f - j;
    const rB = rad[j][0] * (1 - w) + rad[j + 1][0] * w, rN = rad[j][1] * (1 - w) + rad[j + 1][1] * w;
    rings.push({ C, T, Nv, B, rB, rN });
    for (let k = 0; k <= segs; k++) {
      const a = k / segs * Math.PI * 2, ca = Math.cos(a), sa = Math.sin(a);
      const p = C.clone().addScaledVector(Nv, -ca * rN).addScaledVector(B, sa * rB);
      const n = Nv.clone().multiplyScalar(-ca / rN).addScaledVector(B, sa / rB).normalize();
      P.push(p.x, p.y, p.z); N.push(n.x, n.y, n.z);
      U.push(...A.uv(cell, k / segs, vRange[0] + (vRange[1] - vRange[0]) * t));
    }
  }
  const row = segs + 1;
  for (let i = 0; i < nRings - 1; i++) for (let k = 0; k < segs; k++) {
    const a = i * row + k, b = (i + 1) * row + k, c = (i + 1) * row + k + 1, d = i * row + k + 1;
    I.push(a, b, c, a, c, d);
  }
  const capAt = (ri, sign) => {
    const r = rings[ri], base = P.length / 3, ctr = r.C.clone().addScaledVector(r.T, sign * Math.min(r.rB, r.rN) * 0.6);
    P.push(ctr.x, ctr.y, ctr.z); N.push(r.T.x * sign, r.T.y * sign, r.T.z * sign); U.push(...A.uv(cell, 0.5, sign < 0 ? vRange[0] : vRange[1]));
    for (let k = 0; k < segs; k++) { const p0 = ri * row + k, p1 = ri * row + k + 1; if (sign < 0) I.push(base, p0, p1); else I.push(base, p1, p0); }
  };
  if (cap0) capAt(0, -1);
  if (cap1) capAt(nRings - 1, 1);
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(P, 3));
  g.setAttribute('normal', new THREE.Float32BufferAttribute(N, 3));
  g.setAttribute('uv', new THREE.Float32BufferAttribute(U, 2));
  g.setIndex(I);
  return g;
}

// Эллипсоид: центр, радиусы, поворот (Euler), UV — вся клетка.
function blob(A, cell, c, r, rot = [0, 0, 0], ws = 10, hs = 6) {
  const g = new THREE.SphereGeometry(1, ws, hs);
  g.scale(r[0], r[1], r[2]); g.rotateX(rot[0]); g.rotateY(rot[1]); g.rotateZ(rot[2]); g.translate(c.x, c.y, c.z);
  const uv = g.attributes.uv; for (let i = 0; i < uv.count; i++) { const t = A.uv(cell, uv.getX(i), 1 - uv.getY(i)); uv.setXY(i, t[0], t[1]); }
  g.computeVertexNormals();
  return g;
}
function box(A, cell, c, s, rot = [0, 0, 0]) {
  const g = new THREE.BoxGeometry(s[0], s[1], s[2]);
  g.rotateX(rot[0]); g.rotateY(rot[1]); g.rotateZ(rot[2]); g.translate(c.x, c.y, c.z);
  const uv = g.attributes.uv; for (let i = 0; i < uv.count; i++) { const t = A.uv(cell, uv.getX(i), 1 - uv.getY(i)); uv.setXY(i, t[0], t[1]); }
  return g;
}
// Ориентированный эллипсоид вдоль направления dir (кисти, ступни).
function blobAlong(A, cell, c, dir, up, r, ws = 8, hs = 5) {
  const g = new THREE.SphereGeometry(1, ws, hs); g.scale(r[0], r[1], r[2]);
  const z = dir.clone().normalize().negate(), x = up.clone().cross(z).normalize(), y = z.clone().cross(x).normalize();
  g.applyMatrix4(new THREE.Matrix4().makeBasis(x, y, z)); g.translate(c.x, c.y, c.z);
  const uv = g.attributes.uv; for (let i = 0; i < uv.count; i++) { const t = A.uv(cell, uv.getX(i), 1 - uv.getY(i)); uv.setXY(i, t[0], t[1]); }
  g.computeVertexNormals();
  return g;
}

// Оболочка на голове (волосы, платок): сектор сферы, нижняя граница зависит от угла (0 — лоб, π — затылок).
function shell(A, cell, ctr, r, edge, { cols = 16, rows = 7, squash = 1 } = {}) {
  const P = [], N = [], U = [], I = [];
  for (let i = 0; i <= cols; i++) {
    const phi = i / cols * Math.PI * 2, ap = Math.abs(((phi + Math.PI) % (Math.PI * 2)) - Math.PI);
    const tmax = edge(ap);
    for (let j = 0; j <= rows; j++) {
      const th = j / rows * tmax;
      const d = V(Math.sin(th) * Math.sin(phi), Math.cos(th) * squash, -Math.sin(th) * Math.cos(phi));
      const p = ctr.clone().add(V(d.x * r[0], d.y * r[1], d.z * r[2]));
      const n = V(d.x / r[0], d.y / r[1], d.z / r[2]).normalize();
      P.push(p.x, p.y, p.z); N.push(n.x, n.y, n.z); U.push(...A.uv(cell, i / cols, j / rows));
    }
  }
  const R = rows + 1;
  for (let i = 0; i < cols; i++) for (let j = 0; j < rows; j++) {
    const a = i * R + j, b = i * R + j + 1, c = (i + 1) * R + j + 1, d = (i + 1) * R + j;
    I.push(a, b, c, a, c, d);
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(P, 3)); g.setAttribute('normal', new THREE.Float32BufferAttribute(N, 3)); g.setAttribute('uv', new THREE.Float32BufferAttribute(U, 2)); g.setIndex(I);
  return g;
}
const lerpEdge = keys => ap => { for (let i = 1; i < keys.length; i++) if (ap <= keys[i][0]) { const [a0, t0] = keys[i - 1], [a1, t1] = keys[i]; return t0 + (t1 - t0) * (ap - a0) / (a1 - a0); } return keys[keys.length - 1][1]; };
const PI = Math.PI;

// Двухзвенная ИК: плечо/бедро A, цель T, длины, направление «колена/локтя».
function ik2(A, T, l1, l2, pole) {
  const d = T.clone().sub(A); let L = d.length(); const maxL = (l1 + l2) * 0.995;
  if (L > maxL) L = maxL;
  const dir = d.normalize(), a = (l1 * l1 - l2 * l2 + L * L) / (2 * L), h = Math.sqrt(Math.max(0, l1 * l1 - a * a));
  const p = pole.clone().sub(dir.clone().multiplyScalar(pole.dot(dir))).normalize();
  return [A.clone().addScaledVector(dir, a).addScaledVector(p, h), A.clone().addScaledVector(dir, L)];
}

// ---------------------------------------------------------------- голова ----
const HEAD = { w: 0.079, h: 0.118, d: 0.1 };
function headGeo(A, s, female, hc) {
  const hw = HEAD.w * s * (female ? 0.96 : 1), hh = HEAD.h * s * (female ? 0.97 : 1), hd = HEAD.d * s * (female ? 0.97 : 1);
  let g = new THREE.SphereGeometry(1, 18, 12); g.rotateY(PI / 2);      // шов — на затылке
  const p = g.attributes.position;
  for (let i = 0; i < p.count; i++) {
    let x = p.getX(i), y = p.getY(i), z = p.getZ(i);
    if (y < 0) { const t = Math.pow(-y, 1.4); x *= 1 - 0.30 * t; if (z > 0) z *= 1 - 0.45 * t; else z *= 1 - 0.12 * t; }   // челюсть уже
    if (z < 0 && y > 0.15) z *= 0.94;                                        // лоб площе
    if (z < 0 && y < -0.55) { z -= 0.06 * (1 + y); }                         // подбородок вперёд
    if (z > 0 && y > -0.2) z *= 1.04;                                       // затылок
    p.setXYZ(i, x * hw, y * hh, z * hd);
  }
  g.translate(hc.x, hc.y, hc.z);
  g.computeVertexNormals();
  g = g.toNonIndexed();
  // UV: «лицевая» развёртка — вокруг головы, лицо в центре клетки и крупнее (sin от половины угла).
  const P2 = g.attributes.position, uv = g.attributes.uv, top = hc.y + hh, bot = hc.y - hh;
  const us = [];
  for (let i = 0; i < P2.count; i++) {
    const ang = Math.atan2(P2.getX(i) - hc.x, -(P2.getZ(i) - hc.z));
    us.push(0.5 + 0.5 * Math.sin(ang / 2));
  }
  for (let t = 0; t < P2.count; t += 3) {     // треугольники через шов на затылке
    const a = us.slice(t, t + 3);
    if (Math.max(...a) - Math.min(...a) > 0.5) for (let k = 0; k < 3; k++) if (us[t + k] < 0.5) us[t + k] = 0.999;
  }
  for (let i = 0; i < P2.count; i++) { const t = A.uv('head', us[i], (top - P2.getY(i)) / (top - bot)); uv.setXY(i, t[0], t[1]); }
  const parts = [g];
  // нос и уши
  const noseUV = A.uv('head', 0.5, 0.57);
  const nose = new THREE.ConeGeometry(0.012 * s, 0.034 * s, 4); nose.rotateY(PI / 4); nose.scale(1, 1, 0.9);
  nose.rotateX(-PI / 2 - 0.5); nose.translate(hc.x, hc.y - 0.016 * s, hc.z - hd * 0.93);
  nose.computeVertexNormals();
  const nuv = nose.attributes.uv; for (let i = 0; i < nuv.count; i++) nuv.setXY(i, noseUV[0], noseUV[1]);
  parts.push(nose.toNonIndexed());
  for (const sx of [-1, 1]) parts.push(blob(A, 'skin', V(hc.x + sx * hw * 0.97, hc.y - 0.005 * s, hc.z + 0.008 * s), [0.012 * s, 0.03 * s, 0.022 * s], [0, 0, 0], 8, 5).toNonIndexed());
  return { parts, hw, hh, hd };
}

function paintHead(A, o) {
  const [x0, y0, w, h] = A.rect('head'), c = A.ctx, k = A.k;
  const X = deg => x0 + (0.5 + 0.5 * Math.sin(deg * PI / 360)) * w, Y = v => y0 + v * h;
  noiseFill(A, 'head', o.skin, 0.035, 0.6);
  const ell = (deg, v, rxDeg, ry, col, a = 1) => { c.globalAlpha = a; c.fillStyle = col; c.beginPath(); c.ellipse(X(deg), Y(v), Math.abs(X(deg + rxDeg) - X(deg)), ry * h, 0, 0, PI * 2); c.fill(); c.globalAlpha = 1; };
  const soft = (deg, v, rDeg, col, a) => { const cx = X(deg), cy = Y(v), r = Math.abs(X(deg + rDeg) - cx); const g = c.createRadialGradient(cx, cy, 0, cx, cy, r); g.addColorStop(0, col); g.addColorStop(1, 'rgba(0,0,0,0)'); c.globalAlpha = a; c.fillStyle = g; c.fillRect(cx - r, cy - r, 2 * r, 2 * r); c.globalAlpha = 1; };
  // щёки, глазницы, тень под носом
  if (o.female) for (const s of [-1, 1]) soft(s * 38, 0.63, 16, '#d9786a', 0.35);
  for (const s of [-1, 1]) soft(s * 21, 0.47, 13, shade(o.skin, 0.7), 0.5);
  soft(0, 0.66, 8, shade(o.skin, 0.75), 0.4);
  soft(0, 0.53, 5, shade(o.skin, 0.88), 0.5);
  // брови
  c.strokeStyle = css(o.brow || shade(o.hair, 0.9)); c.lineWidth = (o.female ? 1.6 : 2.6) * k; c.lineCap = 'round';
  for (const s of [-1, 1]) { c.beginPath(); c.moveTo(X(s * 9), Y(0.405)); c.quadraticCurveTo(X(s * 21), Y(o.female ? 0.385 : 0.395), X(s * 33), Y(0.415)); c.stroke(); }
  // глаза
  for (const s of [-1, 1]) {
    ell(s * 21, 0.47, 7.5, 0.016, '#ece8e0');
    ell(s * 20.5, 0.47, 3.6, 0.017, css(o.eyes || '#3b2a1e'));
    ell(s * 20.5, 0.47, 1.6, 0.008, '#0b0907');
    c.strokeStyle = '#2a1d15'; c.lineWidth = (o.female ? 2.2 : 1.6) * k;
    c.beginPath(); c.moveTo(X(s * 13), Y(0.468)); c.quadraticCurveTo(X(s * 21), Y(0.448), X(s * 29.5), Y(0.47)); c.stroke();
    c.globalAlpha = 0.35; c.lineWidth = 1 * k; c.beginPath(); c.moveTo(X(s * 14), Y(0.488)); c.quadraticCurveTo(X(s * 21), Y(0.497), X(s * 28), Y(0.486)); c.stroke(); c.globalAlpha = 1;
    if (o.age > 55) { c.globalAlpha = 0.25; c.strokeStyle = shade(o.skin, 0.6); c.lineWidth = 1 * k; for (const dv of [0.51, 0.53]) { c.beginPath(); c.moveTo(X(s * 15), Y(dv)); c.quadraticCurveTo(X(s * 22), Y(dv + 0.01), X(s * 29), Y(dv - 0.01)); c.stroke(); } c.globalAlpha = 1; }
  }
  // ноздри, губы
  for (const s of [-1, 1]) ell(s * 4.5, 0.635, 1.7, 0.006, shade(o.skin, 0.45), 0.8);
  const lip = o.lips || (o.female ? '#a8414a' : shade(o.skin, 0.72));
  ell(0, 0.726, 10.5, 0.017, lip);
  ell(0, 0.742, 8.5, 0.012, shade(lip, 1.08));
  c.strokeStyle = shade(lip, 0.45); c.lineWidth = 1.3 * k; c.beginPath(); c.moveTo(X(-10), Y(0.728)); c.quadraticCurveTo(X(0), Y(0.735), X(10), Y(0.728)); c.stroke();
  if (o.age > 45) { c.globalAlpha = 0.3; c.strokeStyle = shade(o.skin, 0.6); c.lineWidth = 1.2 * k; for (const s of [-1, 1]) { c.beginPath(); c.moveTo(X(s * 9), Y(0.62)); c.quadraticCurveTo(X(s * 15), Y(0.69), X(s * 14), Y(0.75)); c.stroke(); } c.globalAlpha = 1; }
  if (o.mustache) { c.fillStyle = css(o.mustache); c.beginPath(); c.moveTo(X(-14), Y(0.712)); c.quadraticCurveTo(X(0), Y(0.66), X(14), Y(0.712)); c.quadraticCurveTo(X(0), Y(0.70), X(-14), Y(0.712)); c.fill(); }
  if (o.beard) {          // седая борода и усы
    c.fillStyle = css(o.beard);
    c.beginPath(); c.moveTo(X(-62), Y(0.5)); c.lineTo(X(-30), Y(0.6)); c.quadraticCurveTo(X(-14), Y(0.68), X(0), Y(0.69)); c.quadraticCurveTo(X(14), Y(0.68), X(30), Y(0.6)); c.lineTo(X(62), Y(0.5)); c.lineTo(X(62), Y(1)); c.lineTo(X(-62), Y(1)); c.fill();
    ell(0, 0.732, 9, 0.011, lip);
    c.globalAlpha = 0.5; for (let i = 0; i < 260; i++) { c.fillStyle = rnd() > 0.5 ? '#ffffff' : '#9a9a96'; c.fillRect(X(rr(-60, 60)), Y(rr(0.62, 1)), 1 * k, 2 * k); } c.globalAlpha = 1;
  } else if (o.stubble) { c.globalAlpha = 0.18; for (let i = 0; i < 900; i++) { c.fillStyle = '#222'; c.fillRect(X(rr(-55, 55)), Y(rr(0.66, 0.98)), 1, 1); } c.globalAlpha = 1; }
  // волосы на коже головы (под «шапкой» волос, чтобы не было просветов)
  if (o.hair) {
    c.fillStyle = css(o.hair);
    const hl = o.hairline || 0.25;
    c.beginPath(); c.moveTo(X(-180), Y(0)); c.lineTo(X(180), Y(0)); c.lineTo(X(180), Y(o.napeV || 0.62));
    c.lineTo(X(95), Y(o.sideV || 0.42)); c.lineTo(X(60), Y(hl + 0.06)); c.quadraticCurveTo(X(0), Y(hl - 0.03), X(-60), Y(hl + 0.06));
    c.lineTo(X(-95), Y(o.sideV || 0.42)); c.lineTo(X(-180), Y(o.napeV || 0.62)); c.closePath(); c.fill();
    c.globalAlpha = 0.3; for (let i = 0; i < 1400; i++) { c.fillStyle = rnd() > 0.5 ? shade(o.hair, 1.35) : shade(o.hair, 0.6); c.fillRect(X(rr(-180, 180)), Y(rr(0, hl)), 1, 2 * k); } c.globalAlpha = 1;
  }
}
function paintHair(A, col) {
  const [x, y, w, h] = A.rect('hair'), c = A.ctx;
  c.fillStyle = css(col); c.fillRect(x, y, w, h);
  for (let i = 0; i < 900; i++) { c.fillStyle = rnd() > 0.5 ? shade(col, rr(1.15, 1.5)) : shade(col, rr(0.5, 0.8)); c.fillRect(x + rnd() * w, y + rnd() * h, 1, rr(4, 12) * A.k); }
}

// ---------------------------------------------------------------- человек ---
export function buildPerson(o) {
  rnd = mulberry(o.seed || 7);
  const A = new Atlas(o.atlas || 512);
  const s = o.height / 1.70, F = !!o.female, sit = o.pose !== 'stand';
  // ---- раскраска клеток
  paintHead(A, o);
  paintHair(A, o.hair || '#2b1d14');
  noiseFill(A, 'skin', o.skin, 0.04, 0.5);
  const paintCloth = (cell, spec) => { if (!spec) return; if (spec.ikat) ikat(A, cell); else if (spec.stripes) stripes(A, cell, spec.stripes, spec.width || 6); else fabric(A, cell, spec.color, spec); };
  paintCloth('top', o.top); paintCloth('sleeve', o.sleeve || o.top); paintCloth('bottom', o.bottom); paintCloth('skirt', o.skirt || o.top);
  noiseFill(A, 'shoes', o.shoes || '#2a2420', 0.12); noiseFill(A, 'legs', o.legs || o.skin, 0.03, 0.4);
  noiseFill(A, 'bag', o.bagColor || '#1e1a18', 0.1); noiseFill(A, 'hat', o.hatColor || '#222', 0.08);
  if (o.decor) o.decor(A, { css, shade, rr, rnd });
  // ---- скелет
  const shW = (F ? 0.168 : 0.186) * s, upA = 0.29 * s, foA = 0.255 * s, th = 0.44 * s, sh = 0.43 * s, ank = 0.075 * s;
  let P, Wst, Ch, Nk, HP, hipY;
  if (sit) {
    P = V(0, 0.10 * s, 0.075); Wst = V(0, P.y + 0.17 * s, P.z + 0.012); Ch = V(0, P.y + 0.35 * s, P.z + 0.03);
    Nk = V(0, P.y + 0.525 * s, P.z + 0.045); HP = V(0, Nk.y + 0.045 * s, Nk.z - 0.008);
  } else {
    P = V(0, 0.94 * s, 0.0); Wst = V(0, 1.08 * s, 0.006); Ch = V(0, 1.26 * s, 0.012); Nk = V(0, 1.435 * s, 0.018); HP = V(0, Nk.y + 0.045 * s, Nk.z - 0.01);
  }
  if (o.lean) { const l = o.lean; [Ch, Nk, HP].forEach((q, i) => { q.z -= l * (0.5 + i * 0.5); }); }
  const body = [], head = [];
  const g = (geo) => body.push(geo.index ? geo.toNonIndexed() : geo);
  // ---- туловище
  const tw = o.bulk || 1, cw = o.coat ? 0.012 : 0;
  const tr = F
    ? [[0.178 * s + cw, 0.125 * s + cw], [0.132 * s * tw + cw, 0.098 * s * tw + cw], [0.152 * s * tw + cw, 0.112 * s + cw], [0.168 * s + cw, 0.094 * s + cw], [0.078 * s, 0.07 * s]]
    : [[0.165 * s + cw, 0.118 * s + cw], [0.148 * s * tw + cw, 0.108 * s * tw + cw], [0.17 * s * tw + cw, 0.112 * s * tw + cw], [0.19 * s + cw, 0.096 * s + cw], [0.086 * s, 0.075 * s]];
  const shoulderLvl = Ch.clone().lerp(Nk, 0.74);
  g(tube(A, 'top', [P.clone().add(V(0, -0.035 * s, 0)), Wst, Ch, shoulderLvl, Nk], tr, { segs: 14, per: 3, cap1: false }));
  g(tube(A, o.neckCell || 'skin', [Nk.clone().add(V(0, -0.02 * s, 0)), HP.clone().add(V(0, 0.035 * s, 0.004))], [[0.058 * s, 0.056 * s], [0.052 * s, 0.054 * s]], { segs: 10, per: 2 }));
  // ---- ноги
  const legs = [];
  for (const side of [-1, 1]) {
    const H = P.clone().add(V(side * 0.092 * s, -0.01, 0));
    let Ank;
    if (sit) Ank = V(side * (0.115 * s + (o.knees || 0)), (o.floor ?? -0.486) + ank, P.z - (o.footFwd || 0.47) * s);
    else Ank = V(side * 0.095 * s, ank * 0.8, 0.0);
    const [K, A2] = ik2(H, Ank, th, sh, sit ? V(0, 1, -0.6) : V(0, 0.3, -0.25));
    legs.push({ H, K, A: A2, side });
    const legCell = o.skirtLen ? 'legs' : 'bottom';
    const rTh = F && o.skirtLen ? 0.07 * s : 0.082 * s;
    g(tube(A, legCell, [H.clone().add(V(-side * 0.02, 0.035 * s, 0)), H, K, A2], [[rTh, rTh], [rTh, rTh], [0.052 * s, 0.055 * s], [0.036 * s, 0.038 * s]], { segs: 9, per: 3, ref: V(0, 1, 0) }));
    // ботинок
    const fwd = V(0, 0, -1), up = V(0, 1, 0);
    const heel = o.heels && F;
    g(blobAlong(A, 'shoes', A2.clone().add(V(0, -0.035 * s, -0.065 * s)), fwd.clone().add(V(0, heel ? -0.25 : 0, 0)), up, [0.043 * s, 0.038 * s, 0.125 * s], 9, 6));
  }
  // ---- юбка / подол пальто / чапан
  if (o.skirtLen) {
    const L = legs, mid = L[0].K.clone().lerp(L[1].K, 0.5);
    if (sit) {
      const hem = Wst.clone().lerp(mid, 1.0).add(V(0, 0.0, -0.02 * s * (o.skirtLen - 1)));
      const kneeOver = mid.clone().add(V(0, 0.02 * s, -0.03 * s));
      g(tube(A, 'skirt', [Wst.clone().add(V(0, 0.01, 0)), P.clone().add(V(0, 0.035 * s, 0)), P.clone().lerp(kneeOver, 0.5).add(V(0, 0.03 * s, 0)), kneeOver, hem.clone().add(V(0, -0.11 * s * (o.skirtLen - 0.6), -0.03 * s))],
        [[tr[1][0], tr[1][1]], [0.19 * s, 0.13 * s], [0.2 * s, 0.1 * s], [0.205 * s, 0.085 * s], [0.21 * s, 0.05 * s]], { segs: 14, per: 3, cap1: false }));
    } else {
      const kneeY = mid.y, hemY = kneeY - (o.skirtLen - 1) * 0.22 * s;
      g(tube(A, 'skirt', [Wst, P.clone().add(V(0, 0, 0.005)), V(0, (P.y + kneeY) / 2, 0.01), V(0, kneeY, 0.015), V(0, hemY, 0.02)],
        [[tr[1][0], tr[1][1]], [0.188 * s, 0.135 * s], [0.195 * s, 0.15 * s], [0.205 * s, 0.158 * s], [0.218 * s, 0.168 * s]], { segs: 16, per: 3, cap1: false }));
    }
  }
  // ---- руки
  const hands = o.hands || {};
  for (const side of [-1, 1]) {
    const key = side > 0 ? 'right' : 'left';
    const S = shoulderLvl.clone().add(V(side * shW, -0.02 * s, 0.0));
    let Tgt, pole = V(side * 0.6, -0.4, 0.8);
    const L0 = legs.find(l => l.side === side), Lx = legs.find(l => l.side === -side);
    const h = hands[key] || (sit ? 'lap' : 'down');
    if (Array.isArray(h)) Tgt = V(...h);
    else if (h === 'lap') Tgt = L0.H.clone().lerp(L0.K, 0.62).add(V(-side * 0.02 * s, 0.085 * s, 0));
    else if (h === 'lapCenter') Tgt = L0.H.clone().lerp(L0.K, 0.55).lerp(Lx.H.clone().lerp(Lx.K, 0.55), 0.35).add(V(0, 0.1 * s, 0));
    else if (h === 'knee') Tgt = L0.K.clone().add(V(-side * 0.01, 0.06 * s, 0.02 * s));
    else Tgt = S.clone().add(V(side * 0.06 * s, -(upA + foA) * 0.97, 0.03 * s));
    if (Array.isArray(h) && Tgt.y > S.y) pole = V(side * 1, -0.2, 0.5);
    const [E, Wr] = ik2(S, Tgt, upA, foA, pole);
    const sleeveEnd = Wr.clone().lerp(E, 0.04);
    g(tube(A, 'sleeve', [S.clone().add(V(-side * 0.05 * s, 0.01, 0)), S, E, sleeveEnd], [[0.06 * s, 0.058 * s], [0.056 * s, 0.054 * s], [0.045 * s, 0.045 * s], [0.038 * s, 0.038 * s]], { segs: 9, per: 3 }));
    // кисть: «варежка» вдоль предплечья + большой палец
    const fdir = Wr.clone().sub(E).normalize();
    let hdir = fdir.clone(), hup = V(side, 0, 0).cross(fdir).normalize();
    if (h === 'lap' || h === 'lapCenter' || h === 'knee') { hdir = V(-side * 0.25, -0.55, -1).normalize(); hup = V(0, 1, 0); }
    if (hup.lengthSq() < 0.01) hup = V(0, 0, 1);
    const hc = Wr.clone().addScaledVector(hdir, 0.062 * s);
    g(blobAlong(A, 'skin', hc, hdir, hup, [0.044 * s, 0.021 * s, 0.07 * s], 8, 5));
    g(blobAlong(A, 'skin', Wr.clone().addScaledVector(hdir, 0.035 * s).add(V(-side * 0.035 * s, 0.005, 0)), hdir.clone().add(V(-side * 0.6, 0, 0)), hup, [0.016 * s, 0.016 * s, 0.035 * s], 6, 4));
    if (key === 'right') o._rightHand = hc; else o._leftHand = hc;
  }
  // ---- предметы
  if (o.bag === 'hang') g(box(A, 'bag', o._leftHand.clone().add(V(-0.01, -0.17 * s, 0.0)), [0.08 * s, 0.22 * s, 0.30 * s], [0, 0, 0.05]));
  if (o.bag === 'lap') { const m = legs[0].H.clone().lerp(legs[0].K, 0.6).lerp(legs[1].H.clone().lerp(legs[1].K, 0.6), 0.5); g(box(A, 'bag', m.add(V(0, 0.17 * s, 0.03)), [0.28 * s, 0.2 * s, 0.08 * s], [-0.25, 0, 0])); }
  if (o.paper) { const m = o._rightHand.clone().lerp(o._leftHand, 0.5); g(box(A, 'paper', m.add(V(0, 0.13 * s, -0.01)), [0.42 * s, 0.30 * s, 0.006], [0.35, 0, 0])); }
  if (o.belt) g(tube(A, 'bag', [Wst.clone().add(V(0, -0.025 * s, 0)), Wst.clone().add(V(0, 0.025 * s, 0))], [[tr[1][0] + 0.008, tr[1][1] + 0.008], [tr[1][0] + 0.008, tr[1][1] + 0.008]], { segs: 14, per: 1, cap0: false, cap1: false }));
  // ---- голова (отдельный узел: игра поворачивает её)
  const hcLocal = V(0, 0.085 * s, -0.012 * s);
  const H = headGeo(A, s, F, hcLocal);
  H.parts.forEach(p => head.push(p));
  const hr = [H.hw * 1.07, H.hh * 1.05, H.hd * 1.07];
  const hairUp = hcLocal.clone().add(V(0, 0.004 * s, 0.003 * s));
  if (o.hairStyle && o.hairStyle !== 'none') {
    const E = {
      short: lerpEdge([[0, 0.30 * PI], [0.9, 0.36 * PI], [1.4, 0.43 * PI], [2.3, 0.55 * PI], [PI, 0.62 * PI]]),
      longm: lerpEdge([[0, 0.28 * PI], [0.9, 0.38 * PI], [1.4, 0.56 * PI], [2.3, 0.68 * PI], [PI, 0.74 * PI]]),
      bun: lerpEdge([[0, 0.31 * PI], [0.9, 0.38 * PI], [1.4, 0.47 * PI], [2.3, 0.6 * PI], [PI, 0.66 * PI]]),
      perm: lerpEdge([[0, 0.27 * PI], [0.9, 0.42 * PI], [1.4, 0.62 * PI], [2.3, 0.7 * PI], [PI, 0.72 * PI]]),
      girl: lerpEdge([[0, 0.29 * PI], [0.9, 0.4 * PI], [1.4, 0.5 * PI], [2.3, 0.62 * PI], [PI, 0.68 * PI]]),
    }[o.hairStyle];
    const vol = o.hairStyle === 'perm' ? 1.16 : o.hairStyle === 'longm' ? 1.07 : 1.0;
    head.push(shell(A, 'hair', hairUp, hr.map(v => v * vol), E, { cols: 18, rows: 7 }).toNonIndexed());
    if (o.hairStyle === 'bun') head.push(blob(A, 'hair', hcLocal.clone().add(V(0, 0.05 * s, 0.105 * s)), [0.05 * s, 0.045 * s, 0.042 * s], [0, 0, 0], 10, 6).toNonIndexed());
    if (o.hairStyle === 'girl') for (const sx of [-1, 1]) {
      head.push(blob(A, 'hair', hcLocal.clone().add(V(sx * 0.07 * s, -0.04 * s, 0.05 * s)), [0.025 * s, 0.07 * s, 0.025 * s], [0.3, 0, -sx * 0.2], 8, 5).toNonIndexed());
      head.push(blob(A, 'scarf', hcLocal.clone().add(V(sx * 0.075 * s, 0.02 * s, 0.05 * s)), [0.045 * s, 0.04 * s, 0.03 * s], [0, 0, 0], 8, 5).toNonIndexed());    // белые банты
    }
  }
  if (o.kerchief) head.push(shell(A, 'scarf', hairUp, [hr[0] * 1.1, hr[1] * 1.08, hr[2] * 1.1], lerpEdge([[0, 0.33 * PI], [0.9, 0.5 * PI], [1.4, 0.78 * PI], [2.3, 0.86 * PI], [PI, 0.9 * PI]]), { cols: 18, rows: 8 }).toNonIndexed());
  if (o.hat === 'doppi') { const d = new THREE.CylinderGeometry(0.088 * s, 0.1 * s, 0.06 * s, 4, 1, false); d.rotateY(PI / 4); d.translate(hcLocal.x, hcLocal.y + H.hh * 0.74, hcLocal.z + 0.006); const uv = d.attributes.uv; for (let i = 0; i < uv.count; i++) { const t = A.uv('hat', uv.getX(i), 1 - uv.getY(i)); uv.setXY(i, t[0], t[1]); } d.computeVertexNormals(); head.push(d.toNonIndexed()); }
  if (o.hat === 'cap') { head.push(blob(A, 'hat', hcLocal.clone().add(V(0, H.hh * 0.62, -0.012 * s)), [H.hw * 1.15, 0.05 * s, H.hd * 1.12], [0.12, 0, 0], 12, 6).toNonIndexed()); head.push(box(A, 'hat', hcLocal.clone().add(V(0, H.hh * 0.5, -H.hd * 1.08)), [0.13 * s, 0.01 * s, 0.05 * s], [0.3, 0, 0]).toNonIndexed()); }
  if (o.hat === 'fedora') { const cr = new THREE.CylinderGeometry(0.075 * s, 0.088 * s, 0.1 * s, 12, 1, false); cr.scale(1, 1, 1.15); cr.translate(hcLocal.x, hcLocal.y + H.hh * 0.78, hcLocal.z + 0.004); const br = new THREE.CylinderGeometry(0.128 * s, 0.128 * s, 0.008 * s, 16); br.scale(1, 1, 1.12); br.translate(hcLocal.x, hcLocal.y + H.hh * 0.42, hcLocal.z + 0.004);
    [cr, br].forEach(q => { const uv = q.attributes.uv; for (let i = 0; i < uv.count; i++) { const t = A.uv('hat', uv.getX(i), 1 - uv.getY(i)); uv.setXY(i, t[0], t[1]); } q.computeVertexNormals(); head.push(q.toNonIndexed()); }); }
  // ---- сборка
  const tex = new THREE.CanvasTexture(A.canvas); tex.flipY = false; tex.colorSpace = THREE.SRGBColorSpace; tex.userData.mimeType = 'image/jpeg';
  tex.anisotropy = 4;
  const mat = new THREE.MeshStandardMaterial({ map: tex, roughness: 0.88, metalness: 0, name: 'Person_' + o.name });
  const root = new THREE.Group(); root.name = o.name;
  const bodyMesh = new THREE.Mesh(mergeGeometries(body, false), mat); bodyMesh.name = 'Body'; root.add(bodyMesh);
  const headNode = new THREE.Group(); headNode.name = 'Head'; headNode.position.copy(HP); root.add(headNode);
  const headMesh = new THREE.Mesh(mergeGeometries(head, false), mat); headMesh.name = 'HeadMesh'; headNode.add(headMesh);
  root.userData.tris = (bodyMesh.geometry.attributes.position.count + headMesh.geometry.attributes.position.count) / 3;
  return root;
}

export async function exportGLB(root) {
  const res = await new GLTFExporter().parseAsync(root, { binary: true });
  let s = ''; const b = new Uint8Array(res); for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode.apply(null, b.subarray(i, i + 0x8000));
  return btoa(s);
}
