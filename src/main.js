// Главный файл: сцена, фазы игры (меню → поездка → прибытие → улица → конец), управление.
import * as THREE from 'three';
import { CONFIG } from './config.js';
import { STORY } from './story.js';
import { BusDriver, makeSpeedPlan, routeForDuration } from './route.js';
import { World, createMaterials } from './world.js';
import { Bus } from './bus.js';
import { HeroInChair, Human, ModelActor, Wheelchair, faceTowards } from './characters.js';
import { Traffic, parkHospitalCars } from './traffic.js';
import { GameAudio } from './audio.js';
import { loadAssets, MANIFEST } from './assets.js';
import { UI } from './ui.js';
import { Dialogue } from './dialogue.js';
import { tween, until, updateTweens, wait } from './tween.js';
import { skyMaterial } from './textures.js';
import { angleDiff, clamp, damp, lerp, params, smoothstep } from './utils.js';

// ---------------------------------------------------------------------------
// Рендер, сцена, свет
// ---------------------------------------------------------------------------
const canvas = document.getElementById('scene');
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, powerPreference: 'high-performance' });
renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, CONFIG.graphics.pixelRatioMax));
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.05;
renderer.shadowMap.enabled = CONFIG.graphics.shadows;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;

const scene = new THREE.Scene();
const HORIZON = new THREE.Color('#cfe0ee');
scene.background = HORIZON;
scene.fog = new THREE.Fog(HORIZON, 90, 620);
const camera = new THREE.PerspectiveCamera(CONFIG.camera.fov, window.innerWidth / window.innerHeight, 0.05, 2500);
scene.add(camera);

const sky = new THREE.Mesh(new THREE.SphereGeometry(1800, 32, 16), skyMaterial());
sky.renderOrder = -1;
scene.add(sky);
const hemi = new THREE.HemisphereLight(0xcfe3f5, 0x6f6a55, 1.05);
scene.add(hemi);
const sun = new THREE.DirectionalLight(0xfff0d8, 2.6);
const SUN_DIR = new THREE.Vector3(0.45, 0.62, -0.5).normalize();
sun.castShadow = true;
sun.shadow.mapSize.set(CONFIG.graphics.shadowMapSize, CONFIG.graphics.shadowMapSize);
Object.assign(sun.shadow.camera, { left: -32, right: 32, top: 32, bottom: -32, near: 1, far: 220 });
sun.shadow.bias = -0.0004;
sun.shadow.normalBias = 0.03;
scene.add(sun, sun.target);

window.addEventListener('resize', () => {
  camera.aspect = window.innerWidth / window.innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(window.innerWidth, window.innerHeight);
});

// ---------------------------------------------------------------------------
// Состояние
// ---------------------------------------------------------------------------
const ui = new UI();
const audio = new GameAudio();
const raycaster = new THREE.Raycaster();
const V = (x = 0, y = 0, z = 0) => new THREE.Vector3(x, y, z);
const debug = params.has('debug');
let assets = null;

const G = {
  phase: 'loading',
  paused: false,
  time: 0,
  keys: new Set(),
  look: { yaw: 0, pitch: -0.08 },
  orbit: { yaw: 0, pitch: 0.32, idle: 0 },
  cameraMode: 'fp',
  sens: 1,
  expectUnlock: false,
  fps: 60,
};
window.__game = G; // для отладки и автотестов

// ---------------------------------------------------------------------------
// Сборка мира под выбранную длительность поездки
// ---------------------------------------------------------------------------
function disposeTree(obj) {
  obj.traverse((o) => {
    if (o.geometry) o.geometry.dispose();
    if (o.material) (Array.isArray(o.material) ? o.material : [o.material]).forEach((m) => m.dispose());
  });
}

// Точка головы персонажа (для взгляда мамы); у GLB-моделей — примерно на высоте глаз.
function headPos(actor) {
  if (actor.head) return actor.head.getWorldPosition(new THREE.Vector3());
  return actor.root.localToWorld(V(0, 1.25, 0));
}

function makeMom() {
  if (assets.models.mom) return new ModelActor(assets.models.mom, { clips: MANIFEST.models.mom.clips, name: 'mom' });
  return new Human({ name: 'mom', height: 1.62, shirt: '#8e3b46', pants: '#2b2d42', hair: '#2a1b12', shoes: '#3a2a20', hairStyle: 'bun', sitHeight: 0.47 });
}

function makeHero() {
  const chair = new Wheelchair();
  if (assets.models.wheelchair) {
    chair.root.children.forEach((c) => { c.visible = false; });
    chair.root.add(assets.models.wheelchair.scene);
  }
  const hero = assets.models.hero ? new ModelActor(assets.models.hero, { clips: MANIFEST.models.hero.clips, name: 'hero' }) : undefined;
  const h = new HeroInChair({ chair, hero });
  h.root.rotation.order = 'YXZ';
  return h;
}

function buildGame(minutes) {
  if (G.root) {
    scene.remove(G.root);
    disposeTree(G.root);
  }
  const root = new THREE.Group();
  root.name = 'game';
  scene.add(root);
  const route = routeForDuration(minutes * 60);
  const world = new World(root, route, createMaterials(assets.textures));
  if (assets.models.hospital) world.hospital.useModel(assets.models.hospital);
  parkHospitalCars(world.hospital);
  const bus = new Bus({ busFloor: assets.textures.busFloor, busSeat: assets.textures.busSeat, busModel: assets.models.bus });
  root.add(bus.root);
  const driver = new BusDriver(route, makeSpeedPlan(route));
  const traffic = new Traffic(root, world, route);

  const hero = makeHero();
  const a = bus.anchors.wheelchair;
  hero.root.position.copy(a.pos);
  hero.root.rotation.y = a.yaw;
  bus.body.add(hero.root);
  const mom = makeMom();
  mom.root.position.copy(bus.anchors.mom.pos);
  mom.root.rotation.y = bus.anchors.mom.yaw;
  mom.setMode('sit', true);
  bus.body.add(mom.root);
  bus.interactables.push(mom.root);

  const dialogue = new Dialogue(ui, { actors: { mom, driver: bus.driver }, actions: { stopButtonTask } });
  const final = route.byId.hospital;
  const span = final.s - route.startS;
  ui.setupRoute(['park', 'market', 'hospital'].map((id) => ({
    name: STORY.stops[id], at: (route.byId[id].s - route.startS) / span, final: id === 'hospital',
  })));

  Object.assign(G, {
    root, route, world, bus, driver, traffic, hero, mom, dialogue,
    builtMinutes: minutes, fired: new Set(), idleIndex: 0, stopTask: false,
    lightCycle: false, busGone: false, momLookTimer: 4, momLookWindow: 0,
    player: null, outsideTime: 0,
  });
  driver.onArrive = onArrive;
  placeBus(0);
}

