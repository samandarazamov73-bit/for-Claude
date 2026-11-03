// Помощники для геометрии: слияние мелких деталей в один меш (меньше вызовов отрисовки),
// «ленты» вдоль маршрута (дорога, тротуар, бордюр), коробки с UV в метрах.
import * as THREE from 'three';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';

const _m = new THREE.Matrix4();
const _q = new THREE.Quaternion();
const _e = new THREE.Euler();
const _s = new THREE.Vector3();
const _p = new THREE.Vector3();

export function matrix(x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = 0, sx = 1, sy = 1, sz = 1) {
  return _m.compose(_p.set(x, y, z), _q.setFromEuler(_e.set(rx, ry, rz)), _s.set(sx, sy, sz)).clone();
}

// Приводит геометрию к общему набору атрибутов (position, normal, uv, color), без индекса.
function normalize(geo, color) {
  let g = geo.index ? geo.toNonIndexed() : geo.clone();
  for (const name of Object.keys(g.attributes)) {
    if (!['position', 'normal', 'uv', 'color'].includes(name)) g.deleteAttribute(name);
  }
  if (!g.attributes.normal) g.computeVertexNormals();
  if (!g.attributes.uv) g.setAttribute('uv', new THREE.BufferAttribute(new Float32Array(g.attributes.position.count * 2), 2));
  if (!g.attributes.color || color) {
    const c = new THREE.Color(color ?? 0xffffff);
    const n = g.attributes.position.count;
    const arr = new Float32Array(n * 3);
    for (let i = 0; i < n; i++) { arr[i * 3] = c.r; arr[i * 3 + 1] = c.g; arr[i * 3 + 2] = c.b; }
    g.setAttribute('color', new THREE.BufferAttribute(arr, 3));
  }
  g.clearGroups();
  return g;
}

// Копит детали по материалам, потом сливает: одна деталь = один материал.
export class Batcher {
  constructor() {
    this.parts = new Map();
  }

  add(geometry, mat4, material, color = null) {
    if (!this.parts.has(material)) this.parts.set(material, []);
    const g = normalize(geometry, color);
    if (mat4) g.applyMatrix4(mat4);
    this.parts.get(material).push(g);
    return this;
  }

  build({ castShadow = true, receiveShadow = true, name = 'batch' } = {}) {
    const group = new THREE.Group();
    group.name = name;
    for (const [material, list] of this.parts) {
      if (!list.length) continue;
      const merged = mergeGeometries(list, false);
      merged.computeBoundingSphere();
      const mesh = new THREE.Mesh(merged, material);
      mesh.castShadow = castShadow;
      mesh.receiveShadow = receiveShadow;
      group.add(mesh);
      list.forEach((g) => g.dispose());
    }
    this.parts.clear();
    return group;
  }
}

// Коробка, у которой текстура повторяется каждые `tile` метров на любой грани.
export function boxUV(w, h, d, tile = 1) {
  const g = new THREE.BoxGeometry(w, h, d);
  const uv = g.attributes.uv;
  const sizes = [[d, h], [d, h], [w, d], [w, d], [w, h], [w, h]];
  for (let f = 0; f < 6; f++) {
    for (let v = 0; v < 4; v++) {
      const i = f * 4 + v;
      uv.setXY(i, uv.getX(i) * sizes[f][0] / tile, uv.getY(i) * sizes[f][1] / tile);
    }
  }
  return g;
}

// Поверхность, протянутая вдоль маршрута. profile — точки сечения [смещение вправо, высота],
// слева направо; нормаль смотрит «вверх/внутрь» по правилу (dl, dy) -> (−dy, dl).
export function ribbon(route, s0, s1, profile, { step = 2, uScale = 1, vScale = 1, uFromLateral = true } = {}) {
  const rows = Math.max(2, Math.ceil((s1 - s0) / step) + 1);
  const cols = profile.length;
  const pos = new Float32Array(rows * cols * 3);
  const uv = new Float32Array(rows * cols * 2);
  const cum = [0];
  for (let j = 1; j < cols; j++) cum.push(cum[j - 1] + Math.hypot(profile[j][0] - profile[j - 1][0], profile[j][1] - profile[j - 1][1]));
  for (let i = 0; i < rows; i++) {
    const s = s0 + ((s1 - s0) * i) / (rows - 1);
    const q = route.sample(s);
    for (let j = 0; j < cols; j++) {
      const [lat, y] = profile[j];
      const k = (i * cols + j) * 3;
      pos[k] = q.x + q.rx * lat;
      pos[k + 1] = y;
      pos[k + 2] = q.z + q.rz * lat;
      const u = uFromLateral ? lat : cum[j];
      uv[(i * cols + j) * 2] = u / uScale;
      uv[(i * cols + j) * 2 + 1] = s / vScale;
    }
  }
  const idx = [];
  for (let i = 0; i < rows - 1; i++) {
    for (let j = 0; j < cols - 1; j++) {
      const a = i * cols + j, b = a + 1, c = a + cols, d = c + 1;
      idx.push(a, b, c, b, d, c);
    }
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
  g.setAttribute('uv', new THREE.BufferAttribute(uv, 2));
  g.setIndex(idx);
  g.computeVertexNormals();
  return g;
}

// Прерывистая разметка вдоль маршрута (штрихи).
export function dashes(route, s0, s1, lateral, { dash = 3, gap = 6, width = 0.15, y = 0.012 } = {}) {
  const list = [];
  for (let s = s0; s < s1 - dash; s += dash + gap) {
    list.push(ribbon(route, s, s + dash, [[lateral - width / 2, y], [lateral + width / 2, y]], { step: dash }));
  }
  return list.length ? mergeGeometries(list.map((g) => g.toNonIndexed()), false) : null;
}

// Стены и крыша здания: UV стен в «пролётах» по 3 м, чтобы окна совпадали с этажами.
export function buildingParts(w, h, d, bay = 3) {
  const walls = [];
  const face = (width, rotY, ox, oz) => {
    const g = new THREE.PlaneGeometry(width, h);
    const uv = g.attributes.uv;
    for (let i = 0; i < uv.count; i++) uv.setXY(i, uv.getX(i) * width / bay, uv.getY(i) * h / bay);
    g.applyMatrix4(matrix(ox, h / 2, oz, 0, rotY, 0));
    walls.push(g);
  };
  face(w, 0, 0, d / 2);
  face(w, Math.PI, 0, -d / 2);
  face(d, Math.PI / 2, w / 2, 0);
  face(d, -Math.PI / 2, -w / 2, 0);
  const roof = new THREE.PlaneGeometry(w, d);
  roof.applyMatrix4(matrix(0, h, 0, -Math.PI / 2));
  return { walls: mergeGeometries(walls, false), roof };
}
