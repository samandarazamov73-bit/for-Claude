// NPC 01 — Civilian: a young man in an open amber jacket, light tee,
// dark trousers, white sneakers and a small backpack. Original design.

import {
  headClassic, faceStandard, mouthStandard, hairShortWavy, torsoBlock, jacketOpen,
  armsSleeved, hipsAndLegs, sneakers, backpackSmall,
} from '../parts.js';

export default {
  id: 'npc_01',
  index: 1,
  name: 'Civilian 01',
  type: 'Civilian',
  exportName: 'NPC_01_Civilian',
  description: 'Young adult, open zip jacket over a light tee, dark trousers, white sneakers, small backpack.',
  palette: {
    skin: { color: '#F5C518', roughness: 0.26 },
    hair: { color: '#3A2417', roughness: 0.4 },
    eye: { color: '#17110E', roughness: 0.3 },
    eyeHighlight: { color: '#FFFFFF', roughness: 0.3 },
    brow: { color: '#2B1A10', roughness: 0.35 },
    mouth: { color: '#4B1B1E', roughness: 0.4 },
    teeth: { color: '#F6F4EC', roughness: 0.3 },
    tongue: { color: '#C4505B', roughness: 0.4 },
    jacket: { color: '#E8A21A', roughness: 0.3 },
    jacketDark: { color: '#C98612', roughness: 0.32 },
    tee: { color: '#F0EDE4', roughness: 0.34 },
    teeDark: { color: '#D8D2C4', roughness: 0.36 },
    zipper: { color: '#6A6F77', roughness: 0.3, metalness: 0.6 },
    pants: { color: '#2A2D34', roughness: 0.36 },
    shoe: { color: '#F2F1EC', roughness: 0.3 },
    sole: { color: '#D3D0C7', roughness: 0.5 },
    shoeAccent: { color: '#363B44', roughness: 0.34 },
    lace: { color: '#C3C6CB', roughness: 0.4 },
    pack: { color: '#2E333C', roughness: 0.42 },
    packPocket: { color: '#3A414C', roughness: 0.42 },
    packAccent: { color: '#8D949D', roughness: 0.32, metalness: 0.2 },
  },
  build(fb) {
    headClassic(fb, 'skin');
    faceStandard(fb);
    mouthStandard(fb);
    hairShortWavy(fb, 'hair');
    torsoBlock(fb, 'jacket');
    jacketOpen(fb, { tee: 'tee', teeDark: 'teeDark', jacket: 'jacket', jacketDark: 'jacketDark', zipper: 'zipper' });
    armsSleeved(fb, { sleeve: 'jacket', cuff: 'jacketDark', hand: 'skin' });
    hipsAndLegs(fb, { pants: 'pants' });
    sneakers(fb, { sole: 'sole', shoe: 'shoe', accent: 'shoeAccent', lace: 'lace' });
    backpackSmall(fb, { pack: 'pack', pocket: 'packPocket', zipper: 'zipper', accent: 'packAccent' });
  },
};
