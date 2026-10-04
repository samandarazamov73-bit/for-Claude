// Reusable minifigure part library (model millimetres, +Z forward, +X = left).
// Every NPC definition composes these parts with its own palette, so all ten
// characters share one skeleton standard, one scale and one material system.

import * as THREE from 'three';
import {
  roundedBox, box, taperX, extrudeSideProfile, extrudeFrontProfile, limb, sphereAt,
  placeInBasis, sweepStrap, cClip, smoothstep, toV, roundedRectShape, capsule,
} from './geometry.js';
import { JOINTS_MM as J } from './skeleton.js';

export const DIM = {
  headBase: 30.0,
  headR: 4.75,
  headH: 9.6,
  torsoBottom: 16.2,
  torsoTop: 28.8,
  torsoHalfBottom: 7.8,
  torsoHalfTop: 6.0,
  torsoHalfDepth: 3.8,
};

export const torsoHalfWidth = (y) =>
  THREE.MathUtils.lerp(DIM.torsoHalfBottom, DIM.torsoHalfTop, THREE.MathUtils.clamp((y - DIM.torsoBottom) / (DIM.torsoTop - DIM.torsoBottom), 0, 1));

// The torso is one rigid plastic piece driven by Chest; Spine bends it at the waist.
export const torsoSkin = () => [['Chest', 1]];

/* ------------------------------------------------------------------ head */

export function headClassic(fb, color = 'skin') {
  const pts = [new THREE.Vector2(0.001, 0.15)];
  for (let i = 0; i <= 4; i++) {
    const a = -Math.PI / 2 + (i / 4) * (Math.PI / 2);
    pts.push(new THREE.Vector2(3.95 + 0.8 * Math.cos(a), 0.95 + 0.8 * Math.sin(a)));
  }
  pts.push(new THREE.Vector2(4.75, 4.9));
  for (let i = 0; i <= 5; i++) {
    const a = (i / 5) * (Math.PI / 2);
    pts.push(new THREE.Vector2(3.75 + Math.cos(a), 8.6 + Math.sin(a)));
  }
  pts.push(new THREE.Vector2(0.001, 9.6));
  const geo = new THREE.LatheGeometry(pts, 36);
  geo.translate(0, DIM.headBase, 0);
  fb.add('Head_Mesh', geo, color, 'Head', { crease: 50 });
  // neck stud (belongs to the torso piece on a real minifig)
  fb.add('Torso_Mesh', limb([0, 28.4, 0], [0, 30.6, 0], 2.45, 2.45, 20, false), color, 'Neck');
}

// Head surface profile (outer), parametrised by arc length from the top centre.
const TOP_FLAT = 3.75, CORNER_R = 1.0, CORNER_Y = 8.6;
const L1 = TOP_FLAT, L2 = (Math.PI / 2) * CORNER_R;
function headProfile(s) {
  if (s <= L1) return { r: s, y: 9.6, nr: 0, ny: 1 };
  if (s <= L1 + L2) {
    const phi = Math.PI / 2 - (s - L1) / CORNER_R;
    return { r: TOP_FLAT + Math.cos(phi) * CORNER_R, y: CORNER_Y + Math.sin(phi) * CORNER_R, nr: Math.cos(phi), ny: Math.sin(phi) };
  }
  return { r: DIM.headR, y: CORNER_Y - (s - L1 - L2), nr: 1, ny: 0 };
}

/* ------------------------------------------------------------------ hair */

