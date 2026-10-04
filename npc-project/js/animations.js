// Animation library for the shared MiniFig-20 skeleton.
// Clips are authored procedurally (poses, keyframes, cycles, a tiny leg IK and a
// speech generator for the mouth), then baked to 30 fps THREE.AnimationClips with
// redundant keys removed. Every clip carries tracks for every bone and morph, so
// switching clips (here or in Unity / Unreal) never leaves a joint in a stale pose.

import * as THREE from 'three';
import { BONE_NAMES, BONE_DEFS, JOINTS_MM, MM_TO_M } from './skeleton.js';
import { FACE_MORPHS, MOUTH_MORPHS } from './parts.js';

export const FPS = 30;
const D2R = Math.PI / 180;
const TAU = Math.PI * 2;

/* --------------------------------------------------------------- helpers */

const clamp01 = (x) => Math.min(1, Math.max(0, x));
export const EASE = {
  linear: (t) => t,
  smooth: (t) => t * t * (3 - 2 * t),
  in: (t) => t * t,
  out: (t) => 1 - (1 - t) * (1 - t),
  inOut: (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2),
  back: (t) => { const c = 1.7; return 1 + (c + 1) * Math.pow(t - 1, 3) + c * Math.pow(t - 1, 2); },
  snap: (t) => 1 - Math.pow(1 - t, 4),
};
const sin = (p, k = 1, ph = 0) => Math.sin(TAU * (p * k + ph));
const cos = (p, k = 1, ph = 0) => Math.cos(TAU * (p * k + ph));
// smooth bump: 0 outside [c - w, c + w], 1 at c
const bump = (t, c, w) => { const x = (t - c) / w; return Math.abs(x) >= 1 ? 0 : Math.cos((x * Math.PI) / 2) ** 2; };
// smooth trapezoid envelope
const env = (t, a, b, c, d) => (t <= a || t >= d ? 0 : t < b ? EASE.smooth((t - a) / (b - a)) : t <= c ? 1 : EASE.smooth((d - t) / (d - c)));
const blinks = (t, times, d = 0.09) => Math.max(0, ...times.map((c) => bump(t, c, d)));

