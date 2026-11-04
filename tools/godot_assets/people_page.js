// Состав: мама, водитель и пассажиры автобуса (Ташкент, осень 1975). Сборка, превью и выгрузка GLB.
import * as THREE from 'three';
import { buildPerson, exportGLB } from './people_gen.js';

const buttons = (A, cell, n, v0, v1, col = '#1a1412') => { const [x, y, w, h] = A.rect(cell), c = A.ctx; c.fillStyle = col; for (let i = 0; i < n; i++) { c.beginPath(); c.arc(x + w * 0.5, y + h * (v0 + (v1 - v0) * i / Math.max(1, n - 1)), 2.6 * A.k, 0, Math.PI * 2); c.fill(); } };
const band = (A, cell, v0, v1, col, u0 = 0, u1 = 1) => { const [x, y, w, h] = A.rect(cell); A.ctx.fillStyle = col; A.ctx.fillRect(x + w * u0, y + h * v0, w * (u1 - u0), h * (v1 - v0)); };
const fluff = (A, cell, v0, v1, col, T) => { const [x, y, w, h] = A.rect(cell), c = A.ctx; band(A, cell, v0, v1, col); for (let i = 0; i < 700 * A.k; i++) { c.fillStyle = T.shade(col, T.rr(0.6, 1.5)); c.fillRect(x + T.rnd() * w, y + h * T.rr(v0 - 0.02, v1), 1, 3 * A.k); } };