// Short, slightly messy wavy hair sculpted as a shell around the head.
export function hairShortWavy(fb, color = 'hair', opts = {}) {
  const {
    front = 7.5, side = 4.9, back = 2.6, crown = 1.55, edge = 0.5,
    clumps = 5, clumpDepth = 0.36, fringe = 0.45, swirl = 4.2, sweep = 0.3,
  } = opts;
  const U = 60, V = 17;
  // hairline height (head-local y) around the head; theta = 0 faces front (+Z)
  const hairline = (th) => {
    const c = Math.cos(th);
    const B = (front - back) / 2, C = (front + back) / 2 - side;
    let y = side + B * c + C * c * c;
    const f = Math.max(0, c);
    y -= fringe * f ** 3 * (0.5 + 0.5 * Math.sin(th * 9 + 0.6));
    return y;
  };
  const positions = [];
  for (let j = 0; j <= V; j++) {
    const v = j / V;
    for (let i = 0; i <= U; i++) {
      const th = -Math.PI + (i / U) * Math.PI * 2;
      const sEnd = L1 + L2 + (CORNER_Y - hairline(th));
      const s = v * sEnd;
      const p = headProfile(s);
      const f = Math.max(0, Math.cos(th));
      let T = THREE.MathUtils.lerp(crown, edge, smoothstep(0, 0.85, v));
      // flowing wavy locks: two interleaved swirl frequencies instead of regular ribs
      const w1 = Math.pow(Math.abs(Math.sin(th * clumps + v * swirl)), 0.8);
      const w2 = 0.5 + 0.5 * Math.sin(th * (clumps * 2 - 1) - v * swirl * 1.6 + 1.3);
      T += clumpDepth * (0.65 * w1 + 0.35 * w2) * smoothstep(0.06, 0.45, v);
      T += 0.3 * f * f * smoothstep(0.45, 0.8, v) * (1 - smoothstep(0.85, 1, v)); // fringe volume
      T += sweep * -Math.sin(th) * f * smoothstep(0.1, 0.6, v) * (1 - smoothstep(0.85, 1, v)); // side-swept
      const tuck = smoothstep(0.74, 1.0, v);
      T = T * (1 - tuck) - 0.12 * tuck;
      let x = (p.r + p.nr * T) * Math.sin(th);
      let z = (p.r + p.nr * T) * Math.cos(th);
      let y = p.y + p.ny * T;
      // fringe droops forward over the forehead
      const droop = f ** 3 * smoothstep(0.62, 0.95, v) * (1 - tuck * 0.7);
      z += 0.35 * droop;
      y -= 0.15 * droop;
      positions.push(x, y + DIM.headBase, z);
    }
  }
  const index = [];
  for (let j = 0; j < V; j++) {
    for (let i = 0; i < U; i++) {
      const a = j * (U + 1) + i, b = a + 1, c = a + (U + 1), d = c + 1;
      index.push(a, c, b, b, c, d);
    }
  }
  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
  geo.setIndex(index);
  ensureOutward(geo, new THREE.Vector3(0, DIM.headBase + 5, 0));
  fb.add('Hair_Mesh', geo, color, 'Head', { crease: 75 });
}

// Flips triangle winding if the majority of faces point toward `center`.
function ensureOutward(geo, center) {
  const pos = geo.attributes.position, idx = geo.index.array;
  const a = new THREE.Vector3(), b = new THREE.Vector3(), c = new THREE.Vector3(), n = new THREE.Vector3();
  let score = 0;
  for (let i = 0; i < idx.length; i += 3) {
    a.fromBufferAttribute(pos, idx[i]); b.fromBufferAttribute(pos, idx[i + 1]); c.fromBufferAttribute(pos, idx[i + 2]);
    n.crossVectors(b.clone().sub(a), c.clone().sub(a));
    score += Math.sign(n.dot(a.clone().sub(center)));
  }
  if (score < 0) {
    for (let i = 0; i < idx.length; i += 3) { const t = idx[i + 1]; idx[i + 1] = idx[i + 2]; idx[i + 2] = t; }
  }
}

/* ------------------------------------------------------------------ face */

// Face print and mouth are thin "decal" strips wrapped on the head cylinder.
// They carry morph targets for blinking, brows and lip-sync visemes.
export const FACE_MORPHS = ['Blink', 'Brows_Angry', 'Brows_Raised', 'Brows_Sad'];
export const MOUTH_MORPHS = ['Mouth_Open', 'Mouth_A', 'Mouth_E', 'Mouth_O', 'Mouth_U', 'Mouth_Smile', 'Mouth_Frown'];

class DecalStrips {
  constructor(targets) {
    this.targets = targets;
    this.pos = [];
    this.morph = targets.map(() => []);
    this.normals = [];
    this.colorKeys = [];
    this.index = [];
  }

