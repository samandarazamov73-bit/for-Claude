// Prints what takes space inside a .glb (geometry, animation, textures).
import { readFile } from 'node:fs/promises';
const file = process.argv[2];
const buf = await readFile(file);
const jsonLen = buf.readUInt32LE(12);
const gltf = JSON.parse(buf.subarray(20, 20 + jsonLen).toString('utf8'));
const viewBytes = (i) => gltf.bufferViews[i].byteLength;
const acc = (i) => gltf.accessors[i];
const sum = { geometry: {}, animationInput: 0, animationOutput: 0, images: 0, inverseBind: 0 };
for (const m of gltf.meshes) for (const p of m.primitives) {
  for (const [k, a] of Object.entries(p.attributes)) sum.geometry[k] = (sum.geometry[k] || 0) + viewBytes(acc(a).bufferView);
  if (p.indices !== undefined) sum.geometry.indices = (sum.geometry.indices || 0) + viewBytes(acc(p.indices).bufferView);
  for (const t of p.targets || []) for (const a of Object.values(t)) sum.geometry.morphTargets = (sum.geometry.morphTargets || 0) + viewBytes(acc(a).bufferView);
}
let keys = 0;
for (const an of gltf.animations || []) for (const s of an.samplers) {
  sum.animationInput += viewBytes(acc(s.input).bufferView);
  sum.animationOutput += viewBytes(acc(s.output).bufferView);
  keys += acc(s.input).count;
}
for (const img of gltf.images || []) sum.images += viewBytes(img.bufferView);
for (const sk of gltf.skins || []) sum.inverseBind += viewBytes(acc(sk.inverseBindMatrices).bufferView);
const kb = (n) => (n / 1024).toFixed(1) + ' KB';
console.log('file', kb(buf.length), '| json', kb(jsonLen), '| meshes', gltf.meshes.length, '| nodes', gltf.nodes.length, '| animations', (gltf.animations || []).length, '| keys', keys);
console.log('geometry', Object.fromEntries(Object.entries(sum.geometry).map(([k, v]) => [k, kb(v)])));
console.log('anim input', kb(sum.animationInput), 'output', kb(sum.animationOutput), '| images', kb(sum.images), '| invBind', kb(sum.inverseBind));
console.log('extensions', gltf.extensionsUsed || []);
