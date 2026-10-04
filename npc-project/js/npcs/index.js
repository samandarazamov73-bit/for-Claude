// Registry of NPC definitions. New characters are added here one by one.
import npc01 from './npc01_civilian.js';

export const NPC_DEFS = [npc01];

// Planned roster (shown as locked slots in the viewer until they are built).
export const ROSTER = [
  { index: 1, exportName: 'NPC_01_Civilian', label: 'Civilian' },
  { index: 2, exportName: 'NPC_02_Police', label: 'Police' },
  { index: 3, exportName: 'NPC_03_Businesswoman', label: 'Businesswoman' },
  { index: 4, exportName: 'NPC_04_Construction', label: 'Construction' },
  { index: 5, exportName: 'NPC_05_Chef', label: 'Chef' },
  { index: 6, exportName: 'NPC_06_Doctor', label: 'Doctor' },
  { index: 7, exportName: 'NPC_07_ElderlyMan', label: 'Elderly man' },
  { index: 8, exportName: 'NPC_08_HoodieGuy', label: 'Hoodie guy' },
  { index: 9, exportName: 'NPC_09_Woman', label: 'Woman' },
  { index: 10, exportName: 'NPC_10_BusinessMan', label: 'Business man' },
];
