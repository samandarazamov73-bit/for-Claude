// Машины и пешеходы. Двигаются вдоль маршрута, держат дистанцию, стоят на красный.
import * as THREE from 'three';
import { CONFIG } from './data.js';
import { Batcher, matrix } from './geom.js';
import { clamp, rng } from './utils.js';

const CAR_COLORS = ['#c0392b', '#2c3e50', '#ecf0f1', '#7f8c8d', '#2980b9', '#16a085', '#f39c12', '#1b1b1b', '#8e44ad', '#d35400', '#bdc3c7'];
// Оптимизация: машина — ОДИН меш (кузов, стёкла, колёса, фары слиты, цвет в вершинах),
// материал общий для всех машин. Было 6 мешей на машину.
let CAR_MATERIAL = null;
const carMaterial = () => CAR_MATERIAL || (CAR_MATERIAL = new THREE.MeshStandardMaterial({ vertexColors: true, roughness: 0.4, metalness: 0.25 }));
const carCache = new Map();

function carGeometry(color, type) {
  const key = `${color}|${type}`;
  if (carCache.has(key)) return carCache.get(key);
  const b = new Batcher();
  const m = carMaterial();
  const glass = '#1d2a33', tire = '#151515', light = '#fff6dc', tail = '#a01818';
  if (type === 'van' || type === 'ambulance') {
    b.add(new THREE.BoxGeometry(1.95, 1.75, 4.8).translate(0, 1.3, 0), null, m, color);
    b.add(new THREE.BoxGeometry(1.97, 0.55, 1.1).translate(0, 1.7, -1.75), null, m, glass);
    if (type === 'ambulance') {
      b.add(new THREE.BoxGeometry(1.98, 0.22, 4.82).translate(0, 1.05, 0), null, m, '#d32f2f');
      b.add(new THREE.BoxGeometry(0.9, 0.12, 0.3).translate(0, 2.24, -1.6), null, m, '#2f5bff');
    }
  } else {
    const len = type === 'hatch' ? 3.9 : 4.4, z = type === 'hatch' ? 0.35 : 0.15;
    b.add(new THREE.BoxGeometry(1.8, 0.7, len).translate(0, 0.62, 0), null, m, color);
    b.add(new THREE.BoxGeometry(1.62, 0.6, len * 0.5).translate(0, 1.25, z), null, m, glass);
    b.add(new THREE.BoxGeometry(1.64, 0.06, len * 0.48).translate(0, 1.57, z), null, m, color);
  }
  for (const x of [-0.82, 0.82]) for (const zz of [-1.35, 1.35]) b.add(new THREE.CylinderGeometry(0.33, 0.33, 0.24, 12).rotateZ(Math.PI / 2).translate(x, 0.33, zz), null, m, tire);
  b.add(new THREE.BoxGeometry(1.5, 0.12, 0.05).translate(0, 0.72, -2.16), null, m, light);
  b.add(new THREE.BoxGeometry(1.5, 0.12, 0.05).translate(0, 0.78, 2.16), null, m, tail);
  const geo = b.build().children[0].geometry;
  carCache.set(key, geo);
  return geo;
}

// Машина-заглушка. type: sedan | hatch | van | ambulance. Перед — −Z.
export function makeCar(color, type = 'sedan') {
  const g = new THREE.Group();
  const mesh = new THREE.Mesh(carGeometry(color, type), carMaterial());
  mesh.castShadow = true;
  mesh.receiveShadow = true;
  g.add(mesh);
  return g;
}

let PED_MATERIAL = null;
const pedMaterial = () => PED_MATERIAL || (PED_MATERIAL = new THREE.MeshStandardMaterial({ vertexColors: true, roughness: 0.9 }));

export class Traffic {
  constructor(scene, world, route) {
    this.scene = scene;
    this.world = world;
    this.route = route;
    this.r = rng(99);
    this.cars = [];
    this.cross = [];
    this.peds = [];
    this.group = new THREE.Group();
    this.group.name = 'traffic';
    scene.add(this.group);
    this.stopLineFwd = world.light.stopLine;
    this.stopLineBack = world.crossS + 9;
    const startS = route.startS;
    // Встречка: 2 полосы. Попутная внутренняя полоса: обгоняют автобус.
    for (let i = 0; i < 12; i++) this.addCar(i % 2 ? -1.75 : -5.25, -1, startS + 40 + i * 38 + this.r.range(-8, 8));
    for (let i = 0; i < 4; i++) this.addCar(1.75, 1, startS - 40 - i * 45);
    for (let i = 0; i < 16; i++) this.addPed(startS + this.r.range(-80, 220));
    this.lightTimer = 0;
  }

