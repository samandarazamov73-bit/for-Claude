// Интерфейс поверх 3D: субтитры, выбор ответа, подсказки, затемнение, карточки.
import { tween } from './tween.js';
import { STORY } from './data.js';

const $ = (id) => document.getElementById(id);

export class UI {
  constructor() {
    this.el = {
      loading: $('loading'), loadingFill: $('loading-fill'), loadingList: $('loading-list'),
      menu: $('menu'), hud: $('hud'), objective: $('objective'), prompt: $('prompt'),
      subtitle: $('subtitle'), subSpeaker: $('sub-speaker'), subText: $('sub-text'),
      choices: $('choices'), fade: $('fade'), titleCard: $('title-card'), tcTitle: $('tc-title'), tcSub: $('tc-sub'),
      pause: $('pause'), end: $('end'), ff: $('ff-indicator'), lockHint: $('lock-hint'), debug: $('debug'),
      routeStops: $('route-stops'), routeBus: $('route-bus'), routeHud: $('route-hud'), crosshair: $('crosshair'),
    };
    this.choiceResolve = null;
    this.fadeValue = 1;
    $('menu-title').textContent = STORY.title;
    $('menu-subtitle').textContent = STORY.subtitle;
    $('end-title').textContent = STORY.end.title;
    $('end-text').textContent = STORY.end.text;
    document.title = `${STORY.title} — ${STORY.subtitle.toLowerCase()}`;
  }

  show(name, on = true) { this.el[name].classList.toggle('hidden', !on); }

  loadingItem(label, ok, done, total) {
    const li = document.createElement('li');
    li.innerHTML = `${label}<span class="${ok ? 'file' : ''}">${ok ? 'файл' : 'заглушка'}</span>`;
    this.el.loadingList.appendChild(li);
    this.el.loadingFill.style.width = `${Math.round((done / total) * 100)}%`;
  }

  objective(text) { this.el.objective.textContent = text || ''; }

  prompt(html) {
    this.el.prompt.innerHTML = html || '';
    this.show('prompt', !!html);
  }

  line(speakerKey, text) {
    if (!text) { this.show('subtitle', false); return; }
    const sp = STORY.speakers[speakerKey] || { name: speakerKey, color: '#fff' };
    this.el.subSpeaker.textContent = `${sp.name}:`;
    this.el.subSpeaker.style.color = sp.color;
    this.el.subText.textContent = text;
    this.show('subtitle', true);
  }

  // Варианты ответа. Выбор — клавишами 1/2/3 или мышью. Нет ответа 25 с — герой промолчал (−1).
  choose(options, timeout = 25) {
    const box = this.el.choices;
    box.innerHTML = '';
    return new Promise((resolve) => {
      const done = (i) => {
        this.choiceResolve = null;
        this.choiceCancel = null;
        this.show('choices', false);
        resolve(i);
      };
      this.choiceResolve = (i) => { if (i >= 0 && i < options.length) done(i); };
      this.choiceCancel = () => done(-1);
      const token = {};
      this.choiceToken = token;
      tween({ duration: timeout }).then(() => { if (this.choiceToken === token && this.choiceCancel) this.choiceCancel(); });
      options.forEach((text, i) => {
        const b = document.createElement('button');
        b.innerHTML = `<b>${i + 1}</b>${text}`;
        b.addEventListener('click', (e) => { e.stopPropagation(); this.choiceResolve?.(i); });
        box.appendChild(b);
      });
      this.show('choices', true);
    });
  }

  pick(i) { this.choiceResolve?.(i); }
  cancelChoice() { this.choiceCancel?.(); }
  get choosing() { return !!this.choiceResolve; }

  // Затемнение по игровому времени (на паузе замирает).
  fade(to, seconds = 1) {
    const from = this.fadeValue;
    return tween({ duration: seconds, onUpdate: (k) => this.setFade(from + (to - from) * k) });
  }

  setFade(v) {
    this.fadeValue = v;
    this.el.fade.style.opacity = String(v);
  }

  async titleCard(title, sub = '', seconds = 3.5) {
    const tc = this.el.titleCard;
    this.el.tcTitle.textContent = title;
    this.el.tcSub.textContent = sub;
    tc.style.opacity = '0';
    tc.classList.remove('hidden');
    await tween({ duration: 1, onUpdate: (k) => { tc.style.opacity = String(k); } });
    await tween({ duration: seconds });
    await tween({ duration: 1, onUpdate: (k) => { tc.style.opacity = String(1 - k); } });
    tc.classList.add('hidden');
  }

  setupRoute(stops) {
    this.el.routeStops.innerHTML = '';
    for (const st of stops) {
      const d = document.createElement('div');
      d.className = `stop${st.final ? ' final' : ''}`;
      d.style.left = `${st.at * 100}%`;
      d.innerHTML = `<span class="label">${st.name}</span>`;
      this.el.routeStops.appendChild(d);
    }
  }

  setRouteProgress(f) {
    this.el.routeBus.style.left = `${Math.max(0, Math.min(1, f)) * 100}%`;
  }
}