// ---------------------------------------------------------------------------
// Автобус на маршруте
// ---------------------------------------------------------------------------
function curbWeight(s) {
  let w = 0;
  for (const ev of G.route.events) {
    if (ev.kind === 'light') continue;
    const d = ev.s - s;
    w = Math.max(w, d >= 0 ? smoothstep(80, 14, d) : smoothstep(-50, -6, d));
  }
  return w;
}

function busLateral(s) {
  return lerp(CONFIG.bus.laneOffset, CONFIG.bus.curbOffset, curbWeight(s));
}

function placeBus(dt, moving = true) {
  const { route, driver, bus } = G;
  const s = driver.s;
  const lat = busLateral(s);
  bus.root.position.copy(route.point(s, lat, 0));
  const slope = (busLateral(s + 1) - busLateral(s - 1)) / 2;
  bus.root.rotation.y = route.yaw(s) - Math.atan(slope);
  bus.update(dt, { speed: moving ? driver.v : 0, accel: moving ? driver.accel : 0, curvature: route.curvature(s), time: G.time });
}

function nextStopName() {
  const { driver } = G;
  for (let i = driver.index; i < G.route.events.length; i++) {
    const ev = G.route.events[i];
    if (ev.kind !== 'light') return STORY.stops[ev.id];
  }
  return STORY.stops.hospital;
}

function fill(template, stop) {
  return template.replace('{stop}', stop);
}

function openDoors(names, open = true, sim = true) {
  audio.hiss();
  const from = names.map((n) => G.bus.doorOpen[n]);
  return tween({ duration: 1.2, sim, onUpdate: (k) => names.forEach((n, i) => { G.bus.doorOpen[n] = lerp(from[i], open ? 1 : 0, k); }) });
}

async function onArrive(ev) {
  const { bus, driver, world } = G;
  bus.indicator = 0;
  if (ev.kind === 'light') {
    G.dialogue.play(STORY.events.redlight);
    await wait(CONFIG.bus.redLight, true);
    world.trafficLight.set('green');
    driver.release();
    return;
  }
  if (ev.kind === 'final') {
    runArrival();
    return;
  }
  await openDoors(['front', 'middle']);
  const nextName = (() => { const e = G.route.events.slice(driver.index + 1).find((x) => x.kind !== 'light'); return e ? STORY.stops[e.id] : null; })();
  audio.chime();
  G.dialogue.play([['announcer', `${fill(STORY.announce.arrive, STORY.stops[ev.id])}${nextName ? ' ' + fill(STORY.announce.next, nextName) : ''}`]]);
  G.dialogue.play(STORY.events[`arrive_${ev.id}`]);
  exchangePassengers(ev);
  await wait(CONFIG.bus.dwell, true);
  audio.beeps(3);
  await wait(1.0, true);
  await openDoors(['front', 'middle'], false);
  bus.setStopRequested(false);
  bus.indicator = -1;
  driver.release();
  wait(4, true).then(() => { if (bus.indicator === -1 && G.phase === 'ride') bus.indicator = 0; });
}

// ---------------------------------------------------------------------------
// Пассажиры на остановках: кто-то выходит, кто-то входит.
// ---------------------------------------------------------------------------
function walkPath(actor, points, speed = 1.2, sim = true) {
  const pts = [actor.root.position.clone(), ...points];
  const lens = [];
  let total = 0;
  for (let i = 1; i < pts.length; i++) { lens.push(pts[i].distanceTo(pts[i - 1])); total += lens[i - 1]; }
  if (total < 0.01) return Promise.resolve();
  actor.setMode('walk');
  actor.speed = speed;
  return tween({
    duration: total / speed, sim, ease: (t) => t,
    onUpdate: (k) => {
      let d = k * total, i = 0;
      while (i < lens.length - 1 && d > lens[i]) { d -= lens[i]; i++; }
      const a = pts[i], b = pts[i + 1];
      const t = lens[i] > 0 ? Math.min(1, d / lens[i]) : 1;
      actor.root.position.lerpVectors(a, b, t);
      actor.root.rotation.y += angleDiff(actor.root.rotation.y, Math.atan2(-(b.x - a.x), -(b.z - a.z))) * 0.2;
    },
  }).then(() => { actor.setMode('stand'); actor.speed = 0; });
}

