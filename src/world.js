// Город вдоль маршрута + территория больницы. Всё процедурное (заглушки),
// каждую часть можно заменить моделью из assets/.
import * as THREE from 'three';
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';
import { CONFIG, STORY } from './data.js';
import { Batcher, boxUV, buildingParts, dashes, matrix, ribbon } from './geom.js';
import * as TX from './textures.js';
import { rng } from './utils.js';

const R = CONFIG.road;
const SIDE_OUT = R.halfWidth + R.sidewalk; // внешний край тротуара

export function createMaterials(textures = {}) {
  const tex = (key, fallback, repeat = 1) => {
    const t = textures[key] || fallback();
    t.wrapS = t.wrapT = THREE.RepeatWrapping;
    if (repeat !== 1) t.repeat.set(repeat, repeat);
    return t;
  };
  // Матовые поверхности города — Ламберт: на матовом выглядит так же, как PBR,
  // но заметно дешевле для видеокарты (асфальт, фасады и трава занимают почти весь экран).
  // Металл, стекло и вода остаются PBR — там нужен блеск.
  const L = (opts) => new THREE.MeshLambertMaterial(opts);
  return {
    asphalt: L({ map: tex('road', TX.asphalt) }),
    paving: L({ map: tex('sidewalk', TX.paving) }),
    curb: L({ map: tex('concrete', TX.concrete) }),
    grass: L({ map: tex('grass', TX.grass) }),
    facades: [0, 1, 2].map((v) => L({ map: textures[`facade${v}`] || TX.facade(v), vertexColors: true })),
    roof: L({ color: 0x6b6e72 }),
    white: L({ color: 0xf2f2f2 }),
    yellow: L({ color: 0xf2c230 }),
    metal: new THREE.MeshStandardMaterial({ color: 0x7c848c, roughness: 0.45, metalness: 0.6 }),
    darkMetal: new THREE.MeshStandardMaterial({ color: 0x33383d, roughness: 0.5, metalness: 0.4 }),
    glass: new THREE.MeshStandardMaterial({ color: 0x9fc4d8, roughness: 0.05, metalness: 0.1, transparent: true, opacity: 0.35, depthWrite: false }),
    wood: L({ color: 0x8a5a35 }),
    trunk: L({ color: 0x6b4a2f }),
    leaves: L({ color: 0xffffff }),
    color: L({ color: 0xffffff, vertexColors: true }),
    water: new THREE.MeshStandardMaterial({ color: 0x4f86a8, roughness: 0.1, metalness: 0.2 }),
    hospitalWall: L({ map: textures.hospitalFacade || TX.facade(1), vertexColors: true }),
  };
}

// Делит точки на ячейки сетки: каждая ячейка — свой InstancedMesh, и камера
// отсекает целые ячейки за спиной/в тумане (один большой InstancedMesh рисовался бы весь).
function byCell(items, getPos, size = 200) {
  const cells = new Map();
  for (const it of items) {
    const p = getPos(it);
    const key = `${Math.floor(p.x / size)},${Math.floor(p.z / size)}`;
    if (!cells.has(key)) cells.set(key, []);
    cells.get(key).push(it);
  }
  return [...cells.values()];
}

export class World {
  constructor(scene, route, materials) {
    this.scene = scene;
    this.route = route;
    this.m = materials;
    this.group = new THREE.Group();
    this.group.name = 'city';
    scene.add(this.group);
    this.r = rng(42);
    this.light = route.byId.light;
    this.crossS = this.light.stopLine + 9;      // центр перекрёстка со светофором
    this.stopShelters = {};

    this.buildGround();
    this.buildRoad();
    this.buildCrossStreet();
    this.buildBuildings();
    this.buildTreesAndLamps();
    this.buildStops();
    this.buildPark();
    this.buildMarket();
    this.trafficLight = this.buildTrafficLight();
    this.hospital = new HospitalArea(this, route.byId.hospital.s);
  }

  // Участки маршрута, где по этой стороне нельзя ставить дома/деревья.
  blocked(s, side, kind = 'building') {
    const rt = this.route;
    for (const t of rt.turns) if (s > t.s0 - 16 && s < t.s1 + 16) return true;
    if (Math.abs(s - this.crossS) < 15) return true;
    const ev = rt.byId;
    if (side > 0) {
      if (s > ev.hospital.s - 70 && s < ev.hospital.s + 75) return true;
      if (kind === 'building' && s > ev.park.s - 75 && s < ev.park.s + 65) return true;
      if (kind === 'building' && Math.abs(s - ev.market.s) < 28) return true;
      if (kind !== 'building' && (Math.abs(s - ev.park.s) < 9 || Math.abs(s - ev.market.s) < 9 || Math.abs(s - ev.hospital.s) < 9)) return true;
    }
    return false;
  }

