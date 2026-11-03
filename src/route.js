// Маршрут автобуса: прямые + дуги (точная длина и кривизна), план скорости,
// «водитель» и подбор длины маршрута под нужную длительность поездки.
import * as THREE from 'three';
import { CONFIG } from './data.js';

// Секунды на открытие/закрытие дверей сверх стоянки (учитывается при подборе длины).
export const DOOR_EXTRA_SECONDS = 6;

export class Route {
  // theta — направление движения: (cos θ, sin θ) в плоскости XZ; -π/2 = вдоль −Z.
  constructor(pieces, x0 = 0, z0 = 0, theta0 = -Math.PI / 2) {
    this.pieces = [];
    let s = 0, x = x0, z = z0, th = theta0;
    for (const p of pieces) {
      const isArc = p.type === 'arc';
      const len = isArc ? Math.abs(p.angle) * p.radius : p.length;
      // k > 0 — поворот направо, k < 0 — налево.
      const piece = { ...p, s0: s, len, k: isArc ? Math.sign(p.angle) / p.radius : 0, x0: x, z0: z, th0: th };
      this.pieces.push(piece);
      const end = this._eval(piece, len);
      x = end.x; z = end.z; th = end.th; s += len;
    }
    this.length = s;
  }

  _eval(p, t) {
    if (p.k === 0) return { x: p.x0 + Math.cos(p.th0) * t, z: p.z0 + Math.sin(p.th0) * t, th: p.th0 };
    const th = p.th0 + p.k * t;
    return {
      x: p.x0 + (Math.sin(th) - Math.sin(p.th0)) / p.k,
      z: p.z0 + (Math.cos(p.th0) - Math.cos(th)) / p.k,
      th,
    };
  }

  pieceAt(s) {
    const list = this.pieces;
    if (s <= 0) return list[0];
    for (let i = 0; i < list.length; i++) if (s < list[i].s0 + list[i].len) return list[i];
    return list[list.length - 1];
  }

  // Точка на оси дороги: позиция, направление вперёд (dx,dz), вправо (rx,rz), кривизна.
  sample(s) {
    const clamped = Math.max(0, Math.min(this.length, s));
    const p = this.pieceAt(clamped);
    const e = this._eval(p, clamped - p.s0);
    // За концом маршрута продолжаем по прямой (нужно для объектов чуть дальше конца).
    const extra = s - clamped;
    const dx = Math.cos(e.th), dz = Math.sin(e.th);
    return { x: e.x + dx * extra, z: e.z + dz * extra, th: e.th, dx, dz, rx: -dz, rz: dx, k: extra === 0 ? p.k : 0 };
  }

  // lateral > 0 — вправо от оси дороги.
  point(s, lateral = 0, y = 0, out = new THREE.Vector3()) {
    const q = this.sample(s);
    return out.set(q.x + q.rx * lateral, y, q.z + q.rz * lateral);
  }

  // Поворот объекта (rotation.y), чтобы его «перед» (−Z) смотрел вдоль маршрута.
  yaw(s) {
    const q = this.sample(s);
    return Math.atan2(-q.dx, -q.dz);
  }

  curvature(s) {
    return this.pieceAt(s).k;
  }
}

// Маршрут целиком. scale растягивает прямые участки — так подгоняется длительность.
export function buildRoute(scale = 1) {
  const S = (length) => ({ type: 'straight', length });
  const A = (radius, deg) => ({ type: 'arc', radius, angle: (deg * Math.PI) / 180 });
  const pieces = [
    S(400),               // 0  дорога «за спиной» в начале (уходит в туман)
    S(150 * scale),       // 1
    A(26, 90),            // 2  направо
    S(280 * scale),       // 3  остановка «Парк»
    A(34, -90),           // 4  налево
    S(300 * scale),       // 5  светофор
    A(240, 24),           // 6  плавно направо
    S(150 * scale),       // 7
    A(240, -24),          // 8  плавно налево
    S(330 * scale),       // 9  остановка «Рынок»
    A(30, 90),            // 10 направо
    S(240 * scale + 120), // 11 больница в конце этого участка
    S(420),               // 12 дальше автобус уезжает без нас
  ];
  const route = new Route(pieces);
  const P = route.pieces;
  const stopLine = P[5].s0 + P[5].len * 0.6;
  const events = [
    { id: 'park', kind: 'stop', s: P[3].s0 + P[3].len * 0.55 },
    { id: 'light', kind: 'light', s: stopLine - 6.6, stopLine },
    { id: 'market', kind: 'stop', s: P[9].s0 + P[9].len * 0.5 },
    { id: 'hospital', kind: 'final', s: P[12].s0 - 60 },
  ];
  route.startS = 392;
  route.events = events;
  route.byId = Object.fromEntries(events.map((e) => [e.id, e]));
  route.turns = [P[2], P[4], P[10]].map((p) => ({ s0: p.s0, s1: p.s0 + p.len }));
  return route;
}