async function exchangePassengers(ev) {
  const { bus } = G;
  const FY = CONFIG.bus.floorY, HW = CONFIG.bus.width / 2;
  // Выходит ближайший к средней двери сидящий пассажир.
  const leaving = bus.passengers.filter((p) => p.mode === 'sit').sort((a, b) => Math.abs(a.root.position.z - 0.5) - Math.abs(b.root.position.z - 0.5))[0];
  if (leaving) {
    leaving.seat.taken = false;
    bus.passengers.splice(bus.passengers.indexOf(leaving), 1);
    leaving.setMode('stand');
    wait(1, true).then(async () => {
      const p = leaving.root.position;
      await walkPath(leaving, [V(0.1, FY, p.z), V(0.15, FY, 1.6), V(HW - 0.2, FY, 1.0), V(HW + 0.5, 0.18, 1.2), V(HW + 1.8, 0.15, 2.6)], 1.1);
      G.root.attach(leaving.root);
      const dir = G.route.sample(G.driver.s);
      const away = leaving.root.position.clone().add(V(dir.dx * 30, 0, dir.dz * 30));
      await walkPath(leaving, [away], 1.2);
      G.root.remove(leaving.root);
    });
  }
  // Входит новый пассажир у передней двери.
  const seat = bus.seats.find((s) => !s.taken && s.pos.z < -1 && !(s.pos.x < 0 && s.pos.z > -4.5 && s.pos.z < -4.3));
  if (!seat) return;
  seat.taken = true;
  const r = Math.random;
  const p = new Human({ name: 'passenger', shirt: ['#7a4b8c', '#3c7a6a', '#b5622c', '#4a5d8a'][Math.floor(r() * 4)], pants: '#2e2e38', hair: r() < 0.5 ? '#2a1d14' : '#7d7d7d', hairStyle: r() < 0.5 ? 'long' : 'short', height: 1.6 + r() * 0.2, sitHeight: 0.5 });
  p.root.position.set(HW + 2.4, 0.15, -6.5);
  bus.body.add(p.root);
  await walkPath(p, [V(HW + 0.9, 0.15, -5.0), V(HW - 0.3, FY, -5.0), V(0.1, FY, -4.0), V(0.1, FY, seat.pos.z), V(seat.pos.x, FY, seat.pos.z)], 1.0);
  p.root.rotation.y = seat.yaw;
  p.setMode('sit');
  p.seat = seat;
  bus.passengers.push(p);
}

// ---------------------------------------------------------------------------
// Поездка
// ---------------------------------------------------------------------------
function startRide() {
  G.phase = 'ride';
  ui.show('menu', false);
  ui.show('hud', true);
  ui.setFade(1);
  ui.objective(STORY.objectives.ride);
  setCameraMode('fp');
  ui.fade(0, 2.5);
  ui.titleCard(STORY.title, STORY.subtitle, 2.5);
  ui.show('lockHint', true);
  const skip = params.get('skipto');
  if (skip) { jumpTo(skip); return; }
  wait(3).then(() => {
    audio.chime();
    G.dialogue.play([['announcer', fill(STORY.announce.next, STORY.stops.park)]]);
    G.dialogue.play(STORY.events.intro);
  });
}

function setCameraMode(mode) {
  G.cameraMode = mode;
  G.hero.hero.setHeadVisible(mode !== 'fp');
  ui.show('crosshair', mode === 'fp');
}

function stopButtonTask() {
  G.stopTask = true;
  if (!G.bus.stopRequested) ui.objective(STORY.objectives.pressStop);
}

function pressStopButton(byMom = false) {
  const { bus } = G;
  if (bus.stopRequested) return;
  bus.setStopRequested(true);
  audio.ding();
  if (G.stopTask) {
    ui.objective(STORY.objectives.ride);
    G.dialogue.play(byMom ? STORY.events.stop_mom_pressed : STORY.events.stop_pressed);
    G.stopTask = false;
  }
}

function talkToMom() {
  if (G.dialogue.busy) return;
  const conv = G.idleIndex < STORY.idle.length ? STORY.idle[G.idleIndex++] : STORY.idleRepeat[Math.floor(Math.random() * STORY.idleRepeat.length)];
  G.dialogue.play(conv);
}

function updateRide(dt, sdt) {
  const { driver, route, world, bus } = G;
  const ev = driver.next;
  // Светофор: перед автобусом загорается жёлтый, потом красный.
  if (ev?.kind === 'light' && !G.lightCycle && ev.s - driver.s < 150) {
    G.lightCycle = true;
    world.trafficLight.set('yellow');
    wait(2.2, true).then(() => world.trafficLight.set('red'));
  }
  // Поворотник к бордюру перед остановкой.
  if (ev && ev.kind !== 'light' && !driver.stopped) bus.indicator = ev.s - driver.s < 90 ? 1 : (bus.indicator === 1 ? 0 : bus.indicator);
  // Ведём автобус мелкими шагами (при перемотке шаг большой).
  const steps = Math.max(1, Math.ceil(sdt / 0.04));
  for (let i = 0; i < steps; i++) driver.update(sdt / steps);
  placeBus(dt);

  // События по доле пути.
  const final = route.byId.hospital;
  const progress = (driver.s - route.startS) / (final.s - route.startS);
  ui.setRouteProgress(progress);
  for (const p of STORY.events.progress) {
    const key = `p${p.at}`;
    if (progress >= p.at && !G.fired.has(key)) { G.fired.add(key); G.dialogue.play(p.steps); }
  }
  const toFinal = final.s - driver.s;
  if (toFinal < 430 && !G.fired.has('approach')) {
    G.fired.add('approach');
    audio.chime();
    G.dialogue.play([['announcer', fill(STORY.announce.next, STORY.stops.hospital)]]);
    G.dialogue.play(STORY.events.approach_hospital);
  }
  if (G.stopTask && !bus.stopRequested && toFinal < 140) pressStopButton(true);

  // Табло в салоне.
  const atStop = driver.stopped && ev && ev.kind !== 'light';
  bus.led.set(atStop ? STORY.stops[ev.id] : `След.: ${nextStopName()}`);

  traffic(sdt);
  updateMomInBus(dt);
  updateInteraction();
}

function traffic(sdt) {
  G.traffic.update(sdt, G.driver.s, G.driver.v);
}