  buildGround() {
    const g = new THREE.PlaneGeometry(9000, 9000);
    g.rotateX(-Math.PI / 2);
    const uv = g.attributes.uv;
    for (let i = 0; i < uv.count; i++) uv.setXY(i, uv.getX(i) * 1800, uv.getY(i) * 1800);
    const ground = new THREE.Mesh(g, this.m.grass);
    ground.position.y = -0.05;
    ground.receiveShadow = true;
    this.group.add(ground);
  }

  // Участки [s0,s1] без перекрёстка (там тротуар и бордюр прерываются).
  sidewalkSpans(from, to) {
    const gap = [this.crossS - 6, this.crossS + 6];
    return [[from, gap[0]], [gap[1], to]];
  }

  buildRoad() {
    const rt = this.route, m = this.m, L = rt.length;
    const b = new Batcher();
    const end = L + 300;
    b.add(ribbon(rt, -200, end, [[-R.halfWidth, 0], [R.halfWidth, 0]], { step: 2, uScale: 6, vScale: 6 }), null, m.asphalt);
    for (const [s0, s1] of this.sidewalkSpans(-200, end)) {
      b.add(ribbon(rt, s0, s1, [[R.halfWidth, R.curb], [SIDE_OUT, R.curb]], { uScale: 1.2, vScale: 1.2 }), null, m.paving);
      b.add(ribbon(rt, s0, s1, [[-SIDE_OUT, R.curb], [-R.halfWidth, R.curb]], { uScale: 1.2, vScale: 1.2 }), null, m.paving);
      b.add(ribbon(rt, s0, s1, [[R.halfWidth, 0], [R.halfWidth, R.curb]], { uFromLateral: false, uScale: 1, vScale: 1 }), null, m.curb);
      b.add(ribbon(rt, s0, s1, [[-R.halfWidth, R.curb], [-R.halfWidth, 0]], { uFromLateral: false, uScale: 1, vScale: 1 }), null, m.curb);
      b.add(ribbon(rt, s0, s1, [[SIDE_OUT, R.curb], [SIDE_OUT, -0.05]], { uFromLateral: false }), null, m.curb);
      b.add(ribbon(rt, s0, s1, [[-SIDE_OUT, -0.05], [-SIDE_OUT, R.curb]], { uFromLateral: false }), null, m.curb);
    }
    // Разметка: двойная сплошная по оси и прерывистые между полосами.
    const markings = [];
    for (const [s0, s1] of this.sidewalkSpans(-200, end)) {
      const a = s0 + 4, z = s1 - 4;
      if (z <= a) continue;
      markings.push(ribbon(rt, a, z, [[-0.22, 0.012], [-0.1, 0.012]], { step: 3 }).toNonIndexed());
      markings.push(ribbon(rt, a, z, [[0.1, 0.012], [0.22, 0.012]], { step: 3 }).toNonIndexed());
      for (const lat of [-3.5, 3.5]) {
        const d = dashes(rt, a, z, lat);
        if (d) markings.push(d);
      }
    }
    // Стоп-линия и «зебра» перед светофором.
    const sl = this.light.stopLine;
    markings.push(ribbon(rt, sl - 0.4, sl, [[0.2, 0.013], [R.halfWidth - 0.2, 0.013]], { step: 0.4 }).toNonIndexed());
    for (let lat = -6.4; lat < 6.5; lat += 1.2) {
      markings.push(ribbon(rt, sl + 1, sl + 4.5, [[lat, 0.013], [lat + 0.6, 0.013]], { step: 3.5 }).toNonIndexed());
    }
    const markGeo = mergeGeometries(markings.map((g) => { g.deleteAttribute('uv'); g.deleteAttribute('normal'); g.computeVertexNormals(); return g; }), false);
    const marks = new THREE.Mesh(markGeo, m.white);
    marks.receiveShadow = true;
    const road = b.build({ castShadow: false, name: 'road' });
    road.add(marks);
    this.group.add(road);
  }