  static wrap(x, y, layer) {
    const R = DIM.headR + 0.07 + layer * 0.05;
    const a = x / DIM.headR;
    return [R * Math.sin(a), DIM.headBase + y, R * Math.cos(a), Math.sin(a), 0, Math.cos(a)];
  }

  // columnsFn(target | null) -> [[x, yTop, yBottom], ...] with ascending x
  addStrip(colorKey, layer, columnsFn) {
    const variants = [columnsFn(null), ...this.targets.map((t) => columnsFn(t))];
    const cols = variants[0].length;
    const start = this.pos.length / 3;
    for (let i = 0; i < cols; i++) {
      for (const k of [1, 2]) {
        const [bx, by, bz, nx, ny, nz] = DecalStrips.wrap(variants[0][i][0], variants[0][i][k], layer);
        this.pos.push(bx, by, bz);
        this.normals.push(nx, ny, nz);
        this.colorKeys.push(colorKey);
        this.targets.forEach((_, ti) => {
          const c = variants[ti + 1][i];
          const [mx, my, mz] = DecalStrips.wrap(c[0], c[k], layer);
          this.morph[ti].push(mx, my, mz);
        });
      }
    }
    for (let i = 0; i < cols - 1; i++) {
      const a = start + i * 2, b = a + 1, c = a + 2, d = a + 3;
      this.index.push(a, b, d, a, d, c);
    }
  }

  toGeometry(bone) {
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.Float32BufferAttribute(this.pos, 3));
    geo.setAttribute('normal', new THREE.Float32BufferAttribute(this.normals, 3));
    geo.setIndex(this.index);
    geo.morphAttributes.position = this.targets.map((name, i) => {
      const attr = new THREE.Float32BufferAttribute(this.morph[i], 3);
      attr.name = name;
      return attr;
    });
    geo.morphTargetsRelative = false;
    geo.userData.colorKeys = this.colorKeys;
    geo.userData.bone = bone;
    return geo;
  }
}

const cosCols = (n) => Array.from({ length: n }, (_, i) => -Math.cos((Math.PI * i) / (n - 1)));

function ellipseCols(cx, cy, rx, ry, n = 12) {
  return cosCols(n).map((u) => {
    const h = ry * Math.sqrt(Math.max(0, 1 - u * u));
    return [cx + rx * u, cy + h, cy - h];
  });
}

export function faceStandard(fb, opts = {}) {
  const {
    eyeX = 1.5, eyeY = 5.3, eyeRX = 0.36, eyeRY = 0.5,
    browY = 6.65, browInner = 0.72, browOuter = 2.3, browArch = 0.16, browThick = 0.24,
    colors = { eye: 'eye', highlight: 'eyeHighlight', brow: 'brow' },
  } = opts;
  const strips = new DecalStrips(FACE_MORPHS);

  for (const side of [1, -1]) {
    const ex = eyeX * side;
    strips.addStrip(colors.eye, 0, (t) =>
      t === 'Blink' ? ellipseCols(ex, eyeY - 0.12, eyeRX * 1.08, eyeRY * 0.1) : ellipseCols(ex, eyeY, eyeRX, eyeRY));
    const hx = ex + 0.11, hy = eyeY + 0.2;
    strips.addStrip(colors.highlight, 1, (t) =>
      t === 'Blink' ? ellipseCols(ex, eyeY - 0.12, 0.001, 0.001, 6) : ellipseCols(hx, hy, 0.11, 0.11, 6));

    const M = 9;
    strips.addStrip(colors.brow, 0, (t) =>
      Array.from({ length: M }, (_, i) => {
        const ua = i / (M - 1);
        const x = side > 0 ? browInner + (browOuter - browInner) * ua : -browOuter + (browOuter - browInner) * ua;
        const u = side > 0 ? ua : 1 - ua; // 0 = inner end, 1 = outer end
        let y = browY + browArch * Math.sin(Math.PI * u);
        if (t === 'Brows_Angry') y += THREE.MathUtils.lerp(-0.42, 0.12, u) - browArch * 0.6 * Math.sin(Math.PI * u);
        if (t === 'Brows_Raised') y += 0.42 + 0.12 * Math.sin(Math.PI * u);
        if (t === 'Brows_Sad') y += THREE.MathUtils.lerp(0.34, -0.16, u);
        if (t === 'Blink') y -= 0.08;
        const th = THREE.MathUtils.lerp(browThick, browThick * 0.62, u) * (0.6 + 0.4 * Math.sin(Math.PI * ua) ** 0.4);
        return [x, y + th / 2, y - th / 2];
      }));
  }
  fb.addMorphMesh('Face_Mesh', strips.toGeometry('Head'), FACE_MORPHS);
}

