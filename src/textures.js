// Процедурные текстуры (пока нет настоящих). Каждую можно заменить файлом
// из assets/textures — см. assets.js.
import * as THREE from 'three';
import { rng } from './utils.js';

function canvas(w, h) {
  const c = document.createElement('canvas');
  c.width = w;
  c.height = h;
  return [c, c.getContext('2d')];
}

export function toTexture(c, { repeat = true, srgb = true } = {}) {
  const t = new THREE.CanvasTexture(c);
  if (srgb) t.colorSpace = THREE.SRGBColorSpace;
  if (repeat) t.wrapS = t.wrapT = THREE.RepeatWrapping;
  t.anisotropy = 8;
  return t;
}

function noise(ctx, w, h, count, colors, sizeMin, sizeMax, seed) {
  const r = rng(seed);
  for (let i = 0; i < count; i++) {
    ctx.fillStyle = r.pick(colors);
    const s = r.range(sizeMin, sizeMax);
    ctx.fillRect(r() * w, r() * h, s, s);
  }
}

export function asphalt() {
  const [c, x] = canvas(512, 512);
  x.fillStyle = '#4a4d51';
  x.fillRect(0, 0, 512, 512);
  noise(x, 512, 512, 9000, ['#3d4044', '#55585c', '#45484c', '#5c5f63'], 1, 3, 11);
  const r = rng(5);
  for (let i = 0; i < 6; i++) { // заплатки
    x.fillStyle = 'rgba(30,32,35,0.25)';
    x.fillRect(r() * 512, r() * 512, r.range(40, 140), r.range(30, 90));
  }
  return toTexture(c);
}

export function paving() {
  const [c, x] = canvas(256, 256);
  x.fillStyle = '#b9b4ab';
  x.fillRect(0, 0, 256, 256);
  noise(x, 256, 256, 2500, ['#aca79e', '#c4bfb6', '#b2ada4'], 1, 2, 3);
  x.strokeStyle = '#8f8a82';
  x.lineWidth = 3;
  for (let i = 0; i <= 4; i++) {
    x.beginPath(); x.moveTo(i * 64, 0); x.lineTo(i * 64, 256); x.stroke();
    x.beginPath(); x.moveTo(0, i * 64); x.lineTo(256, i * 64); x.stroke();
  }
  return toTexture(c);
}

export function grass() {
  const [c, x] = canvas(256, 256);
  x.fillStyle = '#5e8a3a';
  x.fillRect(0, 0, 256, 256);
  noise(x, 256, 256, 7000, ['#557f33', '#6a9845', '#4f7530', '#73a04d'], 1, 3, 7);
  return toTexture(c);
}

// Один «пролёт» фасада: этаж 3 м × окно. Стена белая — цвет здания задаётся вершинами.
export function facade(variant = 0) {
  const [c, x] = canvas(128, 128);
  x.fillStyle = '#ffffff';
  x.fillRect(0, 0, 128, 128);
  noise(x, 128, 128, 500, ['#f1f1f1', '#e8e8e8'], 1, 2, 20 + variant);
  const wx = variant === 1 ? 18 : 30, ww = variant === 1 ? 92 : 68;
  x.fillStyle = '#d0d3d6';
  x.fillRect(wx - 5, 26, ww + 10, 70);
  const g = x.createLinearGradient(0, 30, 0, 92);
  g.addColorStop(0, '#5c7a96');
  g.addColorStop(1, '#2a3d52');
  x.fillStyle = g;
  x.fillRect(wx, 30, ww, 62);
  x.fillStyle = 'rgba(255,255,255,0.18)';
  x.beginPath(); x.moveTo(wx, 30); x.lineTo(wx + ww * 0.4, 30); x.lineTo(wx, 70); x.fill();
  x.fillStyle = '#d0d3d6';
  x.fillRect(wx + ww / 2 - 2, 30, 4, 62);
  x.fillStyle = '#c4c7ca';
  x.fillRect(wx - 8, 96, ww + 16, 6);
  return toTexture(c);
}

export function concrete() {
  const [c, x] = canvas(128, 128);
  x.fillStyle = '#a4a6a8';
  x.fillRect(0, 0, 128, 128);
  noise(x, 128, 128, 1500, ['#999b9d', '#afb1b3'], 1, 2, 9);
  return toTexture(c);
}

