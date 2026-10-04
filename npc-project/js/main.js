// Viewer app: scene, camera, lights, NPC, animation player, face controls, export.

import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import { NPC_DEFS, ROSTER } from './npcs/index.js';
import { createNPC } from './npc.js';
import { createAnimationLibrary, CATEGORY_ORDER } from './animations.js';
import { exportNPC, exportAllNPCsZip, glbFileName, saveFile, formatBytes, inArtifact } from './exporter.js';
import { BONE_DEFS, SKELETON_STANDARD } from './skeleton.js';
import { FACE_MORPHS, MOUTH_MORPHS } from './parts.js';
import { textToVisemes, visemeWeightsAt } from './lipsync.js';

const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
};

const TARGET = new THREE.Vector3(0, 0.86, 0);
const CAM_DIST = 4.6;
const VIEWS = {
  front: [0, 1.0, CAM_DIST],
  back: [0, 1.0, -CAM_DIST],
  left: [CAM_DIST, 1.0, 0],     // the character's left side (+X)
  right: [-CAM_DIST, 1.0, 0],
  reset: [Math.sin(0.5) * CAM_DIST, 1.25, Math.cos(0.5) * CAM_DIST],
};

const state = {
  def: NPC_DEFS[0],
  npc: null,
  mixer: null,
  lib: createAnimationLibrary(),
  current: null,       // { entry, action }
  playing: false,
  loop: true,
  speed: 1,
  crossfade: true,
  mouth: 'auto',
  brows: 'auto',
  blink: false,
  speech: null,        // { seq, start }
  turntable: false,
  scrubbing: false,
  stopped: false,
  tween: null,
};

/* ---------------------------------------------------------------- scene */

const canvas = $('canvas');
const viewport = $('viewport');
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true, preserveDrawingBuffer: false });
renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.0;
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;

const scene = new THREE.Scene();
const pmrem = new THREE.PMREMGenerator(renderer);
scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
scene.environmentIntensity = 0.55;

const camera = new THREE.PerspectiveCamera(30, 1, 0.05, 60);
camera.position.set(...VIEWS.reset);
const controls = new OrbitControls(camera, canvas);
controls.target.copy(TARGET);
controls.enableDamping = true;
controls.dampingFactor = 0.08;
controls.minDistance = 1.0;
controls.maxDistance = 14;
controls.maxPolarAngle = Math.PI * 0.94;
controls.addEventListener('start', () => { state.tween = null; });

const lights = new THREE.Group();
const hemi = new THREE.HemisphereLight(0xffffff, 0x4a5262, 0.55);
const key = new THREE.DirectionalLight(0xfff3e2, 2.3);
key.position.set(2.2, 4.2, 3.0);
key.castShadow = true;
key.shadow.mapSize.set(2048, 2048);
key.shadow.camera.left = -2; key.shadow.camera.right = 2;
key.shadow.camera.top = 2.6; key.shadow.camera.bottom = -1;
key.shadow.camera.near = 0.5; key.shadow.camera.far = 12;
key.shadow.bias = -0.0004;
key.shadow.normalBias = 0.02;
key.shadow.radius = 4;
const fill = new THREE.DirectionalLight(0xdfe8ff, 0.7);
fill.position.set(-3, 2, 2);
const rim = new THREE.DirectionalLight(0xcfe0ff, 1.3);
rim.position.set(-1.5, 3, -3.5);
lights.add(hemi, key, fill, rim);
scene.add(lights);

// ground: shadow catcher + soft contact shadow + optional grid
const ground = new THREE.Mesh(new THREE.CircleGeometry(3.2, 64), new THREE.ShadowMaterial({ opacity: 0.22 }));
ground.rotation.x = -Math.PI / 2;
ground.receiveShadow = true;
scene.add(ground);
const contact = new THREE.Mesh(new THREE.PlaneGeometry(1.6, 1.6), new THREE.MeshBasicMaterial({
  map: radialTexture(), transparent: true, depthWrite: false, opacity: 0.55,
}));
contact.rotation.x = -Math.PI / 2;
contact.position.y = 0.001;
scene.add(contact);
const grid = new THREE.GridHelper(6, 24, 0x7c8796, 0x9aa4b2);
grid.material.transparent = true;
grid.material.opacity = 0.35;
grid.position.y = 0.002;
grid.visible = false;
scene.add(grid);