// Мама смотрит на сына, иногда — в окно.
function updateMomInBus(dt) {
  const { mom, hero, bus } = G;
  G.momLookTimer -= dt;
  if (G.momLookTimer <= 0) {
    G.momLookWindow = G.momLookWindow > 0 ? 0 : 4;
    G.momLookTimer = G.momLookWindow > 0 ? 4 : 6 + Math.random() * 8;
  }
  const talking = G.dialogue.speaker && G.dialogue.speaker !== 'announcer';
  if (G.momLookWindow > 0 && !talking) mom.lookTarget = bus.body.localToWorld(V(-1.6, 1.7, 1.6));
  else mom.lookTarget = headPos(hero.hero);
  mom.update(dt);
  hero.update(dt);
}

function updateInteraction() {
  if (G.cameraMode !== 'fp' || G.phase !== 'ride') { ui.prompt(null); G.target = null; return; }
  // Автобус за кадр сдвигается на полметра: обновляем координаты салона и камеры,
  // иначе луч летит из нового места в кнопку, оставшуюся в прошлом кадре.
  G.bus.root.updateMatrixWorld(true);
  updateCamera(0);
  camera.updateMatrixWorld();
  raycaster.setFromCamera({ x: 0, y: 0 }, camera);
  raycaster.far = 2.8;
  const hits = raycaster.intersectObjects([G.mom.root, G.bus.stopButton], true);
  let target = null;
  if (hits.length) {
    let o = hits[0].object;
    while (o && o !== G.mom.root && o !== G.bus.stopButton) o = o.parent;
    target = o === G.mom.root ? 'mom' : o === G.bus.stopButton ? 'button' : null;
  }
  G.target = target;
  if (target === 'mom') ui.prompt(G.dialogue.busy ? null : '<b>E</b> — поговорить с мамой');
  else if (target === 'button') ui.prompt(G.bus.stopRequested ? 'Остановка запрошена' : '<b>E</b> — нажать кнопку вызова');
  else ui.prompt(null);
}

function interact() {
  if (G.phase !== 'ride') return;
  if (G.target === 'mom') talkToMom();
  else if (G.target === 'button') pressStopButton(false);
}

// ---------------------------------------------------------------------------
// Прибытие: затемнение, пандус, мама и коляска выходят, автобус уезжает.
// ---------------------------------------------------------------------------
async function runArrival() {
  const { bus, hero, mom, dialogue } = G;
  G.phase = 'arrival';
  dialogue.clear(); // старые разговоры не должны задерживать выход
  ui.prompt(null);
  ui.show('lockHint', false);
  ui.show('ff', false);
  ui.objective('');
  bus.indicator = 0;
  await openDoors(['front', 'middle'], true, false);
  audio.chime();
  await dialogue.play([['announcer', fill(STORY.announce.arrive, STORY.stops.hospital)]]);
  await dialogue.play(STORY.events.arrive_hospital);
  await ui.fade(1, 1.3);
  exitPointerLock();

  // В темноте: разворачиваем коляску к двери, мама встаёт.
  const FY = CONFIG.bus.floorY, HW = CONFIG.bus.width / 2;
  setCameraMode('cut');
  hero.root.position.set(-0.5, FY, 0.5);
  hero.root.rotation.set(0, -Math.PI / 2, 0);
  mom.root.position.set(0.5, FY, 1.4);
  mom.root.rotation.y = -Math.PI / 2;
  mom.setMode('stand', true);
  mom.lookTarget = null;
  const camFrom = bus.root.localToWorld(V(HW + 6.2, 1.6, 5.8));
  const camTo = bus.root.localToWorld(V(HW + 4.3, 1.35, 3.4));
  const lookAt = bus.root.localToWorld(V(HW, 0.9, 0.5));
  G.cut = { pos: camFrom.clone(), look: lookAt.clone() };
  await ui.fade(0, 1.2);

  audio.rampMotor(2.2);
  await tween({ duration: 2.2, onUpdate: (k) => bus.setRamp(k) });
  await walkPath(mom, [V(HW - 0.15, FY, 1.25), V(HW + 0.5, 0.2, 1.35), V(HW + 1.7, 0.15, 1.7), V(HW + 2.5, 0.15, 1.9)], 1.0, false);
  mom.root.rotation.y = Math.atan2(-(HW - (HW + 2.5)), -(0.5 - 1.9));
  mom.lookTarget = headPos(hero.hero);
  G.dialogue.play([['mom', 'Осторожно, пандус…']]);

  // Коляска съезжает: по салону, по пандусу, на тротуар.
  const path = [V(HW - 0.2, FY, 0.5), V(HW + 0.93, 0.15, 0.5), V(HW + 2.0, 0.15, 0.5)];
  const speeds = [0.55, 0.42, 0.5];
  tween({ duration: 7.2, onUpdate: (k) => G.cut.pos.lerpVectors(camFrom, camTo, k) });
  for (let i = 0; i < path.length; i++) {
    const from = hero.root.position.clone(), to = path[i];
    const len = from.distanceTo(to);
    let last = 0;
    await tween({
      duration: len / speeds[i], ease: (t) => t,
      onUpdate: (k) => {
        hero.root.position.lerpVectors(from, to, k);
        hero.root.rotation.x = i === 1 ? -Math.atan2(FY - 0.15, 0.95) * smoothstep(0, 0.15, k) * smoothstep(1, 0.85, k) : 0;
        hero.chair.roll((k - last) * len);
        last = k;
        mom.lookTarget = headPos(hero.hero);
      },
    });
  }
  hero.root.rotation.x = 0;

  // Пандус убирается, двери закрываются, автобус уезжает.
  G.hospitalParent = G.world.hospital.group;
  G.hospitalParent.attach(hero.root);
  G.hospitalParent.attach(mom.root);
  for (const a of [hero.root, mom.root]) { a.rotation.x = 0; a.rotation.z = 0; }
  audio.rampMotor(2);
  await tween({ duration: 2, onUpdate: (k) => bus.setRamp(1 - k) });
  audio.beeps(3);
  await wait(1);
  await openDoors(['front', 'middle'], false, false);
  bus.indicator = -1;
  G.driver.release();
  G.busLeaving = true;
  tween({ duration: 3, onUpdate: (k) => G.cut.look.lerpVectors(lookAt, bus.root.localToWorld(V(0, 1.5, -2)), k * 0.6) });
  await wait(3.5);
  enterOutside(true);
}

