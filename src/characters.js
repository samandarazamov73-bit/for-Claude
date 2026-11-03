// Персонажи-заглушки (человечки из примитивов) и электроколяска.
// Настоящие модели (GLB) подключаются через ModelActor с тем же интерфейсом.
import * as THREE from 'three';
import { angleDiff, clamp, damp, lerp } from './utils.js';
import { Batcher, matrix } from './geom.js';

const mat = (color, rough = 0.8) => new THREE.MeshStandardMaterial({ color, roughness: rough });
// Один материал на всех людей: цвет одежды/кожи хранится в вершинах.
let HUMAN_MATERIAL = null;
const humanMaterial = () => HUMAN_MATERIAL || (HUMAN_MATERIAL = new THREE.MeshStandardMaterial({ vertexColors: true, roughness: 0.8 }));
const cap = (r, len, segs = 8) => new THREE.CapsuleGeometry(r, len, 4, segs);

const POSE_KEYS = ['spine', 'hipL', 'hipR', 'kneeL', 'kneeR', 'shLx', 'shRx', 'shLz', 'shRz', 'elL', 'elR'];
const POSES = {
  stand: { spine: 0, hipL: 0, hipR: 0, kneeL: 0, kneeR: 0, shLx: 0, shRx: 0, shLz: -0.08, shRz: 0.08, elL: 0.12, elR: 0.12 },
  sit: { spine: -0.06, hipL: 1.52, hipR: 1.52, kneeL: -1.5, kneeR: -1.5, shLx: 0.35, shRx: 0.35, shLz: -0.1, shRz: 0.1, elL: 0.95, elR: 0.95 },
  // В коляске: правая рука на джойстике, левая на подлокотнике.
  wheelchair: { spine: -0.04, hipL: 1.45, hipR: 1.45, kneeL: -1.35, kneeR: -1.35, shLx: 0.3, shRx: 0.45, shLz: -0.12, shRz: 0.14, elL: 1.15, elR: 1.25 },
};

export class Human {
  constructor({
    height = 1.7, shirt = '#3a6ea5', pants = '#2f3e5c', skin = '#e2b28f', hair = '#2b1d14',
    shoes = '#f0f0f0', hairStyle = 'short', sleeves = 'long', sitHeight = 0.46, name = 'human', shadows = true,
  } = {}) {
    const k = height / 1.7;
    this.k = k;
    this.sitHeight = sitHeight;
    this.hipHeight = 0.9 * k;
    this.root = new THREE.Group();
    this.root.name = name;
    this.mode = 'stand';
    this.poseName = 'stand';
    this.blend = { from: 'stand', to: 'stand', t: 1 };
    this.walkPhase = 0;
    this.speed = 0;
    this.lookTarget = null;
    this.headYaw = 0;
    this.headPitch = 0;
    this.breath = Math.random() * 6;
    this.talking = 0;

    // Оптимизация: все детали одной «кости» сливаются в ОДИН меш, цвета — в вершинах,
    // материал общий для всех людей. Было ~22 меша на человека, стало 11.
    const C = { shirt, pants, skin, hair, shoes, eye: '#1b1b1b' };
    const parts = new Map();
    const add = (parent, geo, color, x = 0, y = 0, z = 0, sx = 1, sy = 1, sz = 1) => {
      if (!parts.has(parent)) parts.set(parent, new Batcher());
      parts.get(parent).add(geo, matrix(x, y, z, 0, 0, 0, sx, sy, sz), humanMaterial(), color);
    };
    const group = (parent, x = 0, y = 0, z = 0) => {
      const g = new THREE.Group();
      g.position.set(x, y, z);
      parent.add(g);
      return g;
    };

    this.hips = group(this.root, 0, this.hipHeight, 0);
    add(this.hips, new THREE.BoxGeometry(0.32 * k, 0.17 * k, 0.21 * k), C.pants, 0, -0.03 * k, 0);
    this.spine = group(this.hips);
    add(this.spine, cap(0.15 * k, 0.22 * k), C.shirt, 0, 0.27 * k, 0, 1.15, 1, 0.72);
    add(this.spine, new THREE.CylinderGeometry(0.05 * k, 0.055 * k, 0.09 * k, 8), C.skin, 0, 0.53 * k, 0); // шея
    this.neck = group(this.spine, 0, 0.5 * k, 0);
    this.head = group(this.neck, 0, 0.16 * k, 0);
    add(this.head, new THREE.SphereGeometry(0.11 * k, 16, 12), C.skin, 0, 0, 0, 0.9, 1.06, 1);
    add(this.head, new THREE.SphereGeometry(0.115 * k, 16, 10, 0, Math.PI * 2, 0, Math.PI * 0.52), C.hair, 0, 0.012 * k, 0.008 * k, 0.94, 1.06, 1.04);
    for (const x of [-0.035, 0.035]) add(this.head, new THREE.SphereGeometry(0.014 * k, 6, 4), C.eye, x * k, 0.015 * k, -0.095 * k);
    add(this.head, new THREE.BoxGeometry(0.02 * k, 0.035 * k, 0.03 * k), C.skin, 0, -0.012 * k, -0.105 * k);
    if (hairStyle === 'long') add(this.head, new THREE.BoxGeometry(0.2 * k, 0.26 * k, 0.07 * k), C.hair, 0, -0.1 * k, 0.07 * k);
    if (hairStyle === 'bun') add(this.head, new THREE.SphereGeometry(0.06 * k, 10, 8), C.hair, 0, 0.06 * k, 0.1 * k);

    const arm = (side) => {
      const sh = group(this.spine, side * 0.19 * k, 0.45 * k, 0);
      add(sh, cap(0.047 * k, 0.2 * k), C.shirt, 0, -0.145 * k, 0);
      const el = group(sh, 0, -0.29 * k, 0);
      add(el, cap(0.04 * k, 0.17 * k), sleeves === 'long' ? C.shirt : C.skin, 0, -0.125 * k, 0);
      add(el, new THREE.SphereGeometry(0.045 * k, 8, 6), C.skin, 0, -0.27 * k, 0, 0.8, 1.1, 0.9);
      return { sh, el };
    };
    const leg = (side) => {
      const hip = group(this.hips, side * 0.09 * k, 0, 0);
      add(hip, cap(0.068 * k, 0.3 * k), C.pants, 0, -0.215 * k, 0);
      const knee = group(hip, 0, -0.43 * k, 0);
      add(knee, cap(0.052 * k, 0.31 * k), C.pants, 0, -0.205 * k, 0);
      add(knee, new THREE.BoxGeometry(0.1 * k, 0.07 * k, 0.25 * k), C.shoes, 0, -0.43 * k, -0.05 * k);
      return { hip, knee };
    };
    this.armL = arm(-1);
    this.armR = arm(1);
    this.legL = leg(-1);
    this.legR = leg(1);
    this.headMeshes = [];
    for (const [g, batch] of parts) {
      const mesh = batch.build({ castShadow: shadows }).children[0];
      g.add(mesh);
      if (g === this.head) this.headMeshes.push(mesh);
    }
    this.applyPose(POSES.stand);
  }

