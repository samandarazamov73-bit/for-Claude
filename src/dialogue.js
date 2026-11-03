// Проигрывает разговоры из story.js по очереди: реплики, выбор игрока, паузы, действия.
import { until, wait } from './tween.js';
import { clamp } from './utils.js';

export class Dialogue {
  constructor(ui, { actors = {}, actions = {} } = {}) {
    this.ui = ui;
    this.actors = actors;     // { mom: Human, driver: Human } — кивают, пока говорят
    this.actions = actions;   // { stopButtonTask: () => {...} }
    this.queue = [];
    this.running = false;
    this.elapsed = 0;
    this.skipRequested = false;
    this.speaker = null;
    this.generation = 0;      // растёт при clear(): старые разговоры прекращаются
  }

  get busy() {
    return this.running || this.queue.length > 0;
  }

  // Добавляет разговор в очередь; промис — когда он закончится.
  play(steps) {
    if (!steps || !steps.length) return Promise.resolve();
    return new Promise((resolve) => {
      this.queue.push({ steps, resolve });
      if (!this.running) this.run();
    });
  }

  // Обрывает текущий и отменяет ждущие разговоры (например, при прибытии).
  clear() {
    this.generation++;
    const pending = this.queue;
    this.queue = [];
    pending.forEach((item) => item.resolve());
    this.skipRequested = true;
    this.ui.cancelChoice();
  }

  async run() {
    this.running = true;
    while (this.queue.length) {
      const item = this.queue.shift();
      await this.steps(item.steps, this.generation);
      item.resolve();
    }
    this.running = false;
  }

  async steps(list, gen) {
    for (const step of list) {
      if (gen !== this.generation) return;
      if (Array.isArray(step)) await this.say(step[0], step[1]);
      else if (step.choice) {
        const i = await this.ui.choose(step.choice.map((c) => c.text));
        if (i < 0 || gen !== this.generation) return; // не ответил — герой промолчал
        const opt = step.choice[i];
        await this.say('hero', opt.text);
        await this.steps(opt.then || [], gen);
      } else if (step.pause) await wait(step.pause);
      else if (step.action) await this.actions[step.action]?.();
    }
  }

  async say(who, text) {
    const duration = clamp(1.3 + text.length * 0.055, 2.0, 7.5);
    this.elapsed = 0;
    this.skipRequested = false;
    this.speaker = who;
    this.ui.line(who, text);
    const actor = this.actors[who];
    if (actor) actor.talking = duration;
    await until(() => this.skipRequested || this.elapsed >= duration);
    if (actor) actor.talking = 0;
    this.speaker = null;
    this.ui.line(null);
    await wait(0.25);
  }

  skip() {
    this.skipRequested = true;
  }

  update(dt) {
    this.elapsed += dt;
  }
}