// Переход к прогулке. smooth — камера плавно уходит за спину героя.
function enterOutside(smooth) {
  const { hero, mom, world } = G;
  const H = world.hospital;
  if (hero.root.parent !== H.group) {
    H.group.add(hero.root);
    H.group.add(mom.root);
    hero.root.position.set(5.62 + CONFIG.bus.width / 2 + 2.0, 0.15, 0.5);
    hero.root.rotation.set(0, -Math.PI / 2, 0);
    mom.root.position.set(5.62 + CONFIG.bus.width / 2 + 2.5, 0.15, 1.9);
    mom.setMode('stand', true);
  }
  G.player = { x: hero.root.position.x, z: hero.root.position.z, yaw: hero.root.rotation.y, v: 0, w: 0 };
  G.phase = 'outside';
  G.outsideTime = 0;
  G.camBlend = smooth ? 0 : 1;
  G.orbit.yaw = 0;
  setCameraMode('tp');
  ui.objective(STORY.objectives.outside);
  ui.show('routeHud', false);
  ui.show('lockHint', true);
  ui.titleCard(STORY.stops.hospital, '', 2.5);
  G.dialogue.play(STORY.events.outside_start);
}

// ---------------------------------------------------------------------------
// Улица: управление коляской, мама идёт рядом.
// ---------------------------------------------------------------------------
function resolveCollisions(pos, r, colliders) {
  for (let iter = 0; iter < 3; iter++) {
    for (const c of colliders) {
      if (c.type === 'box') {
        const cx = clamp(pos.x, c.x0, c.x1), cz = clamp(pos.z, c.z0, c.z1);
        const dx = pos.x - cx, dz = pos.z - cz, d2 = dx * dx + dz * dz;
        if (d2 >= r * r) continue;
        if (d2 > 1e-8) {
          const d = Math.sqrt(d2);
          pos.x = cx + (dx / d) * r;
          pos.z = cz + (dz / d) * r;
        } else {
          const pen = [pos.x - c.x0, c.x1 - pos.x, pos.z - c.z0, c.z1 - pos.z];
          const m = Math.min(...pen);
          if (m === pen[0]) pos.x = c.x0 - r; else if (m === pen[1]) pos.x = c.x1 + r; else if (m === pen[2]) pos.z = c.z0 - r; else pos.z = c.z1 + r;
        }
      } else {
        const dx = pos.x - c.x, dz = pos.z - c.z, d = Math.hypot(dx, dz), min = r + c.r;
        if (d < min && d > 1e-6) { pos.x = c.x + (dx / d) * min; pos.z = c.z + (dz / d) * min; }
      }
    }
  }
}

function updateOutside(dt) {
  const { hero, mom, world, player: P } = G;
  const H = world.hospital;
  const W = CONFIG.wheelchair;
  G.outsideTime += dt;
  const k = G.keys;
  const fwd = (k.has('KeyW') || k.has('ArrowUp') ? 1 : 0) - (k.has('KeyS') || k.has('ArrowDown') ? 1 : 0);
  const turn = (k.has('KeyA') || k.has('ArrowLeft') ? 1 : 0) - (k.has('KeyD') || k.has('ArrowRight') ? 1 : 0);
  const controls = G.phase === 'outside';
  const maxF = k.has('ShiftLeft') || k.has('ShiftRight') ? W.maxForwardFast : W.maxForward;
  const targetV = controls ? (fwd > 0 ? maxF : fwd < 0 ? -W.maxBackward : 0) : 0;
  // Разгон плавный, торможение резче (как у настоящей электроколяски).
  const speedingUp = Math.abs(targetV) > Math.abs(P.v) && Math.sign(targetV) === Math.sign(P.v || targetV);
  const dv = targetV - P.v;
  P.v += Math.sign(dv) * Math.min(Math.abs(dv), (speedingUp ? W.accel : W.brake) * dt);
  // Джойстик: «влево» — всегда поворот влево, и при езде назад тоже.
  P.w = damp(P.w, controls ? turn * W.turnRate : 0, 10, dt);
  P.yaw += P.w * dt;
  const ox = P.x, oz = P.z;
  const pos = { x: P.x - Math.sin(P.yaw) * P.v * dt, z: P.z - Math.cos(P.yaw) * P.v * dt };
  resolveCollisions(pos, W.radius, H.colliders);
  P.x = pos.x;
  P.z = pos.z;
  const moved = Math.hypot(P.x - ox, P.z - oz) * Math.sign(P.v || 1);
  // Высота по земле и наклон на пандусе.
  const fx = P.x - Math.sin(P.yaw) * 0.35, fz = P.z - Math.cos(P.yaw) * 0.35;
  const bx = P.x + Math.sin(P.yaw) * 0.35, bz = P.z + Math.cos(P.yaw) * 0.35;
  hero.root.position.set(P.x, H.groundHeight(P.x, P.z), P.z);
  hero.root.rotation.set(Math.atan2(H.groundHeight(fx, fz) - H.groundHeight(bx, bz), 0.7), P.yaw, 0, 'YXZ');
  hero.chair.roll(moved, P.w * dt);
  hero.update(dt);

  // Мама держится слева чуть позади.
  const target = { x: P.x - Math.cos(P.yaw) * 0.85 + Math.sin(P.yaw) * 0.9, z: P.z + Math.sin(P.yaw) * 0.85 + Math.cos(P.yaw) * 0.9 };
  const dx = target.x - mom.root.position.x, dz = target.z - mom.root.position.z;
  const dist = Math.hypot(dx, dz);
  if (dist > 0.45) {
    const sp = Math.min(1.7, 0.5 + dist * 0.9);
    const step = Math.min(dist, sp * dt);
    const mp = { x: mom.root.position.x + (dx / dist) * step, z: mom.root.position.z + (dz / dist) * step };
    resolveCollisions(mp, 0.28, H.colliders);
    resolveCollisions(mp, 0.28 + W.radius, [{ type: 'circle', x: P.x, z: P.z, r: 0 }]);
    mom.root.position.set(mp.x, H.groundHeight(mp.x, mp.z), mp.z);
    faceTowards(mom.root, dx, dz, dt);
    mom.speed = sp;
    if (mom.mode !== 'walk') mom.setMode('walk');
    mom.lookTarget = null;
  } else {
    if (mom.mode !== 'stand') mom.setMode('stand');
    mom.speed = 0;
    mom.lookTarget = headPos(hero.hero);
  }
  mom.update(dt);

  // Сюжетные точки: пандус, вход, подсказка, если долго не едем.
  const R = H.ramp, E = H.entrance;
  if (P.x > R.x0 && P.z > R.z0 && P.z < R.z1 && !G.fired.has('ramp')) { G.fired.add('ramp'); G.dialogue.play(STORY.events.outside_ramp); }
  if (G.outsideTime > 45 && !G.fired.has('ramp') && !G.fired.has('nudge') && !G.dialogue.busy) { G.fired.add('nudge'); G.dialogue.play(STORY.events.outside_nudge); }
  H.updateDoors(dt, new THREE.Vector3(P.x, 0, P.z));
  if (controls && P.x > E.x0 && P.x < E.x1 && Math.abs(P.z) < E.z1 && hero.root.position.y > 0.5) finish();

  // Автобус уезжает и исчезает вдали.
  updateLeavingBus(dt);
  G.traffic.update(dt, G.route.byId.hospital.s, 0);
}

