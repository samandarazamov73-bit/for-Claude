// Minimal text-to-viseme lip-sync, a stand-in for audio-driven lip-sync later.
// Works with Latin and Cyrillic text and drives the Mouth_* morph targets.

const MAP = [
  [/[aаяáà]/, 'Mouth_A', 1],
  [/[eэеиiyыéè]/, 'Mouth_E', 0.9],
  [/[oоёó]/, 'Mouth_O', 1],
  [/[uуюwú]/, 'Mouth_U', 1],
  [/[mbpмбп]/, null, 0],
  [/[fvфв]/, 'Mouth_E', 0.35],
  [/[a-zа-яё]/, 'Mouth_Open', 0.45],
];

export function textToVisemes(text, { charsPerSecond = 13 } = {}) {
  const step = 1 / charsPerSecond;
  const out = [];
  let t = 0.05;
  for (const raw of text.toLowerCase()) {
    if (/[.!?…]/.test(raw)) { t += step * 4; continue; }
    if (/[,;:—-]/.test(raw)) { t += step * 2.5; continue; }
    if (/\s/.test(raw)) { t += step * 0.8; continue; }
    const hit = MAP.find(([re]) => re.test(raw));
    if (!hit) continue;
    out.push({ t, d: step * (hit[1] === 'Mouth_Open' ? 0.9 : 1.4), v: hit[1], w: hit[2] });
    t += step;
  }
  return { visemes: out, duration: t + 0.2 };
}

// Weights for every Mouth_* morph at `time` (seconds since speech start).
export function visemeWeightsAt(seq, time, names) {
  const w = Object.fromEntries(names.map((n) => [n, 0]));
  for (const s of seq.visemes) {
    if (!s.v) continue;
    const x = (time - s.t) / s.d;
    if (x > -1 && x < 1) w[s.v] = Math.max(w[s.v], Math.cos((x * Math.PI) / 2) ** 2 * s.w);
  }
  return w;
}