  addCar(lane, dir, s) {
    const type = this.r() < 0.15 ? 'van' : this.r() < 0.4 ? 'hatch' : 'sedan';
    const g = makeCar(this.r.pick(CAR_COLORS), type);
    this.group.add(g);
    const max = this.r.range(10, 14);
    this.cars.push({ g, lane, dir, s, v: max * 0.8, max, len: type === 'van' ? 5 : 4.6 });
  }

  addPed(s) {
    const r = this.r;
    const side = r() < 0.5 ? 1 : -1;
    const g = new THREE.Group();
    const shirt = new THREE.MeshStandardMaterial({ color: r.pick(['#a03e3e', '#3e6aa0', '#4f8a4f', '#c9a227', '#6b4f8a', '#cccccc', '#333333']), roughness: 0.9 });
    const pants = new THREE.MeshStandardMaterial({ color: r.pick(['#2b2b33', '#3a4a66', '#5a4632']), roughness: 0.9 });
    const skin = new THREE.MeshStandardMaterial({ color: r.pick(['#e2b28f', '#c68e64', '#8d5a3b', '#f0c9a8']), roughness: 0.8 });
    const h = r.range(0.92, 1.08);
    const upper = new Batcher();
    upper.add(new THREE.CapsuleGeometry(0.17, 0.4, 3, 8), matrix(0, 1.2 * h, 0), pedMaterial(), shirt.color);
    upper.add(new THREE.SphereGeometry(0.11, 10, 8), matrix(0, 1.62 * h, 0), pedMaterial(), skin.color);
    const body = upper.build().children[0];
    const legs = [];
    for (const x of [-0.09, 0.09]) {
      const pivot = new THREE.Group();
      pivot.position.set(x, 0.88 * h, 0);
      const leg = new THREE.Mesh(new THREE.CapsuleGeometry(0.065, 0.7, 3, 6), pants);
      leg.position.y = -0.44 * h;
      pivot.add(leg);
      g.add(pivot);
      legs.push(pivot);
    }
    g.add(body);
    this.group.add(g);
    this.peds.push({ g, legs, s, side, lat: side * r.range(8.1, 10.2), dir: r() < 0.5 ? 1 : -1, v: r.range(1.0, 1.5), phase: r() * 6 });
  }

  // Для кого сейчас красный (главная дорога).
  mainRed() {
    const st = this.world.trafficLight.state;
    return st === 'red' || st === 'yellow';
  }