function updateLeavingBus(dt) {
  if (!G.busLeaving || G.busGone) return;
  G.driver.update(dt);
  placeBus(dt);
  if (G.driver.s > G.route.byId.hospital.s + 330) {
    G.bus.root.visible = false;
    G.busGone = true;
  }
}

async function finish() {
  G.phase = 'ending';
  exitPointerLock();
  await ui.fade(1, 1.8);
  ui.show('hud', false);
  ui.show('end', true);
  G.phase = 'end';
}

// ---------------------------------------------------------------------------
// Камера
// ---------------------------------------------------------------------------
const _q = new THREE.Quaternion();
const _e = new THREE.Euler(0, 0, 0, 'YXZ');

function updateCamera(dt) {
  const { hero, bus } = G;
  if (G.phase === 'menu') {
    const a = G.time * 0.07;
    const c = bus.root.localToWorld(V(Math.sin(a) * 15, 5.5, Math.cos(a) * 15));
    camera.position.copy(c);
    camera.lookAt(bus.root.localToWorld(V(0, 1.4, 0)));
    return;
  }
  if (G.cameraMode === 'fp') {
    hero.root.getWorldQuaternion(_q);
    camera.position.copy(hero.root.localToWorld(hero.eye.clone()));
    _e.set(G.look.pitch, G.look.yaw, 0, 'YXZ');
    camera.quaternion.copy(_q).multiply(new THREE.Quaternion().setFromEuler(_e));
  } else if (G.cameraMode === 'chase') {
    const want = bus.root.localToWorld(V(3.6, 3.8, 14.5));
    camera.position.lerp(want, 1 - Math.exp(-3 * dt));
    camera.lookAt(bus.root.localToWorld(V(0, 1.3, -5)));
  } else if (G.cameraMode === 'cut' && G.cut) {
    camera.position.copy(G.cut.pos);
    camera.lookAt(G.cut.look);
  } else if (G.cameraMode === 'tp' && G.player) {
    const P = G.player, H = G.world.hospital;
    G.orbit.idle += dt;
    if (G.orbit.idle > 2 && Math.abs(P.v) > 0.2) G.orbit.yaw = damp(G.orbit.yaw, 0, 1.5, dt);
    const yaw = P.yaw + G.orbit.yaw, d = 3.8, p = G.orbit.pitch;
    const ground = hero.root.position.y;
    const local = V(P.x + Math.sin(yaw) * d * Math.cos(p), ground + 0.9 + d * Math.sin(p), P.z + Math.cos(yaw) * d * Math.cos(p));
    local.x = Math.min(local.x, 46.2);
    const want = H.toWorld(local);
    const look = H.toWorld(V(P.x, ground + 1.0, P.z));
    if (G.camBlend < 1) {
      G.camBlend = Math.min(1, G.camBlend + dt / 2);
      const t = G.camBlend * G.camBlend * (3 - 2 * G.camBlend);
      camera.position.lerpVectors(G.cut.pos, want, t);
      const l = G.cut.look.clone().lerp(look, t);
      camera.lookAt(l);
    } else {
      camera.position.lerp(want, 1 - Math.exp(-8 * dt));
      camera.lookAt(look);
    }
  }
}

// ---------------------------------------------------------------------------
// Ввод
// ---------------------------------------------------------------------------
function exitPointerLock() {
  if (document.pointerLockElement) {
    G.expectUnlock = true;
    document.exitPointerLock();
  }
}

canvas.addEventListener('click', () => {
  if (G.paused || !['ride', 'outside'].includes(G.phase) || ui.choosing) return;
  if (!document.pointerLockElement) {
    canvas.requestPointerLock?.();
    ui.show('lockHint', false);
  } else interact();
});

document.addEventListener('pointerlockchange', () => {
  if (document.pointerLockElement) return;
  if (G.expectUnlock) { G.expectUnlock = false; return; }
  if (['ride', 'outside'].includes(G.phase) && !ui.choosing) setPaused(true);
});