export const ROSTER = [
  { name: 'mom', seed: 11, pose: 'stand', female: true, height: 1.62, age: 42, atlas: 1024,
    skin: '#e3b697', hair: '#4a2618', hairStyle: 'bun', hairline: 0.24, sideV: 0.46, napeV: 0.66, lips: '#9c3a42', eyes: '#4a3524',
    top: { color: '#5b4a35' }, coat: true, skirtLen: 1.3, skirt: { color: '#5b4a35' }, legs: '#c7a387', shoes: '#2b1d16', heels: true,
    bag: 'hang', bagColor: '#1b1614', hands: { right: [0.29, 1.74, -0.04] },
    decor: (A, T) => { fluff(A, 'top', 0.84, 1.0, '#3a2a1e', T); buttons(A, 'top', 4, 0.12, 0.72); buttons(A, 'skirt', 3, 0.06, 0.5); band(A, 'top', 0.08, 0.13, '#3b2e22'); } },
  { name: 'driver', seed: 12, pose: 'sit', height: 1.76, age: 46, skin: '#c69772', hair: '#1f1712', hairStyle: 'short', mustache: '#1a120d', stubble: true,
    top: { color: '#4b5866' }, bottom: { color: '#2d3137' }, shoes: '#1b1714', floor: -0.385, footFwd: 0.6,
    hands: { right: [0.19, 0.32, -0.33], left: [-0.19, 0.32, -0.33] },
    decor: (A) => { band(A, 'top', 0.9, 1.0, '#a9c2d8', 0.38, 0.62); } },
  { name: 'elder', seed: 13, pose: 'sit', height: 1.70, age: 72, skin: '#b6865f', hair: '#d6d4cd', hairStyle: 'none', hairline: 0.3, beard: '#e9e7e1', brow: '#d0cec8',
    hat: 'doppi', hatColor: '#141414', top: { stripes: ['#1d3461', '#2e6a4e', '#1d3461', '#6d2a3a', '#1d3461'], width: 5 }, coat: true, skirtLen: 1.45,
    skirt: { stripes: ['#1d3461', '#2e6a4e', '#1d3461', '#6d2a3a', '#1d3461'], width: 5 }, legs: '#2b2b2b', shoes: '#16110d', belt: true, bagColor: '#6b4a2a', hands: { right: 'knee', left: 'knee' },
    decor: (A, T) => {      // чустская тюбетейка: чёрная с белыми «перчиками»
      const [x, y, w, h] = A.rect('hat'), c = A.ctx; c.fillStyle = '#121212'; c.fillRect(x, y, w, h); c.fillStyle = '#f2f0ea';
      for (let i = 0; i < 4; i++) { const cx = x + w * (0.125 + i * 0.25), cy = y + h * 0.55; c.beginPath(); c.moveTo(cx, cy - 18 * A.k); c.quadraticCurveTo(cx + 14 * A.k, cy, cx + 2 * A.k, cy + 16 * A.k); c.quadraticCurveTo(cx - 8 * A.k, cy + 6 * A.k, cx, cy - 18 * A.k); c.fill(); }
      c.fillRect(x, y + h * 0.9, w, 3 * A.k); } },
  { name: 'grandma', seed: 14, pose: 'sit', female: true, height: 1.56, age: 66, skin: '#c4976f', hair: '#3a3a3a', hairStyle: 'none', kerchief: true,
    top: { color: '#2a1e38', folds: 2 }, sleeve: { ikat: true }, skirt: { ikat: true }, skirtLen: 1.75, legs: '#3b2a3c', shoes: '#241a14', hands: { right: 'lapCenter', left: 'lapCenter' },
    decor: (A, T) => { const [x, y, w, h] = A.rect('scarf'), c = A.ctx; c.fillStyle = '#f1eee6'; c.fillRect(x, y, w, h); for (let i = 0; i < 70; i++) { c.fillStyle = ['#c2185b', '#2e7d32', '#1565c0'][i % 3]; c.beginPath(); c.arc(x + T.rnd() * w, y + T.rnd() * h, 1.6 * A.k, 0, Math.PI * 2); c.fill(); } } },
  { name: 'schoolgirl', seed: 15, pose: 'sit', female: true, height: 1.36, age: 10, skin: '#e8c3a5', hair: '#3b2616', hairStyle: 'girl', hairline: 0.23, lips: '#c46a6a',
    top: { color: '#5a3922' }, sleeve: { color: '#5a3922' }, skirt: { color: '#5a3922' }, skirtLen: 1.0, legs: '#6a4a36', shoes: '#16110d', hands: { right: 'lap', left: 'lap' },
    decor: (A) => {         // школьная форма: чёрный фартук, белый воротничок, красный галстук
      band(A, 'top', 0.0, 0.82, '#151313', 0.36, 0.64); band(A, 'top', 0.0, 0.82, '#151313', 0.12, 0.16); band(A, 'top', 0.0, 0.82, '#151313', 0.84, 0.88);
      band(A, 'top', 0.9, 1.0, '#f4f1ea', 0.33, 0.67);
      const [x, y, w, h] = A.rect('top'), c = A.ctx; c.fillStyle = '#c62828'; c.beginPath(); c.moveTo(x + w * 0.44, y + h * 0.9); c.lineTo(x + w * 0.56, y + h * 0.9); c.lineTo(x + w * 0.5, y + h * 0.7); c.fill();
      band(A, 'skirt', 0.0, 1.0, '#151313', 0.38, 0.62); band(A, 'scarf', 0, 1, '#f7f7f4'); } },
  { name: 'worker', seed: 16, pose: 'sit', height: 1.74, age: 38, skin: '#e0b192', hair: '#6b4a2e', hairStyle: 'short', stubble: true, hat: 'cap', hatColor: '#4b4b4b',
    top: { color: '#3d4347' }, bottom: { color: '#2a2c31' }, shoes: '#1b1a19', paper: true, hands: { right: [0.13, 0.29, -0.30], left: [-0.13, 0.29, -0.30] },
    decor: (A) => { const [x, y, w, h] = A.rect('paper'), c = A.ctx; c.fillStyle = '#e8e2d2'; c.fillRect(x, y, w, h); c.fillStyle = '#1b1b1b'; c.font = `bold ${16 * A.k}px serif`; c.fillText('ПРАВДА', x + 14 * A.k, y + 22 * A.k);
      c.fillStyle = '#6f6a62'; for (let r = 0; r < 14; r++) for (let col = 0; col < 3; col++) c.fillRect(x + (8 + col * 40) * A.k, y + (34 + r * 6.4) * A.k, 34 * A.k, 2 * A.k);
      band(A, 'top', 0.88, 1.0, '#d9d6ce', 0.42, 0.58); } },
  { name: 'student', seed: 17, pose: 'sit', height: 1.78, age: 19, skin: '#e7bf9f', hair: '#5a3a20', hairStyle: 'longm', hairline: 0.22, sideV: 0.55, napeV: 0.72,
    top: { color: '#7a4a28', weave: false, folds: 2 }, sleeve: { color: '#7a4a28', weave: false }, bottom: { color: '#384054' }, shoes: '#2a2a2a', hands: { right: 'lap', left: 'lap' },
    decor: (A, T) => { for (const cell of ['top', 'sleeve']) { const [x, y, w, h] = A.rect(cell), c = A.ctx; c.globalAlpha = 0.18; c.fillStyle = '#000'; for (let i = 0; i < w; i += 4 * A.k) c.fillRect(x + i, y, 1.5 * A.k, h); c.globalAlpha = 1; } band(A, 'top', 0.0, 0.06, '#5f391d'); } },
  { name: 'woman', seed: 18, pose: 'sit', female: true, height: 1.65, age: 27, skin: '#ebc5a6', hair: '#b88a50', hairStyle: 'perm', hairline: 0.22, sideV: 0.6, napeV: 0.72, lips: '#b0303c', eyes: '#3d5a6a',
    top: { color: '#97302a' }, coat: true, skirt: { color: '#34343e' }, skirtLen: 1.0, legs: '#d6b498', shoes: '#2a1a14', heels: true, bag: 'lap', bagColor: '#6a3a1e', hands: { right: 'lapCenter', left: 'lapCenter' },
    decor: (A) => { buttons(A, 'top', 3, 0.3, 0.7, '#2a0e0c'); band(A, 'top', 0.86, 1.0, '#7d2520'); } },
  { name: 'hatman', seed: 19, pose: 'sit', height: 1.75, age: 53, skin: '#d9ab8a', hair: '#5b5148', hairStyle: 'short', hat: 'fedora', hatColor: '#3b3833',
    top: { color: '#b3a284' }, coat: true, bottom: { color: '#3a3939' }, shoes: '#1a1612', hands: { right: 'lap', left: 'lap' },
    decor: (A) => { band(A, 'top', 0.3, 0.36, '#9a8a6c'); band(A, 'top', 0.86, 1.0, '#a39274'); band(A, 'top', 0.92, 1.0, '#3a3a40', 0.44, 0.56); } },
];