  applyPose(p) {
    this.spine.rotation.x = p.spine;
    this.legL.hip.rotation.x = p.hipL;
    this.legR.hip.rotation.x = p.hipR;
    this.legL.knee.rotation.x = p.kneeL;
    this.legR.knee.rotation.x = p.kneeR;
    this.armL.sh.rotation.set(p.shLx, 0, p.shLz);
    this.armR.sh.rotation.set(p.shRx, 0, p.shRz);
    this.armL.el.rotation.x = p.elL;
    this.armR.el.rotation.x = p.elR;
  }

  // mode: 'stand' | 'sit' | 'wheelchair' | 'walk'. Переход позы — плавный.
  setMode(mode, instant = false) {
    const pose = mode === 'walk' ? 'stand' : mode;
    this.mode = mode;
    if (pose !== this.blend.to) this.blend = { from: this.blend.t >= 1 ? this.blend.to : this.poseName, to: pose, t: instant ? 1 : 0 };
    if (instant) this.blend.t = 1;
  }

  setHeadVisible(v) {
    for (const m of this.headMeshes) m.visible = v;
  }

  update(dt) {
    this.breath += dt;
    if (this.blend.t < 1) this.blend.t = Math.min(1, this.blend.t + dt / 0.9);
    const a = POSES[this.blend.from], b = POSES[this.blend.to];
    const t = this.blend.t * this.blend.t * (3 - 2 * this.blend.t);
    const pose = {};
    for (const key of POSE_KEYS) pose[key] = lerp(a[key], b[key], t);
    this.poseName = t > 0.5 ? this.blend.to : this.blend.from;
    const hipY = (name) => (name === 'stand' ? this.hipHeight : this.sitHeight + 0.06);
    const hipsY = lerp(hipY(this.blend.from), hipY(this.blend.to), t);

    // Ходьба: размах ног и рук от скорости.
    let bob = 0;
    if (this.mode === 'walk' && this.speed > 0.05) {
      this.walkPhase += dt * this.speed * 5.2;
      const s = Math.sin(this.walkPhase), amp = clamp(this.speed / 1.4, 0.3, 1);
      pose.hipL += s * 0.48 * amp;
      pose.hipR -= s * 0.48 * amp;
      pose.kneeL -= Math.max(0, -Math.cos(this.walkPhase)) * 0.9 * amp;
      pose.kneeR -= Math.max(0, Math.cos(this.walkPhase)) * 0.9 * amp;
      pose.shLx -= s * 0.38 * amp;
      pose.shRx += s * 0.38 * amp;
      bob = Math.abs(Math.cos(this.walkPhase)) * 0.035 * amp;
    }
    pose.spine += Math.sin(this.breath * 1.6) * 0.012;
    this.applyPose(pose);
    this.hips.position.y = hipsY + bob;

    // Голова поворачивается к цели (собеседник, окно), в пределах шеи.
    let yaw = 0, pitch = 0;
    if (this.lookTarget) {
      this.root.updateMatrixWorld(true);
      const local = this.neck.worldToLocal(this.lookTarget.clone());
      yaw = clamp(Math.atan2(-local.x, -local.z), -1.2, 1.2);
      pitch = clamp(Math.atan2(local.y - 0.16 * this.k, Math.hypot(local.x, local.z)), -0.5, 0.45);
    }
    this.headYaw = damp(this.headYaw, yaw, 5, dt);
    this.headPitch = damp(this.headPitch, pitch, 5, dt);
    this.talking = Math.max(0, this.talking - dt);
    const nod = this.talking > 0 ? Math.sin(this.breath * 9) * 0.03 : 0;
    this.head.rotation.set(this.headPitch + nod, this.headYaw, 0, 'YXZ');
  }
}