// Mouth shapes: top(u) = c*u^2 + a*(1-u^2)^p, bottom(u) = c*u^2 - b*(1-u^2)^p
export const MOUTH_SHAPES = {
  base: { hw: 1.12, c: 0.28, a: 0.0, b: 0.22, p: 1.0, yo: 0, open: 0 },
  Mouth_Open: { hw: 0.8, c: 0.06, a: 0.16, b: 0.56, p: 0.55, yo: -0.05, open: 1 },
  Mouth_A: { hw: 0.92, c: 0.04, a: 0.22, b: 0.95, p: 0.55, yo: -0.08, open: 1 },
  Mouth_E: { hw: 1.15, c: 0.12, a: 0.12, b: 0.34, p: 0.5, yo: 0, open: 1 },
  Mouth_O: { hw: 0.52, c: 0.0, a: 0.4, b: 0.5, p: 0.5, yo: -0.08, open: 0.6 },
  Mouth_U: { hw: 0.32, c: 0.0, a: 0.22, b: 0.26, p: 0.5, yo: 0, open: 0.25 },
  Mouth_Smile: { hw: 1.15, c: 0.36, a: 0.03, b: 0.62, p: 0.75, yo: 0.02, open: 1 },
  Mouth_Frown: { hw: 0.92, c: -0.26, a: 0.2, b: 0.0, p: 1.0, yo: -0.02, open: 0 },
};

export function mouthStandard(fb, opts = {}) {
  const { y = 3.0, colors = { mouth: 'mouth', teeth: 'teeth', tongue: 'tongue' } } = opts;
  const strips = new DecalStrips(MOUTH_MORPHS);
  const shape = (t) => MOUTH_SHAPES[t || 'base'];
  const top = (s, u) => s.c * u * u + s.a * Math.pow(Math.max(0, 1 - u * u), s.p);
  const bot = (s, u) => s.c * u * u - s.b * Math.pow(Math.max(0, 1 - u * u), s.p);

  strips.addStrip(colors.mouth, 0, (t) => {
    const s = shape(t);
    return cosCols(19).map((u) => [s.hw * u, y + s.yo + top(s, u), y + s.yo + bot(s, u)]);
  });
  strips.addStrip(colors.teeth, 1, (t) => {
    const s = shape(t);
    const th = s.open * Math.min(0.2, 0.22 * (s.a + s.b));
    return cosCols(9).map((u0) => {
      const u = u0 * 0.62;
      const yt = y + s.yo + top(s, u) - 0.03 * s.open;
      return [s.hw * u, yt, yt - th];
    });
  });
  strips.addStrip(colors.tongue, 1, (t) => {
    const s = shape(t);
    const h = s.open * Math.min(0.26, 0.24 * (s.a + s.b));
    const cy = y + s.yo + bot(s, 0) + h * 0.95;
    return ellipseCols(0, cy, Math.max(0.001, 0.42 * s.hw * (h > 0 ? 1 : 0)), h * 0.85, 9);
  });
  fb.addMorphMesh('Mouth_Mesh', strips.toGeometry('Head'), MOUTH_MORPHS);
}

/* ----------------------------------------------------------------- torso */