// Допустимая скорость по кривизне с заблаговременным торможением перед поворотом.
export function makeSpeedPlan(route, bus = CONFIG.bus) {
  const step = 0.5;
  const n = Math.ceil(route.length / step) + 2;
  const lim = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const k = Math.abs(route.curvature(i * step));
    lim[i] = k > 0 ? Math.min(bus.cruise, Math.sqrt(bus.latAccel / k)) : bus.cruise;
  }
  for (let i = n - 2; i >= 0; i--) lim[i] = Math.min(lim[i], Math.sqrt(lim[i + 1] ** 2 + 2 * bus.decel * step));
  return (s) => lim[Math.max(0, Math.min(n - 1, Math.round(s / step)))];
}

// «Водитель»: разгоняется, тормозит перед поворотами и точно останавливается у события.
export class BusDriver {
  constructor(route, plan, bus = CONFIG.bus) {
    this.route = route;
    this.plan = plan;
    this.bus = bus;
    this.s = route.startS;
    this.v = bus.cruise * 0.85;
    this.accel = 0;
    this.index = 0;          // следующее событие
    this.stopped = false;    // стоит у события и ждёт release()
    this.onArrive = null;
  }

  get next() {
    return this.route.events[this.index];
  }

  release() {
    if (!this.stopped) return;
    this.stopped = false;
    this.index++;
  }

  update(dt) {
    const prevV = this.v;
    if (!this.stopped) {
      const ev = this.next;
      const dist = ev ? ev.s - this.s : Infinity;
      const allowed = Math.min(this.plan(this.s), ev ? Math.sqrt(2 * this.bus.decel * Math.max(0, dist)) : this.bus.cruise);
      this.v = Math.max(0, Math.min(this.v + this.bus.accel * dt, allowed));
      this.s += this.v * dt;
      if (ev && ev.s - this.s < 0.25 && this.v < 0.6) {
        this.s = ev.s;
        this.v = 0;
        this.stopped = true;
        this.accel = 0;
        if (this.onArrive) this.onArrive(ev);
        return;
      }
    }
    // Ограничиваем: при «доводке» до остановки скорость обнуляется рывком, и без
    // ограничения кузов «клевал» бы носом на −12 м/с² и так и застывал.
    this.accel = dt > 0 ? Math.max(-this.bus.decel * 1.5, Math.min(this.bus.accel * 1.5, (this.v - prevV) / dt)) : 0;
  }
}

// Время поездки (с) от старта до больницы при данной длине маршрута.
export function simulateTrip(route, bus = CONFIG.bus) {
  const driver = new BusDriver(route, makeSpeedPlan(route, bus), bus);
  let t = 0;
  let result = null;
  driver.onArrive = (ev) => {
    if (ev.kind === 'final') result = t;
    else t += ev.kind === 'light' ? bus.redLight : bus.dwell + DOOR_EXTRA_SECONDS;
  };
  const dt = 0.1;
  while (result === null && t < 7200) {
    driver.update(dt);
    t += dt;
    if (driver.stopped && result === null) driver.release();
  }
  return result ?? t;
}

// Подбирает растяжение маршрута, чтобы поездка длилась targetSeconds.
export function routeForDuration(targetSeconds) {
  let lo = 0.35, hi = 4;
  for (let i = 0; i < 22; i++) {
    const mid = (lo + hi) / 2;
    if (simulateTrip(buildRoute(mid)) < targetSeconds) lo = mid; else hi = mid;
  }
  const route = buildRoute((lo + hi) / 2);
  route.expectedSeconds = simulateTrip(route);
  return route;
}