document.addEventListener('mousemove', (e) => {
  if (document.pointerLockElement !== canvas || G.paused) return;
  const s = CONFIG.camera.sensitivity * G.sens;
  if (G.cameraMode === 'fp') {
    G.look.yaw = clamp(G.look.yaw - e.movementX * s, -2.4, 2.4);
    G.look.pitch = clamp(G.look.pitch - e.movementY * s, -1.25, 1.1);
  } else if (G.cameraMode === 'tp') {
    G.orbit.yaw -= e.movementX * s;
    G.orbit.pitch = clamp(G.orbit.pitch + e.movementY * s, 0.05, 1.1);
    G.orbit.idle = 0;
  }
});

window.addEventListener('keydown', (e) => {
  if (e.repeat && !['KeyF'].includes(e.code)) { G.keys.add(e.code); return; }
  G.keys.add(e.code);
  if (e.code === 'Escape' || e.code === 'KeyP') {
    if (['ride', 'arrival', 'outside'].includes(G.phase)) setPaused(!G.paused);
    return;
  }
  if (G.paused) return;
  if (e.code === 'KeyM') audio.toggleMute();
  if (/^Digit[1-3]$/.test(e.code) && ui.choosing) ui.pick(Number(e.code.slice(5)) - 1);
  if (e.code === 'Enter' || e.code === 'NumpadEnter') G.dialogue?.skip();
  if (e.code === 'KeyE') interact();
  if (e.code === 'KeyV' && G.phase === 'ride') setCameraMode(G.cameraMode === 'fp' ? 'chase' : 'fp');
  if (['Space', 'ArrowUp', 'ArrowDown'].includes(e.code)) e.preventDefault();
});
window.addEventListener('keyup', (e) => G.keys.delete(e.code));
window.addEventListener('blur', () => {
  G.keys.clear();
  if (['ride', 'outside'].includes(G.phase) && !document.hasFocus()) setPaused(true);
});

// Без мыши (тачпад/ноутбук): стрелки ←/→/↑/↓ крутят взгляд в салоне.
function keyboardLook(dt) {
  if (G.cameraMode !== 'fp') return;
  const k = G.keys;
  G.look.yaw = clamp(G.look.yaw + ((k.has('ArrowLeft') ? 1 : 0) - (k.has('ArrowRight') ? 1 : 0)) * dt * 1.6, -2.4, 2.4);
  G.look.pitch = clamp(G.look.pitch + ((k.has('ArrowUp') ? 1 : 0) - (k.has('ArrowDown') ? 1 : 0)) * dt * 1.2, -1.25, 1.1);
}

function setPaused(p) {
  G.paused = p;
  ui.show('pause', p);
  if (p) exitPointerLock();
  if (audio.ctx) p ? audio.ctx.suspend() : audio.ctx.resume();
}

document.getElementById('btn-resume').addEventListener('click', () => { setPaused(false); canvas.requestPointerLock?.(); });
const restart = () => {
  const u = new URL(location.href);
  u.searchParams.set('autostart', '1');
  u.searchParams.set('minutes', String(G.builtMinutes || CONFIG.rideMinutes));
  u.searchParams.delete('skipto');
  location.href = u.toString();
};
document.getElementById('btn-restart').addEventListener('click', restart);
document.getElementById('btn-again').addEventListener('click', restart);
for (const id of ['opt-volume', 'pause-volume']) {
  document.getElementById(id).addEventListener('input', (e) => {
    audio.setVolume(Number(e.target.value));
    document.getElementById('opt-volume').value = e.target.value;
    document.getElementById('pause-volume').value = e.target.value;
  });
}
document.getElementById('opt-sens').addEventListener('input', (e) => { G.sens = Number(e.target.value); });
document.getElementById('opt-shadows').addEventListener('change', (e) => {
  renderer.shadowMap.enabled = e.target.checked;
  scene.traverse((o) => { if (o.material) (Array.isArray(o.material) ? o.material : [o.material]).forEach((m) => { m.needsUpdate = true; }); });
});
const durationSelect = document.getElementById('opt-duration');
if (params.get('minutes')) durationSelect.value = params.get('minutes');

document.getElementById('btn-start').addEventListener('click', async () => {
  audio.init(Promise.resolve(assets.sounds));
  audio.setVolume(Number(document.getElementById('opt-volume').value));
  const minutes = Number(durationSelect.value) || CONFIG.rideMinutes;
  if (minutes !== G.builtMinutes) {
    ui.setFade(1);
    await new Promise((r) => setTimeout(r, 30));
    buildGame(minutes);
  }
  startRide();
});

// ---------------------------------------------------------------------------
// Отладка: ?debug=1 — панель, прыжки по сюжету.
// ---------------------------------------------------------------------------
function jumpTo(where) {
  const { driver, route } = G;
  const final = route.byId.hospital;
  const setS = (s) => {
    driver.s = s;
    driver.v = CONFIG.bus.cruise * 0.6;
    driver.stopped = false;
    driver.index = route.events.findIndex((e) => e.s > s + 0.5);
    if (driver.index < 0) driver.index = route.events.length;
    const progress = (s - route.startS) / (final.s - route.startS);
    for (const p of STORY.events.progress) if (p.at < progress) G.fired.add(`p${p.at}`);
  };
  if (where === 'light') setS(route.byId.light.s - 180);
  if (where === 'market') setS(route.byId.market.s - 150);
  if (where === 'hospital') setS(final.s - 460);
  if (where === 'arrival') { setS(final.s - 40); }
  if (where === 'outside') {
    setS(final.s);
    driver.stopped = true;
    driver.index = route.events.length - 1;
    placeBus(0);
    G.bus.root.visible = false;
    G.busGone = true;
    G.cut = { pos: camera.position.clone(), look: V() };
    enterOutside(false);
    ui.setFade(0);
  }
}

