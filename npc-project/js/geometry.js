// Geometry helpers for building minifigure parts.
// All builders work in "model millimetres" (a classic minifig is ~40 mm tall);
// npc.js scales the finished meshes to metres with MM_TO_M.

import * as THREE from 'three';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';

const _v = new THREE.Vector3();

export function roundedBox(w, h, d, r = 0.5, segments = 2) {
  const geo = new RoundedBoxGeometry(w, h, d, segments, Math.min(r, w / 2, h / 2, d / 2) * 0.999);
  return geo;
}

export function box(w, h, d) {
  return new THREE.BoxGeometry(w, h, d);
}

// Scales X of every vertex depending on its height: used for the trapezoid torso.
export function taperX(geo, yMin, yMax, scaleBottom, scaleTop) {
  const pos = geo.attributes.position;
  for (let i = 0; i < pos.count; i++) {
    const y = pos.getY(i);
    const t = THREE.MathUtils.clamp((y - yMin) / (yMax - yMin), 0, 1);
    pos.setX(i, pos.getX(i) * THREE.MathUtils.lerp(scaleBottom, scaleTop, t));
  }
  geo.deleteAttribute('normal');
  geo.computeVertexNormals();
  return geo;
}

export function roundedRectShape(x0, y0, x1, y1, r) {
  const s = new THREE.Shape();
  r = Math.min(r, (x1 - x0) / 2, (y1 - y0) / 2);
  s.moveTo(x0 + r, y0);
  s.lineTo(x1 - r, y0);
  s.quadraticCurveTo(x1, y0, x1, y0 + r);
  s.lineTo(x1, y1 - r);
  s.quadraticCurveTo(x1, y1, x1 - r, y1);
  s.lineTo(x0 + r, y1);
  s.quadraticCurveTo(x0, y1, x0, y1 - r);
  s.lineTo(x0, y0 + r);
  s.quadraticCurveTo(x0, y0, x0 + r, y0);
  return s;
}

// Extrudes a 2D side profile drawn in (z, y) along the X axis.
// The result spans x in [xCenter - width/2, xCenter + width/2].
export function extrudeSideProfile(shape, width, xCenter, bevel = 0.3, curveSegments = 6) {
  const depth = Math.max(0.01, width - bevel * 2);
  const geo = new THREE.ExtrudeGeometry(shape, {
    depth,
    bevelEnabled: bevel > 0,
    bevelThickness: bevel,
    bevelSize: bevel,
    bevelSegments: 2,
    curveSegments,
  });
  // shape (x, y) -> world (z, y); extrusion (z) -> world x
  geo.rotateY(-Math.PI / 2);
  geo.translate(xCenter + depth / 2, 0, 0);
  return geo;
}

// Extrudes a 2D front profile drawn in (x, y) along +Z, starting at z0.
export function extrudeFrontProfile(shape, thickness, z0, bevel = 0.06, curveSegments = 6) {
  const geo = new THREE.ExtrudeGeometry(shape, {
    depth: Math.max(0.01, thickness - bevel * 2),
    bevelEnabled: bevel > 0,
    bevelThickness: bevel,
    bevelSize: bevel * 0.6,
    bevelSegments: 1,
    curveSegments,
  });
  geo.translate(0, 0, z0 + bevel);
  return geo;
}

// Tapered cylinder from p0 to p1 (Vector3 or [x,y,z]).
export function limb(p0, p1, r0, r1, radialSegments = 14, openEnded = true) {
  const a = toV(p0), b = toV(p1);
  const dir = new THREE.Vector3().subVectors(b, a);
  const len = dir.length();
  const geo = new THREE.CylinderGeometry(r1, r0, len, radialSegments, 1, openEnded);
  // Cylinder is along +Y centred at origin; align it with dir.
  const q = new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 1, 0), dir.normalize());
  geo.applyQuaternion(q);
  const mid = new THREE.Vector3().addVectors(a, b).multiplyScalar(0.5);
  geo.translate(mid.x, mid.y, mid.z);
  return geo;
}

// Capsule-like limb: hemisphere (r0) at p0, cone, hemisphere (r1) at p1.
export function capsule(p0, p1, r0, r1, radialSegments = 18, capSegments = 5) {
  const a = toV(p0), b = toV(p1);
  const dir = new THREE.Vector3().subVectors(b, a);
  const len = dir.length();
  const pts = [];
  for (let i = 0; i <= capSegments; i++) {
    const t = -Math.PI / 2 + (i / capSegments) * (Math.PI / 2);
    pts.push(new THREE.Vector2(Math.max(0.0005, Math.cos(t) * r0), Math.sin(t) * r0));
  }
  for (let i = 0; i <= capSegments; i++) {
    const t = (i / capSegments) * (Math.PI / 2);
    pts.push(new THREE.Vector2(Math.max(0.0005, Math.cos(t) * r1), len + Math.sin(t) * r1));
  }
  const geo = new THREE.LatheGeometry(pts, radialSegments);
  const q = new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 1, 0), dir.normalize());
  geo.applyQuaternion(q);
  geo.translate(a.x, a.y, a.z);
  return geo;
}

export function sphereAt(p, r, w = 14, h = 10) {
  const geo = new THREE.SphereGeometry(r, w, h);
  const c = toV(p);
  geo.translate(c.x, c.y, c.z);
  return geo;
}