function mulberry32(a) {
  return () => {
    a |= 0; a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/* ------------------------------------------------------------------ pose */

// Pose = additive Euler rotations in degrees per bone, position offsets in mm,
// scale multipliers and morph weights. Static poses are plain objects:
//   { LeftArm: [x, y, z], $hips: [dx, dy, dz], $root: [...], $morph: { Mouth_A: 1 } }
class Pose {
  constructor() { this.rot = {}; this.pos = {}; this.scl = {}; this.morph = {}; }
  r(bone, x = 0, y = 0, z = 0) {
    const a = this.rot[bone] || (this.rot[bone] = [0, 0, 0]);
    a[0] += x; a[1] += y; a[2] += z;
    return this;
  }
  p(bone, x = 0, y = 0, z = 0) {
    const a = this.pos[bone] || (this.pos[bone] = [0, 0, 0]);
    a[0] += x; a[1] += y; a[2] += z;
    return this;
  }
  s(bone, x = 1, y = x, z = x) {
    const a = this.scl[bone] || (this.scl[bone] = [1, 1, 1]);
    a[0] *= x; a[1] *= y; a[2] *= z;
    return this;
  }
  m(name, w) { this.morph[name] = clamp01((this.morph[name] || 0) + w); return this; }
  mouth(weights, k = 1) { for (const [n, w] of Object.entries(weights)) this.m(n, w * k); return this; }
  apply(obj, w = 1) {
    if (!obj) return this;
    for (const [k, v] of Object.entries(obj)) {
      if (k === '$hips') this.p('Hips', v[0] * w, v[1] * w, v[2] * w);
      else if (k === '$root') this.p('Root', v[0] * w, v[1] * w, v[2] * w);
      else if (k === '$morph') for (const [n, mw] of Object.entries(v)) this.m(n, mw * w);
      else if (k[0] !== '$') this.r(k, v[0] * w, v[1] * w, v[2] * w);
    }
    return this;
  }
  // Two-bone leg IK keeping feet planted. foot = [dx, dy, dz, pitch] relative to the rest ankle.
  legs(left = [0, 0, 0, 0], right = [0, 0, 0, 0], straighten = 0.85) {
    solveLegs(this, left, right, straighten);
    return this;
  }
}

const L_THIGH = JOINTS_MM.LeftUpperLeg[1] - JOINTS_MM.LeftLowerLeg[1]; // 6.8
const L_SHIN = JOINTS_MM.LeftLowerLeg[1] - JOINTS_MM.LeftFoot[1];      // 4.4

function solveLegs(P, left, right, straighten) {
  const hipOff = P.pos.Hips || [0, 0, 0];
  const hipRot = P.rot.Hips || [0, 0, 0];
  const yaw = hipRot[1] * D2R, pitch = hipRot[0];
  for (const [side, foot] of [['Left', left], ['Right', right]]) {
    const hj = JOINTS_MM[side + 'UpperLeg'];
    const ank = JOINTS_MM[side + 'Foot'];
    // hip joint in world (mm)
    const hx = hipOff[0] + hj[0] * Math.cos(yaw);
    const hy = hj[1] + hipOff[1];
    const hz = hipOff[2] - hj[0] * Math.sin(yaw);
    // ankle target in world
    const tx = ank[0] + (foot[0] || 0), ty = ank[1] + (foot[1] || 0), tz = (foot[2] || 0);
    let dx = tx - hx, dy = ty - hy, dz = tz - hz;
    // into the hips' yaw frame
    const lx = dx * Math.cos(yaw) - dz * Math.sin(yaw);
    const lz = dx * Math.sin(yaw) + dz * Math.cos(yaw);
    const lateral = Math.atan2(lx, -dy) / D2R;
    const down = Math.hypot(lx, dy);
    const D = Math.min(Math.hypot(lz, down), L_THIGH + L_SHIN - 1e-3);
    const phi = Math.atan2(lz, down);
    const alpha = Math.acos(THREE.MathUtils.clamp((L_THIGH ** 2 + D * D - L_SHIN ** 2) / (2 * L_THIGH * D), -1, 1));
    const inner = Math.acos(THREE.MathUtils.clamp((L_THIGH ** 2 + L_SHIN ** 2 - D * D) / (2 * L_THIGH * L_SHIN), -1, 1));
    const thighWorld = (phi + alpha) / D2R;
    const knee = 180 - inner / D2R;
    P.r(side + 'UpperLeg', -thighWorld - pitch, -hipRot[1] * straighten, lateral);
    P.r(side + 'LowerLeg', knee, 0, 0);
    P.r(side + 'Foot', (foot[3] || 0) + thighWorld - knee, 0, -lateral - (hipRot[2] || 0));
  }
}

// Keeps the soles on the ground for FK leg poses (sagittal approximation).
// mode 'contact': lowest sole touches the floor; 'clamp': only prevents sinking.
const SOLE = [[-3.95, -2.4], [5.55, -2.4], [-3.95, -1.6], [5.55, -1.3]];
function soleHeight(P, side) {
  const hip = P.rot.Hips || [0, 0, 0];
  const th = (hip[0] + (P.rot[side + 'UpperLeg']?.[0] || 0)) * D2R;
  const sh = th + (P.rot[side + 'LowerLeg']?.[0] || 0) * D2R;
  const ft = sh + (P.rot[side + 'Foot']?.[0] || 0) * D2R;
  const hy = JOINTS_MM[side + 'UpperLeg'][1] + (P.pos.Hips?.[1] || 0);
  const ay = hy - L_THIGH * Math.cos(th) - L_SHIN * Math.cos(sh);
  let lo = Infinity;
  for (const [z, y] of SOLE) lo = Math.min(lo, ay + y * Math.cos(ft) - z * Math.sin(ft));
  return lo;
}
function groundFeet(P, mode = 'contact') {
  const lo = Math.min(soleHeight(P, 'Left'), soleHeight(P, 'Right'));
  if (mode === 'contact' || lo < 0) P.p('Hips', 0, -lo, 0);
}

// Convert a static pose with $legs into explicit leg rotations (for keyframing).
const LEG_BONES = ['LeftUpperLeg', 'LeftLowerLeg', 'LeftFoot', 'RightUpperLeg', 'RightLowerLeg', 'RightFoot'];
function ik(obj) {
  const P = new Pose();
  P.apply(obj);
  for (const b of LEG_BONES) delete P.rot[b];
  const legs = obj.$legs || {};
  P.legs(legs.left, legs.right, legs.straighten ?? 0.85);
  const out = { ...obj };
  delete out.$legs;
  for (const b of LEG_BONES) out[b] = P.rot[b];
  return out;
}

function lerpPose(a, b, u) {
  const out = {};
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  for (const k of keys) {
    if (k === '$morph') {
      const m = {};
      const names = new Set([...Object.keys(a.$morph || {}), ...Object.keys(b.$morph || {})]);
      for (const n of names) m[n] = THREE.MathUtils.lerp(a.$morph?.[n] || 0, b.$morph?.[n] || 0, u);
      out.$morph = m;
    } else {
      const va = a[k] || [0, 0, 0], vb = b[k] || [0, 0, 0];
      out[k] = [0, 1, 2].map((i) => THREE.MathUtils.lerp(va[i], vb[i], u));
    }
  }
  return out;
}

// keys: [[time, pose, ease?], ...] — ease shapes the segment arriving at that key
function keyed(t, keys) {
  if (t <= keys[0][0]) return keys[0][1];
  for (let i = 1; i < keys.length; i++) {
    if (t <= keys[i][0]) {
      const [t0, a] = keys[i - 1];
      const [t1, b, e = 'smooth'] = keys[i];
      return lerpPose(a, b, EASE[e](clamp01((t - t0) / (t1 - t0))));
    }
  }
  return keys[keys.length - 1][1];
}

function mirrorPose(src, dst) {
  const swap = (n) => (n.startsWith('Left') ? 'Right' + n.slice(4) : n.startsWith('Right') ? 'Left' + n.slice(5) : n);
  for (const [b, v] of Object.entries(src.rot)) dst.r(swap(b), v[0], -v[1], -v[2]);
  for (const [b, v] of Object.entries(src.pos)) dst.p(swap(b), -v[0], v[1], v[2]);
  for (const [b, v] of Object.entries(src.scl)) dst.s(swap(b), ...v);
  for (const [n, w] of Object.entries(src.morph)) dst.m(n, w);
}

// Deterministic "speech": syllables mapped to visemes, for talk clips.
function speech(seed, phrases, { rate = 6.5, intensity = 0.9, set = ['Mouth_A', 'Mouth_E', 'Mouth_O', 'Mouth_U', 'Mouth_Open'] } = {}) {
  const rnd = mulberry32(seed);
  const syl = [];
  for (const [a, b] of phrases) {
    let t = a;
    while (t < b - 0.05) {
      const d = (0.7 + rnd() * 0.6) / rate;
      syl.push({ c: t + d / 2, d, v: set[Math.floor(rnd() * set.length)], amp: intensity * (0.55 + 0.45 * rnd()) });
      t += d;
    }
  }
  const fn = (time) => {
    const w = {};
    for (const s of syl) {
      const x = (time - s.c) / (s.d * 0.7);
      if (Math.abs(x) < 1) w[s.v] = Math.max(w[s.v] || 0, Math.cos((x * Math.PI) / 2) ** 2 * s.amp);
    }
    return w;
  };
  fn.syllables = syl;
  return fn;
}

/* ---------------------------------------------------------- static poses */

const GUARD = ik({
  Hips: [0, -18, 0], $hips: [0, -0.9, 0],
  Spine: [3, 6, 0], Chest: [3, 6, 0], Neck: [0, 2, 0], Head: [4, 4, 0],
  LeftArm: [-38, -30, 6], LeftForearm: [-98, 0, 0], LeftHand: [0, 0, 0],
  RightArm: [-26, 26, -6], RightForearm: [-112, 0, 0],
  $legs: { left: [0.6, 0, 2.4, 0], right: [-0.6, 0, -2.4, 0] },
  $morph: { Brows_Angry: 0.35 },
});

const CROUCH = ik({
  $hips: [0, -2.6, -1.6], Spine: [16, 0, 0], Chest: [6, 0, 0], Head: [-14, 0, 0],
  LeftArm: [38, 0, 10], RightArm: [38, 0, -10], LeftForearm: [-18, 0, 0], RightForearm: [-18, 0, 0],
  $legs: { left: [0, 0, 0, 0], right: [0, 0, 0, 0] },
});

const LAND_POSE = ik({
  $hips: [0, -2.4, -1.4], Spine: [14, 0, 0], Chest: [5, 0, 0], Head: [-10, 0, 0],
  LeftArm: [-20, 0, 32], RightArm: [-20, 0, -32], LeftForearm: [-35, 0, 0], RightForearm: [-35, 0, 0],
  $legs: { left: [0.4, 0, 0.4, 0], right: [-0.4, 0, -0.4, 0] },
  $morph: { Mouth_O: 0.3 },
});

// Lying on the back, propped up by the backpack.
const LYING = {
  Hips: [-62, 0, 0], $hips: [0, -9.4, -2.8],
  Spine: [6, 0, 0], Chest: [4, 0, 0], Neck: [-8, 0, 0], Head: [-6, 26, 0],
  LeftArm: [-12, 0, 62], RightArm: [-8, 0, -58], LeftForearm: [-20, 0, 0], RightForearm: [-30, 0, 0],
  LeftUpperLeg: [-24, 0, 6], RightUpperLeg: [-30, 0, -4], LeftLowerLeg: [8, 0, 0], RightLowerLeg: [14, 0, 0],
  LeftFoot: [10, 0, 0], RightFoot: [12, 0, 0],
  $morph: { Blink: 1, Mouth_Open: 0.25 },
};

/* ----------------------------------------------------------- locomotion */

function locomotion(P, p, k) {
  const s = sin(p), c2 = cos(p, 2);
  for (const [side, ph, sgn] of [['Left', 0, 1], ['Right', 0.5, -1]]) {
    const q = p + ph;
    const fwd = sin(q);                         // >0 leg in front
    const swing = Math.max(0, cos(q, 1, k.kneeLead ?? 0.06)) ** 1.4;
    const thigh = -k.thigh * fwd - (k.thighBias ?? 0);
    const knee = k.kneeStance + k.kneeSwing * swing;
    const strike = bump(((q % 1) + 1) % 1, 0.25, 0.14);
    const toeOff = bump(((q % 1) + 1) % 1, 0.7, 0.12);
    P.r(side + 'UpperLeg', thigh, 0, sgn * (k.legOut ?? 0));
    P.r(side + 'LowerLeg', knee);
    P.r(side + 'Foot', -(thigh + knee) * (k.footFollow ?? 1) - 12 * k.roll * strike + 22 * k.roll * toeOff);
    // arms swing opposite to the leg on the same side
    const armFwd = -fwd;
    P.r(side + 'Arm', -k.arm * armFwd + (k.armBias ?? 0), 0, sgn * k.armOut);
    P.r(side + 'Forearm', k.forearm - k.forearmSwing * Math.max(0, armFwd));
  }
  P.p('Hips', -k.sway * cos(p), k.bob * c2 - (k.drop ?? 0), 0);
  P.r('Hips', 0, -k.twist * s, 0);
  P.r('Spine', k.lean, k.twist * 0.5 * s, 0);
  P.r('Chest', k.lean * 0.4 + k.breath * c2, k.twist * 1.2 * s, 0);
  P.r('Neck', -k.lean * 0.4, 0, 0);
  P.r('Head', -k.lean * 0.5 + k.headBob * c2, -k.twist * 1.2 * s, 0);
  groundFeet(P, k.flight ? 'clamp' : 'contact');
}

const WALK = {
  thigh: 24, kneeStance: 5, kneeSwing: 34, roll: 0.8, arm: 21, armOut: 3, forearm: -10, forearmSwing: 14,
  bob: 0.32, sway: 0.25, twist: 5, lean: 3, headBob: 1.2, breath: 0.6,
};
const WALK_SLOW = { ...WALK, thigh: 15, kneeSwing: 22, arm: 11, forearmSwing: 6, bob: 0.18, sway: 0.18, twist: 3, lean: 1.5, headBob: 0.8, roll: 0.5 };
const WALK_FAST = { ...WALK, thigh: 31, kneeSwing: 48, arm: 32, forearm: -24, forearmSwing: 22, bob: 0.45, twist: 7, lean: 6, roll: 1 };
const RUN = {
  thigh: 40, thighBias: 8, kneeStance: 14, kneeSwing: 80, kneeLead: 0.1, roll: 0.9, footFollow: 0.85,
  arm: 44, armOut: 7, forearm: -78, forearmSwing: 18, armBias: -6, bob: 0.9, drop: 0.7, sway: 0.2, twist: 9, lean: 11, headBob: 1.5, breath: 1,
  flight: true,
};
const SPRINT = { ...RUN, thigh: 54, thighBias: 14, kneeSwing: 102, kneeStance: 18, arm: 60, forearm: -88, forearmSwing: 12, bob: 1.2, drop: 1.2, twist: 11, lean: 19, armBias: -10 };

/* --------------------------------------------------------------- library */

// Each entry: [name, category, duration (s), loop, fn(t, P, p)]
function defineClips() {
  const C = [];
  const add = (name, category, duration, loop, fn, label) => C.push({ name, category, duration, loop, fn, label: label || name.replace(/_/g, ' ') });
  const mirrored = (fn) => (t, P, p) => { const tmp = new Pose(); fn(t, tmp, p); mirrorPose(tmp, P); };

  /* ---- idle ---- */
  add('Idle', 'Idle', 3.0, true, (t, P, p) => {
    P.p('Hips', 0.22 * sin(p), 0.04 * cos(p, 2), 0);
    P.r('Hips', 0, 0, 0.8 * sin(p));
    P.r('Spine', 0.6 * sin(p, 1, 0.25), 0, -0.9 * sin(p));
    P.r('Chest', 1.1 * sin(p, 1, 0.1), 1.2 * sin(p, 1, 0.4), 0);
    P.s('Chest', 1 + 0.008 * sin(p, 1, 0.1));
    P.r('Head', 1.2 * sin(p, 2), 3 * sin(p, 1, 0.6), -0.8 * sin(p));
    P.r('LeftArm', 1.2 * sin(p, 1, 0.3), 0, 2.5 + 1 * sin(p, 1, 0.1));
    P.r('RightArm', 1.2 * sin(p, 1, 0.8), 0, -2.5 - 1 * sin(p, 1, 0.1));
    P.r('LeftForearm', -2 + 1.5 * sin(p, 1, 0.4));
    P.r('RightForearm', -2 + 1.5 * sin(p, 1, 0.9));
    P.legs([0, 0, 0, 0], [0, 0, 0, 0], 0);
    P.m('Blink', blinks(t, [1.15]));
  });

  add('Idle_Breathing', 'Idle', 4.0, true, (t, P, p) => {
    const br = sin(p, 1, -0.25) * 0.5 + 0.5; // inhale 0..1
    P.r('Spine', -1.2 * br, 0, 0);
    P.r('Chest', -2.6 * br, 0, 0);
    P.s('Chest', 1 + 0.035 * br, 1 + 0.02 * br, 1 + 0.045 * br);
    P.r('LeftShoulder', 0, 0, 3 * br);
    P.r('RightShoulder', 0, 0, -3 * br);
    P.r('LeftArm', 0, 0, 2 + 1.5 * br);
    P.r('RightArm', 0, 0, -2 - 1.5 * br);
    P.r('Head', -2.5 * br + 0.8, 0, 0);
    P.p('Hips', 0, 0.12 * br, 0);
    P.m('Mouth_Open', 0.18 * bump(p, 0.82, 0.14));
    P.m('Blink', blinks(t, [2.55]));
  });

  add('Idle_Combat', 'Combat', 1.2, true, (t, P, p) => {
    const b = 0.5 + 0.5 * cos(p, 2);
    const g = { ...GUARD };
    P.apply(g);
    P.p('Hips', 0, -0.35 * b, 0);
    // recompute legs for the bounce so feet stay planted
    for (const n of LEG_BONES) delete P.rot[n];
    P.legs([0.6, 0, 2.4, 0], [-0.6, 0, -2.4, 0]);
    P.r('LeftArm', 3 * b, 0, 0);
    P.r('RightArm', 3 * cos(p, 2, 0.2), 0, 0);
    P.r('Head', 1.5 * b, 0, 0);
    P.m('Blink', blinks(t, [0.85]));
  });

  /* ---- locomotion ---- */
  add('Walk', 'Locomotion', 1.0, true, (t, P, p) => locomotion(P, p, WALK));
  add('Walk_Slow', 'Locomotion', 1.4, true, (t, P, p) => { locomotion(P, p, WALK_SLOW); P.r('Head', 3, 0, 0); });
  add('Walk_Fast', 'Locomotion', 0.76, true, (t, P, p) => locomotion(P, p, WALK_FAST));
  add('Walk_Backward', 'Locomotion', 1.1, true, (t, P, p) => { locomotion(P, 1 - p, { ...WALK, thigh: 20, kneeSwing: 30, lean: -2, arm: 14 }); });
  add('Run', 'Locomotion', 0.62, true, (t, P, p) => { locomotion(P, p, RUN); P.m('Mouth_Open', 0.25); });
  add('Sprint', 'Locomotion', 0.46, true, (t, P, p) => { locomotion(P, p, SPRINT); P.m('Mouth_Open', 0.45); P.m('Brows_Angry', 0.3); });

  const turn = (t, P) => {
    const u = EASE.inOut(clamp01(t / 0.85));
    P.r('Root', 0, 90 * u, 0);
    const stepL = env(t, 0.05, 0.2, 0.3, 0.45), stepR = env(t, 0.38, 0.52, 0.62, 0.8);
    P.p('Hips', 0, -0.5 * Math.max(stepL, stepR), 0);
    P.legs([0, 1.4 * stepL, 0.8 * stepL, 0], [0, 1.4 * stepR, -0.6 * stepR, 0], 0);
    P.r('Chest', 0, 10 * env(t, 0, 0.15, 0.4, 0.75), 0);
    P.r('Head', 0, 18 * env(t, 0, 0.12, 0.35, 0.7), 0);
    P.r('LeftArm', -10 * stepR + 8 * stepL, 0, 4);
    P.r('RightArm', -10 * stepL + 8 * stepR, 0, -4);
  };
  add('Turn_Left', 'Locomotion', 1.0, false, turn);
  add('Turn_Right', 'Locomotion', 1.0, false, mirrored(turn));

  add('Jump', 'Locomotion', 1.25, false, (t, P) => {
    const TAKEOFF = { $hips: [0, 2.2, 0.3], Spine: [-4, 0, 0], Head: [-6, 0, 0],
      LeftUpperLeg: [6, 0, 0], RightUpperLeg: [6, 0, 0], LeftLowerLeg: [6, 0, 0], RightLowerLeg: [6, 0, 0], LeftFoot: [32, 0, 0], RightFoot: [32, 0, 0],
      LeftArm: [-150, 0, 14], RightArm: [-150, 0, -14], LeftForearm: [-12, 0, 0], RightForearm: [-12, 0, 0], $morph: { Mouth_O: 0.4, Brows_Raised: 0.5 } };
    const APEX = { $hips: [0, 9.5, 0.4], Spine: [6, 0, 0], Head: [-4, 0, 0],
      LeftUpperLeg: [-34, 0, 4], RightUpperLeg: [-26, 0, -4], LeftLowerLeg: [58, 0, 0], RightLowerLeg: [48, 0, 0], LeftFoot: [12, 0, 0], RightFoot: [10, 0, 0],
      LeftArm: [-118, 0, 28], RightArm: [-118, 0, -28], LeftForearm: [-24, 0, 0], RightForearm: [-24, 0, 0], $morph: { Mouth_Smile: 0.5, Brows_Raised: 0.8 } };
    const PRE = { $hips: [0, 2.6, 0.2], Spine: [4, 0, 0],
      LeftUpperLeg: [-16, 0, 2], RightUpperLeg: [-14, 0, -2], LeftLowerLeg: [20, 0, 0], RightLowerLeg: [18, 0, 0], LeftFoot: [6, 0, 0], RightFoot: [6, 0, 0],
      LeftArm: [-60, 0, 34], RightArm: [-60, 0, -34], LeftForearm: [-30, 0, 0], RightForearm: [-30, 0, 0], $morph: { Mouth_O: 0.3 } };
    P.apply(keyed(t, [
      [0, {}], [0.3, CROUCH], [0.42, TAKEOFF, 'out'], [0.66, APEX, 'out'], [0.86, PRE, 'in'], [0.95, LAND_POSE, 'out'], [1.25, {}],
    ]));
  });

  add('Land', 'Locomotion', 0.75, false, (t, P) => {
    const AIR = { $hips: [0, 3.2, 0.2], Spine: [2, 0, 0],
      LeftUpperLeg: [-18, 0, 3], RightUpperLeg: [-14, 0, -3], LeftLowerLeg: [24, 0, 0], RightLowerLeg: [20, 0, 0], LeftFoot: [8, 0, 0], RightFoot: [8, 0, 0],
      LeftArm: [-70, 0, 38], RightArm: [-70, 0, -38], LeftForearm: [-25, 0, 0], RightForearm: [-25, 0, 0], $morph: { Mouth_O: 0.35, Brows_Raised: 0.6 } };
    const DEEP = ik({ ...LAND_POSE, $hips: [0, -3.1, -1.9], Spine: [20, 0, 0], $legs: { left: [0.4, 0, 0.4, 0], right: [-0.4, 0, -0.4, 0] } });
    P.apply(keyed(t, [[0, AIR], [0.1, LAND_POSE, 'in'], [0.2, DEEP, 'out'], [0.75, {}, 'smooth']]));
  });

  add('Fall', 'Locomotion', 0.9, true, (t, P, p) => {
    P.p('Hips', 0, 3 + 0.4 * sin(p, 2), 0);
    P.r('Spine', -10 + 3 * sin(p), 0, 0);
    P.r('Chest', -4, 4 * sin(p), 0);
    P.r('Head', -12 + 4 * sin(p, 2), 6 * sin(p, 1, 0.2), 0);
    P.r('LeftArm', -40 + 30 * sin(p, 1, 0.1), 0, 120 + 22 * sin(p, 2));
    P.r('RightArm', -40 + 30 * sin(p, 1, 0.6), 0, -120 - 22 * sin(p, 2, 0.3));
    P.r('LeftForearm', -30 + 20 * sin(p, 2, 0.2));
    P.r('RightForearm', -30 + 20 * sin(p, 2, 0.7));
    P.r('LeftUpperLeg', -30 - 22 * sin(p), 0, 6);
    P.r('RightUpperLeg', -30 + 22 * sin(p), 0, -6);
    P.r('LeftLowerLeg', 45 + 25 * sin(p, 1, 0.25));
    P.r('RightLowerLeg', 45 + 25 * sin(p, 1, 0.75));
    P.r('LeftFoot', 10); P.r('RightFoot', 10);
    P.m('Mouth_O', 0.85); P.m('Brows_Raised', 1);
  });

  add('Get_Up', 'Locomotion', 2.1, false, (t, P) => {
    const SIT = { Hips: [-14, 0, 0], $hips: [0, -9.6, -1.0], Spine: [10, 0, 0], Chest: [6, 0, 0], Head: [6, 0, 0],
      LeftUpperLeg: [-74, 0, 6], RightUpperLeg: [-74, 0, -6], LeftLowerLeg: [12, 0, 0], RightLowerLeg: [12, 0, 0], LeftFoot: [-6, 0, 0], RightFoot: [-6, 0, 0],
      LeftArm: [36, 0, 20], RightArm: [36, 0, -20], LeftForearm: [-6, 0, 0], RightForearm: [-6, 0, 0], $morph: { Brows_Sad: 0.4 } };
    const TUCK = ik({ $hips: [0, -7.4, -2.8], Spine: [34, 0, 0], Chest: [8, 0, 0], Head: [-22, 0, 0],
      LeftArm: [-48, 0, 12], RightArm: [-48, 0, -12], LeftForearm: [-30, 0, 0], RightForearm: [-30, 0, 0],
      $legs: { left: [0.3, 0, 0.6, 0], right: [-0.3, 0, -0.6, 0] }, $morph: { Brows_Sad: 0.3 } });
    const RISE = ik({ $hips: [0, -2.0, -0.9], Spine: [12, 0, 0], Head: [-8, 0, 0],
      LeftArm: [-12, 0, 8], RightArm: [-12, 0, -8], LeftForearm: [-14, 0, 0], RightForearm: [-14, 0, 0],
      $legs: { left: [0, 0, 0, 0], right: [0, 0, 0, 0] } });
    P.apply(keyed(t, [[0, LYING], [0.2, LYING], [0.75, SIT], [1.25, TUCK], [1.7, RISE], [2.1, {}]]));
    P.m('Blink', 1 - EASE.smooth(clamp01((t - 0.1) / 0.25)));
  });

  /* ---- combat ---- */
  add('Punch_Right', 'Combat', 0.62, false, (t, P) => {
    const WIND = { ...GUARD, Hips: [0, -26, 0], Chest: [3, -6, 0], RightArm: [-22, 22, -8], RightForearm: [-118, 0, 0] };
    const HIT = { ...GUARD, Hips: [0, 4, 0], Spine: [6, 14, 0], Chest: [5, 18, 0], Head: [4, -26, 0], $hips: [0, -0.9, 0.9],
      RightArm: [-90, 8, -2], RightForearm: [22, 0, 0], RightHand: [0, 0, 0], LeftArm: [-44, -34, 8], LeftForearm: [-104, 0, 0],
      $morph: { Brows_Angry: 0.9, Mouth_E: 0.5 } };
    P.apply(keyed(t, [[0, GUARD], [0.12, WIND], [0.22, HIT, 'snap'], [0.32, HIT], [0.62, GUARD]]));
  });
  add('Punch_Left', 'Combat', 0.5, false, (t, P) => {
    const HIT = { ...GUARD, Hips: [0, -24, 0], Spine: [5, -6, 0], Chest: [4, -10, 0], Head: [4, 24, 0], $hips: [0, -0.9, 0.7],
      LeftArm: [-90, -6, 2], LeftForearm: [22, 0, 0], $morph: { Brows_Angry: 0.9, Mouth_E: 0.4 } };
    P.apply(keyed(t, [[0, GUARD], [0.15, HIT, 'snap'], [0.24, HIT], [0.5, GUARD]]));
  });
  add('Punch_Combo', 'Combat', 1.5, false, (t, P) => {
    const JAB = { ...GUARD, Hips: [0, -24, 0], Chest: [4, -10, 0], Head: [4, 24, 0], $hips: [0, -0.9, 0.7],
      LeftArm: [-90, -6, 2], LeftForearm: [22, 0, 0], $morph: { Brows_Angry: 1, Mouth_E: 0.4 } };
    const CROSS = { ...GUARD, Hips: [0, 6, 0], Spine: [6, 14, 0], Chest: [5, 18, 0], Head: [4, -28, 0], $hips: [0, -1.0, 1.0],
      RightArm: [-90, 8, -2], RightForearm: [22, 0, 0], LeftArm: [-44, -34, 8], LeftForearm: [-104, 0, 0], $morph: { Brows_Angry: 1, Mouth_A: 0.5 } };
    const UPPER = { ...GUARD, Hips: [0, -30, 0], Spine: [-4, -10, 0], Chest: [-6, -14, 0], Head: [0, 30, 0], $hips: [0, -1.6, 0.4],
      LeftArm: [-120, -26, 6], LeftForearm: [-70, 0, 0], RightArm: [-30, 30, -6], RightForearm: [-118, 0, 0], $morph: { Brows_Angry: 1, Mouth_E: 0.6 } };
    P.apply(keyed(t, [[0, GUARD], [0.16, JAB, 'snap'], [0.26, JAB], [0.38, GUARD], [0.5, CROSS, 'snap'], [0.62, CROSS], [0.78, GUARD],
      [0.94, UPPER, 'snap'], [1.06, UPPER], [1.5, GUARD]]));
  });
  add('Kick', 'Combat', 1.0, false, (t, P) => {
    const base = { ...GUARD, Hips: [0, -10, 0] };
    const sup = { left: [0.6, 0, 1.6, 0], right: [-0.6, 0, -2.4, 0] };
    const CHAMBER = { ...ik({ ...base, $hips: [0, -0.4, 0], Spine: [-8, 6, 0], $legs: sup }),
      RightUpperLeg: [-92, 12, 0], RightLowerLeg: [104, 0, 0], RightFoot: [10, 0, 0], LeftArm: [-50, -36, 14], RightArm: [-14, 30, -20] };
    const EXT = { ...CHAMBER, Spine: [-16, 6, 0], Head: [10, 4, 0], RightUpperLeg: [-98, 12, 0], RightLowerLeg: [6, 0, 0], RightFoot: [28, 0, 0],
      $morph: { Brows_Angry: 1, Mouth_A: 0.5 } };
    P.apply(keyed(t, [[0, GUARD], [0.22, CHAMBER], [0.34, EXT, 'snap'], [0.46, EXT], [0.6, CHAMBER], [1.0, GUARD]]));
  });
  add('Block', 'Combat', 1.0, true, (t, P, p) => {
    const b = 0.5 + 0.5 * cos(p, 2);
    P.apply(ik({ ...GUARD, $hips: [0, -1.3 - 0.25 * b, -0.3], Spine: [8, 4, 0], Chest: [6, 4, 0], Head: [12, 6, 0],
      LeftArm: [-74, -40, 12], LeftForearm: [-88, 0, 0], RightArm: [-70, 40, -12], RightForearm: [-92, 0, 0],
      $legs: { left: [0.6, 0, 2.4, 0], right: [-0.6, 0, -2.4, 0] }, $morph: { Brows_Angry: 0.8, Blink: 0.35 } }));
    P.r('LeftArm', 2 * b); P.r('RightArm', 2 * b);
  });
  add('Dodge', 'Combat', 0.8, false, (t, P) => {
    const e = env(t, 0.04, 0.24, 0.42, 0.75);
    P.apply(GUARD, 1 - e * 0.3);
    for (const n of LEG_BONES) delete P.rot[n];
    P.p('Hips', 3.6 * e, -1.8 * e, 0);
    P.r('Spine', 8 * e, 0, -16 * e);
    P.r('Chest', 6 * e, 0, -8 * e);
    P.r('Head', 0, 0, 14 * e);
    P.legs([1.2 * e, 0, 2.4, 0], [-0.6, 0, -2.4, 0]);
    P.m('Brows_Raised', 0.6 * e); P.m('Mouth_O', 0.4 * e);
  });
  add('Hit_Reaction', 'Combat', 0.7, false, (t, P) => {
    const IMPACT = { Head: [-26, 12, 8], Neck: [-10, 0, 0], Chest: [-14, 6, 0], Spine: [-8, 0, 0], $hips: [0, -0.6, -1.2],
      LeftArm: [-30, 0, 24], RightArm: [-36, 0, -30], LeftForearm: [-40, 0, 0], RightForearm: [-46, 0, 0],
      LeftUpperLeg: [4, 0, 0], RightUpperLeg: [10, 0, 0], LeftLowerLeg: [8, 0, 0], RightLowerLeg: [10, 0, 0],
      $morph: { Blink: 1, Mouth_O: 0.6, Brows_Sad: 0.7 } };
    const RECOIL = { Head: [-8, 4, 2], Chest: [-5, 2, 0], Spine: [-2, 0, 0], $hips: [0, -0.3, -0.8],
      LeftArm: [-10, 0, 10], RightArm: [-12, 0, -12], LeftForearm: [-15, 0, 0], RightForearm: [-18, 0, 0],
      $morph: { Mouth_Frown: 0.5, Brows_Sad: 0.6 } };
    P.apply(keyed(t, [[0, {}], [0.08, IMPACT, 'snap'], [0.3, RECOIL], [0.7, {}]]));
  });
  add('Death', 'Combat', 1.9, false, (t, P) => {
    const HIT = { Head: [-24, 8, 0], Chest: [-12, 0, 0], Spine: [-6, 0, 0], $hips: [0, -0.5, -1.0],
      LeftArm: [-26, 0, 22], RightArm: [-30, 0, -26], LeftForearm: [-36, 0, 0], RightForearm: [-40, 0, 0], $morph: { Blink: 1, Mouth_O: 0.7, Brows_Sad: 0.8 } };
    const BUCKLE = ik({ $hips: [0, -2.4, -0.8], Spine: [14, 0, 0], Chest: [6, 0, 0], Head: [18, 0, 0],
      LeftArm: [6, 0, 8], RightArm: [8, 0, -8], LeftForearm: [-6, 0, 0], RightForearm: [-6, 0, 0],
      $legs: { left: [0.3, 0, 0.2, 0], right: [-0.3, 0, -0.2, 0] }, $morph: { Blink: 0.8, Mouth_Open: 0.4, Brows_Sad: 0.9 } });
    const TOPPLE = { Hips: [-40, 0, 0], $hips: [0, -5.5, -3.4], Spine: [4, 0, 0], Head: [-4, 10, 0],
      LeftArm: [-30, 0, 40], RightArm: [-30, 0, -40], LeftForearm: [-20, 0, 0], RightForearm: [-20, 0, 0],
      LeftUpperLeg: [-20, 0, 4], RightUpperLeg: [-24, 0, -4], LeftLowerLeg: [30, 0, 0], RightLowerLeg: [34, 0, 0], LeftFoot: [-6, 0, 0], RightFoot: [-6, 0, 0],
      $morph: { Blink: 1, Mouth_Open: 0.5 } };
    const BOUNCE = { ...LYING, $hips: [0, -8.6, -2.8], Hips: [-58, 0, 0] };
    P.apply(keyed(t, [[0, {}], [0.12, HIT, 'snap'], [0.55, BUCKLE], [0.95, TOPPLE, 'in'], [1.2, LYING, 'in'], [1.35, BOUNCE, 'out'], [1.6, LYING, 'in'], [1.9, LYING]]));
  });

  /* ---- social / emotes ---- */
  add('Wave', 'Social', 1.6, true, (t, P, p) => {
    P.r('RightArm', -12, 0, -152);
    P.r('RightForearm', -18, 0, 26 * sin(p, 2));
    P.r('RightHand', 0, 0, 10 * sin(p, 2, 0.15));
    P.r('RightShoulder', 0, 0, -5);
    P.r('Chest', 0, -4, 3);
    P.r('Head', -3, -6, -5 + 2 * sin(p, 2));
    P.r('LeftArm', 0, 0, 3);
    P.m('Mouth_Smile', 0.75); P.m('Brows_Raised', 0.35);
    P.m('Blink', blinks(t, [1.1]));
  });
  add('Point', 'Social', 1.5, false, (t, P) => {
    const POINT = { RightArm: [-84, 14, -8], RightForearm: [20, 0, 0], RightHand: [0, 0, 0], RightShoulder: [0, 0, -4],
      Chest: [0, 14, 0], Spine: [0, 4, 0], Head: [-3, -12, 0], LeftArm: [0, 0, 4],
      $morph: { Brows_Raised: 0.7, Mouth_Open: 0.35 } };
    P.apply(keyed(t, [[0, {}], [0.32, POINT, 'back'], [1.1, POINT], [1.5, {}]]));
    P.r('RightArm', 3 * bump(t, 0.75, 0.25), 0, 0);
  });
  add('Clap', 'Social', 0.9, true, (t, P, p) => {
    const close = Math.max(0, cos(p, 2)) ** 2.5; // two claps per loop
    for (const [side, sgn] of [['Left', 1], ['Right', -1]]) {
      P.r(side + 'Arm', -42 - 2 * close, sgn * (-30 - 46 * close), sgn * -13);
      P.r(side + 'Forearm', -42);
      P.r(side + 'Hand', 0, sgn * 20, 0);
    }
    P.r('Chest', 2 * close, 0, 0);
    P.r('Head', 3 * close, 0, 0);
    P.m('Mouth_Smile', 0.85); P.m('Brows_Raised', 0.4);
  });

  const talk = (seed, phrases, opts) => speech(seed, phrases, opts);
  const T1 = talk(7, [[0.15, 1.4], [1.7, 3.0]], { rate: 6.5, intensity: 0.85 });
  add('Talk', 'Talk', 3.2, true, (t, P, p) => {
    P.r('Chest', 1.2 * sin(p, 2), 4 * sin(p), 0);
    P.r('Spine', 0, 1.5 * sin(p, 1, 0.3), 0);
    P.r('Head', 2.5 * sin(p, 3, 0.1) + 1, 6 * sin(p, 2, 0.3), 2.5 * sin(p, 1, 0.6));
    P.r('RightArm', -16 + 6 * sin(p, 2), 18, -4);
    P.r('RightForearm', -48 + 20 * sin(p, 2, 0.2));
    P.r('RightHand', 0, 25 * sin(p, 2, 0.4), 0);
    P.r('LeftArm', -6 + 4 * sin(p, 1, 0.5), -6, 3);
    P.r('LeftForearm', -22 + 12 * sin(p, 2, 0.7));
    P.mouth(T1(t));
    P.m('Brows_Raised', 0.35 * bump(t, 0.3, 0.25) + 0.3 * bump(t, 1.85, 0.25));
    P.m('Blink', blinks(t, [1.5, 3.05]));
  });
  const T2 = talk(21, [[0.1, 1.05], [1.25, 2.25]], { rate: 8, intensity: 1, set: ['Mouth_A', 'Mouth_E', 'Mouth_O', 'Mouth_Open', 'Mouth_A'] });
  add('Talk_Excited', 'Talk', 2.4, true, (t, P, p) => {
    P.p('Hips', 0, 0.25 * Math.abs(sin(p, 2)), 0);
    P.r('Chest', -2 + 2 * sin(p, 4), 6 * sin(p, 2), 0);
    P.r('Head', -3 + 4 * sin(p, 4, 0.1), 8 * sin(p, 2, 0.2), 4 * sin(p, 2, 0.5));
    P.r('RightArm', -34 + 14 * sin(p, 2), 20, -14);
    P.r('RightForearm', -70 + 30 * sin(p, 4));
    P.r('LeftArm', -34 + 14 * sin(p, 2, 0.5), -20, 14);
    P.r('LeftForearm', -70 + 30 * sin(p, 4, 0.5));
    P.r('RightHand', 0, 30 * sin(p, 4), 0);
    P.r('LeftHand', 0, -30 * sin(p, 4, 0.5), 0);
    P.mouth(T2(t));
    P.m('Mouth_Smile', 0.35);
    P.m('Brows_Raised', 0.7 + 0.3 * sin(p, 4));
    P.m('Blink', blinks(t, [1.15]));
  });
  const T3 = talk(5, [[0.1, 1.0], [1.2, 2.25]], { rate: 7, intensity: 1, set: ['Mouth_A', 'Mouth_E', 'Mouth_E', 'Mouth_Open', 'Mouth_O'] });
  add('Talk_Angry', 'Talk', 2.4, true, (t, P, p) => {
    const jab = Math.max(bump(t, 0.35, 0.12), bump(t, 0.75, 0.12), bump(t, 1.45, 0.12), bump(t, 1.95, 0.12));
    P.r('Spine', 4, 0, 0);
    P.r('Chest', 4 + 3 * jab, 4 * sin(p, 2), 0);
    P.r('Neck', 6, 0, 0);
    P.r('Head', -4 + 7 * jab, 5 * sin(p, 2, 0.2), 0);
    P.r('RightArm', -58 + 8 * jab, 16, -6);
    P.r('RightForearm', -34 + 16 * jab);
    P.r('LeftArm', 6, -30, 30);
    P.r('LeftForearm', -84);
    P.r('LeftHand', 0, 0, 0);
    P.mouth(T3(t));
    P.m('Mouth_Frown', 0.35);
    P.m('Brows_Angry', 1);
  });
  const T4 = talk(13, [[0.2, 1.6], [2.1, 3.6]], { rate: 5, intensity: 0.6, set: ['Mouth_E', 'Mouth_O', 'Mouth_Open', 'Mouth_U', 'Mouth_A'] });
  add('Talk_Calm', 'Talk', 4.0, true, (t, P, p) => {
    // hands resting together in front of the belly
    for (const [side, sgn] of [['Left', 1], ['Right', -1]]) {
      P.r(side + 'Arm', -55 + 1.5 * sin(p, 1, sgn > 0 ? 0 : 0.5), sgn * -70, sgn * -40);
      P.r(side + 'Forearm', -12);
    }
    P.r('Chest', 0.8 * sin(p), 2 * sin(p, 1, 0.2), 0);
    P.r('Head', 2 * sin(p, 2), 3 * sin(p, 1, 0.4), -3 + 2 * sin(p, 1));
    P.mouth(T4(t));
    P.m('Mouth_Smile', 0.25);
    P.m('Blink', blinks(t, [1.9, 3.8], 0.11));
  });

  add('Look_Around', 'Social', 4.0, true, (t, P) => {
    const yaw = keyed(t, [[0, { y: [0, 0, 0] }], [0.6, { y: [0, 55, 0] }], [1.6, { y: [0, 55, 0] }], [2.3, { y: [0, -55, 0] }],
      [3.3, { y: [0, -55, 0] }], [4.0, { y: [0, 0, 0] }]]).y[1];
    const up = 6 * bump(t, 1.1, 0.5) - 4 * bump(t, 2.8, 0.5);
    P.r('Head', -up, yaw * 0.62, 0);
    P.r('Neck', 0, yaw * 0.18, 0);
    P.r('Chest', 0, yaw * 0.2, 0);
    P.m('Blink', blinks(t, [0.3, 1.95, 3.65]));
    P.m('Brows_Raised', 0.3 * bump(t, 1.1, 0.5));
  });
  add('Shake_Head', 'Social', 1.3, false, (t, P) => {
    const e = env(t, 0, 0.12, 0.85, 1.25);
    P.r('Head', 3 * e, 26 * e * Math.sin(TAU * 2.2 * t / 1.0), 0);
    P.r('Neck', 0, 8 * e * Math.sin(TAU * 2.2 * t / 1.0 - 0.4), 0);
    P.m('Mouth_Frown', 0.5 * e); P.m('Brows_Sad', 0.5 * e);
  });
  add('Nod', 'Social', 1.1, false, (t, P) => {
    const x = keyed(t, [[0, { a: [0, 0, 0] }], [0.2, { a: [17, 0, 0] }], [0.42, { a: [-3, 0, 0] }], [0.62, { a: [13, 0, 0] }], [1.1, { a: [0, 0, 0] }]]).a[0];
    P.r('Head', x, 0, 0);
    P.r('Neck', x * 0.3, 0, 0);
    P.m('Mouth_Smile', 0.45 * env(t, 0, 0.2, 0.8, 1.1));
  });
  add('Celebrate', 'Emotes', 1.2, true, (t, P, p) => {
    const hop = Math.max(0, sin(p, 1, 0)) ;               // airborne half of the loop
    const squat = Math.max(0, -sin(p, 1, 0));
    P.p('Hips', 0, 4.5 * hop ** 0.8 - 1.6 * squat, 0);
    P.legs([0.2, 3.8 * hop ** 0.9, 0.4 * hop, 18 * hop], [-0.2, 3.8 * hop ** 0.9, 0.4 * hop, 18 * hop], 0);
    const pump = sin(p, 2);
    P.r('LeftArm', -14, 0, 148 + 10 * pump);
    P.r('RightArm', -14, 0, -148 - 10 * pump);
    P.r('LeftForearm', -22 - 14 * pump);
    P.r('RightForearm', -22 - 14 * pump);
    P.r('Spine', -4, 0, 0);
    P.r('Head', -10 + 3 * pump, 0, 0);
    P.m('Mouth_Smile', 1); P.m('Brows_Raised', 0.8);
  });
  add('Shrug', 'Emotes', 1.3, false, (t, P) => {
    const SHRUG = { LeftShoulder: [0, 0, 14], RightShoulder: [0, 0, -14], LeftArm: [-8, 36, 22], RightArm: [-8, -36, -22],
      LeftForearm: [-74, 0, 0], RightForearm: [-74, 0, 0], LeftHand: [0, 30, 0], RightHand: [0, -30, 0], Head: [-4, 0, -10], Chest: [-2, 0, 0],
      $morph: { Brows_Raised: 1, Mouth_Frown: 0.5 } };
    P.apply(keyed(t, [[0, {}], [0.35, SHRUG, 'out'], [0.85, SHRUG], [1.3, {}]]));
  });
  add('Think', 'Emotes', 3.0, true, (t, P, p) => {
    // right hand on the chin, left arm across the belly
    P.r('RightArm', -102, 56, 36);
    P.r('RightForearm', -42 - 3 * Math.max(0, sin(p, 6)));
    P.r('RightHand', 0, -20, 0);
    P.r('LeftArm', -55, -70, -40);
    P.r('LeftForearm', -12);
    P.r('Head', 6 + 1.5 * sin(p), 6 * sin(p, 1, 0.3), -7);
    P.r('Chest', 1, 0, 0);
    P.p('Hips', 0.25 * sin(p), 0, 0);
    P.m('Mouth_U', 0.35); P.m('Brows_Sad', 0.25); P.m('Brows_Raised', 0.25 * bump(t, 2.0, 0.4));
    P.m('Blink', blinks(t, [0.9, 2.4]));
  });
  add('Sit_Idle', 'Emotes', 3.0, true, (t, P, p) => {
    P.p('Hips', 0, -6.7, 0);
    for (const [side, sgn] of [['Left', 1], ['Right', -1]]) {
      P.r(side + 'UpperLeg', -90, 0, sgn * 3);
      P.r(side + 'LowerLeg', 88);
      P.r(side + 'Foot', 2);
      P.r(side + 'Arm', -46, sgn * -8, sgn * 4);
      P.r(side + 'Forearm', -22);
    }
    P.r('Spine', 4 + 0.8 * sin(p), 0, 0);
    P.r('Chest', 1.2 * sin(p, 1, 0.1), 2 * sin(p, 1, 0.4), 0);
    P.r('Head', 2 + 1 * sin(p, 2), 8 * sin(p, 1, 0.6), 0);
    P.m('Blink', blinks(t, [1.3]));
  });
  add('Dance', 'Emotes', 1.0, true, (t, P, p) => {
    const side = sin(p), beat = Math.abs(cos(p));
    P.p('Hips', 2.0 * side, -1.0 - 0.6 * beat, 0);
    P.r('Hips', 0, 8 * side, -3 * side);
    P.legs([1.6 * Math.max(0, side), 1.2 * Math.max(0, -side), 0, 0], [1.6 * Math.min(0, side), 1.2 * Math.max(0, side), 0, 0], 0.5);
    P.r('Spine', 4, -6 * side, 4 * side);
    P.r('Chest', 0, -8 * side, 3 * side);
    P.r('LeftArm', -30 * sin(p, 2), -10, 18);
    P.r('RightArm', 30 * sin(p, 2), 10, -18);
    P.r('LeftForearm', -88);
    P.r('RightForearm', -88);
    P.r('Head', 4 * beat, 10 * side, -6 * side);
    P.m('Mouth_Smile', 0.8); P.m('Brows_Raised', 0.3 * beat);
  });

  return C;
}

/* ----------------------------------------------------------------- bake */

const MORPH_TARGET_MESH = Object.fromEntries([
  ...FACE_MORPHS.map((n) => [n, 'Face_Mesh']),
  ...MOUTH_MORPHS.map((n) => [n, 'Mouth_Mesh']),
]);
const ALL_MORPHS = [...FACE_MORPHS, ...MOUTH_MORPHS];

function bakeClip({ name, duration, fn }) {
  const frames = Math.max(2, Math.round(duration * FPS) + 1);
  const times = new Float32Array(frames);
  const quats = Object.fromEntries(BONE_NAMES.map((b) => [b, new Float32Array(frames * 4)]));
  const posFrames = [];
  const sclFrames = [];
  const morphs = Object.fromEntries(ALL_MORPHS.map((n) => [n, new Float32Array(frames)]));
  const e = new THREE.Euler(), q = new THREE.Quaternion(), prev = {};
  for (let i = 0; i < frames; i++) {
    const t = (i / (frames - 1)) * duration;
    times[i] = t;
    const P = new Pose();
    fn(t, P, t / duration);
    for (const b of BONE_NAMES) {
      const r = P.rot[b] || [0, 0, 0];
      q.setFromEuler(e.set(r[0] * D2R, r[1] * D2R, r[2] * D2R, 'XYZ'));
      if (prev[b] && prev[b].dot(q) < 0) q.set(-q.x, -q.y, -q.z, -q.w);
      prev[b] = (prev[b] || new THREE.Quaternion()).copy(q);
      q.toArray(quats[b], i * 4);
    }
    posFrames.push(P.pos);
    sclFrames.push(P.scl);
    for (const n of ALL_MORPHS) morphs[n][i] = P.morph[n] || 0;
  }

  const tracks = [];
  for (const b of BONE_NAMES) tracks.push(new THREE.QuaternionKeyframeTrack(`${b}.quaternion`, times, quats[b]));
  // position tracks: Root & Hips always, other bones only if animated
  const posBones = new Set(['Root', 'Hips']);
  posFrames.forEach((pf) => Object.keys(pf).forEach((b) => posBones.add(b)));
  for (const b of posBones) {
    const v = new Float32Array(frames * 3);
    const rest = restOffset(b);
    for (let i = 0; i < frames; i++) {
      const o = posFrames[i][b] || [0, 0, 0];
      v[i * 3] = (rest[0] + o[0]) * MM_TO_M;
      v[i * 3 + 1] = (rest[1] + o[1]) * MM_TO_M;
      v[i * 3 + 2] = (rest[2] + o[2]) * MM_TO_M;
    }
    tracks.push(new THREE.VectorKeyframeTrack(`${b}.position`, times, v));
  }
  const sclBones = new Set();
  sclFrames.forEach((sf) => Object.keys(sf).forEach((b) => sclBones.add(b)));
  for (const b of sclBones) {
    const v = new Float32Array(frames * 3);
    for (let i = 0; i < frames; i++) {
      const s = sclFrames[i][b] || [1, 1, 1];
      v.set(s, i * 3);
    }
    tracks.push(new THREE.VectorKeyframeTrack(`${b}.scale`, times, v));
  }
  for (const n of ALL_MORPHS) {
    tracks.push(new THREE.NumberKeyframeTrack(`${MORPH_TARGET_MESH[n]}.morphTargetInfluences[${n}]`, times, morphs[n]));
  }
  for (const tr of tracks) reduceTrack(tr);
  // Tracks that never leave the rest pose are dropped: three.js, Unity and Unreal
  // all fall back to the bind pose for bones a clip does not animate.
  const kept = tracks.filter((tr) => !isRestTrack(tr));
  return new THREE.AnimationClip(name, duration, kept);
}

function isRestTrack(tr) {
  const v = tr.values, size = tr.getValueSize();
  let rest;
  if (tr.name.endsWith('.quaternion')) rest = [0, 0, 0, 1];
  else if (tr.name.endsWith('.scale')) rest = [1, 1, 1];
  else if (tr.name.endsWith('.position')) rest = restOffset(tr.name.split('.')[0]).map((x) => x * MM_TO_M);
  else rest = [0];
  for (let i = 0; i < v.length; i++) if (Math.abs(v[i] - rest[i % size]) > 1e-5) return false;
  return true;
}

function restOffset(bone) {
  const def = BONE_DEFS_BY_NAME[bone];
  const p = def[2], parent = def[1] ? BONE_DEFS_BY_NAME[def[1]][2] : [0, 0, 0];
  return [p[0] - parent[0], p[1] - parent[1], p[2] - parent[2]];
}
const BONE_DEFS_BY_NAME = Object.fromEntries(BONE_DEFS.map((d) => [d[0], d]));

// Douglas–Peucker style key reduction with per-type tolerance.
function reduceTrack(track) {
  const n = track.times.length;
  const size = track.getValueSize();
  const tol = track.name.endsWith('.quaternion') ? 0.0012 : track.name.endsWith('.position') ? 0.00005
    : track.name.endsWith('.scale') ? 0.0006 : 0.008;
  const keep = new Uint8Array(n);
  keep[0] = keep[n - 1] = 1;
  const stack = [[0, n - 1]];
  const v = track.values, ti = track.times;
  while (stack.length) {
    const [a, b] = stack.pop();
    if (b - a < 2) continue;
    let worst = -1, worstErr = 0;
    for (let i = a + 1; i < b; i++) {
      const u = (ti[i] - ti[a]) / (ti[b] - ti[a]);
      let err = 0;
      for (let c = 0; c < size; c++) {
        const lerp = v[a * size + c] + (v[b * size + c] - v[a * size + c]) * u;
        err = Math.max(err, Math.abs(lerp - v[i * size + c]));
      }
      if (err > worstErr) { worstErr = err; worst = i; }
    }
    if (worstErr > tol) { keep[worst] = 1; stack.push([a, worst], [worst, b]); }
  }
  const idx = [];
  for (let i = 0; i < n; i++) if (keep[i]) idx.push(i);
  const times = new Float32Array(idx.length), values = new Float32Array(idx.length * size);
  idx.forEach((k, j) => { times[j] = ti[k]; for (let c = 0; c < size; c++) values[j * size + c] = v[k * size + c]; });
  track.times = times;
  track.values = values;
}

let _cache = null;
// Returns [{ clip, name, label, category, loop, duration }]
export function createAnimationLibrary() {
  if (_cache) return _cache;
  _cache = defineClips().map((def) => {
    const clip = bakeClip(def);
    clip.userData = { category: def.category, loop: def.loop, label: def.label };
    return { clip, name: def.name, label: def.label, category: def.category, loop: def.loop, duration: def.duration };
  });
  return _cache;
}

export const CATEGORY_ORDER = ['Idle', 'Locomotion', 'Combat', 'Talk', 'Social', 'Emotes'];