function radialTexture() {
  const c = document.createElement('canvas');
  c.width = c.height = 128;
  const g = c.getContext('2d');
  const grad = g.createRadialGradient(64, 64, 4, 64, 64, 64);
  grad.addColorStop(0, 'rgba(0,0,0,0.55)');
  grad.addColorStop(0.5, 'rgba(0,0,0,0.18)');
  grad.addColorStop(1, 'rgba(0,0,0,0)');
  g.fillStyle = grad;
  g.fillRect(0, 0, 128, 128);
  const t = new THREE.CanvasTexture(c);
  t.colorSpace = THREE.SRGBColorSpace;
  return t;
}

/* ------------------------------------------------------------------ NPC */

function loadNPC(def) {
  if (state.npc) {
    scene.remove(state.npc.group);
    state.mixer.stopAllAction();
  }
  state.def = def;
  const npc = createNPC(def);
  state.npc = npc;
  scene.add(npc.group);
  state.mixer = new THREE.AnimationMixer(npc.group);
  state.mixer.addEventListener('finished', () => { state.playing = false; syncTransport(); });
  state.current = null;
  const box = new THREE.Box3();
  npc.meshes.forEach((m) => { m.geometry.computeBoundingBox(); box.union(m.geometry.boundingBox); });
  npc.height = box.max.y - box.min.y;
  renderInfo();
  renderParts();
}

/* ------------------------------------------------------------ animation */

function selectClip(name, { autoplay = true } = {}) {
  const entry = state.lib.find((e) => e.name === name);
  if (!entry) return;
  const action = state.mixer.clipAction(entry.clip);
  const prev = state.current;
  state.loop = entry.loop;
  action.reset();
  action.setLoop(state.loop ? THREE.LoopRepeat : THREE.LoopOnce, Infinity);
  action.clampWhenFinished = true;
  action.enabled = true;
  action.setEffectiveTimeScale(1);
  action.setEffectiveWeight(1);
  if (prev && prev.action !== action && state.crossfade && state.playing) {
    action.play();
    action.crossFadeFrom(prev.action, 0.25, false);
  } else {
    state.mixer.stopAllAction();
    action.play();
  }
  action.paused = !autoplay;
  state.stopped = false;
  state.scrubbing = false;
  state.current = { entry, action };
  state.playing = autoplay;
  document.querySelectorAll('.anim-btn').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.clip === name)));
  $('now-playing-name').textContent = entry.label;
  $('now-playing-meta').textContent = `${entry.category} · ${entry.duration.toFixed(2)} s · ${entry.loop ? 'loop' : 'one-shot'}`;
  syncTransport();
}

function play() {
  if (!state.current) return selectClip('Idle');
  const { action, entry } = state.current;
  if (state.stopped || !action.isScheduled()) {
    action.reset();
    action.play();
    state.stopped = false;
  } else if (!state.loop && action.time >= entry.duration - 1e-3) {
    action.reset();
  }
  action.enabled = true;
  action.paused = false;
  state.playing = true;
  syncTransport();
}

function pause() {
  if (!state.current) return;
  state.current.action.paused = true;
  state.playing = false;
  syncTransport();
}

// Stop returns the figure to its bind (rest) pose; Play restarts the clip.
function stop() {
  state.mixer.stopAllAction();
  state.stopped = true;
  state.playing = false;
  syncTransport();
}

function setLoop(on) {
  state.loop = on;
  if (state.current) {
    const { action } = state.current;
    action.setLoop(on ? THREE.LoopRepeat : THREE.LoopOnce, Infinity);
    action.clampWhenFinished = true;
  }
  syncTransport();
}

function syncTransport() {
  $('btn-play').setAttribute('aria-pressed', String(state.playing));
  $('btn-pause').setAttribute('aria-pressed', String(!state.playing && !!state.current && !state.stopped));
  $('btn-stop').setAttribute('aria-pressed', String(!!state.stopped));
  $('btn-loop').setAttribute('aria-pressed', String(state.loop));
  document.querySelectorAll('#speed button').forEach((b) => b.setAttribute('aria-pressed', String(+b.dataset.speed === state.speed)));
}

/* ----------------------------------------------------------------- face */

