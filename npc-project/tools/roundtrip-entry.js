// Loads an exported .glb back with GLTFLoader and plays its clips (test helper).
import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';

const W = 1600, H = 600;
const renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true });
renderer.setSize(W, H);
renderer.toneMapping = THREE.ACESFilmicToneMapping;
document.body.appendChild(renderer.domElement);
const scene = new THREE.Scene();
scene.background = new THREE.Color('#d5dbe2');
scene.environment = new THREE.PMREMGenerator(renderer).fromScene(new RoomEnvironment(), 0.04).texture;
scene.add(new THREE.HemisphereLight(0xffffff, 0x445566, 0.8));
const dir = new THREE.DirectionalLight(0xffffff, 2); dir.position.set(2, 4, 3); scene.add(dir);
const cam = new THREE.PerspectiveCamera(30, (W / 5) / H, 0.05, 50);

window.roundtrip = async (b64, clips) => {
  const bin = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)).buffer;
  const gltf = await new GLTFLoader().parseAsync(bin, '');
  const root = gltf.scene;
  scene.add(root);
  const mixer = new THREE.AnimationMixer(root);
  const skinned = [], morphs = {};
  root.traverse((o) => { if (o.isSkinnedMesh) { skinned.push(o.name); if (o.morphTargetDictionary) morphs[o.name] = Object.keys(o.morphTargetDictionary); } });
  renderer.setScissorTest(true);
  clips.forEach(([name, t], i) => {
    mixer.stopAllAction();
    const clip = gltf.animations.find((a) => a.name === name);
    const a = mixer.clipAction(clip); a.play(); a.time = t; mixer.update(0);
    cam.position.set(1.8, 1.25, 3.6); cam.lookAt(0, 0.8, 0);
    renderer.setViewport(i * W / 5, 0, W / 5, H); renderer.setScissor(i * W / 5, 0, W / 5, H);
    renderer.render(scene, cam);
  });
  return { animations: gltf.animations.length, names: gltf.animations.map((a) => a.name).slice(0, 6), skinned, morphs, sceneName: root.name, bones: root.getObjectByName('Root') ? 'Root found' : 'no Root' };
};
window.ready = true;