// ---- превью
let renderer, scene;
function setupPreview(W, H) {
  renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true }); renderer.setSize(W, H);
  renderer.outputColorSpace = THREE.SRGBColorSpace; renderer.toneMapping = THREE.ACESFilmicToneMapping; document.body.appendChild(renderer.domElement);
  scene = new THREE.Scene(); scene.background = new THREE.Color('#a9b2b8');
  scene.add(new THREE.HemisphereLight(0xe8eef4, 0x5d5a55, 1.7));
  const sun = new THREE.DirectionalLight(0xfff0dc, 1.6); sun.position.set(-2, 4, -3); scene.add(sun);
  const floor = new THREE.Mesh(new THREE.PlaneGeometry(40, 40), new THREE.MeshStandardMaterial({ color: '#4a4744', roughness: 1 })); floor.rotation.x = -Math.PI / 2; scene.add(floor);
}
window.run = async (names) => {
  setupPreview(1600, 700);
  const out = {}, stats = {};
  let i = 0;
  for (const spec of ROSTER) {
    if (names && !names.includes(spec.name)) continue;
    const person = buildPerson({ ...spec });
    stats[spec.name] = Math.round(person.userData.tris);
    out[spec.name] = await exportGLB(person);
    const holder = new THREE.Group(); holder.position.set((i - 4) * 0.85, 0, 0); i++;
    if (spec.pose !== 'stand') {
      const seatH = -(spec.floor ?? -0.486);
      const seat = new THREE.Mesh(new THREE.BoxGeometry(0.44, 0.06, 0.42), new THREE.MeshStandardMaterial({ color: '#6a2a22' })); seat.position.set(0, seatH - 0.03, 0); holder.add(seat);
      const back = new THREE.Mesh(new THREE.BoxGeometry(0.44, 0.5, 0.06), new THREE.MeshStandardMaterial({ color: '#6a2a22' })); back.position.set(0, seatH + 0.3, 0.25); back.rotation.x = -0.2; holder.add(back);
      person.position.y = seatH;
    }
    holder.add(person); scene.add(holder);
  }
  const shots = [];
  for (const [p, t, fov] of [[[0, 1.25, -4.6], [0, 0.95, 0], 44], [[3.2, 1.6, -3.4], [0, 0.9, 0], 48], [[0, 1.4, 3.6], [0, 0.9, 0], 48]]) {
    const cam = new THREE.PerspectiveCamera(fov, 1600 / 700, 0.05, 100); cam.position.set(...p); cam.lookAt(...t); renderer.render(scene, cam);
    shots.push(renderer.domElement.toDataURL('image/jpeg', 0.85));
  }
  // крупные планы лиц
  const faces = [];
  for (const h of scene.children.filter(c => c.isGroup)) {
    const head = h.getObjectByName('Head'); if (!head) continue;
    const p = head.getWorldPosition(new THREE.Vector3());
    const cam = new THREE.PerspectiveCamera(30, 1600 / 700, 0.05, 100); cam.position.set(p.x + 0.25, p.y + 0.12, p.z - 0.75); cam.lookAt(p.x, p.y + 0.06, p.z);
    renderer.setViewport(0, 0, 1600, 700); renderer.render(scene, cam); faces.push(renderer.domElement.toDataURL('image/jpeg', 0.85));
  }
  return { glb: out, shots, faces, stats };
};
window.ready = true;
