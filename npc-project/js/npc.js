// Generic NPC assembly: turns part geometry into skinned meshes that share one
// skeleton and one material. Character-specific looks live in js/npcs/*.js.

import * as THREE from 'three';
import { mergeGeometries, mergeVertices, toCreasedNormals } from 'three/addons/utils/BufferGeometryUtils.js';
import { createSkeletonBones, MM_TO_M, SKELETON_STANDARD, BONE_NAMES } from './skeleton.js';
import { createPaletteMaterial } from './materials.js';
import { mirrorX } from './geometry.js';

const toRight = (name) => name.replace(/^Left/, 'Right');

export class FigureBuilder {
  constructor(palette) {
    this.paletteApi = createPaletteMaterial(palette);
    this.pieces = new Map();      // meshName -> [{geo, colorKey, skin}]
    this.morphMeshes = [];        // custom geometry with morph targets
  }

  // skin: bone name (rigid) or fn(x, y, z) -> [[bone, weight], ...]
  add(meshName, geo, colorKey, skin, { mirror = false, crease = 60 } = {}) {
    this._push(meshName, geo, colorKey, skin, crease);
    if (mirror) {
      const rightMesh = typeof mirror === 'string' ? mirror : toRight(meshName);
      const rightSkin = typeof skin === 'string' ? toRight(skin) : skin;
      this._push(rightMesh, mirrorX(geo), colorKey, rightSkin, crease);
    }
  }

  addMorphMesh(meshName, geometry, morphNames) {
    this.morphMeshes.push({ meshName, geometry, morphNames });
  }

  _push(meshName, geo, colorKey, skin, crease) {
    if (!this.pieces.has(meshName)) this.pieces.set(meshName, []);
    this.pieces.get(meshName).push({ geo, colorKey, skin, crease });
  }

  build({ name, merged = false }) {
    const { root, bones, byName } = createSkeletonBones();
    const boneIndex = Object.fromEntries(bones.map((b, i) => [b.name, i]));
    root.updateMatrixWorld(true);
    const skeleton = new THREE.Skeleton(bones);

    const group = new THREE.Group();
    group.name = name;
    group.add(root);

    const material = this.paletteApi.material;
    const meshGeos = [];
    for (const [meshName, pieces] of this.pieces) {
      const geos = pieces.map((p) => this._processPiece(p, boneIndex));
      let geo = mergeGeometries(geos, false);
      geo = mergeVertices(geo, 1e-6);
      geo.name = meshName;
      meshGeos.push([meshName, geo]);
    }

    const finalGeos = merged
      ? [['Body_Mesh', mergeVertices(mergeGeometries(meshGeos.map((g) => g[1]), false), 1e-6)]]
      : meshGeos;

    const meshes = [];
    for (const [meshName, geo] of finalGeos) {
      compactAttributes(geo);
      const mesh = new THREE.SkinnedMesh(geo, material);
      mesh.name = meshName;
      mesh.castShadow = true;
      mesh.receiveShadow = true;
      mesh.frustumCulled = false;
      group.add(mesh);
      mesh.bind(skeleton, new THREE.Matrix4());
      meshes.push(mesh);
    }

    for (const { meshName, geometry, morphNames } of this.morphMeshes) {
      const geo = geometry.clone();
      const uv = new Float32Array(geo.attributes.position.count * 2);
      const keys = geo.userData.colorKeys;
      for (let i = 0; i < keys.length; i++) {
        const [u, v] = this.paletteApi.uvOf(keys[i]);
        uv[i * 2] = u;
        uv[i * 2 + 1] = v;
      }
      geo.setAttribute('uv', new THREE.BufferAttribute(uv, 2));
      const n = geo.attributes.position.count;
      const si = new Uint16Array(n * 4), sw = new Float32Array(n * 4);
      const hi = boneIndex[geo.userData.bone];
      for (let i = 0; i < n; i++) { si[i * 4] = hi; sw[i * 4] = 1; }
      geo.setAttribute('skinIndex', new THREE.Uint16BufferAttribute(si, 4));
      geo.setAttribute('skinWeight', new THREE.Float32BufferAttribute(sw, 4));
      scaleGeometry(geo, MM_TO_M);
      compactAttributes(geo);
      delete geo.userData.colorKeys;
      const mesh = new THREE.SkinnedMesh(geo, material);
      mesh.name = meshName;
      mesh.castShadow = false;
      mesh.receiveShadow = false;
      mesh.frustumCulled = false;
      mesh.updateMorphTargets();
      group.add(mesh);
      mesh.bind(skeleton, new THREE.Matrix4());
      mesh.userData.morphTargets = morphNames;
      meshes.push(mesh);
    }

    return { group, skeleton, bones: byName, meshes, material };
  }

