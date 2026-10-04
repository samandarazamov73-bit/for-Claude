// One shared PBR material per NPC.
// Colours live in a tiny palette atlas (8x8 swatches) so the whole figure uses a
// single material / texture pair: cheap for draw calls and portable to Unity/Unreal.

import * as THREE from 'three';

const GRID = 8;      // 8 x 8 swatches
const CELL = 4;      // pixels per swatch -> 32 x 32 texture

export function createPaletteMaterial(palette, name = 'NPC_Plastic') {
  const keys = Object.keys(palette);
  if (keys.length > GRID * GRID) throw new Error('Palette too large');
  const size = GRID * CELL;

  const colorCanvas = makeCanvas(size);
  const mrCanvas = makeCanvas(size);
  const cctx = colorCanvas.getContext('2d');
  const mctx = mrCanvas.getContext('2d');
  cctx.fillStyle = '#ff00ff';
  cctx.fillRect(0, 0, size, size);
  mctx.fillStyle = 'rgb(255,128,0)';
  mctx.fillRect(0, 0, size, size);

  const uv = {};
  keys.forEach((key, i) => {
    const col = i % GRID, row = Math.floor(i / GRID);
    const entry = typeof palette[key] === 'string' ? { color: palette[key] } : palette[key];
    cctx.fillStyle = entry.color;
    cctx.fillRect(col * CELL, row * CELL, CELL, CELL);
    // glTF metallicRoughness: G = roughness, B = metalness
    const rough = Math.round((entry.roughness ?? 0.3) * 255);
    const metal = Math.round((entry.metalness ?? 0) * 255);
    mctx.fillStyle = `rgb(255,${rough},${metal})`;
    mctx.fillRect(col * CELL, row * CELL, CELL, CELL);
    // canvas row 0 is the top of the image; CanvasTexture flips Y on upload
    uv[key] = [(col + 0.5) / GRID, 1 - (row + 0.5) / GRID];
  });

  const map = new THREE.CanvasTexture(colorCanvas);
  map.colorSpace = THREE.SRGBColorSpace;
  map.name = name + '_BaseColor';
  const mrMap = new THREE.CanvasTexture(mrCanvas);
  mrMap.colorSpace = THREE.NoColorSpace;
  mrMap.name = name + '_MetalRough';
  for (const t of [map, mrMap]) {
    t.magFilter = THREE.NearestFilter;
    t.minFilter = THREE.NearestFilter;
    t.generateMipmaps = false;
  }

  const material = new THREE.MeshPhysicalMaterial({
    name,
    map,
    roughnessMap: mrMap,
    metalnessMap: mrMap,
    roughness: 1,
    metalness: 1,
    clearcoat: 0.35,
    clearcoatRoughness: 0.22,
  });

  return {
    material,
    uvOf(key) {
      if (!uv[key]) throw new Error('Unknown palette key: ' + key);
      return uv[key];
    },
    keys,
    textureSize: size,
  };
}

function makeCanvas(size) {
  if (typeof document !== 'undefined') {
    const c = document.createElement('canvas');
    c.width = c.height = size;
    return c;
  }
  return new OffscreenCanvas(size, size);
}