  update(dt, busS, busV) {
    const rt = this.route;
    const red = this.mainRed();
    // Машины на главной дороге.
    for (const car of this.cars) {
      let target = car.max;
      // Машина впереди в той же полосе.
      let gap = Infinity;
      for (const other of this.cars) {
        if (other === car || other.lane !== car.lane) continue;
        const d = (other.s - car.s) * car.dir;
        if (d > 0 && d < gap) gap = d - (car.len + other.len) / 2;
      }
      if (gap < Infinity) target = Math.min(target, Math.sqrt(2 * 3.5 * Math.max(0, gap - 2.5)));
      // Красный свет: стоим у своей стоп-линии.
      if (red) {
        const front = car.s + car.dir * car.len / 2;
        const line = car.dir > 0 ? this.stopLineFwd : this.stopLineBack;
        const dist = (line - front) * car.dir;
        if (dist > -0.5 && dist < 70) target = Math.min(target, Math.sqrt(2 * 3.5 * Math.max(0, dist - 0.6)));
      }
      const a = target > car.v ? 2.2 : -6;
      car.v = clamp(car.v + a * dt, 0, Math.max(target, 0));
      if (target < car.v) car.v = Math.max(target, car.v - 6 * dt);
      car.s += car.v * car.dir * dt;
      // Переносим уехавшие машины вперёд/назад, чтобы трафик всегда был рядом.
      if (car.dir < 0 && car.s < busS - 170) this.respawn(car, busS + this.r.range(260, 460));
      if (car.dir > 0 && car.s > busS + 480 && busV > 2) this.respawn(car, busS - this.r.range(120, 220));
      const p = rt.point(car.s, car.lane, 0);
      car.g.position.copy(p);
      car.g.rotation.y = rt.yaw(car.s) + (car.dir < 0 ? Math.PI : 0);
    }

    // Поперечный поток, пока у нас красный.
    this.lightTimer -= dt;
    if (red && this.world.trafficLight.state === 'red' && this.lightTimer <= 0 && Math.abs(busS - this.world.crossS) < 200) {
      this.spawnCrossCar();
      this.lightTimer = this.r.range(2.2, 3.8);
    }
    const q = rt.sample(this.world.crossS);
    for (let i = this.cross.length - 1; i >= 0; i--) {
      const c = this.cross[i];
      c.t += c.v * dt;
      const along = c.t - 70;
      c.g.position.set(q.x + q.rx * along * c.dir + q.dx * c.lane, 0, q.z + q.rz * along * c.dir + q.dz * c.lane);
      c.g.rotation.y = Math.atan2(-q.rx * c.dir, -q.rz * c.dir);
      if (c.t > 140) {
        this.group.remove(c.g);
        this.cross.splice(i, 1);
      }
    }

    // Пешеходы.
    for (const p of this.peds) {
      p.s += p.v * p.dir * dt;
      p.phase += dt * p.v * 5.5;
      if (p.s < busS - 140 || p.s > busS + 300) {
        p.s = busS + (busV > 1 ? this.r.range(120, 280) : this.r.range(-60, 160));
        p.dir = this.r() < 0.5 ? 1 : -1;
      }
      const pos = rt.point(p.s, p.lat, CONFIG.road.curb);
      p.g.position.copy(pos);
      p.g.rotation.y = rt.yaw(p.s) + (p.dir < 0 ? Math.PI : 0);
      p.legs[0].rotation.x = Math.sin(p.phase) * 0.45;
      p.legs[1].rotation.x = -Math.sin(p.phase) * 0.45;
    }
  }

  respawn(car, s) {
    // Не ставим машину вплотную к другой.
    for (let tries = 0; tries < 6; tries++) {
      if (!this.cars.some((o) => o !== car && o.lane === car.lane && Math.abs(o.s - s) < 14)) break;
      s += 16 * (car.dir < 0 ? 1 : -1);
    }
    car.s = s;
    car.v = car.max * 0.9;
  }

  spawnCrossCar() {
    const dir = this.r() < 0.5 ? 1 : -1;
    const g = makeCar(this.r.pick(CAR_COLORS), this.r() < 0.2 ? 'van' : 'sedan');
    this.group.add(g);
    // Правостороннее движение: едущие «вправо» держатся ближней к автобусу полосы (−2.75 вдоль маршрута).
    this.cross.push({ g, dir, lane: dir > 0 ? -2.75 : 2.75, t: 0, v: this.r.range(9, 12) });
  }

  // Когда автобус уехал от больницы — убираем поток, чтобы не мешал прогулке.
  setVisible(v) {
    this.group.visible = v;
  }
}

// Припаркованные машины и «скорая» у больницы + их коллайдеры.
export function parkHospitalCars(hospital) {
  const r = rng(5);
  const list = [];
  for (let i = 0; i < 6; i++) {
    for (const row of [0, 1]) {
      if (r() < 0.3) continue;
      const x = 19 + i * 3.1, z = row ? 43 : 30;
      list.push({ x, z, yaw: row ? Math.PI : 0, color: r.pick(CAR_COLORS), type: r() < 0.2 ? 'hatch' : 'sedan' });
    }
  }
  list.push({ x: 37.5, z: 18.5, yaw: Math.PI / 2, color: '#f5f5f5', type: 'ambulance' });
  for (const c of list) {
    const g = makeCar(c.color, c.type);
    g.position.set(c.x, CONFIG.road.curb, c.z);
    g.rotation.y = c.yaw;
    hospital.group.add(g);
    const along = c.type === 'ambulance' ? 2.5 : 2.3;
    if (Math.abs(Math.sin(c.yaw)) > 0.5) hospital.box(c.x - along, c.x + along, c.z - 1.05, c.z + 1.05);
    else hospital.box(c.x - 1.0, c.x + 1.0, c.z - along, c.z + along);
  }
}