  // Поперечная улица на перекрёстке со светофором.
  buildCrossStreet() {
    const rt = this.route, m = this.m;
    const q = rt.sample(this.crossS);
    const b = new Batcher();
    for (const side of [1, -1]) {
      // Мини-маршрут от края главной дороги наружу.
      const startLat = side * R.halfWidth;
      const ox = q.x + q.rx * startLat, oz = q.z + q.rz * startLat;
      const theta = Math.atan2(q.rz * side, q.rx * side);
      const side_ = { sample: (s) => {
        const dx = Math.cos(theta), dz = Math.sin(theta);
        return { x: ox + dx * s, z: oz + dz * s, dx, dz, rx: -dz, rz: dx };
      } };
      const len = 120;
      b.add(ribbon(side_, 0, len, [[-5.5, 0], [5.5, 0]], { step: 4, uScale: 6, vScale: 6 }), null, m.asphalt);
      b.add(ribbon(side_, SIDE_OUT - R.halfWidth, len, [[5.5, R.curb], [9, R.curb]], { step: 4, uScale: 1.2, vScale: 1.2 }), null, m.paving);
      b.add(ribbon(side_, SIDE_OUT - R.halfWidth, len, [[-9, R.curb], [-5.5, R.curb]], { step: 4, uScale: 1.2, vScale: 1.2 }), null, m.paving);
      b.add(ribbon(side_, SIDE_OUT - R.halfWidth, len, [[5.5, 0], [5.5, R.curb]], { step: 4, uFromLateral: false }), null, m.curb);
      b.add(ribbon(side_, SIDE_OUT - R.halfWidth, len, [[-5.5, R.curb], [-5.5, 0]], { step: 4, uFromLateral: false }), null, m.curb);
      b.add(ribbon(side_, 1, len, [[-0.08, 0.012], [0.08, 0.012]], { step: 4 }), null, m.white);
    }
    this.crossDir = { x: q.rx, z: q.rz }; // направление поперечной улицы (вправо)
    this.group.add(b.build({ castShadow: false, name: 'cross-street' }));
  }

  buildBuildings() {
    const rt = this.route, r = this.r, m = this.m;
    const palette = ['#e8d8b8', '#e9c9bb', '#efe2a6', '#d9dcde', '#bfd5e2', '#c9876a', '#f4f1ea', '#d6c6e0', '#c8dcc0'];
    const chunk = 130; // меньше кусок — точнее отсечение камерой и тенями
    let batch = new Batcher();
    let chunkEnd = chunk;
    const flush = () => { this.group.add(batch.build({ name: 'buildings' })); batch = new Batcher(); };
    const plots = [];
    for (const side of [1, -1]) {
      let s = -180;
      while (s < rt.length + 260) {
        const w = r.range(14, 28);
        const mid = s + w / 2;
        if (!this.blocked(s, side) && !this.blocked(s + w, side) && !this.blocked(mid, side)) plots.push({ side, s, w });
        s += w + r.range(1, 5);
      }
    }
    plots.sort((a, b) => a.s - b.s);
    for (const p of plots) {
      if (p.s > chunkEnd) { flush(); chunkEnd = p.s + chunk; }
      const depth = r.range(12, 18);
      const floors = r.int(3, 9);
      const h = floors * 3 + 0.6;
      const setback = SIDE_OUT + 1.2 + r.range(0, 1.6);
      const mid = p.s + p.w / 2;
      const q = rt.sample(mid);
      const lat = p.side * (setback + depth / 2);
      const cx = q.x + q.rx * lat, cz = q.z + q.rz * lat;
      const yaw = rt.yaw(mid);
      const { walls, roof } = buildingParts(depth, h, p.w);
      const M = matrix(cx, 0, cz, 0, yaw, 0);
      const color = new THREE.Color(r.pick(palette));
      batch.add(walls, M, r.pick(m.facades), color);
      batch.add(roof, M, m.roof);
      // Цоколь и козырёк магазина на первом этаже — у части домов.
      if (r() < 0.45) {
        const awning = new THREE.Color(r.pick(['#c0392b', '#2e86c1', '#27ae60', '#f39c12', '#8e44ad']));
        batch.add(boxUV(1.4, 0.15, p.w * 0.8), matrix(cx - q.rx * p.side * (depth / 2 + 0.7), 3.1, cz - q.rz * p.side * (depth / 2 + 0.7), 0, yaw, 0), m.color, awning);
      }
      batch.add(new THREE.BoxGeometry(depth + 0.4, 0.6, p.w + 0.4), matrix(cx, 0.3, cz, 0, yaw, 0), m.curb);
    }
    flush();
  }

  buildTreesAndLamps() {
    const rt = this.route, r = this.r, m = this.m;
    const trees = [];
    for (const side of [1, -1]) {
      for (let s = -150; s < rt.length + 250; s += r.range(10, 16)) {
        if (this.blocked(s, side, 'tree')) continue;
        trees.push(rt.point(s, side * (SIDE_OUT - 0.9), R.curb));
      }
    }
    this.addTrees(trees);

    const lamps = [];
    for (let s = -150, i = 0; s < rt.length + 250; s += 30, i++) {
      const side = i % 2 ? 1 : -1;
      if (this.blocked(s, side, 'lamp')) continue;
      lamps.push({ pos: rt.point(s, side * (R.halfWidth + 0.45)), yaw: rt.yaw(s) + (side > 0 ? Math.PI / 2 : -Math.PI / 2) });
    }
    this.addLamps(lamps);
  }