  _processPiece({ geo, colorKey, skin, crease }, boneIndex) {
    let g = geo.index ? geo.toNonIndexed() : geo.clone();
    for (const key of Object.keys(g.attributes)) if (key !== 'position') g.deleteAttribute(key);
    g = toCreasedNormals(g, THREE.MathUtils.degToRad(crease));
    const n = g.attributes.position.count;
    const [u, v] = this.paletteApi.uvOf(colorKey);
    const uv = new Float32Array(n * 2);
    const si = new Uint16Array(n * 4);
    const sw = new Float32Array(n * 4);
    const pos = g.attributes.position;
    for (let i = 0; i < n; i++) {
      uv[i * 2] = u;
      uv[i * 2 + 1] = v;
      const weights = typeof skin === 'string' ? [[skin, 1]] : skin(pos.getX(i), pos.getY(i), pos.getZ(i));
      let total = 0;
      weights.forEach(([, w]) => (total += w));
      weights.slice(0, 4).forEach(([bone, w], k) => {
        const idx = boneIndex[bone];
        if (idx === undefined) throw new Error('Unknown bone ' + bone);
        si[i * 4 + k] = idx;
        sw[i * 4 + k] = w / total;
      });
    }
    g.setAttribute('uv', new THREE.BufferAttribute(uv, 2));
    g.setAttribute('skinIndex', new THREE.Uint16BufferAttribute(si, 4));
    g.setAttribute('skinWeight', new THREE.Float32BufferAttribute(sw, 4));
    scaleGeometry(g, MM_TO_M);
    return g;
  }
}

// Game-ready vertex layout: unit normals, UNSIGNED_BYTE joints, normalized
// UNSIGNED_BYTE weights and normalized UNSIGNED_SHORT UVs (all core glTF 2.0).
function compactAttributes(geo) {
  const n = geo.attributes.normal;
  for (let i = 0; i < n.count; i++) {
    const x = n.getX(i), y = n.getY(i), z = n.getZ(i);
    const len = Math.hypot(x, y, z);
    if (!(len > 1e-6)) n.setXYZ(i, 0, 1, 0);
    else n.setXYZ(i, x / len, y / len, z / len);
  }
  const si = geo.attributes.skinIndex, sw = geo.attributes.skinWeight, uv = geo.attributes.uv;
  const joints = new Uint8Array(si.count * 4), weights = new Uint8Array(sw.count * 4), uvs = new Uint16Array(uv.count * 2);
  for (let i = 0; i < si.count; i++) {
    let sum = 0;
    for (let c = 0; c < 4; c++) {
      joints[i * 4 + c] = si.getComponent(i, c);
      weights[i * 4 + c] = Math.round(sw.getComponent(i, c) * 255);
      sum += weights[i * 4 + c];
    }
    weights[i * 4] += 255 - sum; // keep the sum exactly 1.0
  }
  for (let i = 0; i < uv.count; i++) {
    uvs[i * 2] = Math.round(uv.getX(i) * 65535);
    uvs[i * 2 + 1] = Math.round(uv.getY(i) * 65535);
  }
  geo.setAttribute('skinIndex', new THREE.BufferAttribute(joints, 4));
  geo.setAttribute('skinWeight', new THREE.BufferAttribute(weights, 4, true));
  geo.setAttribute('uv', new THREE.BufferAttribute(uvs, 2, true));
}

function scaleGeometry(geo, s) {
  geo.scale(s, s, s); // positions only; morph targets are scaled below
  for (const attr of geo.morphAttributes.position || []) {
    for (let i = 0; i < attr.array.length; i++) attr.array[i] *= s;
    attr.needsUpdate = true;
  }
  if (geo.attributes.normal) geo.normalizeNormals();
}

// Builds an NPC from a character definition (see js/npcs/npc01_civilian.js).
export function createNPC(def, { merged = false } = {}) {
  const fb = new FigureBuilder(def.palette);
  def.build(fb);
  const built = fb.build({ name: def.exportName, merged });
  const { group, meshes } = built;

  let triangles = 0, vertices = 0, morphTargets = 0;
  for (const m of meshes) {
    const g = m.geometry;
    triangles += (g.index ? g.index.count : g.attributes.position.count) / 3;
    vertices += g.attributes.position.count;
    morphTargets += (g.morphAttributes.position || []).length;
  }

  group.userData = {
    npcId: def.id,
    npcName: def.name,
    npcType: def.type,
    skeletonStandard: SKELETON_STANDARD,
    unitScale: 'metres',
  };

  const morphMeshes = Object.fromEntries(
    meshes.filter((m) => m.morphTargetDictionary).map((m) => [m.name, m])
  );

  return {
    def,
    ...built,
    morphMeshes,
    stats: {
      triangles: Math.round(triangles),
      vertices,
      bones: BONE_NAMES.length,
      meshes: meshes.length,
      materials: 1,
      morphTargets,
      textureSize: fb.paletteApi.textureSize,
    },
  };
}