export function busSeat() {
  const [c, x] = canvas(64, 64);
  x.fillStyle = '#23407a';
  x.fillRect(0, 0, 64, 64);
  noise(x, 64, 64, 400, ['#e04a4a', '#f2c84b', '#3a64b8', '#1a2f5c'], 1, 3, 4);
  return toTexture(c);
}

export function busFloor() {
  const [c, x] = canvas(128, 128);
  x.fillStyle = '#5b5f63';
  x.fillRect(0, 0, 128, 128);
  noise(x, 128, 128, 1800, ['#53575b', '#64686c', '#6b6f73'], 1, 2, 12);
  return toTexture(c);
}

// Табличка/вывеска с текстом. Возвращает текстуру и пропорцию.
export function textSign(text, { w = 512, h = 128, bg = '#1d5fa8', fg = '#ffffff', font = 'bold 64px sans-serif', border = null, sub = null } = {}) {
  const [c, x] = canvas(w, h);
  x.fillStyle = bg;
  x.fillRect(0, 0, w, h);
  if (border) {
    x.strokeStyle = border;
    x.lineWidth = 8;
    x.strokeRect(4, 4, w - 8, h - 8);
  }
  x.fillStyle = fg;
  x.textAlign = 'center';
  x.textBaseline = 'middle';
  x.font = font;
  fitText(x, text, w - 30, font);
  x.fillText(text, w / 2, sub ? h * 0.38 : h / 2);
  if (sub) {
    x.font = `${Math.round(h * 0.2)}px sans-serif`;
    x.fillText(sub, w / 2, h * 0.75);
  }
  return toTexture(c, { repeat: false });
}

function fitText(x, text, maxW, font) {
  let size = parseInt(font.match(/(\d+)px/)[1], 10);
  while (size > 12 && x.measureText(text).width > maxW) {
    size -= 2;
    x.font = font.replace(/\d+px/, `${size}px`);
  }
}

// Табло в салоне / маршрутоуказатель: перерисовывается при смене текста.
export class LedBoard {
  constructor(w = 512, h = 64) {
    [this.canvas, this.ctx] = canvas(w, h);
    this.texture = toTexture(this.canvas, { repeat: false });
    this.text = null;
  }

  set(text, { color = '#ffb020', bg = '#120c04' } = {}) {
    if (text === this.text) return;
    this.text = text;
    const { ctx: x, canvas: c } = this;
    x.fillStyle = bg;
    x.fillRect(0, 0, c.width, c.height);
    x.font = `bold ${Math.round(c.height * 0.62)}px monospace`;
    x.textBaseline = 'middle';
    x.textAlign = 'center';
    fitText(x, text, c.width - 16, x.font);
    x.shadowColor = color;
    x.shadowBlur = 8;
    x.fillStyle = color;
    x.fillText(text, c.width / 2, c.height / 2 + 1);
    x.shadowBlur = 0;
    x.fillStyle = 'rgba(0,0,0,0.35)'; // «точки» матрицы
    for (let i = 0; i < c.width; i += 4) x.fillRect(i, 0, 1, c.height);
    for (let j = 0; j < c.height; j += 4) x.fillRect(0, j, c.width, 1);
    this.texture.needsUpdate = true;
  }
}

export function skyMaterial() {
  return new THREE.ShaderMaterial({
    side: THREE.BackSide,
    depthWrite: false,
    fog: false,
    uniforms: {
      top: { value: new THREE.Color('#3f7cc9') },
      horizon: { value: new THREE.Color('#cfe0ee') },
      sunDir: { value: new THREE.Vector3(0.4, 0.6, -0.5).normalize() },
    },
    vertexShader: `varying vec3 vDir; void main(){ vDir = normalize(position); gl_Position = projectionMatrix * modelViewMatrix * vec4(position,1.0); }`,
    fragmentShader: `uniform vec3 top; uniform vec3 horizon; uniform vec3 sunDir; varying vec3 vDir;
      void main(){ float h = clamp(vDir.y, 0.0, 1.0); vec3 col = mix(horizon, top, pow(h, 0.55));
      float sun = max(dot(normalize(vDir), sunDir), 0.0); col += vec3(1.0,0.9,0.7) * (pow(sun, 600.0) * 3.0 + pow(sun, 12.0) * 0.18);
      if (vDir.y < 0.0) col = horizon * 0.92; gl_FragColor = vec4(col, 1.0);
      #include <tonemapping_fragment>
      #include <colorspace_fragment>
      }`,
  });
}