// Manual face controls are applied only while rendering and then undone, so the
// AnimationMixer (which skips writes for unchanged values) never loses track of
// what the current clip has set.
const savedMorphs = new Map();
function applyFaceOverrides(now) {
  const { npc } = state;
  const mouth = npc.morphMeshes.Mouth_Mesh;
  const face = npc.morphMeshes.Face_Mesh;
  const md = mouth.morphTargetDictionary, fd = face.morphTargetDictionary;
  savedMorphs.set(mouth, mouth.morphTargetInfluences.slice());
  savedMorphs.set(face, face.morphTargetInfluences.slice());
  if (state.speech) {
    const t = now - state.speech.start;
    if (t > state.speech.seq.duration) {
      state.speech = null;
      $('say-status').textContent = '';
    } else {
      const w = visemeWeightsAt(state.speech.seq, t, MOUTH_MORPHS);
      for (const n of MOUTH_MORPHS) mouth.morphTargetInfluences[md[n]] = w[n];
    }
  } else if (state.mouth !== 'auto') {
    for (const n of MOUTH_MORPHS) mouth.morphTargetInfluences[md[n]] = n === state.mouth ? 1 : 0;
  }
  if (state.brows !== 'auto') {
    for (const n of FACE_MORPHS) if (n.startsWith('Brows')) face.morphTargetInfluences[fd[n]] = n === state.brows ? 1 : 0;
  }
  if (state.blink) face.morphTargetInfluences[fd.Blink] = 1;
}

function restoreFaceOverrides() {
  for (const [mesh, values] of savedMorphs) values.forEach((v, i) => { mesh.morphTargetInfluences[i] = v; });
  savedMorphs.clear();
}

/* ------------------------------------------------------------- the loop */

const clock = new THREE.Clock();
let lastUi = 0;
function frame() {
  requestAnimationFrame(frame);
  const dt = Math.min(clock.getDelta(), 0.1);
  const now = clock.elapsedTime;
  resizeIfNeeded();
  state.mixer.timeScale = state.speed;
  state.mixer.update(state.playing ? dt : 0);
  if (state.turntable) {
    state.npc.group.rotation.y = (state.npc.group.rotation.y + dt * 0.6) % (Math.PI * 2);
    $('rot-slider').value = String(Math.round(THREE.MathUtils.radToDeg(state.npc.group.rotation.y)));
  }
  if (state.tween) stepTween(dt);
  controls.update();
  applyFaceOverrides(now);
  renderer.render(scene, camera);
  restoreFaceOverrides();
  if (now - lastUi > 0.05) { lastUi = now; updateTimelineUi(); }
}

function updateTimelineUi() {
  $('drawcalls').textContent = String(renderer.info.render.calls);
  if (!state.current || state.scrubbing) return;
  const { action, entry } = state.current;
  const t = state.stopped ? 0 : action.time % (entry.duration + 1e-9);
  $('timeline').value = String(entry.duration ? t / entry.duration : 0);
  $('time-readout').textContent = `${t.toFixed(2)} / ${entry.duration.toFixed(2)} s · f${Math.round(t * 30)}`;
}

function resizeIfNeeded() {
  const w = viewport.clientWidth, h = viewport.clientHeight;
  if (canvas.width !== Math.floor(w * renderer.getPixelRatio()) || canvas.height !== Math.floor(h * renderer.getPixelRatio())) {
    renderer.setSize(w, h, false);
    camera.aspect = w / Math.max(1, h);
    camera.updateProjectionMatrix();
  }
}

/* --------------------------------------------------------------- camera */

function goToView(name) {
  const to = new THREE.Vector3(...VIEWS[name]);
  if (name !== 'reset') {
    // keep the current zoom level for the four orthogonal views
    const d = camera.position.distanceTo(controls.target);
    to.sub(TARGET).setLength(d).add(TARGET);
  }
  state.tween = { t: 0, fromPos: camera.position.clone(), toPos: to, fromTarget: controls.target.clone(), toTarget: TARGET.clone() };
}

function stepTween(dt) {
  const tw = state.tween;
  tw.t = Math.min(1, tw.t + dt / 0.6);
  const u = tw.t < 0.5 ? 4 * tw.t ** 3 : 1 - Math.pow(-2 * tw.t + 2, 3) / 2;
  // orbit around the target instead of cutting through the model
  const a = tw.fromPos.clone().sub(tw.fromTarget), b = tw.toPos.clone().sub(tw.toTarget);
  const sa = new THREE.Spherical().setFromVector3(a), sb = new THREE.Spherical().setFromVector3(b);
  let dTheta = sb.theta - sa.theta;
  if (dTheta > Math.PI) dTheta -= Math.PI * 2;
  if (dTheta < -Math.PI) dTheta += Math.PI * 2;
  const s = new THREE.Spherical(
    THREE.MathUtils.lerp(sa.radius, sb.radius, u),
    THREE.MathUtils.lerp(sa.phi, sb.phi, u),
    sa.theta + dTheta * u,
  );
  controls.target.lerpVectors(tw.fromTarget, tw.toTarget, u);
  camera.position.setFromSpherical(s).add(controls.target);
  if (tw.t >= 1) state.tween = null;
}