export function torsoBlock(fb, color) {
  const h = DIM.torsoTop - DIM.torsoBottom;
  const geo = roundedBox(DIM.torsoHalfBottom * 2, h, DIM.torsoHalfDepth * 2, 0.75, 3);
  taperX(geo, -h / 2, h / 2, 1, DIM.torsoHalfTop / DIM.torsoHalfBottom);
  geo.translate(0, (DIM.torsoBottom + DIM.torsoTop) / 2, 0);
  fb.add('Torso_Mesh', geo, color, torsoSkin, { crease: 50 });
}

// Open zip jacket over a T-shirt, with collar, plackets, pockets and hem.
export function jacketOpen(fb, c) {
  const Z = DIM.torsoHalfDepth;
  // T-shirt panel visible between the open jacket fronts
  const tee = new THREE.Shape();
  tee.moveTo(-2.3, 17.25); tee.lineTo(2.3, 17.25); tee.lineTo(2.05, 27.95);
  tee.quadraticCurveTo(0, 27.95, -2.05, 27.95); tee.lineTo(-2.3, 17.25);
  fb.add('Torso_Mesh', extrudeFrontProfile(tee, 0.16, Z - 0.08, 0.04), c.tee, torsoSkin);
  // T-shirt neckline rib
  const rib = new THREE.Shape();
  rib.moveTo(-1.85, 27.95); rib.quadraticCurveTo(0, 26.2, 1.85, 27.95);
  rib.lineTo(1.45, 27.95); rib.quadraticCurveTo(0, 26.75, -1.45, 27.95); rib.lineTo(-1.85, 27.95);
  fb.add('Torso_Mesh', extrudeFrontProfile(rib, 0.22, Z - 0.06, 0.04), c.teeDark, torsoSkin);
  // jacket plackets (left side, mirrored)
  const plk = new THREE.Shape();
  plk.moveTo(2.3, 17.25); plk.lineTo(3.12, 17.25); plk.lineTo(2.88, 27.7); plk.lineTo(2.05, 27.7); plk.lineTo(2.3, 17.25);
  fb.add('Torso_Mesh', extrudeFrontProfile(plk, 0.38, Z - 0.08, 0.09), c.jacket, torsoSkin, { mirror: 'Torso_Mesh' });
  const zip = new THREE.Shape();
  zip.moveTo(2.28, 17.3); zip.lineTo(2.46, 17.3); zip.lineTo(2.22, 27.6); zip.lineTo(2.04, 27.6); zip.lineTo(2.28, 17.3);
  fb.add('Torso_Mesh', extrudeFrontProfile(zip, 0.42, Z - 0.08, 0.03), c.zipper, torsoSkin, { mirror: 'Torso_Mesh' });
  // zipper pull on the left front
  fb.add('Torso_Mesh', box(0.5, 1.05, 0.22).translate(2.3, 23.9, Z + 0.42), c.zipper, torsoSkin);
  // lapels
  const lap = new THREE.Shape();
  lap.moveTo(2.0, 28.3); lap.lineTo(3.45, 28.3); lap.quadraticCurveTo(2.8, 27.0, 2.26, 26.1); lap.lineTo(2.0, 28.3);
  fb.add('Torso_Mesh', extrudeFrontProfile(lap, 0.5, Z - 0.08, 0.1), c.jacketDark, torsoSkin, { mirror: 'Torso_Mesh' });
  // collar around the neck (open at the front)
  const gap = THREE.MathUtils.degToRad(80);
  const collar = new THREE.TorusGeometry(3.05, 0.55, 7, 22, Math.PI * 2 - gap);
  collar.rotateZ(Math.PI * 1.5 + gap / 2);
  collar.rotateX(-Math.PI / 2);
  collar.scale(1, 1.35, 1);
  collar.translate(0, DIM.torsoTop + 0.2, -0.15);
  fb.add('Torso_Mesh', collar, c.jacketDark, torsoSkin);
  // welt pockets
  const pocket = box(1.9, 0.42, 0.3);
  pocket.rotateZ(THREE.MathUtils.degToRad(-18));
  pocket.translate(5.55, 18.6, Z + 0.06);
  fb.add('Torso_Mesh', pocket, c.jacketDark, torsoSkin, { mirror: 'Torso_Mesh' });
  // hem / waistband
  const hem = roundedBox(DIM.torsoHalfBottom * 2 + 0.3, 1.1, DIM.torsoHalfDepth * 2 + 0.3, 0.45, 2);
  taperX(hem, -0.55, 0.55, 1.0, torsoHalfWidth(17.3) / DIM.torsoHalfBottom);
  hem.translate(0, 16.72, 0);
  fb.add('Torso_Mesh', hem, c.jacketDark, torsoSkin);
}