  // Деревья — инстансами: тысячи штук почти бесплатно.
  addTrees(points, parent = this.group) {
    if (!points.length) return;
    if (points.length > 24) {
      for (const cell of byCell(points, (p) => p)) this.addTreeCell(cell, parent);
      return;
    }
    this.addTreeCell(points, parent);
  }

  addTreeCell(points, parent) {
    const r = this.r;
    this.treeGeo ||= {
      trunk: new THREE.CylinderGeometry(0.14, 0.2, 3, 7).translate(0, 1.5, 0),
      crown: new THREE.IcosahedronGeometry(1.9, 1).translate(0, 4.1, 0),
    };
    const { trunk: trunkGeo, crown: crownGeo } = this.treeGeo;
    const trunks = new THREE.InstancedMesh(trunkGeo, this.m.trunk, points.length);
    const crowns = new THREE.InstancedMesh(crownGeo, this.m.leaves, points.length);
    const greens = ['#4f7f35', '#5b8f3c', '#3f6e2c', '#6a9a45', '#557d2f'];
    points.forEach((p, i) => {
      const sc = r.range(0.8, 1.25);
      const M = matrix(p.x, p.y ?? 0.15, p.z, 0, r() * 6.28, 0, sc, sc * r.range(0.9, 1.15), sc);
      trunks.setMatrixAt(i, M);
      crowns.setMatrixAt(i, M);
      crowns.setColorAt(i, new THREE.Color(r.pick(greens)));
    });
    for (const im of [trunks, crowns]) { im.castShadow = true; im.receiveShadow = true; parent.add(im); }
  }

  addLamps(list, parent = this.group) {
    if (!list.length) return;
    if (list.length > 12) {
      for (const cell of byCell(list, (l) => l.pos)) this.addLampCell(cell, parent);
      return;
    }
    this.addLampCell(list, parent);
  }

  addLampCell(list, parent) {
    this.lampGeo ||= mergeGeometries([
      new THREE.CylinderGeometry(0.07, 0.1, 7, 8).translate(0, 3.5, 0).toNonIndexed(),
      new THREE.BoxGeometry(0.08, 0.08, 1.6).translate(0, 6.9, -0.75).toNonIndexed(),
      new THREE.BoxGeometry(0.35, 0.14, 0.6).translate(0, 6.85, -1.5).toNonIndexed(),
    ], false);
    const geo = this.lampGeo;
    const im = new THREE.InstancedMesh(geo, this.m.darkMetal, list.length);
    list.forEach((l, i) => im.setMatrixAt(i, matrix(l.pos.x, 0.15, l.pos.z, 0, l.yaw, 0)));
    im.castShadow = true;
    parent.add(im);
  }

  // Остановочный павильон (стоит на тротуаре справа, по центру — средняя дверь автобуса).
  makeShelter(name) {
    const m = this.m;
    const g = new THREE.Group();
    const b = new Batcher();
    b.add(new THREE.BoxGeometry(1.7, 0.08, 4.6), matrix(0, 2.55, 0), m.darkMetal);
    for (const z of [-2.2, 2.2]) for (const x of [-0.75, 0.75]) b.add(new THREE.CylinderGeometry(0.04, 0.04, 2.5, 6), matrix(x, 1.27, z), m.metal);
    b.add(new THREE.BoxGeometry(0.45, 0.06, 3.2), matrix(0.35, 0.5, 0), m.wood);
    b.add(new THREE.BoxGeometry(0.06, 0.45, 3.2), matrix(0.58, 0.75, 0), m.wood);
    g.add(b.build({ name: 'shelter' }));
    const glass = new THREE.Mesh(new THREE.PlaneGeometry(4.4, 2.2), m.glass);
    glass.position.set(0.8, 1.35, 0);
    glass.rotation.y = -Math.PI / 2;
    g.add(glass);
    const sign = new THREE.Mesh(new THREE.PlaneGeometry(1.6, 0.4), new THREE.MeshBasicMaterial({ map: TX.textSign(name, { w: 512, h: 128 }) }));
    sign.position.set(-0.86, 2.3, -1.6);
    sign.rotation.y = -Math.PI / 2;
    g.add(sign);
    const pole = new THREE.Mesh(new THREE.CylinderGeometry(0.04, 0.04, 2.8, 6), m.metal);
    pole.position.set(-1.05, 1.4, -3.2);
    g.add(pole);
    const plate = new THREE.Mesh(new THREE.BoxGeometry(0.05, 0.5, 0.5), new THREE.MeshBasicMaterial({ map: TX.textSign('А', { w: 128, h: 128, bg: '#2e7d32', font: 'bold 90px sans-serif' }) }));
    plate.position.set(-1.05, 2.6, -3.2);
    g.add(plate);
    return g;
  }

