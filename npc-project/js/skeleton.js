// Shared skeleton standard for every NPC in the project.
// All bones have identity rest rotations (local axes aligned with the model):
//   +Y up, +Z forward (glTF front), +X = character's LEFT side.
// Rotation cheat-sheet used by animations.js (degrees, Euler XYZ):
//   Arm/Leg X < 0  -> swing forward        Forearm X < 0 -> bend elbow
//   LowerLeg X > 0 -> bend knee            Foot X < 0    -> toes up
//   Spine/Chest/Head X > 0 -> lean / look down
//   Y > 0 -> turn toward the character's left
//   LeftArm Z > 0 / RightArm Z < 0 -> raise arm sideways

import * as THREE from 'three';

export const SKELETON_STANDARD = 'MiniFig-20 v1';
export const MM_TO_M = 0.04; // 1 model mm = 4 cm  ->  figure is ~1.66 m tall

// [name, parent, model-space joint position in mm]
const LEFT = [
  ['LeftShoulder', 'Chest', [3.0, 27.0, 0]],
  ['LeftArm', 'LeftShoulder', [7.3, 26.6, 0]],
  ['LeftForearm', 'LeftArm', [8.8, 21.4, 0.0]],
  ['LeftHand', 'LeftForearm', [9.3, 17.9, 2.6]],
  ['LeftUpperLeg', 'Hips', [3.9, 13.6, 0]],
  ['LeftLowerLeg', 'LeftUpperLeg', [3.9, 6.8, 0]],
  ['LeftFoot', 'LeftLowerLeg', [3.9, 2.4, 0]],
];

const mirror = ([name, parent, [x, y, z]]) => [
  name.replace('Left', 'Right'),
  parent.replace('Left', 'Right'),
  [-x, y, z],
];

export const BONE_DEFS = [
  ['Root', null, [0, 0, 0]],
  ['Hips', 'Root', [0, 13.6, 0]],
  ['Spine', 'Hips', [0, 16.6, 0]],
  ['Chest', 'Spine', [0, 22.0, 0]],
  ['Neck', 'Chest', [0, 28.8, 0]],
  ['Head', 'Neck', [0, 30.0, 0]],
  ...LEFT.slice(0, 4),
  ...LEFT.slice(0, 4).map(mirror),
  ...LEFT.slice(4),
  ...LEFT.slice(4).map(mirror),
];

export const BONE_NAMES = BONE_DEFS.map((b) => b[0]);

export const JOINTS_MM = Object.fromEntries(BONE_DEFS.map(([n, , p]) => [n, p]));

export function createSkeletonBones() {
  const byName = {};
  const bones = [];
  for (const [name, parent, p] of BONE_DEFS) {
    const bone = new THREE.Bone();
    bone.name = name;
    const pp = parent ? JOINTS_MM[parent] : [0, 0, 0];
    bone.position.set((p[0] - pp[0]) * MM_TO_M, (p[1] - pp[1]) * MM_TO_M, (p[2] - pp[2]) * MM_TO_M);
    bone.userData.restPosition = bone.position.clone();
    if (parent) byName[parent].add(bone);
    byName[name] = bone;
    bones.push(bone);
  }
  return { root: byName.Root, bones, byName };
}
