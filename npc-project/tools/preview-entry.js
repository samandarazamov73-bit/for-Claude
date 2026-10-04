import * as THREE from 'three';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import { createNPC } from '../js/npc.js';
import def from '../js/npcs/npc01_civilian.js';

const W = 1600, H = 900;
const renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true });
renderer.setSize(W, H);
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.shadowMap.enabled = true;
document.body.appendChild(renderer.domElement);
const scene = new THREE.Scene();
scene.background = new THREE.Color('#cfd6de');
const pmrem = new THREE.PMREMGenerator(renderer);
scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
scene.environmentIntensity = 0.7;
const key = new THREE.DirectionalLight(0xffffff, 2.2); key.position.set(2, 4, 3); scene.add(key);
const rim = new THREE.DirectionalLight(0xbfd4ff, 1.0); rim.position.set(-3, 2, -3); scene.add(rim);
scene.add(new THREE.HemisphereLight(0xffffff, 0x445566, 0.6));
const npc = createNPC(def);
window.npc = npc;
scene.add(npc.group);
const cam = new THREE.PerspectiveCamera(30, 1, 0.05, 50);
window.renderViews = (views, target = [0, 0.85, 0], dist = 3.6) => {
  renderer.setScissorTest(true);
  const n = views.length; const w = W / n;
  views.forEach((deg, i) => {
    const a = THREE.MathUtils.degToRad(deg);
    cam.aspect = w / H; cam.updateProjectionMatrix();
    cam.position.set(target[0] + Math.sin(a) * dist, target[1] + 0.25, target[2] + Math.cos(a) * dist);
    cam.lookAt(...target);
    renderer.setViewport(i * w, 0, w, H); renderer.setScissor(i * w, 0, w, H);
    renderer.render(scene, cam);
  });
  return npc.stats;
};
window.ready = true;

// ---- animation contact sheets ----
import { createAnimationLibrary } from '../js/animations.js';
const lib = createAnimationLibrary();
window.clipNames = lib.map((c) => c.name);
const mixer = new THREE.AnimationMixer(npc.group);
const restState = npc.skeleton.bones.map((b) => [b.position.clone(), b.quaternion.clone(), b.scale.clone()]);
function resetPose() {
  npc.skeleton.bones.forEach((b, i) => { b.position.copy(restState[i][0]); b.quaternion.copy(restState[i][1]); b.scale.copy(restState[i][2]); });
}
window.renderSheet = (names, cols = 6, camDeg = 35, dist = 5.2, ty = 0.8) => {
  const rows = names.length;
  const cw = W / cols, ch = H / rows;
  renderer.setScissorTest(true);
  renderer.setClearColor('#cfd6de');
  const a = THREE.MathUtils.degToRad(camDeg);
  names.forEach((name, r) => {
    const entry = lib.find((c) => c.name === name);
    for (let c = 0; c < cols; c++) {
      const t = (c / (cols - 1)) * entry.duration * (entry.loop ? (cols - 1) / cols : 1);
      // re-activating the action makes the mixer re-save the rest pose and re-apply every track
      mixer.stopAllAction();
      const action = mixer.clipAction(entry.clip);
      action.reset().play();
      action.time = t;
      mixer.update(0);
      cam.aspect = cw / ch; cam.updateProjectionMatrix();
      cam.position.set(Math.sin(a) * dist, ty + 0.3, Math.cos(a) * dist);
      cam.lookAt(0, ty, 0);
      const y = H - (r + 1) * ch;
      renderer.setViewport(c * cw, y, cw, ch); renderer.setScissor(c * cw, y, cw, ch);
      renderer.render(scene, cam);
    }
  });
  return names.map((n) => { const e = lib.find((c) => c.name === n); return n + ':' + e.clip.tracks.reduce((s, t) => s + t.times.length, 0); });
};
window.debugPose = (name, t) => {
  const entry = lib.find((c) => c.name === name);
  mixer.stopAllAction();
  const action = mixer.clipAction(entry.clip);
  action.reset().play();
  action.time = t;
  mixer.update(0);
  const b = npc.bones.LeftLowerLeg;
  return { q: b.quaternion.toArray().map((x) => +x.toFixed(3)), hips: npc.bones.Hips.position.toArray().map((x) => +x.toFixed(4)), time: action.time, w: action.getEffectiveWeight() };
};
window.debugAll = (name, t) => {
  window.debugPose(name, t);
  const out = {};
  for (const b of npc.skeleton.bones) out[b.name] = new THREE.Euler().setFromQuaternion(b.quaternion).toArray().slice(0, 3).map((x) => Math.round(x * 57.3));
  return out;
};
// list: [[clip, time, camDeg], ...]
window.renderPoses = (list, dist = 3.4, ty = 0.8) => {
  const cw = W / list.length;
  renderer.setScissorTest(true);
  list.forEach(([name, t, deg], i) => {
    window.debugPose(name, t);
    const a = THREE.MathUtils.degToRad(deg ?? 30);
    cam.aspect = cw / H; cam.updateProjectionMatrix();
    cam.position.set(Math.sin(a) * dist, ty + 0.3, Math.cos(a) * dist);
    cam.lookAt(0, ty, 0);
    renderer.setViewport(i * cw, 0, cw, H); renderer.setScissor(i * cw, 0, cw, H);
    renderer.render(scene, cam);
  });
};
const ringOffset = (() => {
  const E = new THREE.Vector3(8.8, 21.4, 0.0), Wr = new THREE.Vector3(9.3, 17.9, 2.6);
  const d = Wr.clone().sub(E).normalize();
  return d.multiplyScalar(1.8 * 0.04);
})();
window.handGap = (name, t) => {
  window.debugPose(name, t);
  npc.group.updateMatrixWorld(true);
  const l = npc.bones.LeftHand.localToWorld(ringOffset.clone());
  const r = npc.bones.RightHand.localToWorld(ringOffset.clone().setX(-ringOffset.x));
  return { gap: +(l.distanceTo(r) / 0.04).toFixed(2), l: l.toArray().map((x) => +(x / 0.04).toFixed(1)), r: r.toArray().map((x) => +(x / 0.04).toFixed(1)) };
};
// brute-force search for arm angles that put the left ring centre at a target (mm)
window.searchArm = (target, ranges, weights = [1, 1, 1]) => {
  mixer.stopAllAction(); resetPose();
  const arm = npc.bones.LeftArm, fore = npc.bones.LeftForearm;
  const e = new THREE.Euler(); let best = null;
  const D = Math.PI / 180;
  for (let ax = ranges.ax[0]; ax <= ranges.ax[1]; ax += ranges.step)
  for (let ay = ranges.ay[0]; ay <= ranges.ay[1]; ay += ranges.step)
  for (let az = ranges.az[0]; az <= ranges.az[1]; az += ranges.step)
  for (let fx = ranges.fx[0]; fx <= ranges.fx[1]; fx += ranges.step) {
    arm.quaternion.setFromEuler(e.set(ax * D, ay * D, az * D));
    fore.quaternion.setFromEuler(e.set(fx * D, 0, 0));
    npc.group.updateMatrixWorld(true);
    const p = npc.bones.LeftHand.localToWorld(ringOffset.clone()).divideScalar(0.04);
    const err = Math.abs(p.x - target[0]) * weights[0] + Math.abs(p.y - target[1]) * weights[1] + Math.abs(p.z - target[2]) * weights[2];
    if (!best || err < best.err) best = { err: +err.toFixed(2), ax, ay, az, fx, p: p.toArray().map((v) => +v.toFixed(1)) };
  }
  resetPose();
  return best;
};