  buildStops() {
    const rt = this.route;
    for (const id of ['park', 'market', 'hospital']) {
      const ev = rt.byId[id];
      const shelter = this.makeShelter(STORY.stops[id]);
      // У больницы павильон сдвинут вперёд: место у средней двери нужно коляске.
      const at = id === 'hospital' ? ev.s + 6 : ev.s - 0.5;
      const p = rt.point(at, R.halfWidth + 2.6, R.curb);
      shelter.position.copy(p);
      shelter.rotation.y = rt.yaw(ev.s);
      this.group.add(shelter);
      this.stopShelters[id] = shelter;
    }
  }

  buildPark() {
    const rt = this.route, r = this.r, m = this.m;
    const s0 = rt.byId.park.s;
    const b = new Batcher();
    const trees = [];
    for (let i = 0; i < 46; i++) {
      const s = s0 + r.range(-70, 62), lat = r.range(SIDE_OUT + 2, 60);
      const p = rt.point(s, lat);
      const pond = rt.point(s0 - 10, 34);
      if (p.distanceTo(pond) < 13) continue;
      trees.push(p.setY(0));
    }
    this.addTrees(trees);
    const q = rt.sample(s0 - 10);
    const pond = new THREE.Mesh(new THREE.CircleGeometry(10, 28), m.water);
    pond.rotation.x = -Math.PI / 2;
    pond.position.copy(rt.point(s0 - 10, 34, 0.02));
    this.group.add(pond);
    for (let i = 0; i < 5; i++) { // утки :)
      const a = r() * 6.28, d = r.range(2, 7);
      const p = rt.point(s0 - 10, 34);
      b.add(new THREE.BoxGeometry(0.35, 0.22, 0.2), matrix(p.x + Math.cos(a) * d, 0.12, p.z + Math.sin(a) * d, 0, a), m.color, i === 2 ? '#c46a2b' : '#f5f5f0');
    }
    // Низкая ограда вдоль тротуара с проходом у остановки.
    for (let s = s0 - 72; s < s0 + 64; s += 2.5) {
      if (Math.abs(s - s0) < 5) continue;
      const p = rt.point(s, SIDE_OUT + 0.3, 0);
      b.add(new THREE.BoxGeometry(0.06, 0.8, 2.5), matrix(p.x, 0.55, p.z, 0, rt.yaw(s), 0), m.darkMetal);
    }
    for (const ds of [-30, -12, 20, 40]) {
      const p = rt.point(s0 + ds, SIDE_OUT + 3);
      b.add(new THREE.BoxGeometry(0.5, 0.08, 1.8), matrix(p.x, 0.45, p.z, 0, rt.yaw(s0 + ds), 0), m.wood);
    }
    this.group.add(b.build({ name: 'park' }));
    this.parkCenter = q;
  }

  buildMarket() {
    const rt = this.route, r = this.r, m = this.m;
    const s0 = rt.byId.market.s;
    const b = new Batcher();
    const awnings = ['#c0392b', '#e67e22', '#27ae60', '#2980b9', '#f1c40f'];
    for (let i = 0; i < 7; i++) {
      for (const row of [0, 1]) {
        const s = s0 - 24 + i * 7 + row * 3.5;
        const lat = SIDE_OUT + 4 + row * 7;
        const p = rt.point(s, lat);
        const yaw = rt.yaw(s);
        b.add(new THREE.BoxGeometry(3.2, 0.9, 2.2), matrix(p.x, 0.45, p.z, 0, yaw, 0), m.wood);
        b.add(new THREE.BoxGeometry(3.6, 0.1, 2.8), matrix(p.x, 2.4, p.z, 0.12, yaw, 0), m.color, r.pick(awnings));
        for (const dx of [-1.6, 1.6]) b.add(new THREE.CylinderGeometry(0.04, 0.04, 2.4, 5), matrix(p.x + Math.cos(yaw) * dx, 1.2, p.z - Math.sin(yaw) * dx), m.metal);
        for (let k = 0; k < 6; k++) {
          b.add(new THREE.SphereGeometry(0.16, 6, 5), matrix(p.x + r.range(-1.2, 1.2), 1.0, p.z + r.range(-0.6, 0.6)), m.color, r.pick(['#d62d20', '#ffa700', '#7bb661', '#ffd700', '#7d3c98']));
        }
      }
    }
    this.group.add(b.build({ name: 'market' }));
  }

