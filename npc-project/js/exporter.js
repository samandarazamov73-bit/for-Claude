// GLB export (model / model + animations / all NPCs as ZIP) and file saving.

import * as THREE from 'three';
import { GLTFExporter } from 'three/addons/exporters/GLTFExporter.js';
import JSZip from 'jszip';
import { createNPC } from './npc.js';
import { createAnimationLibrary } from './animations.js';

export async function exportNPC(def, { animations = true, merged = false } = {}) {
  const npc = createNPC(def, { merged });
  const clips = animations ? createAnimationLibrary().map((e) => e.clip) : [];
  // Skinned meshes and the bone hierarchy become root nodes of a scene named
  // after the NPC (recommended layout for skinned glTF assets).
  const scene = new THREE.Scene();
  scene.name = def.exportName;
  scene.userData = { ...npc.group.userData };
  scene.add(...npc.group.children);
  const exporter = new GLTFExporter();
  const glb = await exporter.parseAsync(scene, {
    binary: true,
    animations: clips,
    onlyVisible: false,
    trs: false,
  });
  disposeNPC(npc, scene);
  return glb;
}

export function glbFileName(def, { animations = true, merged = false } = {}) {
  return `${def.exportName}${animations ? '' : '_NoAnim'}${merged ? '_Merged' : ''}.glb`;
}

export async function exportAllNPCsZip(defs) {
  const zip = new JSZip();
  for (const def of defs) zip.file(`${def.exportName}.glb`, await exportNPC(def, { animations: true }));
  return zip.generateAsync({ type: 'blob', compression: 'DEFLATE', compressionOptions: { level: 6 } });
}

function disposeNPC(npc, scene) {
  const seen = new Set();
  scene.traverse((o) => {
    if (o.geometry && !seen.has(o.geometry)) { seen.add(o.geometry); o.geometry.dispose(); }
  });
  const m = npc.material;
  if (m) { m.map?.dispose(); m.roughnessMap?.dispose(); m.dispose(); }
}

// Inside a claude.ai Artifact the page cannot start downloads itself; the
// `downloads` capability asks the viewer instead and only accepts some
// extensions, so .glb files travel inside a .zip there.
const ARTIFACT_OK = /\.(zip|json|txt|md|csv|png|jpg|jpeg|webp|gif|svg|html|pdf)$/i;

export function inArtifact() {
  return typeof window !== 'undefined' && !!window.claude && typeof window.claude.use === 'function';
}

export async function saveFile(filename, data, mime = 'application/octet-stream') {
  if (inArtifact()) {
    const downloads = await window.claude.use('downloads');
    if (!downloads) throw new Error('Saving files is not available in this view. Open index.html from the project to download.');
    if (!ARTIFACT_OK.test(filename)) {
      const zip = new JSZip();
      zip.file(filename, data);
      data = await zip.generateAsync({ type: 'blob', compression: 'DEFLATE' });
      filename = filename.replace(/\.[^.]+$/, '.zip');
    }
    try {
      await downloads.save({ filename, data });
    } catch (err) {
      if (err?.code === 'declined') return { filename, declined: true };
      throw new Error(err?.message || 'The download could not be saved.');
    }
    return { filename };
  }
  const blob = data instanceof Blob ? data : new Blob([data], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 4000);
  return { filename };
}

export function formatBytes(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(0)} KB`;
  return `${(n / 1024 / 1024).toFixed(2)} MB`;
}