// Электроколяска со средним приводом. Начало координат — на земле под осью ведущих колёс,
// «перед» смотрит в −Z.
export class Wheelchair {
  constructor({ frame = '#2d3136', seat = '#1f4e8c', accent = '#4fa3ff' } = {}) {
    this.root = new THREE.Group();
    this.root.name = 'wheelchair';
    this.seatHeight = 0.52;
    this.wheels = [];
    // Оптимизация: рама — один меш, каждое колесо — один меш (цвета в вершинах).
    const C = { frame, seat, tire: '#151515', rim: '#9aa3ab', accent, black: '#0e0e0e' };
    const material = new THREE.MeshStandardMaterial({ vertexColors: true, roughness: 0.6 });
    const body = new Batcher();
    const add = (geo, color, x, y, z, rx = 0) => body.add(geo, matrix(x, y, z, rx), material, color);
    add(new THREE.BoxGeometry(0.5, 0.18, 0.78), C.frame, 0, 0.22, 0);              // база
    add(new THREE.BoxGeometry(0.34, 0.14, 0.4), C.black, 0, 0.36, 0.05);           // аккумулятор
    add(new THREE.CylinderGeometry(0.05, 0.05, 0.12, 10), C.frame, 0, 0.44, 0.04); // стойка сиденья
    add(new THREE.BoxGeometry(0.47, 0.09, 0.47), C.seat, 0, this.seatHeight - 0.04, 0.03);
    add(new THREE.BoxGeometry(0.46, 0.56, 0.08), C.seat, 0, 0.84, 0.29);           // спинка
    add(new THREE.BoxGeometry(0.28, 0.17, 0.08), C.seat, 0, 1.24, 0.31);           // подголовник
    add(new THREE.CylinderGeometry(0.015, 0.015, 0.2, 6), C.frame, 0, 1.12, 0.33);
    const wheel = (parent, x, y, z, r, pieces) => {
      const g = new THREE.Group();
      g.position.set(x, y, z);
      parent.add(g);
      const b = new Batcher();
      for (const [geo, color] of pieces) b.add(geo, null, material, color);
      g.add(b.build().children[0]);
      this.wheels.push({ g, r });
    };
    for (const side of [-1, 1]) {
      add(new THREE.BoxGeometry(0.07, 0.05, 0.4), C.black, side * 0.27, 0.72, 0.0); // подлокотник
      add(new THREE.BoxGeometry(0.03, 0.22, 0.03), C.frame, side * 0.27, 0.6, 0.15);
      wheel(this.root, side * 0.29, 0.17, 0, 0.17, [                               // ведущее колесо
        [new THREE.TorusGeometry(0.15, 0.035, 8, 20).rotateY(Math.PI / 2), C.tire],
        [new THREE.CylinderGeometry(0.11, 0.11, 0.05, 14).rotateZ(Math.PI / 2), C.rim],
        [new THREE.BoxGeometry(0.055, 0.2, 0.03), C.accent],
      ]);
      for (const z of [-0.36, 0.38]) {                                               // поворотные колёсики
        wheel(this.root, side * 0.2, 0.065, z, 0.065, [[new THREE.CylinderGeometry(0.065, 0.065, 0.04, 10).rotateZ(Math.PI / 2), C.tire]]);
      }
    }
    // Подножка, кронштейн, пульт джойстика (справа).
    add(new THREE.BoxGeometry(0.4, 0.03, 0.22), C.frame, 0, 0.12, -0.44, 0.15);
    add(new THREE.BoxGeometry(0.03, 0.4, 0.03), C.frame, 0, 0.32, -0.36, -0.35);
    add(new THREE.BoxGeometry(0.08, 0.05, 0.12), C.black, 0.3, 0.74, -0.18);
    add(new THREE.SphereGeometry(0.022, 8, 6), C.accent, 0.3, 0.84, -0.2);
    this.root.add(body.build().children[0]);
    this.joystick = new THREE.Mesh(new THREE.CylinderGeometry(0.012, 0.012, 0.07, 6), mat(frame, 0.5));
    this.joystick.position.set(0.3, 0.8, -0.2);
    this.root.add(this.joystick);
    this.lightBar = new THREE.Mesh(new THREE.BoxGeometry(0.16, 0.02, 0.01), new THREE.MeshStandardMaterial({ color: '#103010', emissive: '#30ff60', emissiveIntensity: 1.2 }));
    this.lightBar.position.set(0.3, 0.768, -0.24);
    this.root.add(this.lightBar);
  }