/* ------------------------------------------------------------------ arms */

export function armsSleeved(fb, c) {
  const S = toV(J.LeftArm), E = toV(J.LeftForearm), W = toV(J.LeftHand);
  const d = W.clone().sub(E).normalize();
  const o = { mirror: true };
  fb.add('LeftArm_Mesh', capsule(S, E, 2.12, 1.9, 16, 5), c.sleeve, 'LeftArm', o);
  fb.add('LeftArm_Mesh', capsule(E, W.clone().addScaledVector(d, -0.6), 1.8, 1.66, 16, 4), c.sleeve, 'LeftForearm', o);
  fb.add('LeftArm_Mesh', limb(W.clone().addScaledVector(d, -1.0), W.clone().addScaledVector(d, -0.05), 1.78, 1.76, 16, false),
    c.cuff, 'LeftForearm', o);
  handsClassic(fb, c.hand);
}

export function handsClassic(fb, color) {
  const E = toV(J.LeftForearm), W = toV(J.LeftHand);
  const d = W.clone().sub(E).normalize();
  const o = { mirror: true };
  fb.add('LeftHand_Mesh', limb(W.clone().addScaledVector(d, -0.4), W.clone().addScaledVector(d, 0.55), 0.82, 0.8, 12, false),
    color, 'LeftHand', o);
  const e2 = d.clone().negate();
  const X = new THREE.Vector3(1, 0, 0);
  const e1 = X.clone().addScaledVector(d, -X.dot(d)).normalize();
  const e3 = new THREE.Vector3().crossVectors(e1, e2);
  const center = W.clone().addScaledVector(d, 1.8);
  const gapCenter = THREE.MathUtils.degToRad(-90 - 40);
  for (const g of cClip(1.05, 0.56, gapCenter, THREE.MathUtils.degToRad(70), 8, 16)) {
    fb.add('LeftHand_Mesh', placeInBasis(g, center, e1, e2, e3), color, 'LeftHand', o);
  }
}

/* ------------------------------------------------------------ hips/legs */

export function hipsAndLegs(fb, c) {
  fb.add('Hips_Mesh', roundedBox(15.4, 4.2, 7.2, 0.6, 2).translate(0, 14.9, 0), c.pants, 'Hips');
  const o = { mirror: true };
  const thigh = new THREE.Shape();
  thigh.moveTo(3.2, 7.1); thigh.lineTo(3.2, 13.6);
  thigh.absarc(0, 13.6, 3.2, 0, Math.PI, false);
  thigh.lineTo(-3.2, 7.1); thigh.lineTo(3.2, 7.1);
  fb.add('LeftLeg_Mesh', extrudeSideProfile(thigh, 7.4, 3.9, 0.3, 14), c.pants, 'LeftUpperLeg', o);
  const shin = new THREE.Shape();
  shin.moveTo(3.2, 6.5); shin.lineTo(-3.2, 6.5); shin.lineTo(-3.2, 2.1); shin.lineTo(3.2, 2.1); shin.lineTo(3.2, 6.5);
  fb.add('LeftLeg_Mesh', extrudeSideProfile(shin, 7.4, 3.9, 0.3, 4), c.pants, 'LeftLowerLeg', o);
  // knee hinge filler (hidden at rest, fills the gap when the knee bends)
  fb.add('LeftLeg_Mesh', limb([0.6, 6.8, 0], [7.2, 6.8, 0], 3.38, 3.38, 22, false), c.pants, 'LeftLowerLeg', o);
}

