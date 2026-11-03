// Простые анимации по времени игры (на паузе замирают вместе с игрой).
import { easeInOut } from './utils.js';

const tweens = [];
const waiters = [];

// sim: true — идёт по «времени поездки» (ускоряется перемоткой F), иначе по обычному.
export function tween({ duration = 1, delay = 0, ease = easeInOut, onUpdate = () => {}, sim = false }) {
  return new Promise((resolve) => tweens.push({ t: -delay, duration, ease, onUpdate, resolve, sim }));
}

export function wait(seconds, sim = false) {
  return tween({ duration: seconds, sim });
}

// Ждёт, пока условие станет истинным (проверяется каждый кадр).
export function until(predicate) {
  return new Promise((resolve) => waiters.push({ predicate, resolve }));
}

export function updateTweens(dt, simDt = dt) {
  for (let i = tweens.length - 1; i >= 0; i--) {
    const tw = tweens[i];
    tw.t += tw.sim ? simDt : dt;
    if (tw.t < 0) continue;
    const k = tw.duration > 0 ? Math.min(1, tw.t / tw.duration) : 1;
    tw.onUpdate(tw.ease(k), k);
    if (k >= 1) {
      tweens.splice(i, 1);
      tw.resolve();
    }
  }
  for (let i = waiters.length - 1; i >= 0; i--) {
    if (waiters[i].predicate()) {
      const w = waiters.splice(i, 1)[0];
      w.resolve();
    }
  }
}