/* ------------------------------------------------------------------- UI */

function renderRoster() {
  const nav = $('roster');
  nav.textContent = '';
  for (const r of ROSTER) {
    const built = NPC_DEFS.find((d) => d.index === r.index);
    const b = el('button', 'roster-item');
    b.type = 'button';
    b.disabled = !built;
    b.setAttribute('aria-pressed', String(built && built === state.def));
    b.title = built ? built.name : `${r.label} — ещё не создан`;
    b.append(el('span', 'roster-num', String(r.index).padStart(2, '0')), el('span', 'roster-label', r.label));
    if (built) b.addEventListener('click', () => { loadNPC(built); selectClip('Idle'); renderRoster(); });
    nav.append(b);
  }
  $('roster-progress').textContent = `${NPC_DEFS.length} / ${ROSTER.length}`;
}

function renderInfo() {
  const { def, npc } = state;
  $('npc-index').textContent = `NPC ${String(def.index).padStart(2, '0')}`;
  $('npc-name').textContent = def.name;
  $('npc-desc').textContent = def.description;
  const s = npc.stats;
  const rows = [
    ['Name', def.name],
    ['Type', def.type],
    ['Polygon count', `${s.triangles.toLocaleString('en-US')} tris`],
    ['Vertices', s.vertices.toLocaleString('en-US')],
    ['Bones', `${s.bones} · ${SKELETON_STANDARD}`],
    ['Animations', String(state.lib.length)],
    ['Meshes', `${s.meshes} skinned`],
    ['Materials', `${s.materials} (PBR, ${s.textureSize}px atlas)`],
    ['Morph targets', `${s.morphTargets} (face + visemes)`],
    ['Height', `${npc.height.toFixed(2)} m`],
    ['Draw calls', `${s.meshes} / NPC · <span id="drawcalls">–</span> frame`],
    ['GLB size', '<span id="glb-size">measuring…</span>'],
  ];
  const dl = $('stats');
  dl.textContent = '';
  for (const [k, v] of rows) {
    const dt = el('dt', null, k);
    const dd = el('dd');
    if (v.includes('<span')) dd.innerHTML = v; else dd.textContent = v;
    dl.append(dt, dd);
  }
  measureGlb();
}

async function measureGlb() {
  try {
    const def = state.def;
    const [withAnim, model] = await Promise.all([exportNPC(def, { animations: true }), exportNPC(def, { animations: false })]);
    if (def !== state.def) return;
    $('glb-size').textContent = `${formatBytes(withAnim.byteLength)} · model ${formatBytes(model.byteLength)}`;
  } catch (err) {
    $('glb-size').textContent = 'n/a';
    console.error(err);
  }
}

function renderParts() {
  const wrap = $('parts');
  wrap.textContent = '';
  for (const mesh of state.npc.meshes) {
    const id = `part-${mesh.name}`;
    const label = el('label', 'part-chip');
    const input = el('input');
    input.type = 'checkbox';
    input.id = id;
    input.checked = mesh.visible;
    input.addEventListener('change', () => { mesh.visible = input.checked; });
    label.append(input, el('span', null, mesh.name.replace('_Mesh', '')));
    wrap.append(label);
  }
}

function renderBoneTree() {
  const depth = (name) => { let d = 0, cur = BONE_DEFS.find((b) => b[0] === name); while (cur && cur[1]) { d++; cur = BONE_DEFS.find((b) => b[0] === cur[1]); } return d; };
  const children = (p) => BONE_DEFS.filter((b) => b[1] === p).map((b) => b[0]);
  const lines = [];
  const walk = (name) => { lines.push(`${'  '.repeat(depth(name))}${name}`); children(name).forEach(walk); };
  walk('Root');
  $('bone-tree').textContent = lines.join('\n');
}