export function sneakers(fb, c) {
  const o = { mirror: 'Shoes_Mesh' };
  const sole = roundedRectShape(-3.95, 0, 5.55, 0.9, 0.42);
  fb.add('Shoes_Mesh', extrudeSideProfile(sole, 7.7, 3.9, 0.22, 4), c.sole, 'LeftFoot', o);
  const up = new THREE.Shape();
  up.moveTo(-3.55, 0.7);
  up.lineTo(-3.55, 2.6);
  up.quadraticCurveTo(-3.55, 3.05, -3.1, 3.05);
  up.lineTo(0.8, 3.05);
  up.quadraticCurveTo(2.0, 3.0, 3.2, 2.45);
  up.quadraticCurveTo(5.25, 1.75, 5.25, 1.0);
  up.lineTo(5.25, 0.7);
  up.lineTo(-3.55, 0.7);
  fb.add('Shoes_Mesh', extrudeSideProfile(up, 7.3, 3.9, 0.36, 5), c.shoe, 'LeftFoot', o);
  // side accent panels (no logos)
  const band = new THREE.Shape();
  band.moveTo(-2.9, 1.05); band.lineTo(3.4, 1.05); band.quadraticCurveTo(3.9, 1.3, 3.4, 1.55);
  band.lineTo(-1.6, 1.6); band.quadraticCurveTo(-2.9, 1.7, -2.9, 1.05);
  fb.add('Shoes_Mesh', extrudeSideProfile(band, 0.16, 7.57, 0, 3), c.accent, 'LeftFoot', o);
  fb.add('Shoes_Mesh', extrudeSideProfile(band, 0.16, 0.23, 0, 3), c.accent, 'LeftFoot', o);
  fb.add('Shoes_Mesh', box(3.0, 1.3, 0.45).translate(3.9, 2.45, -3.82), c.accent, 'LeftFoot', o);
  for (const z of [1.15, 1.85, 2.55]) {
    const lace = box(3.4, 0.2, 0.36);
    lace.rotateX(THREE.MathUtils.degToRad(15));
    lace.translate(3.9, 3.08 - (z - 0.8) * 0.26, z);
    fb.add('Shoes_Mesh', lace, c.lace, 'LeftFoot', o);
  }
}

/* -------------------------------------------------------------- backpack */

export function backpackSmall(fb, c) {
  const Z = DIM.torsoHalfDepth;
  const skin = () => [['Chest', 1]];
  fb.add('Backpack_Mesh', roundedBox(10.2, 10.6, 3.6, 1.3, 3).translate(0, 22.6, -Z - 1.6), c.pack, skin);
  fb.add('Backpack_Mesh', roundedBox(7.6, 4.6, 1.4, 0.55, 2).translate(0, 20.3, -Z - 3.85), c.pocket, skin);
  fb.add('Backpack_Mesh', box(6.2, 0.16, 0.16).translate(0, 22.1, -Z - 4.58), c.zipper, skin);
  fb.add('Backpack_Mesh', box(0.5, 1.0, 0.24).translate(2.2, 21.6, -Z - 4.62), c.accent, skin);
  const handle = new THREE.TorusGeometry(1.25, 0.3, 6, 12, Math.PI);
  handle.translate(0, 27.75, -Z - 1.6);
  fb.add('Backpack_Mesh', handle, c.pack, skin);
  // shoulder straps
  const strapPts = [
    [4.55, 19.5, 4.02], [4.5, 22.6, 4.06], [4.45, 26.2, 4.04],
    [4.42, 28.78, 3.72], [4.4, 29.17, 2.2], [4.4, 29.2, 0], [4.4, 29.17, -2.2],
    [4.42, 28.78, -3.72], [4.4, 27.4, -4.05], [4.3, 26.4, -4.5],
  ];
  const outward = (p) => new THREE.Vector3(0, p.y - 25.5, p.z);
  const strap = sweepStrap(strapPts, 1.3, 0.35, [1, 0, 0], 24, outward, true);
  fb.add('Backpack_Mesh', strap, c.pack, torsoSkin, { mirror: 'Backpack_Mesh', crease: 70 });
  fb.add('Backpack_Mesh', box(1.75, 0.7, 0.5).translate(4.5, 21.2, Z + 0.32), c.accent, torsoSkin,
    { mirror: 'Backpack_Mesh' });
}