// Places a geometry built around the origin using a basis (e1, e2, e3) and an origin.
export function placeInBasis(geo, origin, e1, e2, e3) {
  const m = new THREE.Matrix4().makeBasis(e1, e2, e3);
  m.setPosition(toV(origin));
  geo.applyMatrix4(m);
  return geo;
}

// Rectangular strap swept along a smooth path. `side` is the strap's width direction hint.
// `outward(point)` returns a vector pointing away from the surface the strap lies on.
export function sweepStrap(points, width, thickness, side, samples = 28, outward = null, capEnds = true) {
  const curve = new THREE.CatmullRomCurve3(points.map(toV), false, 'centripetal');
  const pts = curve.getSpacedPoints(samples);
  const S = toV(side).normalize();
  const positions = [];
  const rings = [];
  for (let i = 0; i < pts.length; i++) {
    const t = curve.getTangentAt(i / (pts.length - 1)).normalize();
    const s = S.clone().sub(t.clone().multiplyScalar(S.dot(t))).normalize();
    let n = new THREE.Vector3().crossVectors(t, s).normalize();
    if (outward) {
      const o = outward(pts[i]);
      if (n.dot(o) < 0) n.negate();
    }
    const hw = width / 2, ht = thickness / 2;
    const c = pts[i];
    rings.push([
      c.clone().addScaledVector(s, hw).addScaledVector(n, ht),
      c.clone().addScaledVector(s, -hw).addScaledVector(n, ht),
      c.clone().addScaledVector(s, -hw).addScaledVector(n, -ht),
      c.clone().addScaledVector(s, hw).addScaledVector(n, -ht),
    ]);
  }
  const center = (ring) => ring.reduce((acc, p) => acc.add(p), new THREE.Vector3()).multiplyScalar(0.25);
  const tri = (a, b, c, hint) => {
    const n = new THREE.Vector3().crossVectors(_v.subVectors(b, a), new THREE.Vector3().subVectors(c, a));
    if (n.dot(hint) < 0) [b, c] = [c, b];
    positions.push(a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z);
  };
  for (let i = 0; i < rings.length - 1; i++) {
    const A = rings[i], B = rings[i + 1];
    const mid = center(A).add(center(B)).multiplyScalar(0.5);
    for (let k = 0; k < 4; k++) {
      const k2 = (k + 1) % 4;
      const faceCenter = A[k].clone().add(A[k2]).add(B[k]).add(B[k2]).multiplyScalar(0.25);
      const hint = faceCenter.sub(mid);
      tri(A[k], A[k2], B[k2], hint);
      tri(A[k], B[k2], B[k], hint);
    }
  }
  if (capEnds) {
    for (const [ring, other] of [[rings[0], rings[1]], [rings[rings.length - 1], rings[rings.length - 2]]]) {
      const hint = center(ring).sub(center(other));
      tri(ring[0], ring[1], ring[2], hint);
      tri(ring[0], ring[2], ring[3], hint);
    }
  }
  const geo = new THREE.BufferGeometry();
  geo.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
  geo.computeVertexNormals();
  return geo;
}

// Partial torus ("C" shape) with rounded tips, in the local XY plane.
// gapCenter: angle (radians, from +X towards +Y) where the opening is centred.
export function cClip(radius, tube, gapCenter, gapAngle, radialSegments = 10, tubularSegments = 20) {
  const arc = Math.PI * 2 - gapAngle;
  const geo = new THREE.TorusGeometry(radius, tube, radialSegments, tubularSegments, arc);
  const start = gapCenter + gapAngle / 2;
  geo.rotateZ(start);
  const tipA = new THREE.Vector3(Math.cos(start) * radius, Math.sin(start) * radius, 0);
  const tipB = new THREE.Vector3(Math.cos(start + arc) * radius, Math.sin(start + arc) * radius, 0);
  const capA = new THREE.SphereGeometry(tube, radialSegments, 8);
  capA.translate(tipA.x, tipA.y, tipA.z);
  const capB = new THREE.SphereGeometry(tube, radialSegments, 8);
  capB.translate(tipB.x, tipB.y, tipB.z);
  return [geo, capA, capB];
}

// Mirror a geometry across the YZ plane (x -> -x) keeping outward-facing triangles.
export function mirrorX(geo) {
  const g = geo.index ? geo.toNonIndexed() : geo.clone();
  const pos = g.attributes.position;
  for (let i = 0; i < pos.count; i++) pos.setX(i, -pos.getX(i));
  // flip winding
  for (let i = 0; i < pos.count; i += 3) {
    for (const name of Object.keys(g.attributes)) {
      const a = g.attributes[name];
      for (let c = 0; c < a.itemSize; c++) {
        const t = a.getComponent(i + 1, c);
        a.setComponent(i + 1, c, a.getComponent(i + 2, c));
        a.setComponent(i + 2, c, t);
      }
    }
  }
  if (g.attributes.normal) {
    const n = g.attributes.normal;
    for (let i = 0; i < n.count; i++) n.setX(i, -n.getX(i));
  }
  return g;
}

export function toV(p) {
  return p.isVector3 ? p.clone() : new THREE.Vector3(p[0], p[1], p[2]);
}

export function smoothstep(e0, e1, x) {
  const t = THREE.MathUtils.clamp((x - e0) / (e1 - e0), 0, 1);
  return t * t * (3 - 2 * t);
}