function renderAnimList(filter = '') {
  const list = $('anim-list');
  list.textContent = '';
  const f = filter.trim().toLowerCase();
  let shown = 0;
  for (const cat of CATEGORY_ORDER) {
    const items = state.lib.filter((e) => e.category === cat && (!f || e.name.toLowerCase().includes(f) || e.label.toLowerCase().includes(f)));
    if (!items.length) continue;
    const group = el('section', 'anim-group');
    const head = el('h4', 'anim-cat');
    head.append(el('span', null, cat), el('span', 'anim-cat-count', String(items.length)));
    const grid = el('div', 'anim-grid');
    for (const e of items) {
      const b = el('button', 'anim-btn');
      b.type = 'button';
      b.dataset.clip = e.name;
      b.setAttribute('aria-pressed', String(state.current?.entry.name === e.name));
      b.append(el('span', 'anim-name', e.label), el('span', 'anim-meta', `${e.duration.toFixed(2)}s${e.loop ? ' · ∞' : ''}`));
      b.addEventListener('click', () => selectClip(e.name));
      grid.append(b);
      shown++;
    }
    group.append(head, grid);
    list.append(group);
  }
  if (!shown) list.append(el('p', 'empty', 'Нет анимаций с таким названием.'));
}

function renderFaceControls() {
  const mouthOpts = [['auto', 'Auto'], ['Mouth_Idle', 'Idle'], ...MOUTH_MORPHS.map((n) => [n, n.replace('Mouth_', '')])];
  const browOpts = [['auto', 'Auto'], ['none', 'Neutral'], ['Brows_Angry', 'Angry'], ['Brows_Raised', 'Raised'], ['Brows_Sad', 'Sad']];
  const build = (wrapId, opts, key) => {
    const wrap = $(wrapId);
    wrap.textContent = '';
    for (const [v, label] of opts) {
      const b = el('button', 'chip', label);
      b.type = 'button';
      b.setAttribute('aria-pressed', String(state[key] === v));
      b.addEventListener('click', () => {
        state[key] = v;
        wrap.querySelectorAll('.chip').forEach((c) => c.setAttribute('aria-pressed', String(c === b)));
      });
      wrap.append(b);
    }
  };
  build('mouth-chips', mouthOpts, 'mouth');
  build('brow-chips', browOpts, 'brows');
}

function setStatus(text, kind = '') {
  const s = $('export-status');
  s.textContent = text;
  s.dataset.kind = kind;
}

async function doExport(animations) {
  const merged = $('merge-toggle').checked;
  const buttons = [$('btn-glb'), $('btn-glb-anim')];
  buttons.forEach((b) => (b.disabled = true));
  setStatus('Экспорт GLB…');
  try {
    const glb = await exportNPC(state.def, { animations, merged });
    const name = glbFileName(state.def, { animations, merged });
    const res = await saveFile(name, glb, 'model/gltf-binary');
    if (res.declined) setStatus('Сохранение отменено.');
    else setStatus(`Готово: ${res.filename} · ${formatBytes(glb.byteLength)}${res.filename.endsWith('.zip') ? ' (GLB внутри ZIP)' : ''}`, 'ok');
  } catch (err) {
    console.error(err);
    setStatus(`Не удалось экспортировать: ${err.message}`, 'error');
  } finally {
    buttons.forEach((b) => (b.disabled = false));
  }
}