  // distance — пройдено вперёд (м), turn — поворот (рад) за кадр: колёса крутятся.
  roll(distance, turn = 0) {
    for (const [i, w] of this.wheels.entries()) {
      const side = i < 3 ? -1 : 1;
      const d = distance + side * turn * 0.29;
      w.g.rotation.x -= d / w.r;
    }
    this.joystick.rotation.x = clamp(-distance * 25, -0.4, 0.4);
  }
}

// Персонаж с героем в коляске: удобная связка для салона, катсцены и улицы.
export class HeroInChair {
  constructor(opts = {}) {
    this.root = new THREE.Group();
    this.root.name = 'hero-in-chair';
    this.chair = opts.chair || new Wheelchair();
    this.root.add(this.chair.root);
    this.hero = opts.hero || new Human({ name: 'hero', shirt: '#3a6ea5', pants: '#2f3e5c', hair: '#21160f', sitHeight: this.chair.seatHeight });
    this.hero.root.position.set(0, 0, 0.04);
    this.root.add(this.hero.root);
    this.hero.setMode('wheelchair', true);
    // Глаза героя в координатах коляски (для вида от первого лица).
    this.eye = new THREE.Vector3(0, this.chair.seatHeight + 0.06 + 0.67 * this.hero.k + 0.02, -0.06);
  }

  update(dt) {
    this.hero.update(dt);
  }
}

// Обёртка для GLB-моделей: тот же интерфейс, что у Human (setMode/update/root).
// clips: { stand: 'Idle', walk: 'Walking', sit: 'Sitting', wheelchair: 'Sitting' }.
export class ModelActor {
  constructor(gltf, { clips = {}, name = 'actor' } = {}) {
    this.root = new THREE.Group();
    this.root.name = name;
    this.model = gltf.scene;
    this.root.add(this.model);
    this.model.traverse((o) => { if (o.isMesh) { o.castShadow = true; o.receiveShadow = true; } });
    this.mixer = gltf.animations?.length ? new THREE.AnimationMixer(this.model) : null;
    this.clips = clips;
    this.actions = {};
    this.mode = 'stand';
    this.speed = 0;
    this.lookTarget = null;
    this.k = 1;
    this.talking = 0;
    if (this.mixer) {
      for (const clip of gltf.animations) this.actions[clip.name] = this.mixer.clipAction(clip);
    }
    this.current = null;
    this.setMode('stand', true);
  }

  setMode(mode, instant = false) {
    this.mode = mode;
    const name = this.clips[mode];
    const next = name && this.actions[name];
    if (!next || next === this.current) return;
    next.reset().play();
    if (this.current) this.current.crossFadeTo(next, instant ? 0 : 0.5, false);
    this.current = next;
  }

  setHeadVisible() {}

  update(dt) {
    if (this.mixer) this.mixer.update(dt * (this.mode === 'walk' ? clamp(this.speed / 1.3, 0.5, 1.6) : 1));
  }
}

// Поворот объекта к направлению движения (для ходьбы).
export function faceTowards(obj, dx, dz, dt, rate = 6) {
  if (Math.abs(dx) + Math.abs(dz) < 1e-4) return;
  const target = Math.atan2(-dx, -dz);
  obj.rotation.y += angleDiff(obj.rotation.y, target) * Math.min(1, dt * rate);
}