  buildTrafficLight() {
    const rt = this.route, m = this.m;
    const lamps = [];
    const housing = (pos, yaw) => {
      const g = new THREE.Group();
      const pole = new THREE.Mesh(new THREE.CylinderGeometry(0.08, 0.1, 3.4, 8), m.darkMetal);
      pole.position.y = 1.7;
      g.add(pole);
      const box = new THREE.Mesh(new THREE.BoxGeometry(0.4, 1.1, 0.32), m.darkMetal);
      box.position.set(0, 3.6, 0);
      g.add(box);
      const colors = { red: 0xff2a1a, yellow: 0xffc21a, green: 0x2aff6a };
      ['red', 'yellow', 'green'].forEach((c, i) => {
        const mat = new THREE.MeshStandardMaterial({ color: 0x222222, emissive: colors[c], emissiveIntensity: 0 });
        const lamp = new THREE.Mesh(new THREE.CircleGeometry(0.12, 14), mat);
        lamp.position.set(0, 3.95 - i * 0.34, -0.165);
        lamp.rotation.y = Math.PI;
        g.add(lamp);
        lamps.push({ color: c, mat });
      });
      g.position.copy(pos);
      g.rotation.y = yaw;
      g.traverse((o) => { o.castShadow = true; });
      this.group.add(g);
    };
    const sl = this.light.stopLine;
    // Наш светофор: справа у стоп-линии, «лицом» к автобусу. И для встречных — слева за перекрёстком.
    housing(rt.point(sl - 1, R.halfWidth + 0.6, R.curb), rt.yaw(sl) + Math.PI);
    housing(rt.point(this.crossS + 9, -(R.halfWidth + 0.6), R.curb), rt.yaw(sl));
    const light = {
      state: 'green',
      set(state) {
        this.state = state;
        for (const l of lamps) l.mat.emissiveIntensity = l.color === state ? 2.4 : 0;
      },
    };
    light.set('green');
    return light;
  }
}

// Территория больницы. Локальные координаты группы: −Z — вперёд по маршруту,
// +X — вправо от дороги (x=0 — ось дороги, x=7 — бордюр).
export class HospitalArea {
  constructor(world, s) {
    this.world = world;
    const m = world.m, rt = world.route;
    this.group = new THREE.Group();
    this.group.name = 'hospital';
    this.group.position.copy(rt.point(s, 0, 0));
    this.group.rotation.y = rt.yaw(s);
    world.group.add(this.group);
    this.group.updateMatrixWorld(true);
    this.inverse = this.group.matrixWorld.clone().invert();
    this.colliders = [];
    this.platform = { x0: 40, x1: 47, z0: -8, z1: 8, y: 0.6 };
    this.ramp = { x0: 32, x1: 40, z0: 3.5, z1: 7.5 };
    this.entrance = { x0: 42.5, x1: 46, z0: -1.8, z1: 1.8 };
    this.build(m);
  }

  toLocal(v, out = new THREE.Vector3()) { return out.copy(v).applyMatrix4(this.inverse); }
  toWorld(v, out = new THREE.Vector3()) { return out.copy(v).applyMatrix4(this.group.matrixWorld); }

  // Высота поверхности (y) в локальной точке: тротуар/площадь, пандус, площадка у входа.
  groundHeight(x, z) {
    const { platform: P, ramp: Rp } = this;
    if (x >= P.x0 && x <= P.x1 && z >= P.z0 && z <= P.z1) return P.y;
    if (x >= Rp.x0 && x <= Rp.x1 && z >= Rp.z0 && z <= Rp.z1) return R.curb + (P.y - R.curb) * ((x - Rp.x0) / (Rp.x1 - Rp.x0));
    if (x < R.halfWidth) return 0;
    return R.curb;
  }

  box(x0, x1, z0, z1) { this.colliders.push({ type: 'box', x0, x1, z0, z1 }); }
  circle(x, z, r) { this.colliders.push({ type: 'circle', x, z, r }); }