function wireUi() {
  document.querySelectorAll('[data-view]').forEach((b) => b.addEventListener('click', () => goToView(b.dataset.view)));
  $('btn-play').addEventListener('click', play);
  $('btn-pause').addEventListener('click', pause);
  $('btn-stop').addEventListener('click', stop);
  $('btn-loop').addEventListener('click', () => setLoop(!state.loop));
  document.querySelectorAll('#speed button').forEach((b) => b.addEventListener('click', () => { state.speed = +b.dataset.speed; syncTransport(); }));
  $('xfade').addEventListener('change', (e) => { state.crossfade = e.target.checked; });

  const tl = $('timeline');
  tl.addEventListener('input', () => {
    if (!state.current) return;
    state.scrubbing = true;
    const { action, entry } = state.current;
    if (state.stopped) { action.reset(); action.play(); state.stopped = false; }
    pause();
    action.time = +tl.value * entry.duration;
    $('time-readout').textContent = `${action.time.toFixed(2)} / ${entry.duration.toFixed(2)} s · f${Math.round(action.time * 30)}`;
  });
  for (const ev of ['change', 'pointerup', 'keyup', 'blur']) tl.addEventListener(ev, () => { state.scrubbing = false; });

  $('anim-search').addEventListener('input', (e) => renderAnimList(e.target.value));

  $('grid-toggle').addEventListener('click', (e) => {
    grid.visible = !grid.visible;
    e.currentTarget.setAttribute('aria-pressed', String(grid.visible));
  });
  $('light-toggle').addEventListener('click', (e) => {
    lights.visible = !lights.visible;
    scene.environmentIntensity = lights.visible ? 0.55 : 1.15;
    ground.visible = lights.visible;
    e.currentTarget.setAttribute('aria-pressed', String(lights.visible));
  });
  $('turntable-toggle').addEventListener('click', (e) => {
    state.turntable = !state.turntable;
    e.currentTarget.setAttribute('aria-pressed', String(state.turntable));
  });
  $('rot-slider').addEventListener('input', (e) => {
    state.turntable = false;
    $('turntable-toggle').setAttribute('aria-pressed', 'false');
    state.npc.group.rotation.y = THREE.MathUtils.degToRad(+e.target.value);
  });
  document.querySelectorAll('[data-bg]').forEach((b) => b.addEventListener('click', () => {
    viewport.dataset.bg = b.dataset.bg;
    viewport.style.removeProperty('--stage-custom');
    document.querySelectorAll('[data-bg]').forEach((x) => x.setAttribute('aria-pressed', String(x === b)));
  }));
  $('bg-color').addEventListener('input', (e) => {
    viewport.dataset.bg = 'custom';
    viewport.style.setProperty('--stage-custom', e.target.value);
    document.querySelectorAll('[data-bg]').forEach((x) => x.setAttribute('aria-pressed', 'false'));
  });

  $('blink-toggle').addEventListener('change', (e) => { state.blink = e.target.checked; });
  $('say-form').addEventListener('submit', (e) => {
    e.preventDefault();
    const text = $('say-input').value.trim();
    if (!text) return;
    state.speech = { seq: textToVisemes(text), start: clock.elapsedTime };
    $('say-status').textContent = `Говорит… ${state.speech.seq.duration.toFixed(1)} s`;
  });

  $('btn-glb').addEventListener('click', () => doExport(false));
  $('btn-glb-anim').addEventListener('click', () => doExport(true));
  if (inArtifact()) $('export-note').hidden = false;

  window.addEventListener('keydown', (e) => {
    if (e.target.closest('input, textarea, select')) return;
    if (e.code === 'Space') { e.preventDefault(); state.playing ? pause() : play(); }
    if (e.code === 'ArrowDown' || e.code === 'ArrowUp') {
      e.preventDefault();
      const names = [...document.querySelectorAll('.anim-btn')].map((b) => b.dataset.clip);
      const i = names.indexOf(state.current?.entry.name);
      const next = names[(i + (e.code === 'ArrowDown' ? 1 : -1) + names.length) % names.length];
      selectClip(next);
      document.querySelector(`.anim-btn[data-clip="${next}"]`)?.scrollIntoView({ block: 'nearest' });
    }
  });
}

/* ----------------------------------------------------------------- boot */

// Dark theme starts on the night backdrop.
const prefersDark = document.documentElement.dataset.theme === 'dark'
  || (document.documentElement.dataset.theme !== 'light' && window.matchMedia?.('(prefers-color-scheme: dark)').matches);
if (prefersDark) {
  viewport.dataset.bg = 'night';
  document.querySelectorAll('[data-bg]').forEach((x) => x.setAttribute('aria-pressed', String(x.dataset.bg === 'night')));
}

loadNPC(state.def);
renderRoster();
renderAnimList();
renderFaceControls();
renderBoneTree();
wireUi();
$('anim-count').textContent = String(state.lib.length);
selectClip('Idle');
frame();

// Small API for tooling (tools/export-glb.mjs) and console use.
window.NPCApp = {
  defs: NPC_DEFS,
  get npc() { return state.npc; },
  get state() { return state; },
  animations: state.lib.map((e) => e.name),
  play: selectClip,
  exportGLB: (opts = {}) => exportNPC(state.def, opts),
  exportDef: (index, opts = {}) => exportNPC(NPC_DEFS[index], opts),
  exportAllZip: () => exportAllNPCsZip(NPC_DEFS),
};