function updateDebug() {
  if (!debug) return;
  const d = G.driver;
  ui.el.debug.textContent = `phase ${G.phase}  fps ${G.fps.toFixed(0)}\ns ${d?.s.toFixed(1)} / ${G.route?.byId.hospital.s.toFixed(0)}  v ${(d?.v * 3.6).toFixed(1)} км/ч\nпоездка ~${(G.route?.expectedSeconds / 60).toFixed(2)} мин  t ${G.time.toFixed(1)} c\nследующее: ${d?.next?.id ?? '—'}`;
}

// ---------------------------------------------------------------------------
// Главный цикл
// ---------------------------------------------------------------------------
let last = performance.now();
let debugTimer = 0;

function step(dt) {
  const ff = G.phase === 'ride' && G.keys.has('KeyF') && !ui.choosing;
  ui.show('ff', ff);
  const sdt = dt * (ff ? CONFIG.fastForward : 1);
  G.time += dt;
  updateTweens(dt, sdt);
  G.dialogue?.update(dt);
  keyboardLook(dt);
  if (G.phase === 'menu') {
    placeBus(dt, false);
    G.traffic.update(dt, G.driver.s, 0);
  } else if (G.phase === 'ride') {
    updateRide(dt, sdt);
  } else if (G.phase === 'arrival') {
    placeBus(dt);
    updateLeavingBus(dt);
    traffic(dt);
    G.mom.update(dt);
    G.hero.update(dt);
  } else if (G.phase === 'outside' || G.phase === 'ending') {
    updateOutside(dt);
  }
  const inside = G.cameraMode === 'fp' || (G.phase === 'arrival' && G.cameraMode !== 'cut');
  audio.update(dt, {
    busSpeed: G.driver?.v || 0,
    busAccel: G.driver?.accel || 0,
    busNear: !G.busGone,
    inside,
    doorsOpen: (G.bus?.doorOpen.middle || 0) > 0.3,
    chairSpeed: G.player ? Math.abs(G.player.v) : 0,
    outdoorCalm: G.phase === 'outside' || G.phase === 'ending',
  });
  // Щелчок поворотника.
  const blinkOn = G.bus?.indicator && Math.sin(G.time * Math.PI * 3) > 0;
  if (blinkOn !== G.lastBlink) { G.lastBlink = blinkOn; if (G.bus?.indicator && G.phase === 'ride') audio.tick(); }
}

function frame(now) {
  requestAnimationFrame(frame);
  const dt = Math.min(0.05, (now - last) / 1000);
  last = now;
  G.fps = lerp(G.fps, 1 / Math.max(dt, 1e-3), 0.05);
  if (G.phase === 'loading' || !G.root) return;
  if (!G.paused) step(dt);
  render(dt);
}

// Для автотестов (?debug=1): прокрутить игру на seconds секунд без отрисовки каждого кадра.
if (debug) {
  window.__advance = (seconds, keys = []) => {
    keys.forEach((k) => G.keys.add(k));
    for (let t = 0; t < seconds; t += 0.05) { if (!G.paused) step(0.05); updateCamera(0.05); }
    keys.forEach((k) => G.keys.delete(k));
    render(0);
  };
  window.__jump = (where) => jumpTo(where);
  window.THREE = THREE;
  window.__camera = camera;
  // Навести взгляд (вид из коляски) на маму или кнопку.
  window.__aimAt = (what) => {
    const target = what === 'mom' ? headPos(G.mom) : G.bus.stopButton.getWorldPosition(new THREE.Vector3());
    const eye = G.hero.root.localToWorld(G.hero.eye.clone());
    const q = G.hero.root.getWorldQuaternion(new THREE.Quaternion()).invert();
    const d = target.sub(eye).applyQuaternion(q);
    G.look.yaw = Math.atan2(-d.x, -d.z);
    G.look.pitch = Math.atan2(d.y, Math.hypot(d.x, d.z));
  };
}

function render(dt) {
  updateCamera(dt);
  // Солнце и тени следуют за тем, на что смотрим.
  const focus = G.phase === 'outside' || G.phase === 'ending' ? G.hero.root.getWorldPosition(new THREE.Vector3()) : G.bus.root.position;
  sun.target.position.copy(focus);
  sun.position.copy(focus).addScaledVector(SUN_DIR, 120);
  sky.position.copy(camera.position);
  renderer.render(scene, camera);
  debugTimer -= dt;
  if (debugTimer <= 0) { updateDebug(); debugTimer = 0.25; }
}

// ---------------------------------------------------------------------------
// Запуск
// ---------------------------------------------------------------------------
async function boot() {
  if (location.protocol === 'file:') return;
  const total = Object.values(MANIFEST).reduce((n, group) => n + Object.keys(group).length, 0);
  let done = 0;
  assets = await loadAssets((label, kind, ok) => ui.loadingItem(label, ok, ++done, total));
  G.assetReport = assets.report;
  buildGame(Number(durationSelect.value) || CONFIG.rideMinutes);
  ui.show('loading', false);
  ui.setFade(0);
  if (debug) {
    ui.show('debug', true);
    const bar = document.createElement('div');
    bar.style.pointerEvents = 'auto';
    for (const [label, where] of [['светофор', 'light'], ['рынок', 'market'], ['к больнице', 'hospital'], ['прибытие', 'arrival'], ['улица', 'outside']]) {
      const b = document.createElement('button');
      b.textContent = label;
      b.onclick = () => { if (G.phase === 'ride') jumpTo(where); };
      bar.appendChild(b);
    }
    document.body.appendChild(Object.assign(bar, { style: 'position:fixed;left:8px;bottom:84px;z-index:41' }));
  }
  if (params.get('autostart')) {
    G.phase = 'menu';
    document.getElementById('btn-start').click();
  } else {
    G.phase = 'menu';
    ui.show('menu', true);
  }
  requestAnimationFrame(frame);
}

boot().catch((err) => {
  console.error(err);
  document.querySelector('#loading h2').textContent = 'Ошибка запуска: ' + err.message;
});