  build(m) {
    const g = this.group;
    const world = this.world;
    const b = new Batcher();
    const cy = R.curb;
    // Площадь перед больницей.
    const plaza = new THREE.PlaneGeometry(36, 96);
    const uv = plaza.attributes.uv;
    for (let i = 0; i < uv.count; i++) uv.setXY(i, uv.getX(i) * 36 / 1.2, uv.getY(i) * 96 / 1.2);
    b.add(plaza, matrix(SIDE_OUT + 18, cy + 0.001, 0, -Math.PI / 2), m.paving);
    // Главный корпус и входная группа — отдельной группой: её заменяет hospital.glb.
    const bb = new Batcher();
    const main = buildingParts(20, 15.6, 80);
    bb.add(main.walls, matrix(57, 0, 0), m.hospitalWall, new THREE.Color('#f3f4f2'));
    bb.add(main.roof, matrix(57, 0, 0), m.roof);
    const wing = buildingParts(3, 5, 12);
    bb.add(wing.walls, matrix(45.5, 0, 0), m.hospitalWall, new THREE.Color('#dfe9f2'));
    bb.add(wing.roof, matrix(45.5, 0, 0), m.roof);
    this.building = bb.build({ name: 'hospital-building' });
    g.add(this.building);
    // Площадка у входа, лестница, пандус с поручнями.
    const P = this.platform, Rp = this.ramp;
    b.add(boxUV(P.x1 - P.x0, P.y, P.z1 - P.z0, 1), matrix((P.x0 + P.x1) / 2, P.y / 2, 0), m.curb);
    for (let i = 0; i < 3; i++) {
      const h = cy + (P.y - cy) * (i + 1) / 3;
      b.add(boxUV(1, h, 8.5, 1), matrix(P.x0 - 2.5 + i, h / 2, -1.75), m.curb);
    }
    const rampLen = Math.hypot(Rp.x1 - Rp.x0, P.y - cy);
    const rampAngle = Math.atan2(P.y - cy, Rp.x1 - Rp.x0);
    b.add(boxUV(rampLen, 0.12, Rp.z1 - Rp.z0, 1), matrix((Rp.x0 + Rp.x1) / 2, (cy + P.y) / 2 - 0.05, (Rp.z0 + Rp.z1) / 2, 0, 0, rampAngle), m.curb);
    for (const z of [Rp.z0 - 0.1, Rp.z1 + 0.1]) {
      b.add(new THREE.BoxGeometry(rampLen, 0.05, 0.05), matrix((Rp.x0 + Rp.x1) / 2, (cy + P.y) / 2 + 0.85, z, 0, 0, rampAngle), m.metal);
      for (let x = Rp.x0; x <= Rp.x1 + 0.01; x += 2) b.add(new THREE.CylinderGeometry(0.03, 0.03, 0.9, 6), matrix(x, this.groundHeight(x, (Rp.z0 + Rp.z1) / 2) + 0.45, z), m.metal);
    }
    // Козырёк на колоннах.
    b.add(new THREE.BoxGeometry(7.5, 0.3, 14.4), matrix(43.2, 4.1, 0), m.white);
    for (const z of [-6.9, 6.9]) {
      b.add(new THREE.CylinderGeometry(0.18, 0.18, 3.5, 10), matrix(40.4, P.y + 1.75, z), m.white);
      this.circle(40.4, z, 0.22);
    }
    // Клумбы, скамейки, урны.
    for (const [x, z] of [[20, -14], [20, 18], [30, -20], [30, 22]]) {
      b.add(boxUV(6, 0.45, 4, 1), matrix(x, cy + 0.22, z), m.curb);
      b.add(new THREE.BoxGeometry(5.6, 0.1, 3.6), matrix(x, cy + 0.47, z), m.color, '#4c7d34');
      for (let k = 0; k < 10; k++) b.add(new THREE.SphereGeometry(0.16, 6, 4), matrix(x + world.r.range(-2.5, 2.5), cy + 0.6, z + world.r.range(-1.5, 1.5)), m.color, world.r.pick(['#e74c3c', '#f1c40f', '#ecf0f1', '#9b59b6']));
      this.box(x - 3, x + 3, z - 2, z + 2);
    }
    for (const [x, z] of [[24, -6], [24, 12]]) {
      b.add(new THREE.BoxGeometry(0.6, 0.08, 2), matrix(x, cy + 0.45, z), m.wood);
      b.add(new THREE.BoxGeometry(0.08, 0.5, 2), matrix(x + 0.3, cy + 0.7, z), m.wood);
      this.box(x - 0.4, x + 0.45, z - 1.05, z + 1.05);
    }
    // Вывеска над входом и табличка у дороги.
    const signTex = TX.textSign(STORY.hospitalSign, { w: 1024, h: 128, bg: '#ffffff', fg: '#1d5fa8', font: 'bold 80px sans-serif' });
    const sign = new THREE.Mesh(new THREE.PlaneGeometry(14, 1.75), new THREE.MeshBasicMaterial({ map: signTex }));
    sign.position.set(46.9, 9, 0);
    sign.rotation.y = -Math.PI / 2;
    this.building.add(sign);
    const crossTex = TX.textSign('+', { w: 128, h: 128, bg: '#ffffff', fg: '#e53935', font: 'bold 150px sans-serif' });
    const cross = new THREE.Mesh(new THREE.PlaneGeometry(2.6, 2.6), new THREE.MeshBasicMaterial({ map: crossTex }));
    cross.position.set(46.9, 12.3, 0);
    cross.rotation.y = -Math.PI / 2;
    this.building.add(cross);
    const roadSign = new THREE.Mesh(new THREE.PlaneGeometry(3.2, 1.0), new THREE.MeshBasicMaterial({ map: TX.textSign(STORY.stops.hospital, { w: 512, h: 160, sub: 'Поликлиника · Приёмный покой' }), side: THREE.DoubleSide }));
    roadSign.position.set(SIDE_OUT - 0.4, 2.6, 14);
    roadSign.rotation.y = -Math.PI / 2;
    g.add(roadSign);
    b.add(new THREE.CylinderGeometry(0.05, 0.05, 3.1, 6), matrix(SIDE_OUT - 0.4, 1.55, 12.6), m.metal);
    b.add(new THREE.CylinderGeometry(0.05, 0.05, 3.1, 6), matrix(SIDE_OUT - 0.4, 1.55, 15.4), m.metal);
    // Парковка со «скорой».
    b.add(new THREE.PlaneGeometry(24, 22), matrix(28, cy + 0.004, 36, -Math.PI / 2), m.asphalt);
    g.add(b.build({ name: 'hospital' }));

    // Автоматические двери входа.
    this.doors = [];
    for (const side of [-1, 1]) {
      const d = new THREE.Mesh(new THREE.BoxGeometry(0.06, 2.3, 1.5), m.glass);
      d.position.set(43.98, P.y + 1.15, side * 0.75);
      d.userData.closedZ = side * 0.75;
      d.userData.side = side;
      g.add(d);
      this.doors.push(d);
    }
    this.doorOpen = 0;

    // Деревья и фонари площади.
    const trees = [];
    for (const [x, z] of [[14, -30], [14, -42], [14, 30], [34, -32], [36, -42], [16, 8], [16, -4]]) {
      trees.push(this.toWorld(new THREE.Vector3(x, cy, z)));
      this.circle(x, z, 0.45);
    }
    world.addTrees(trees);
    const lamps = [];
    for (const [x, z] of [[18, -24], [18, 26], [34, -10], [34, 14]]) {
      lamps.push({ pos: this.toWorld(new THREE.Vector3(x, 0, z)), yaw: this.group.rotation.y });
      this.circle(x, z, 0.25);
    }
    world.addLamps(lamps);

    // Границы: дорога, корпус, края площади, лестница, края площадки, поручни пандуса.
    this.box(-50, R.halfWidth + 0.35, -60, 60);
    this.box(47, 80, -60, 60);
    this.box(44, 47, -6, 6);              // входная группа (кроме дверей — там триггер)
    this.box(-50, 80, 47.5, 60);
    this.box(-50, 80, -60, -47.5);
    this.box(37, 40, -6, 2.6);            // лестница
    this.box(39.7, 40.2, -8.3, 3.4);      // край площадки слева от пандуса
    this.box(39.7, 40.2, 7.6, 8.3);
    this.box(40, 44, -8.3, -7.9);
    this.box(40, 44, 7.9, 8.3);
    this.box(Rp.x0, Rp.x1, Rp.z0 - 0.25, Rp.z0 - 0.02);
    this.box(Rp.x0, Rp.x1, Rp.z1 + 0.02, Rp.z1 + 0.25);
    this.box(8.7, 10.5, -8.4, -3.6);      // павильон остановки
    this.box(SIDE_OUT - 0.7, SIDE_OUT - 0.1, 12.4, 15.6); // табличка
  }

  // hospital.glb вместо корпуса-заглушки. Вход модели должен смотреть «вперёд» (−Z),
  // здесь он разворачивается к дороге и ставится фасадом на линию входа (x = 44).
  useModel(gltf) {
    this.building.visible = false;
    const model = gltf.scene;
    model.rotation.y += Math.PI / 2;
    model.traverse((o) => { if (o.isMesh) { o.castShadow = true; o.receiveShadow = true; } });
    model.removeFromParent();
    model.updateMatrixWorld(true);
    const box = new THREE.Box3().setFromObject(model); // пока без родителя — это локальные координаты
    model.position.x += 44 - box.min.x;
    model.position.y += R.curb;
    this.group.add(model);
  }

  updateDoors(dt, playerLocal) {
    const near = playerLocal && playerLocal.x > 36 && Math.abs(playerLocal.z) < 6;
    this.doorOpen = Math.max(0, Math.min(1, this.doorOpen + (near ? dt : -dt) * 1.5));
    for (const d of this.doors) d.position.z = d.userData.closedZ + d.userData.side * 1.4 * this.doorOpen;
  }
}
