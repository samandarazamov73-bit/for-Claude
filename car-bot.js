'use strict';

/*
 * 🚗 OLX.uz → Telegram: новые легковые машины, фильтр только по цене.
 *
 * Движок поиска взят из бота квартир: «перебор» номеров объявлений подряд
 * (видит объявление через секунды после публикации) + список раздела раз в
 * 30 сек как страховка. Без ИИ, без подписок, без проверок автора — только
 * поймать и сразу отправить.
 *
 * Шлёт ТОЛЬКО машины, которые ещё на проверке у OLX (до публикации).
 * Уже опубликованные объявления не шлёт.
 *
 * .env:
 *   TELEGRAM_TOKEN=...        токен ОТДЕЛЬНОГО бота (@BotFather), не бота квартир
 * Кто написал боту /start — получает машины, /stop — отключает. Список
 * подписчиков хранится в car_subscribers.json.
 * необязательно:
 *   CHAT_IDS=-100123          чаты, которые получают всегда (например, свой канал)
 *   PRICE_MIN=15000           в долларах (у.е.); строки нет — без нижней границы
 *   PRICE_MAX=30000           строки нет — без верхней границы (обеих нет = любая цена)
 *   CITY_ID=4                 только Ташкент; пусто — весь Узбекистан
 *   ONLY_PRIVATE=1            без автосалонов (только частные лица)
 *   MODELS=Cobalt,Gentra,Nexia 3,Кобальт
 *                             только эти модели (через запятую); пусто — любые
 *   CAR_CATEGORY_IDS=...      номер раздела «Легковые автомобили» на OLX;
 *                             пусто — бот найдёт сам при первом запуске
 *
 * Запуск:
 *   npm i playwright dotenv && npx playwright install chromium
 *   node car-bot.js
 */

const fs = require('fs');
const path = require('path');

try {
  require('dotenv').config({ path: path.join(__dirname, '.env') });
} catch {
  const envFile = path.join(__dirname, '.env');
  if (fs.existsSync(envFile)) {
    for (const rawLine of fs.readFileSync(envFile, 'utf8').split(/\r?\n/)) {
      const line = rawLine.trim();
      if (!line || line.startsWith('#')) continue;
      const match = line.match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
      if (!match || process.env[match[1]] !== undefined) continue;
      let value = match[2].trim();
      if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) value = value.slice(1, -1);
      process.env[match[1]] = value;
    }
  }
}

let chromium = null;
try {
  ({ chromium } = require('playwright'));
} catch {
  // Без playwright OLX не пустит к API (нужен настоящий браузер). Проверяется в main().
}

// ============================================================================
// Настройки
// ============================================================================

const TOKEN = process.env.TELEGRAM_TOKEN || '';
const CHAT_IDS = String(process.env.CHAT_IDS || '').split(/[,\s]+/).filter(Boolean);
// Цена в долларах. Строки нет или она пустая — ограничения нет («любая цена»). 0 тоже работает.
function numberFromEnv(name, fallback) {
  const raw = String(process.env[name] ?? '').trim().replace(/[\s_]/g, '');
  if (raw === '') return fallback;
  const value = Number(raw);
  return Number.isFinite(value) ? value : fallback;
}
const PRICE_MIN = numberFromEnv('PRICE_MIN', 0);
const PRICE_MAX = numberFromEnv('PRICE_MAX', Infinity);
const PRICE_FILTER = PRICE_MIN > 0 || Number.isFinite(PRICE_MAX);
// Подпись цены для сообщений: «любой цены», «от 15 000 $», «до 30 000 $», «15 000–30 000 $».
function priceRangeText() {
  if (!PRICE_FILTER) return 'любой цены';
  if (PRICE_MIN > 0 && Number.isFinite(PRICE_MAX)) return `${Math.round(PRICE_MIN).toLocaleString('ru-RU')}–${Math.round(PRICE_MAX).toLocaleString('ru-RU')} $`;
  if (PRICE_MIN > 0) return `от ${Math.round(PRICE_MIN).toLocaleString('ru-RU')} $`;
  return `до ${Math.round(PRICE_MAX).toLocaleString('ru-RU')} $`;
}
// Подходит ли цена (без фильтра подходит любая, даже «договорная» без цены).
function priceOk(usd) {
  if (!PRICE_FILTER) return true;
  return usd !== null && usd >= PRICE_MIN && usd <= PRICE_MAX;
}
const CITY_ID = Number(process.env.CITY_ID) || null;
const ONLY_PRIVATE = ['1', 'true', 'yes'].includes(String(process.env.ONLY_PRIVATE || '').trim().toLowerCase());
// Для сравнения моделей: «Nexia-3», «NEXIA3», «nexia 3» → «nexia 3» (регистр, ё, знаки и слитные цифры не мешают).
function normalizeModel(text) {
  return String(text || '').toLowerCase().replace(/ё/g, 'е')
    .replace(/(\p{L})(\p{N})/gu, '$1 $2').replace(/(\p{N})(\p{L})/gu, '$1 $2')
    .replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
}
// Только эти модели. Ищутся в параметре «Модель» и в названии объявления целыми словами:
// «Nexia» — любая Nexia, «Nexia 3» — только третья. Пусто — любые модели.
const MODEL_NAMES = String(process.env.MODELS || '').split(/[,;]+/).map((name) => name.trim()).filter(Boolean);
const MODELS = MODEL_NAMES.map(normalizeModel).filter(Boolean);
const modelsText = () => (MODEL_NAMES.length ? MODEL_NAMES.join(', ') : 'любые');
const ENV_CATEGORY_IDS = String(process.env.CAR_CATEGORY_IDS || '').split(/[,\s]+/).map(Number).filter((id) => id > 0);

const OLX_API = 'https://www.olx.uz/api/v1/offers/';
const CARS_PAGE = 'https://www.olx.uz/transport/legkovye-avtomobili/';

const PROBE_STATE_FILE = path.join(__dirname, 'car_probe.json');
const HANDLED_FILE = path.join(__dirname, 'car_seen.json');
const CATEGORIES_FILE = path.join(__dirname, 'car_categories.json');
const SUBSCRIBERS_FILE = path.join(__dirname, 'car_subscribers.json');

// Темп перебора — как в боте квартир (подобран симуляцией). Быстрее не надо:
// OLX начнёт отвечать 429/403, и бот встанет на 5 минут.
// Интервал считается от НАЧАЛА запроса (раньше — после ответа, это лишние 0,3-0,8 сек).
const PROBE_INTERVAL_MS = Number(process.env.PROBE_INTERVAL_MS) || 1_500;
const PROBE_FAST_INTERVAL_MS = Math.min(700, PROBE_INTERVAL_MS);
const PROBE_RECENT_WINDOW = 20;
const RETRY_LAGGING_MS = 30_000;
const RETRY_LAGGING_HEAVY_MS = 60_000;
const PROBE_CATCHUP_RETRY_INTERVAL_MS = Math.min(700, PROBE_INTERVAL_MS);
const PROBE_BEHIND_SHARE = 0.5;
const PROBE_LOOKAHEAD_MIN = 6;
const PROBE_LOOKAHEAD_MAX = 60;
// Перепроверка номеров, которые ещё не открылись. Пока номер закрыт, OLX не говорит,
// что внутри — квартира или машина, поэтому ждать приходится все. Как только номер
// открылся и это не наша машина — он сразу уходит из очереди.
// «fast» — OLX ответил «есть, но скрыто» (410, на проверке), «slow» — «нет такого» (404, черновик).
// Расписание короче, чем в боте квартир (там до 30 мин): очередь в 2-4 раза меньше,
// больше запросов уходит на свежие номера. Если работает список раздела (страховка
// раз в 30 сек), очередь ещё короче — поздние объявления он подберёт сам.
// «Черновики» (404) иногда публикуют через пару минут — поэтому первые перепроверки
// у них частые (1, 2 мин), а дальше редкие: большинство черновиков так и не открывается.
// На olx.uz объявление на модерации отвечает «нет такого» (404), а не «скрыто» (410) —
// это видно по логу: из «черновиков» половина открывается через пару минут. Поэтому 404
// тоже смотрим часто (не реже раза в 1,5 мин ~11 мин): иначе машина откроется между
// проверками и окажется старше лимита свежести.
// Днём новых номеров 70-90 в минуту. Раньше каждый закрытый номер перепроверялся до 26 раз —
// бот захлёбывался и находил машины позже лимита свежести (на модели терялась ~половина).
// Теперь: 0,5 → 1 → 2 → 4 мин (~7,5 мин), с 3+ потоками — шаги вдвое чаще.
const RETRY_PLAN = { fast: [0.5, 1, 2, 4], slow: [0.5, 1, 2, 4] };
const RETRY_PLAN_WITH_LIST = RETRY_PLAN;
const PROBE_MAX_RETRIES = 3_000;
const PROBE_JUMP_MAX_SCHEDULE = 1_000;
const PROBE_STUCK_MS = 90_000;
const PROBE_LOG_KEEP = 30_000;
const TRANSIENT_RETRY_MS = 30_000;
const LIST_INTERVAL_MS = 30_000;
const LIST_LIMIT = 50;
const API_MAX_AGE_MINUTES = 180; // создано не раньше 3 ч назад — отсекает платные поднятия старых
// Объявления из списка, которые при запуске уже на OLX дольше MAX_AGE_MINUTES (по умолчанию 2 мин),
// бот молча помечает просмотренными.
const PUBLISHED_MAX_AGE_MINUTES = Number(process.env.MAX_AGE_MINUTES) || 2;
const LIST_PUBLISHED_MAX_AGE_MINUTES = PUBLISHED_MAX_AGE_MINUTES;
// OLX ругнулся (429/403): пауза 1 мин, повторно — 3, дальше — 5. Заодно бот сам
// замедляется на 30%, а через 10 спокойных минут понемногу разгоняется обратно.
const OLX_BLOCK_PAUSES_MS = [60_000, 3 * 60_000, 5 * 60_000];
// Бот шлёт ТОЛЬКО машины, которые OLX ещё проверяет: одно сообщение сразу, со ссылкой
// (ссылка заработает после публикации). Уже опубликованные машины не шлёт.
// Машину в нужной цене со статусом из SKIP_STATUSES смотрим каждые 10 сек
// (а не по общему расписанию 30 сек … 3 мин) — вдруг статус сменится. Таких единицы.
const WATCH_INTERVAL_MS = 10_000;
const WATCH_MAX_MS = 60 * 60_000;
const WATCH_MAX_ITEMS = 20;
const GAP_QUICK_RETRY_MS = 15_000;
// Ответ старше 20 сек про номер, который остался позади фронта, ничего не значит: бот мог
// проверить его, когда номера ещё не существовало (смотрел далеко вперёд).
const GAP_STALE_MS = 20_000;
// Общий список OLX раз в минуту — замечает, если перебор застрял (OLX перескочил номера).
const GENERAL_LIST_INTERVAL_MS = 60_000;
const OLX_BROWSER_RESTART_MS = 6 * 60 * 60_000;
const OLX_FETCH_TIMEOUT_MS = 15_000;
const REPORT_MS = 5 * 60_000;
const HANDLED_KEEP = 5_000;

// ============================================================================
// Мелочи
// ============================================================================

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function loadJson(file, fallback) {
  try {
    return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : fallback;
  } catch {
    return fallback;
  }
}

function saveJson(file, value) {
  try {
    fs.writeFileSync(`${file}.tmp`, JSON.stringify(value), 'utf8');
    fs.renameSync(`${file}.tmp`, file);
  } catch (error) {
    console.error(`[Файл] ${path.basename(file)}: ${error.message}`);
  }
}

function oneLine(text) {
  return String(text || '').replace(/\s+/g, ' ').trim();
}

function truncate(text, max) {
  const value = String(text ?? '');
  return value.length > max ? `${value.slice(0, Math.max(0, max - 1)).trimEnd()}…` : value;
}

function esc(value) {
  return String(value ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function money(value) {
  return Math.round(Number(value) || 0).toLocaleString('ru-RU');
}

function formatAge(ms) {
  const seconds = Math.max(0, Math.round(ms / 1000));
  if (seconds < 90) return `${seconds} сек`;
  const minutes = Math.round(seconds / 60);
  return minutes < 120 ? `${minutes} мин` : `${Math.round(minutes / 60)} ч`;
}

function cleanUrl(href) {
  try {
    const url = new URL(href, 'https://www.olx.uz');
    url.search = '';
    url.hash = '';
    return url.href;
  } catch {
    return null;
  }
}

function withTimeout(promise, ms, fallback) {
  let timer;
  return Promise.race([promise, new Promise((resolve) => { timer = setTimeout(() => resolve(fallback), ms); })])
    .finally(() => clearTimeout(timer));
}

// ============================================================================
// Диагностика: все гипотезы, почему машина может прийти поздно или не прийти.
// Копится с запуска, показывается по команде /diag.
// ============================================================================

const diag = {
  startedAt: Date.now(),
  selfChecks: 0, selfCheckFails: 0, blocks: 0, notJson: 0, netFails: 0,
  ticks: 0, behindTicks: 0, lagReports: 0, reports: 0, jumps: 0,
  reopened: 0, reopenedCars: 0, reopenedWaitSum: 0, reopenedWaitMax: 0,
  unknownCars: 0, unknownSamples: [], ageCut: 0, ageSamples: [], noPrice: 0, missed: 0,
  sent: 0, foundAgeSum: 0, foundAgeMax: 0, deliverSum: 0, deliverMax: 0, photoFallbacks: 0, timeouts: 0,
  sleeps: 0, sleepMax: 0, clockSkew: null, bigJumps: 0
};

function sample(list, text) {
  list.push(text);
  if (list.length > 3) list.shift();
}

// Если Mac уснул или программа зависла, таймер «пропускает» время — это и ловим.
{
  let lastBeat = Date.now();
  const timer = setInterval(() => {
    const gap = Date.now() - lastBeat - 5_000;
    lastBeat = Date.now();
    if (gap > 20_000) {
      diag.sleeps += 1;
      diag.sleepMax = Math.max(diag.sleepMax, gap);
      console.warn(`💤 Бот стоял ${formatAge(gap)} (Mac спал, крышка закрыта или завис) — в это время машины не ловились.`);
    }
  }, 5_000);
  timer.unref?.();
}

// ============================================================================
// Telegram
// ============================================================================

async function tg(method, payload, timeoutMs = 20_000) {
  for (let attempt = 1; ; attempt += 1) {
    const response = await fetch(`https://api.telegram.org/bot${TOKEN}/${method}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(timeoutMs)
    });
    const body = await response.json().catch(() => ({}));
    if (body.ok) return body.result;
    // 429 = Telegram просит подождать; сообщение при этом НЕ ушло, повтор безопасен.
    if (response.status === 429 && attempt < 3) {
      await sleep(((body.parameters?.retry_after || 1) + 0.5) * 1000);
      continue;
    }
    throw new Error(body.description || `HTTP ${response.status}`);
  }
}

// Подписчики: chatId -> { name, since }.
const subscribers = new Map(Object.entries(loadJson(SUBSCRIBERS_FILE, {})));

function saveSubscribers() {
  saveJson(SUBSCRIBERS_FILE, Object.fromEntries(subscribers));
}

function recipients() {
  return [...new Set([...CHAT_IDS, ...subscribers.keys()])];
}

// Человек заблокировал бота / бота убрали из канала — больше не шлём.
const CHAT_GONE = /blocked by the user|user is deactivated|chat not found|bot was kicked|not a member|CHAT_WRITE_FORBIDDEN|have no rights|need administrator rights|not enough rights/i;

function dropChat(chatId, reason) {
  if (!subscribers.delete(String(chatId))) return;
  saveSubscribers();
  console.log(`👋 ${chatId} отключён (${reason}). Подписчиков: ${subscribers.size}`);
}

// Telegram разрешает боту ~30 сообщений в секунду на всех. Держим 25.
const sendTimes = [];
async function sendSlot() {
  while (true) {
    const now = Date.now();
    while (sendTimes.length && now - sendTimes[0] >= 1_000) sendTimes.shift();
    if (sendTimes.length < 25) {
      sendTimes.push(now);
      return;
    }
    await sleep(1_000 - (now - sendTimes[0]) + 5);
  }
}

// Telegram иногда не может сам скачать фото с OLX — тогда качаем и заливаем файлом.
async function uploadPhoto(chatId, msg, photoUrl) {
  const image = await fetch(photoUrl, {
    headers: { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36', Referer: 'https://www.olx.uz/' },
    signal: AbortSignal.timeout(15_000)
  });
  if (!image.ok) return null;
  await sendSlot();
  const form = new FormData();
  form.append('chat_id', String(chatId));
  form.append('caption', msg.text);
  form.append('parse_mode', 'HTML');
  form.append('reply_markup', JSON.stringify(msg.keyboard));
  form.append('photo', new Blob([Buffer.from(await image.arrayBuffer())]), 'car.jpg');
  const response = await fetch(`https://api.telegram.org/bot${TOKEN}/sendPhoto`, { method: 'POST', body: form, signal: AbortSignal.timeout(60_000) });
  const body = await response.json().catch(() => ({}));
  return body.ok ? (body.result.photo?.at(-1)?.file_id || true) : null;
}

async function sendCar(chatId, msg, photo) {
  const base = { chat_id: chatId, parse_mode: 'HTML', reply_markup: msg.keyboard };
  if (photo) {
    try {
      await sendSlot();
      const sent = await tg('sendPhoto', { ...base, photo, caption: msg.text }, 30_000);
      return { ok: true, fileId: sent.photo?.at(-1)?.file_id || null };
    } catch (error) {
      if (CHAT_GONE.test(error.message)) {
        dropChat(chatId, error.message);
        return { ok: false, fileId: null };
      }
      // Время вышло — Telegram мог всё-таки отправить фото. Не дублируем текстом.
      if (/abort|timeout/i.test(`${error.name} ${error.message}`)) {
        diag.timeouts += 1;
        console.warn(`[Telegram] Фото в ${chatId} отправлялось дольше 30 сек — не дублирую текстом.`);
        return { ok: true, fileId: null };
      }
      diag.photoFallbacks += 1;
      if (/^https?:/.test(photo) && /HTTP URL|WEBPAGE_MEDIA_EMPTY|wrong type|wrong file identifier/i.test(error.message)) {
        const uploaded = await uploadPhoto(chatId, msg, photo).catch(() => null);
        if (uploaded) return { ok: true, fileId: typeof uploaded === 'string' ? uploaded : null };
      }
      console.warn(`[Telegram] Фото не ушло в ${chatId}: ${error.message} — отправляю текстом`);
    }
  }
  try {
    await sendSlot();
    await tg('sendMessage', { ...base, text: msg.text, link_preview_options: { is_disabled: true } });
    return { ok: true, fileId: null };
  } catch (error) {
    if (CHAT_GONE.test(error.message)) dropChat(chatId, error.message);
    else console.error(`[Telegram] Не удалось отправить в ${chatId}: ${error.message}`);
    return { ok: false, fileId: null };
  }
}

// /start — подписаться, /stop — отписаться. Работает и в каналах (бот должен быть админом).
async function pollUpdates() {
  let offset = 0;
  while (true) {
    try {
      const updates = await tg('getUpdates', { offset, timeout: 25, allowed_updates: ['message', 'channel_post'] }, 35_000);
      for (const update of updates) {
        offset = update.update_id + 1;
        const message = update.message || update.channel_post;
        const command = String(message?.text || '').match(/^\/(start|stop|why|diag)\b/)?.[1];
        if (!message?.chat || !command) continue;
        const chatId = String(message.chat.id);
        if (command === 'diag') {
          await tg('sendMessage', { chat_id: chatId, text: diagReport(), parse_mode: 'HTML' }).catch((error) => console.error(`[/diag] ${error.message}`));
          continue;
        }
        if (command === 'why') {
          const id = Number(String(message.text).match(/\d{6,}/)?.[0]);
          const answer = id ? await explainNumber(id) : 'Напишите так: /why 66509980\nНомер объявления (ID) есть внизу страницы объявления на OLX.';
          await tg('sendMessage', { chat_id: chatId, text: answer, parse_mode: 'HTML', link_preview_options: { is_disabled: true } }).catch(() => {});
          continue;
        }
        const name = oneLine(message.chat.title || [message.from?.first_name, message.from?.last_name].filter(Boolean).join(' ') || message.chat.username || chatId);
        let text;
        if (command === 'start') {
          if (!subscribers.has(chatId)) {
            subscribers.set(chatId, { name, since: new Date().toISOString() });
            saveSubscribers();
            console.log(`➕ Новый подписчик: ${name} (${chatId}). Всего: ${subscribers.size}`);
          }
          text = `✅ Готово! Буду присылать новые машины с OLX ${PRICE_FILTER ? `за ${priceRangeText()}` : 'любой цены'}${MODEL_NAMES.length ? ` (модели: ${modelsText()})` : ''}, пока они ещё на проверке у OLX (до публикации).\n\nОтключить — /stop`;
        } else {
          if (subscribers.delete(chatId)) {
            saveSubscribers();
            console.log(`➖ Отписался: ${name} (${chatId}). Всего: ${subscribers.size}`);
          }
          text = CHAT_IDS.includes(chatId) ? 'Этот чат указан в настройках бота (CHAT_IDS) — он получает машины всегда.' : '🔕 Отключено. Включить снова — /start';
        }
        await tg('sendMessage', { chat_id: chatId, text }).catch(() => {});
      }
    } catch (error) {
      if (/Conflict/i.test(error.message)) {
        console.warn('⚠️ Этот TELEGRAM_TOKEN уже работает в другой программе (например, в боте квартир) — /start и /stop не работают, новые люди не смогут подписаться. Создайте отдельного бота в @BotFather.');
        return;
      }
      console.error(`[Telegram] getUpdates: ${error.message}`);
      await sleep(10_000);
    }
  }
}

// ============================================================================
// OLX: браузер и API (как в боте квартир)
// ============================================================================

// Идёт остановка (Ctrl+C): новые запросы не начинаем, ошибки оборванных запросов не печатаем.
let shuttingDown = false;
const firstLine = (error) => String(error?.message || error).split('\n')[0].slice(0, 200);

// Каждый IP — своя «линия»: свой браузер, свои куки, своя пауза при блоке.
// Главная линия (olx) — домашний интернет; через неё же идут списки, /why и обход марок.
// Остальные — прокси из .env (PROXIES), они параллельно ищут и перепроверяют номера.
function parseProxy(text) {
  const value = String(text || '').trim();
  if (!value) return null;
  // Форматы: http://логин:пароль@ip:порт  или  ip:порт:логин:пароль (как выдаёт Proxy-Seller)
  if (/^[a-z0-9]+:\/\//i.test(value)) {
    const url = new URL(value);
    return { server: `${url.protocol}//${url.hostname}:${url.port}`, username: decodeURIComponent(url.username) || undefined, password: decodeURIComponent(url.password) || undefined, label: url.hostname };
  }
  const [host, port, username, password] = value.split(':');
  if (!host || !port) return null;
  return { server: `http://${host}:${port}`, username, password, label: host };
}

function makeLane(name, proxy, shared = null) {
  return { name, proxy, shared, ip: proxy ? proxy.server : 'home', runtime: null, opening: null, openedAt: 0, blockedUntil: 0, transport: null, pace: 1, blockStreak: 0, lastBlockAt: 0, lastEaseAt: 0, requests: 0 };
}

const PROXY_LIST = String(process.env.PROXIES || '').split(/[\s,;]+/).map(parseProxy).filter(Boolean);
const USE_HOME_IP = !['0', 'false', 'no'].includes(String(process.env.USE_HOME_IP || '').trim().toLowerCase());
const olx = USE_HOME_IP || !PROXY_LIST.length ? makeLane('домашний IP', null) : makeLane(`прокси ${PROXY_LIST[0].label}`, PROXY_LIST[0]);
// HOME_LANES — сколько параллельных потоков на главном IP (одна вкладка браузера на всех).
// По умолчанию 1. Каждый поток — +60-75 запросов в минуту с того же IP.
const HOME_LANES = Math.max(1, Math.min(5, Number(process.env.HOME_LANES) || 1));
const lanes = [
  olx,
  ...Array.from({ length: HOME_LANES - 1 }, (_, index) => makeLane(`${olx.name} #${index + 2}`, olx.proxy, olx)),
  ...(USE_HOME_IP ? PROXY_LIST : PROXY_LIST.slice(1)).map((proxy) => makeLane(`прокси ${proxy.label}`, proxy))
];

async function createBrowser(lane = olx) {
  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-blink-features=AutomationControlled'],
    ...(lane.proxy ? { proxy: { server: lane.proxy.server, username: lane.proxy.username, password: lane.proxy.password } } : {})
  });
  const context = await browser.newContext({
    userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    locale: 'ru-RU',
    timezoneId: 'Asia/Tashkent',
    viewport: { width: 1366, height: 768 }
  });
  return { browser, context, listPage: await context.newPage() };
}

async function closeOlxSession(lane = olx) {
  const current = lane.runtime;
  lane.runtime = null;
  if (current) await current.browser.close().catch(() => {});
}

function openOlxSession(lane = olx) {
  if (shuttingDown) return Promise.reject(new Error('остановка'));
  if (lane.opening) return lane.opening;
  lane.opening = (async () => {
    await closeOlxSession(lane);
    if (!chromium) throw new Error('playwright не установлен');
    const runtime = await createBrowser(lane);
    try {
      // Главная линия — сразу на страницу легковых (с неё бот узнаёт разделы).
      // Прокси — на лёгкую страницу: нужны только куки сайта.
      await runtime.listPage.goto(lane === olx ? CARS_PAGE : 'https://www.olx.uz/', { waitUntil: 'domcontentloaded', timeout: 60_000 });
    } catch (error) {
      await runtime.browser.close().catch(() => {});
      throw new Error(`${lane.name}: ${error.message}`);
    }
    lane.runtime = runtime;
    lane.openedAt = Date.now();
    console.log(`[OLX] Вкладка открыта (${lane.name}).`);
    return runtime;
  })().finally(() => {
    lane.opening = null;
  });
  return lane.opening;
}

async function ensureOlxSession(lane = olx) {
  const current = lane.runtime;
  if (current && current.browser.isConnected() && !current.listPage.isClosed()) return current;
  return openOlxSession(lane);
}

async function browserTransport(url, lane = olx) {
  lane = lane.shared || lane; // потоки одного IP делят одну вкладку
  const runtime = await ensureOlxSession(lane);
  const request = runtime.listPage.evaluate(async ({ target, timeoutMs }) => {
    try {
      const response = await fetch(target, { headers: { Accept: 'application/json' }, cache: 'no-store', credentials: 'include', signal: AbortSignal.timeout(timeoutMs) });
      return { status: response.status, text: await response.text(), date: response.headers.get('date') };
    } catch (error) {
      return { status: 0, text: String(error) };
    }
  }, { target: url, timeoutMs: OLX_FETCH_TIMEOUT_MS });
  const result = await withTimeout(request.catch((error) => ({ failed: error })), OLX_FETCH_TIMEOUT_MS + 5_000, { failed: new Error(`вкладка OLX не отвечает (${lane.name})`) });
  if (result.failed) {
    if (lane.runtime === runtime) await closeOlxSession(lane);
    throw result.failed;
  }
  return result;
}

// Что отвечал OLX за 5 минут — по этим цифрам видно, не принял ли он бота за робота.
const answers = { ok: 0, notFound: 0, hidden: 0, blocked: 0, notJson: 0, failed: 0 };

async function olxApi(pathAndQuery, lane = olx) {
  lane.requests += 1;
  const { status, text, date } = await (lane.transport ? lane.transport(`${OLX_API}${pathAndQuery}`) : browserTransport(`${OLX_API}${pathAndQuery}`, lane));
  // Часы Mac против часов OLX (среднее; точность ~1 сек).
  const serverTime = Date.parse(date || '');
  if (Number.isFinite(serverTime)) {
    const skew = serverTime - Date.now();
    diag.clockSkew = diag.clockSkew === null ? skew : diag.clockSkew * 0.95 + skew * 0.05;
  }
  if (status === 404) answers.notFound += 1;
  else if (status === 410) answers.hidden += 1;
  else if (status === 0 || status >= 500) {
    answers.failed += 1;
    diag.netFails += 1;
  }
  if (status === 403 || status === 429) {
    answers.blocked += 1;
    diag.blocks += 1;
    const now = Date.now();
    lane.blockStreak = now - lane.lastBlockAt < 30 * 60_000 ? lane.blockStreak + 1 : 1;
    lane.blocks = (lane.blocks || 0) + 1;
    const pace = Math.min(3, lane.pace * 1.3);
    const until = now + OLX_BLOCK_PAUSES_MS[Math.min(OLX_BLOCK_PAUSES_MS.length - 1, lane.blockStreak - 1)];
    // Блок — на IP, а не на поток: на паузу встают все потоки этого IP.
    for (const other of lanes) {
      if (other.ip !== lane.ip) continue;
      other.lastBlockAt = now;
      other.pace = Math.max(other.pace, pace);
      other.blockedUntil = Math.max(other.blockedUntil, until);
      other.blockStreak = Math.max(other.blockStreak, lane.blockStreak);
    }
    if (status === 403 && !lane.transport) await closeOlxSession(lane.shared || lane);
    throw new Error(`OLX_BLOCKED ${status} ${lane.name}`);
  }
  if (status !== 200) return { status, data: null };
  try {
    const data = JSON.parse(text)?.data ?? null;
    answers.ok += 1;
    return { status, data };
  } catch {
    // Вместо данных пришла страница (капча / проверка «вы не робот?»).
    answers.notJson += 1;
    diag.notJson += 1;
    return { status: 0, data: null };
  }
}

// ============================================================================
// Какой раздел OLX — «Легковые автомобили»
// ============================================================================
// На olx.uz у легковых есть подразделы по маркам (…/legkovye-avtomobili/chevrolet/),
// и у объявления стоит номер подраздела. Поэтому бот помнит НАБОР номеров:
// родительский раздел (по нему читается список) и все подразделы-марки, которые
// встречались в этом списке. Набор хранится в car_categories.json и пополняется сам.

const cars = {
  parents: new Set(ENV_CATEGORY_IDS),
  ids: new Set(ENV_CATEGORY_IDS)
};
{
  const saved = loadJson(CATEGORIES_FILE, {});
  if (!ENV_CATEGORY_IDS.length) for (const id of saved.parents || []) cars.parents.add(Number(id));
  for (const id of saved.ids || []) cars.ids.add(Number(id));
}

function saveCategories() {
  const saved = loadJson(CATEGORIES_FILE, {});
  saveJson(CATEGORIES_FILE, { parents: [...cars.parents], ids: [...cars.ids], harvestedAt: saved.harvestedAt || 0, visited: saved.visited || [] });
}

function learnCategory(raw) {
  const id = Number(raw?.category?.id);
  if (!id || cars.ids.has(id) || (raw.category.type && raw.category.type !== 'automotive')) return;
  cars.ids.add(id);
  saveCategories();
  console.log(`🔎 Новый подраздел легковых: № ${id} (${truncate(oneLine(raw.title), 40)})`);
}

const DEBUG_FILE = path.join(__dirname, 'car_debug.json');
const HARVEST_EVERY_MS = 7 * 24 * 60 * 60_000; // марки перепроверяются раз в неделю
// Если на странице не найдутся ссылки на марки — обходим эти (лишние просто пропустятся).
const FALLBACK_BRAND_SLUGS = ['chevrolet', 'daewoo', 'ravon', 'kia', 'hyundai', 'toyota', 'byd', 'chery', 'vaz', 'lada',
  'mercedes-benz', 'bmw', 'nissan', 'honda', 'volkswagen', 'lexus', 'mitsubishi', 'ford', 'audi', 'mazda', 'opel',
  'geely', 'haval', 'changan', 'jac', 'gaz', 'uaz', 'zaz', 'renault', 'peugeot', 'skoda', 'subaru', 'suzuki',
  'land-rover', 'porsche', 'tesla', 'infiniti', 'li-auto', 'zeekr', 'jetour', 'exeed', 'hongqi', 'ssangyong',
  'citroen', 'volvo', 'jeep', 'cadillac', 'moskvich', 'faw', 'dongfeng', 'gac', 'tank', 'leapmotor', 'voyah', 'drugie'];

const debugInfo = {};
function saveDebug(part) {
  Object.assign(debugInfo, part, { at: new Date().toISOString() });
  saveJson(DEBUG_FILE, debugInfo);
}

const isAutomotive = (raw) => !raw?.category?.type || raw.category.type === 'automotive';

async function cardAdIds(page) {
  const ids = await page.$$eval('[data-cy="l-card"], [data-testid="l-card"]', (cards) => cards.map((card) => card.id)).catch(() => []);
  return [...new Set(ids.filter((id) => /^\d+$/.test(id)))];
}

// Разделы объявлений с карточек страницы (через API) — все они разделы легковых.
async function categoriesFromCards(page, limit, pauseMs) {
  const found = new Set();
  for (const adId of (await cardAdIds(page)).slice(0, limit)) {
    const { data } = await olxApi(`${adId}/`);
    if (data?.category?.id && isAutomotive(data)) found.add(Number(data.category.id));
    await sleep(pauseMs);
  }
  return found;
}

// Ищем в данных страницы сам раздел «legkovye-avtomobili» (его id) и его подразделы.
async function readPageState(page) {
  return page.evaluate(() => {
    const parents = [];
    const pairs = [];
    const seen = new Set();
    const walk = (node, depth) => {
      if (node === null || node === undefined || depth > 14) return;
      if (typeof node === 'string') {
        const text = node.trim();
        if (text.length > 100 && (text[0] === '{' || text[0] === '[')) {
          try { walk(JSON.parse(text), depth + 1); } catch {}
        }
        return;
      }
      if (typeof node !== 'object' || seen.has(node)) return;
      seen.add(node);
      const id = Number(node.id);
      if (Number.isInteger(id) && id > 0) {
        const values = Object.values(node);
        if (values.some((value) => typeof value === 'string' && (value === 'legkovye-avtomobili' || /\/legkovye-avtomobili\/?(\?.*)?$/.test(value)))) parents.push(id);
        const parent = Number(node.parentId ?? node.parent_id ?? (typeof node.parent === 'object' ? node.parent?.id : node.parent));
        if (Number.isInteger(parent) && parent > 0) pairs.push([id, parent]);
      }
      for (const value of Object.values(node)) walk(value, depth + 1);
    };
    for (const key of Object.keys(window)) {
      if (/^__[A-Z0-9_]+__$/.test(key)) {
        try { walk(window[key], 0); } catch {}
      }
    }
    return { parents: [...new Set(parents)], pairs };
  }).catch(() => ({ parents: [], pairs: [] }));
}

// Подходит ли раздел как «все легковые»: в его списке машины разных марок и почти нет
// дешёвых объявлений (у «Транспорта» целиком их много — запчасти, шины).
async function checkParent(candidate, known) {
  const { data } = await olxApi(`?offset=0&limit=${LIST_LIMIT}&category_id=${candidate}&sort_by=created_at:desc`).catch(() => ({ data: null }));
  const ads = Array.isArray(data) ? data : [];
  const ids = new Set(ads.map((ad) => Number(ad.category?.id)).filter(Boolean));
  const cheap = ads.filter((ad) => (priceUsd(ad) ?? 0) < 1_000).length;
  const result = { candidate, ads: ads.length, categories: ids.size, cheap, overlap: [...known].filter((id) => ids.has(id)).length };
  result.ok = ads.length >= 10 && ads.every(isAutomotive) && cheap / ads.length < 0.2 && (!known.size || result.overlap > 0 || known.has(candidate));
  return { result, ids };
}

async function detectCarCategories() {
  if (cars.parents.size) return;
  const runtime = await ensureOlxSession();
  const page = runtime.listPage;
  const candidates = new Map();
  let cardCategories = new Set();
  let state = { parents: [], pairs: [] };
  let slugs = [];
  try {
    if (!page.url().includes('legkovye-avtomobili')) await page.goto(CARS_PAGE, { waitUntil: 'domcontentloaded', timeout: 60_000 });
    cardCategories = await categoriesFromCards(page, 20, 250);
    for (const id of cardCategories) cars.ids.add(id);
    state = await readPageState(page);
    for (const id of state.parents) candidates.set(id, (candidates.get(id) || 0) + 100);
    const html = await page.content();
    const patterns = [/category_?[iI]d(?:\\?"\s*:\s*\\?"?|=)(\d+)/g, /\\?"category\\?"\s*:\s*\{\s*\\?"id\\?"\s*:\s*(\d+)/g];
    for (const pattern of patterns) {
      for (const match of html.matchAll(pattern)) candidates.set(Number(match[1]), (candidates.get(Number(match[1])) || 0) + 1);
    }
    // Ссылки на подразделы: /transport/legkovye-avtomobili/<марка>/
    const hrefs = await page.$$eval('a[href*="/legkovye-avtomobili/"]', (links) => links.map((link) => link.getAttribute('href'))).catch(() => []);
    slugs = [...new Set(hrefs.map((href) => String(href).split('?')[0].match(/\/legkovye-avtomobili\/([a-z0-9-]+)\/?$/)?.[1]).filter(Boolean))];
  } catch (error) {
    console.warn(`[OLX] Не смог прочитать страницу легковых: ${error.message}`);
  }

  const checks = [];
  for (const [candidate] of [...candidates].sort((a, b) => b[1] - a[1]).slice(0, 6)) {
    if (cardCategories.has(candidate) && !state.parents.includes(candidate)) continue; // это марка, а не «все легковые»
    const { result, ids } = await checkParent(candidate, cardCategories);
    checks.push(result);
    if (!result.ok) continue;
    cars.parents.add(candidate);
    cars.ids.add(candidate);
    for (const id of ids) cars.ids.add(id);
    for (const [child, parent] of state.pairs) if (parent === candidate) cars.ids.add(child);
    break;
  }
  saveCategories();
  saveDebug({ cardCategories: [...cardCategories], stateParents: state.parents, statePairs: state.pairs.length, candidates: [...candidates].sort((a, b) => b[1] - a[1]).slice(0, 15), checks, brandLinks: slugs.length });

  if (cars.parents.size) {
    console.log(`🔎 Раздел «Легковые автомобили» на OLX: № ${[...cars.parents].join(', ')}; подразделов известно: ${cars.ids.size}. Можно вписать CAR_CATEGORY_IDS=${[...cars.parents].join(',')} в .env.`);
    return;
  }
  // Родителя нет — соберём подразделы сами, обходя страницы марок (в фоне, перебор не ждёт).
  const saved = loadJson(CATEGORIES_FILE, {});
  if (Date.now() - Number(saved.harvestedAt || 0) < HARVEST_EVERY_MS) {
    console.log(`🔎 Подразделов легковых известно: ${cars.ids.size} (марки обходил ${formatAge(Date.now() - Number(saved.harvestedAt))} назад).`);
    return;
  }
  const list = [...new Set([...slugs, ...FALLBACK_BRAND_SLUGS])];
  console.log(`🔎 Обхожу страницы марок (${list.length}) в фоне, чтобы узнать все подразделы. Займёт ~${Math.ceil(list.length * 5 / 60)} мин, поиск машин уже работает.`);
  harvestBrandPages(list).catch((error) => { if (!shuttingDown) console.warn(`[Марки] ${firstLine(error)}`); });
}

async function harvestBrandPages(allSlugs) {
  // Прогресс обхода хранится в файле: если бота перезапустили раньше, чем обход закончился,
  // он продолжит с того места, где остановился, а не начнёт с нуля.
  const visited = new Set(loadJson(CATEGORIES_FILE, {}).visited || []);
  const slugs = allSlugs.filter((slug) => !visited.has(slug));
  if (visited.size && slugs.length) console.log(`🔎 Продолжаю обход марок: уже сделано ${visited.size}, осталось ${slugs.length}.`);
  if (!slugs.length) {
    saveJson(CATEGORIES_FILE, { parents: [...cars.parents], ids: [...cars.ids], harvestedAt: Date.now(), visited: [] });
    return;
  }
  const runtime = await ensureOlxSession();
  const tab = await runtime.context.newPage();
  // Картинки, шрифты и стили не грузим — так быстрее и меньше нагрузка на OLX.
  await tab.route('**/*', (route) => (['image', 'media', 'font', 'stylesheet'].includes(route.request().resourceType()) ? route.abort() : route.continue())).catch(() => {});
  const before = cars.ids.size;
  const perBrand = {};
  let failed = 0;
  let sinceSave = 0;
  const saveProgress = (harvestedAt) => saveJson(CATEGORIES_FILE, { parents: [...cars.parents], ids: [...cars.ids], harvestedAt, visited: [...visited] });
  try {
    for (const slug of slugs) {
      if (tab.isClosed()) {
        failed = slugs.length; // браузер перезапустился — доделаем при следующем запуске
        break;
      }
      if (Date.now() < olx.blockedUntil) await sleep(olx.blockedUntil - Date.now());
      try {
        await tab.goto(`${CARS_PAGE}${slug}/`, { waitUntil: 'domcontentloaded', timeout: 45_000 });
        if (tab.url().includes('/legkovye-avtomobili/')) {
          const found = await categoriesFromCards(tab, 3, 900);
          perBrand[slug] = [...found];
          for (const id of found) cars.ids.add(id);
        }
        visited.add(slug); // страница обработана (или у OLX такой марки нет) — повторно не ходим
      } catch (error) {
        if (!/OLX_BLOCKED/.test(error.message)) perBrand[slug] = `ошибка: ${error.message.slice(0, 80)}`;
        failed += 1;
      }
      sinceSave += 1;
      if (sinceSave >= 5) {
        sinceSave = 0;
        saveProgress(0);
      }
      await sleep(1_500);
    }
  } finally {
    await tab.close().catch(() => {});
  }
  // Остановили бота посреди обхода — прогресс уже сохранён, продолжим при следующем запуске.
  if (shuttingDown) {
    saveJson(CATEGORIES_FILE, { parents: [...cars.parents], ids: [...cars.ids], harvestedAt: 0, visited: [...visited] });
    return;
  }
  // Если много страниц не открылось — не считаем обход сделанным, продолжим при следующем запуске.
  const complete = failed <= slugs.length / 3;
  saveJson(CATEGORIES_FILE, { parents: [...cars.parents], ids: [...cars.ids], harvestedAt: complete ? Date.now() : 0, visited: complete ? [] : [...visited] });
  saveDebug({ perBrand });
  const multi = Object.values(perBrand).filter((ids) => Array.isArray(ids) && ids.length > 1).length;
  console.log(`🔎 Марки обойдены: подразделов легковых теперь ${cars.ids.size} (+${cars.ids.size - before}).`
    + (multi > 3 ? ' ⚠️ Внутри марок тоже разные подразделы (похоже, по моделям) — пришлите файл car_debug.json.' : ''));
}

// ============================================================================
// Фильтр: машина, цена, город
// ============================================================================

function apiParam(raw, key) {
  return (raw.params || []).find((param) => param.key === key)?.value;
}

// Сколько сумов в 1 у.е. Уточняется по объявлениям, где OLX даёт обе цены.
let usdRate = 12_000;

function priceUsd(raw) {
  const price = apiParam(raw, 'price');
  if (!price) return null;
  const value = Number(price.value) || 0;
  const converted = Number(price.converted_value) || 0;
  const currency = String(price.currency || '').toUpperCase();
  const convertedCurrency = String(price.converted_currency || '').toUpperCase();
  if (currency === 'UYE' || currency === 'USD') {
    if (value && converted && (!convertedCurrency || convertedCurrency === 'UZS')) {
      const rate = converted / value;
      if (rate > 5_000 && rate < 30_000) usdRate = rate;
    }
    return value || null;
  }
  if (currency === 'UZS') {
    if (converted && (convertedCurrency === 'UYE' || convertedCurrency === 'USD')) return converted;
    return value ? value / usdRate : null;
  }
  return null;
}

// Раздел легковых может быть ещё неизвестен: обход марок идёт ~10 мин, а OLX заводит
// новые модели. Тогда машину узнаём по подписям параметров (как в карточке OLX):
// «Тип кузова», «Коробка передач», «Вид топлива», «Объем двигателя», «Пробег», «Год выпуска».
// Нужно 3 из 6. Побочный эффект: иногда так пройдёт микроавтобус или мотоцикл.
// Выключить: STRICT_SECTIONS=1 в .env (тогда только известные разделы).
const STRICT_SECTIONS = ['1', 'true', 'yes'].includes(String(process.env.STRICT_SECTIONS || '').trim().toLowerCase());
const CAR_LABELS = ['тип кузова', 'коробка передач', 'вид топлива', 'объем двигателя', 'объём двигателя', 'пробег', 'год выпуска'];
const unknownSectionsSeen = new Set();

function hasCarLabels(raw) {
  const labels = (raw?.params || []).map((param) => String(param?.name || '').toLowerCase());
  const hits = new Set();
  for (const label of CAR_LABELS) {
    if (labels.some((name) => name.includes(label))) hits.add(label.replace('объём', 'объем'));
  }
  return hits.size >= 3;
}

function isCar(raw) {
  if (!cars.ids.size) return raw?.category?.type === 'automotive';
  const id = Number(raw?.category?.id);
  if (cars.ids.has(id)) return true;
  if (!STRICT_SECTIONS && raw?.category?.type === 'automotive' && hasCarLabels(raw)) {
    if (id && !unknownSectionsSeen.has(id)) {
      unknownSectionsSeen.add(id);
      console.log(`🔎 Раздел № ${id} бот ещё не знал — принимаю машины из него по параметрам (${truncate(oneLine(raw.title), 40)}).`);
    }
    return true;
  }
  return false;
}

// Модель из параметров объявления («Модель»), если OLX её дал.
function carModel(raw) {
  const param = (raw?.params || []).find((item) => /model/i.test(String(item?.key || '')) || /модел/i.test(String(item?.name || '')));
  return oneLine(param?.value?.label);
}

// Подходит ли модель (без MODELS подходит любая).
function modelOk(raw) {
  if (!MODELS.length) return true;
  const text = ` ${normalizeModel(`${carModel(raw)} ${raw?.title || ''}`)} `;
  return MODELS.some((model) => text.includes(` ${model} `));
}

// Могло бы это объявление уйти клиенту (раздел, город, цена, модель)? Статус и возраст не смотрим.
function looksLikeOurCar(raw) {
  if (!raw?.id || !isCar(raw)) return false;
  if (CITY_ID && raw.location?.city?.id !== CITY_ID) return false;
  if (ONLY_PRIVATE && raw.business) return false;
  if (!modelOk(raw)) return false;
  return priceOk(priceUsd(raw));
}

const isActive = (raw) => !raw.status || raw.status === 'active';

// last_refresh_time — когда объявление реально появилось на OLX после проверки.
function publishedAt(raw) {
  const createdAt = Date.parse(raw.created_time);
  const refreshedAt = Date.parse(raw.last_refresh_time);
  return Number.isFinite(refreshedAt) && refreshedAt >= createdAt ? refreshedAt : createdAt;
}

function isNewAd(raw) {
  const ageMinutes = (Date.now() - Date.parse(raw.created_time)) / 60_000;
  return ageMinutes >= -5 && ageMinutes <= API_MAX_AGE_MINUTES;
}

function isFresh(raw, source) {
  const limit = source === 'list' ? LIST_PUBLISHED_MAX_AGE_MINUTES : PUBLISHED_MAX_AGE_MINUTES;
  return (Date.now() - publishedAt(raw)) / 60_000 <= limit;
}

// ============================================================================
// Сообщение и отправка
// ============================================================================

function photoUrl(raw) {
  const photo = (raw.photos || [])[0];
  if (!photo?.link) return null;
  const width = Number(photo.width) || 1280;
  const height = Number(photo.height) || 960;
  const scale = Math.min(1, 1280 / Math.max(width, height));
  const url = String(photo.link).replace('{width}', Math.round(width * scale)).replace('{height}', Math.round(height * scale)).replace(':443/', '/');
  return /^https?:\/\//.test(url) ? url : null;
}

function buildMessage(raw, { pending = false } = {}) {
  const price = apiParam(raw, 'price') || {};
  const usd = priceUsd(raw);
  const url = cleanUrl(raw.url) || raw.url;
  const inSum = String(price.currency || '').toUpperCase() === 'UZS';
  const priceLabel = oneLine(price.label) || `${money(usd)} у.е.`;
  const location = [oneLine(raw.location?.city?.name), oneLine(raw.location?.district?.name)].filter(Boolean).join(', ');
  const params = (raw.params || [])
    .filter((param) => param.key !== 'price' && param.name && oneLine(param.value?.label) && oneLine(param.value?.label).length <= 40)
    .slice(0, 8)
    .map((param) => `▫️ ${esc(oneLine(param.name))}: ${esc(oneLine(param.value.label))}`);
  const head = [
    `${pending ? '🕓' : '🚗'} <b>${esc(truncate(oneLine(raw.title), 120))}</b>`,
    `💰 <b>${esc(priceLabel)}</b>${inSum ? ` (≈ ${money(usd)} $)` : ''}${price.negotiable ? ' · торг' : ''}`,
    ...(location ? [`📍 ${esc(location)}`] : []),
    raw.business ? '🏢 Компания / автосалон' : '👤 Частное лицо',
    ...params
  ];
  const tail = pending
    ? [`🕓 <b>На проверке у OLX</b> — ссылка заработает после публикации:`, `<a href="${esc(url)}">${esc(url)}</a>`]
    : [`⚡ ${formatAge(Date.now() - publishedAt(raw))} после публикации · <a href="${esc(url)}">OLX</a>`];
  let text = [...head, '', ...tail].join('\n');
  // Описание — сколько влезет в подпись к фото (1024 символа).
  const description = oneLine(String(raw.description || '').replace(/<br\s*\/?>/gi, ' ').replace(/<[^>]+>/g, ' ')
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&'));
  const room = 1_000 - text.length - 10;
  if (description && room > 60) text = [...head, '', `<i>${esc(truncate(description, room))}</i>`, '', ...tail].join('\n');
  return { text, url, photo: photoUrl(raw), keyboard: { inline_keyboard: [[{ text: pending ? '🔗 Открыть (после публикации)' : '🔗 Открыть на OLX', url }]] } };
}

const stats = { checked: 0, open: 0, cars: 0, sentPending: 0, pendingPublished: 0, missed: 0, reopened: 0, reopenedCars: 0, reopenedWait: 0 };
const handledIds = new Set(loadJson(HANDLED_FILE, []).map(Number));
// Номера, по которым уже отправлено уведомление «на проверке» — чтобы не слать повторно.
const pendingAlerted = new Set();
// Статусы, которые бот НЕ считает «на проверке» и не шлёт. По умолчанию ПУСТО: какие статусы
// у olx.uz бывают на модерации, мы наверняка не знаем, а лишнее уведомление лучше пропущенной машины.
// Статус каждой машины на проверке виден в логе (строка 👀). Если какой-то статус окажется мусором,
// впишите его в .env, например: SKIP_STATUSES=disabled
const SKIP_STATUSES = new Set(String(process.env.SKIP_STATUSES || '').split(/[,\s]+/).filter(Boolean));

function rememberHandled(id) {
  handledIds.add(Number(id));
  while (handledIds.size > HANDLED_KEEP) handledIds.delete(handledIds.values().next().value);
}

let handledSaveTimer = null;
function saveHandledSoon() {
  if (handledSaveTimer) return;
  handledSaveTimer = setTimeout(() => {
    handledSaveTimer = null;
    saveJson(HANDLED_FILE, [...handledIds]);
  }, 2_000);
}

async function deliver(raw, source, { pending = false } = {}) {
  const msg = buildMessage(raw, { pending });
  const ageText = pending ? 'на проверке' : `через ${formatAge(Date.now() - publishedAt(raw))}`;
  const line = `${pending ? '🕓 ' : ''}${truncate(oneLine(raw.title), 50)} · ${oneLine(apiParam(raw, 'price')?.label)} · ${source === 'probe' ? 'перебор' : 'список'} · ${ageText} [раздел ${raw.category?.id}]`;
  const chats = recipients();
  if (!chats.length) {
    console.log(`🚗 ${line} → никто не подписан (напишите боту /start)`);
    return;
  }
  // Первые 25 — одновременно, фото по ссылке. Остальным — уже копия Telegram
  // (file_id): она уходит мгновенно, OLX и Telegram не качают фото заново.
  const started = Date.now();
  const firstResults = await Promise.all(chats.slice(0, 25).map((chatId) => sendCar(chatId, msg, msg.photo)));
  const firstMs = Date.now() - started;
  diag.deliverSum += firstMs;
  diag.deliverMax = Math.max(diag.deliverMax, firstMs);
  if (firstMs > 5_000) console.warn(`🐢 Отправка в Telegram заняла ${formatAge(firstMs)} — ${truncate(oneLine(raw.title), 40)}`);
  const fileId = firstResults.find((result) => result.fileId)?.fileId;
  const restResults = await Promise.all(chats.slice(25).map((chatId) => sendCar(chatId, msg, fileId || msg.photo)));
  const delivered = [...firstResults, ...restResults].filter((result) => result.ok).length;
  console.log(`✉️ ${line} → получили ${delivered} из ${chats.length}`);
}

// Что бот решил по каждому открытому объявлению — для команды /why.
const decisions = new Map(); // номер -> { at, text }
function note(id, text) {
  decisions.set(Number(id), { at: Date.now(), text });
  while (decisions.size > 30_000) decisions.delete(decisions.keys().next().value);
}

// Почему объявление НЕ наше (null — наше).
function whyNotOurs(raw) {
  if (!isCar(raw)) return `не легковая машина (раздел ${raw.category?.id}${raw.category?.type ? `, ${raw.category.type}` : ''})`;
  if (CITY_ID && raw.location?.city?.id !== CITY_ID) return `другой город (${oneLine(raw.location?.city?.name) || '?'})`;
  if (ONLY_PRIVATE && raw.business) return 'автосалон / компания';
  const usd = priceUsd(raw);
  if (PRICE_FILTER && usd === null) return 'цена не указана';
  if (!priceOk(usd)) return `цена ${money(usd)} $ — не подходит (нужно ${priceRangeText()})`;
  if (!modelOk(raw)) return `другая модель (${truncate(carModel(raw) || oneLine(raw.title), 40)}; нужны: ${modelsText()})`;
  if (!isNewAd(raw)) return `старое объявление, создано ${formatAge(Date.now() - Date.parse(raw.created_time))} назад (платное поднятие)`;
  return null;
}

function handleAd(raw, source) {
  if (!isActive(raw)) return;
  const reason = whyNotOurs(raw);
  if (reason) {
    if (decisions.has(Number(raw.id))) return;
    note(raw.id, `пропущено: ${reason}`);
    const usd = priceUsd(raw);
    const inRange = priceOk(usd);
    const label = `${truncate(oneLine(raw.title), 40)} (№ ${raw.id})`;
    if (!isCar(raw) && raw.category?.type === 'automotive' && inRange) {
      // Транспорт в нужной цене, но в разделе, которого бот не знает: новая марка? грузовик?
      diag.unknownCars += 1;
      sample(diag.unknownSamples, `${label}, раздел ${raw.category.id}`);
      console.log(`❓ Транспорт в цене, но незнакомый раздел ${raw.category.id}: ${label}. Если это легковая — напишите, добавим.`);
    } else if (isCar(raw) && usd === null) {
      diag.noPrice += 1;
    } else if (isCar(raw) && inRange && modelOk(raw) && !isNewAd(raw)) {
      diag.ageCut += 1;
      sample(diag.ageSamples, `${label}, создано ${formatAge(Date.now() - Date.parse(raw.created_time))} назад`);
      console.log(`🕰 Машина в цене отсечена как «старая» (создана ${formatAge(Date.now() - Date.parse(raw.created_time))} назад, опубликована ${formatAge(Date.now() - publishedAt(raw))} назад): ${label}`);
    }
    return;
  }
  if (handledIds.has(Number(raw.id))) return;
  rememberHandled(raw.id);
  saveHandledSoon();
  // Уже отправили это объявление «на проверке» — второй раз (после публикации) не шлём.
  if (pendingAlerted.has(Number(raw.id))) {
    stats.pendingPublished += 1;
    note(raw.id, '✅ опубликовано (уже отправляли «на проверке»)');
    return;
  }
  // Бот шлёт только машины «на проверке». Эту OLX на проверке не показывал (отвечал 404/410) —
  // бот увидел её уже опубликованной и не шлёт.
  stats.missed += 1;
  diag.missed += 1;
  const age = formatAge(Date.now() - publishedAt(raw));
  note(raw.id, `не отправлено: бот увидел его уже опубликованным (${age} назад), а шлёт только «на проверке»`);
  console.log(`⏭ Не отправляю: уже опубликовано (${age} назад), на проверке не видел · ${truncate(oneLine(raw.title), 50)} · ${source === 'probe' ? 'перебор' : 'список'}`);
}

// ============================================================================
// Способ 1: перебор номеров подряд (самый быстрый)
// ============================================================================

const probe = {
  cursor: 0, nearOffset: 0, farOffset: 0, farOrder: [], frontToggle: false, hammer: false, lookahead: PROBE_LOOKAHEAD_MIN,
  retries: new Map(), // номер -> { attempt, dueAt, fast }
  retryStreak: 0, lastFrontOpened: false, lastFrontHitAt: 0,
  startedAt: 0, startCursor: 0, retryLagAvg: 0, recentScans: []
};
const probeLog = new Map(); // номер -> { status, olxStatus, relevant }

function logProbe(id, status, data) {
  probeLog.set(Number(id), { status, olxStatus: data?.status || null, relevant: data?.id ? looksLikeOurCar(data) : null, at: Date.now() });
  while (probeLog.size > PROBE_LOG_KEEP) probeLog.delete(probeLog.keys().next().value);
}

function countCheck(status, data) {
  stats.checked += 1;
  if (status !== 200 || !data?.id) return;
  stats.open += 1;
  if (isActive(data) && isCar(data)) stats.cars += 1;
}

function loadProbeState() {
  const saved = loadJson(PROBE_STATE_FILE, {});
  if (!(Number(saved?.cursor) > 0) || Date.now() - Number(saved.savedAt || 0) >= 30 * 60_000) return;
  probe.cursor = Number(saved.cursor);
  const now = Date.now();
  for (const [id, attempt, dueAt, fast, watchSince] of Array.isArray(saved.retries) ? saved.retries : []) {
    if (!(Number(id) > 0)) continue;
    const watch = Number(watchSince) > 0 ? { watch: true, since: Number(watchSince) } : {};
    probe.retries.set(Number(id), { attempt: Number(attempt) || 0, dueAt: Math.max(Number(dueAt) || 0, now), fast: Boolean(fast), ...watch });
  }
}

function saveProbeState() {
  const retries = [...probe.retries].slice(-PROBE_MAX_RETRIES).map(([id, retry]) => [id, retry.attempt, retry.dueAt, retry.fast ? 1 : 0, retry.watch ? retry.since : 0]);
  saveJson(PROBE_STATE_FILE, { cursor: probe.cursor, savedAt: Date.now(), retries });
}

async function syncProbeStart() {
  const { data } = await olxApi('?offset=0&limit=50&sort_by=created_at:desc');
  const ids = (Array.isArray(data) ? data : []).filter((ad) => !ad.promotion?.top_ad).map((ad) => Number(ad.id)).filter(Boolean);
  if (ids.length) probe.cursor = Math.max(probe.cursor, ...ids);
}

// Быстрые взгляды на номер, который только что остался позади фронта: такие часто
// открываются через секунды. С 1-2 IP — один взгляд через 15 сек (больше не потянуть),
// с 3 и больше — каждые 3-5 сек первые полминуты (по модели: новые машины за ~4 сек).
function quickPlanSec() {
  return lanes.length >= 3 ? [3, 3, 4, 5, 5, 10] : [GAP_QUICK_RETRY_MS / 1000];
}

function scheduleRetry(id, attempt, fast = false) {
  const plan = cars.parents.size ? RETRY_PLAN_WITH_LIST : RETRY_PLAN;
  // С 3+ IP обычные перепроверки вдвое чаще, а окно ожидания то же (~11 мин): шагов вдвое больше.
  const scale = lanes.length >= 3 ? 0.5 : 1;
  const delays = (fast ? plan.fast : plan.slow).flatMap((delay) => Array(Math.ceil(1 / scale)).fill(delay * scale));
  if (attempt < 0) {
    const quick = quickPlanSec();
    if (!probe.retries.has(id) && probe.retries.size >= PROBE_MAX_RETRIES) return;
    probe.retries.set(id, { attempt, fast, firstAt: probe.retries.get(id)?.firstAt || Date.now(), dueAt: Date.now() + quick[Math.max(0, quick.length + attempt)] * 1000 });
    return;
  }
  if (attempt >= delays.length) {
    probe.retries.delete(id);
    return;
  }
  if (!probe.retries.has(id) && probe.retries.size >= PROBE_MAX_RETRIES) return;
  probe.retries.set(id, { attempt, fast, firstAt: probe.retries.get(id)?.firstAt || Date.now(), dueAt: Date.now() + delays[attempt] * 60_000 });
}

// Наша машина (раздел, цена, город подходят), но OLX её ещё не открыл.
function watchCar(id) {
  const current = probe.retries.get(id);
  const since = current?.watch ? current.since : Date.now();
  if (Date.now() - since > WATCH_MAX_MS) {
    probe.retries.delete(id);
    return;
  }
  const watched = [...probe.retries.values()].filter((retry) => retry.watch).length;
  if (!current?.watch && watched >= WATCH_MAX_ITEMS) {
    scheduleRetry(id, 0, true);
    return;
  }
  probe.retries.set(id, { attempt: 0, fast: true, watch: true, since, firstAt: current?.firstAt || since, dueAt: Date.now() + WATCH_INTERVAL_MS });
}

function statusText(status, olxStatus) {
  if (status === 200 && (!olxStatus || olxStatus === 'active')) return 'открыто';
  if (status === 200) return `есть, но ещё не показано (статус «${olxStatus}»)`;
  if (status === 404) return '«нет такого» (черновик, удалено или ещё не создано)';
  if (status === 410) return '«скрыто» (на проверке у OLX, снято или продано)';
  return `сбой ответа (${status})`;
}

// /why <номер>: что бот видел на этом номере, что решил, и что OLX отвечает прямо сейчас.
async function explainNumber(id) {
  const lines = [`🔎 <b>Номер ${id}</b>`];
  const seen = probeLog.get(id);
  const decision = decisions.get(id);
  const retry = probe.retries.get(id);
  if (seen) lines.push(`Бот проверял ${formatAge(Date.now() - seen.at)} назад: ${statusText(seen.status, seen.olxStatus)}.`);
  else if (id > probe.cursor) lines.push(`Перебор до него ещё не дошёл (сейчас на ${probe.cursor}).`);
  else if (id <= probe.startCursor) lines.push('Номер старше запуска бота — бот его не проверял.');
  else lines.push('Бот этот номер ещё не проверял.');
  if (decision) lines.push(`Решение: ${esc(decision.text)} (${formatAge(Date.now() - decision.at)} назад).`);
  if (retry) {
    const kind = retry.watch ? 'наша машина на проверке, но её статус исключён SKIP_STATUSES — смотрю каждые 10 сек, вдруг сменится' : retry.fast ? 'OLX его проверяет' : '«нет такого» — проверяю редко';
    lines.push(`В очереди: ${kind}; следующая проверка через ${formatAge(Math.max(0, retry.dueAt - Date.now()))}.`);
  }
  if (Date.now() >= olx.blockedUntil) {
    try {
      const { status, data } = await olxApi(`${id}/`);
      logProbe(id, status, data);
      let now = `Сейчас OLX отвечает: ${statusText(status, data?.status)}.`;
      if (status === 200 && data?.id) {
        now += `\n${esc(truncate(oneLine(data.title), 60))} · ${esc(oneLine(apiParam(data, 'price')?.label) || 'без цены')}`;
        const reason = whyNotOurs(data);
        now += reason ? `\nДля бота: ${esc(reason)}.` : '\nДля бота: подходит ✅';
        // Открылось — обрабатываем сразу, не дожидаясь очереди.
        if (isActive(data)) probe.retries.delete(id);
        onProbeHit(data);
      }
      lines.push(now);
    } catch (error) {
      lines.push(`Сейчас проверить не удалось: ${esc(error.message)}`);
    }
  }
  return lines.join('\n');
}

// 410 / «ещё не активно» = объявление на проверке у OLX, скоро откроется — проверять чаще.
function isLikelyUnderReview(id) {
  const seen = probeLog.get(id);
  return seen?.status === 410 || seen?.status === 0 || seen?.status >= 500
    || (seen?.status === 200 && seen.olxStatus && seen.olxStatus !== 'active');
}

// Недавно открытые объявления — для самопроверки «не прячет ли OLX от бота объявления».
const recentOpen = [];

// Уведомить о машине, пока она на проверке у OLX. Один раз на номер.
// false — номер стоит смотреть дальше (статус из SKIP_STATUSES может смениться),
// true — с ним всё: отправлено сейчас или раньше, либо не будет отправлено никогда.
function alertPending(raw) {
  if (SKIP_STATUSES.has(raw.status)) return false;
  const id = Number(raw.id);
  if (pendingAlerted.has(id) || handledIds.has(id)) return true;
  // Совсем старое (создано больше 3 ч назад — поднятие или правка) не шлём.
  if (!isNewAd(raw)) return true;
  pendingAlerted.add(id);
  while (pendingAlerted.size > HANDLED_KEEP) pendingAlerted.delete(pendingAlerted.values().next().value);
  stats.sentPending += 1;
  const foundAge = Date.now() - Date.parse(raw.created_time);
  diag.sent += 1;
  diag.foundAgeSum += foundAge;
  diag.foundAgeMax = Math.max(diag.foundAgeMax, foundAge);
  note(id, `🕓 отправлено «на проверке» (до публикации, через ${formatAge(foundAge)} после создания)`);
  // Не ждём Telegram: перебор сразу идёт дальше.
  deliver(raw, 'probe', { pending: true }).catch((error) => console.error(`[Отправка «на проверке»] ${id}: ${error.message}`));
  return true;
}

// Каждая машина, которую OLX показал «на проверке», — одна строка в лог: статус и решение.
const pendingSeen = new Set();
function logPendingSeen(raw) {
  const id = Number(raw.id);
  if (pendingSeen.has(id)) return;
  pendingSeen.add(id);
  while (pendingSeen.size > 2_000) pendingSeen.delete(pendingSeen.values().next().value);
  const usd = priceUsd(raw);
  // Сначала настоящие причины (цена, раздел, город), и только потом статус — иначе он их заслоняет.
  const reason = whyNotOurs(raw) || (SKIP_STATUSES.has(raw.status) ? `статус «${raw.status}» исключён настройкой SKIP_STATUSES` : null);
  const verdict = reason ? `пропущено: ${reason}` : 'отправляю сразу';
  console.log(`👀 На проверке [${raw.status}] №${id} · ${truncate(oneLine(raw.title), 40)} · ${usd !== null ? `${money(usd)} $` : 'без цены'} · раздел ${raw.category?.id} → ${verdict}`);
}

function onProbeHit(raw) {
  if (!isActive(raw) && raw?.category?.type === 'automotive') logPendingSeen(raw);
  if (isActive(raw)) {
    recentOpen.push({ id: Number(raw.id), at: Date.now() });
    if (recentOpen.length > 200) recentOpen.shift();
  }
  if (!isActive(raw)) {
    // Ещё на проверке. OLX показал данные — значит, можно сразу уведомить.
    if (looksLikeOurCar(raw)) {
      if (alertPending(raw)) probe.retries.delete(Number(raw.id));
      else watchCar(Number(raw.id));
    } else {
      probe.retries.delete(Number(raw.id));
    }
    return;
  }
  handleAd(raw, 'probe');
}

function isProbeBehind() {
  if (probe.recentScans.length < PROBE_RECENT_WINDOW / 2) return false;
  return probe.recentScans.filter(Boolean).length / probe.recentScans.length >= PROBE_BEHIND_SHARE;
}

function probeIntervalMs() {
  if (isProbeBehind()) return PROBE_FAST_INTERVAL_MS;
  const lag = probe.retryLagAvg;
  if (lag <= RETRY_LAGGING_MS) return PROBE_INTERVAL_MS;
  const share = Math.min(1, (lag - RETRY_LAGGING_MS) / (RETRY_LAGGING_HEAVY_MS - RETRY_LAGGING_MS));
  return Math.round(PROBE_INTERVAL_MS - share * (PROBE_INTERVAL_MS - PROBE_CATCHUP_RETRY_INTERVAL_MS));
}

// Номера, которые прямо сейчас проверяются (при нескольких IP — чтобы не проверять дважды).
const inFlight = new Set();

// Порядок очереди: наши машины на проверке → непроверенные номера позади фронта → остальные по сроку.
function pickDue(now) {
  const rank = (retry) => (retry.watch ? 0 : retry.unchecked ? 1 : 2);
  let due = null;
  for (const entry of probe.retries) {
    const [id, retry] = entry;
    if (retry.dueAt > now || inFlight.has(id)) continue;
    if (!due || rank(retry) < rank(due[1]) || (rank(retry) === rank(due[1]) && retry.dueAt < due[1].dueAt)) due = entry;
  }
  return due;
}

// Режим «вижу каждый запрос»: LOG_REQUESTS=1 — все номера, LOG_REQUESTS=2 — только открывшиеся.
const LOG_REQUESTS = String(process.env.LOG_REQUESTS || '').trim();
const clock = () => {
  const now = new Date();
  return `${now.toTimeString().slice(0, 8)}.${String(now.getMilliseconds()).padStart(3, '0')}`;
};

function traceRequest(kind, lane, id, status, data, extra) {
  if (!LOG_REQUESTS || LOG_REQUESTS === '0') return;
  const opened = status === 200 && Boolean(data?.id);
  if (LOG_REQUESTS === '2' && !opened) return;
  const who = `${kind === 'front' ? '🔭 новый ' : '🔁 повтор'} #${lanes.indexOf(lane) + 1}`;
  let what;
  if (opened) {
    const usd = priceUsd(data);
    const state = isActive(data) ? '✅ открыто' : `🕓 НА ПРОВЕРКЕ [${data.status}]`;
    const reason = whyNotOurs(data);
    what = `${state} · ${truncate(oneLine(data.title), 38)} · ${usd !== null ? `${money(usd)} $` : 'без цены'} · раздел ${data.category?.id} → ${reason ? `не наша: ${reason}` : '🚗 ПОДХОДИТ'}`;
  } else if (status === 404) what = 'нет такого (404) — OLX не дал данных';
  else if (status === 410) what = 'скрыто (410) — OLX не дал данных: ни названия, ни цены, ни фото';
  else if (status === 0) what = 'сбой ответа';
  else what = `ответ ${status}`;
  console.log(`${clock()} ${who} ${id} ${extra} → ${what}`);
}

// Перепроверка одного номера из очереди.
async function retryStep(due, lane) {
  const [id, retry] = due;
  const lag = Math.min(Math.max(0, Date.now() - retry.dueAt), 30 * 60_000);
  probe.retryLagAvg = probe.retryLagAvg * 0.9 + lag * 0.1;
  inFlight.add(id);
  let result;
  try {
    result = await olxApi(`${id}/`, lane);
  } finally {
    inFlight.delete(id);
  }
  const { status, data } = result;
  countCheck(status, data);
  logProbe(id, status, data);
  traceRequest('retry', lane, id, status, data, `(ждёт ${formatAge(Date.now() - (retry.firstAt || Date.now()))})`);
  if (!probe.retries.has(id)) {
    // Пока шёл запрос, номер уже разобрали (другой IP или /why).
    if (status === 200 && data?.id && isActive(data)) onProbeHit(data);
    return;
  }
  if (status === 200 && data?.id && isActive(data)) {
    probe.retries.delete(id);
    const waited = Date.now() - (retry.firstAt || Date.now());
    stats.reopened += 1;
    stats.reopenedWait += waited;
    diag.reopened += 1;
    diag.reopenedWaitSum += waited;
    diag.reopenedWaitMax = Math.max(diag.reopenedWaitMax, waited);
    if (isCar(data)) {
      stats.reopenedCars += 1;
      diag.reopenedCars += 1;
    }
    onProbeHit(data);
  } else if (status === 200 && data?.id && !looksLikeOurCar(data)) {
    probe.retries.delete(id);
  } else if (status === 200 && data?.id) {
    // Наша машина на проверке — сообщаем сразу, один раз. Следить дальше незачем:
    // опубликованную бот всё равно не шлёт.
    if (alertPending(data)) probe.retries.delete(id);
    else watchCar(id);
  } else if (status === 0 || status >= 500) {
    probe.retries.set(id, { ...retry, dueAt: Date.now() + (retry.watch ? WATCH_INTERVAL_MS : TRANSIENT_RETRY_MS) });
  } else if (retry.watch) {
    if (status === 410) watchCar(id); // скрыто — возможно, снова на проверке
    else probe.retries.delete(id); // 404 — удалили
  } else {
    const fast = retry.fast || status === 410 || (status === 200 && data?.status && data.status !== 'active');
    // Первая проверка ранее непроверенного номера: ещё один быстрый взгляд через 15 сек.
    const nextAttempt = retry.unchecked ? -quickPlanSec().length : retry.attempt < 0 ? retry.attempt + 1 : fast && !retry.fast ? 0 : retry.attempt + 1;
    scheduleRetry(id, nextAttempt, fast);
  }
}

// Проверка свежего номера впереди.
async function frontStep(lane) {
  const id = nextFrontId();
  const { status, data } = await olxApi(`${id}/`, lane);
  countCheck(status, data);
  logProbe(id, status, data);
  traceRequest('front', lane, id, status, data, `(впереди +${id - probe.cursor})`);
  const opened = status === 200 && Boolean(data?.id);
  probe.recentScans.push(opened);
  if (probe.recentScans.length > PROBE_RECENT_WINDOW) probe.recentScans.shift();
  probe.lastFrontOpened = opened;
  if (!opened) return;
  if (id > probe.cursor) {
    // Номера позади открывшегося созданы раньше него — значит, могут уже быть открыты.
    // Закрытые 0-20 сек назад — быстрый повтор через 15 сек. Непроверенные или
    // проверенные давно (тогда их, возможно, ещё не существовало) — в начало очереди.
    const at = Date.now();
    for (let gap = probe.cursor + 1; gap < id; gap += 1) {
      if (probe.retries.has(gap)) continue;
      const seen = probeLog.get(gap);
      if (seen?.relevant === false) continue;
      if (!seen || at - seen.at > GAP_STALE_MS) probe.retries.set(gap, { attempt: -1, fast: false, unchecked: true, firstAt: at, dueAt: at });
      else scheduleRetry(gap, -quickPlanSec().length, isLikelyUnderReview(gap));
    }
    if (id - probe.cursor > 12) diag.bigJumps += 1;
    probe.cursor = id;
    resetFront();
    probe.lastFrontHitAt = Date.now();
  } else if (isActive(data)) {
    probe.retries.delete(id); // другой IP уже сдвинул фронт дальше
  }
  onProbeHit(data);
}

// Один IP: поиск новых номеров и перепроверки по очереди (сколько ходов кому — по нагрузке).
async function mixedStep(lane) {
  const behind = isProbeBehind();
  const lagging = probe.retryLagAvg > RETRY_LAGGING_MS && !probe.lastFrontOpened;
  const retryTurns = !lagging ? 1 : probe.retryLagAvg > RETRY_LAGGING_HEAVY_MS ? 3 : 2;
  const due = behind ? null : pickDue(Date.now());
  // Непроверенным номерам позади фронта — до 3 ходов подряд: они созданы раньше уже
  // открывшегося номера, поэтому, скорее всего, тоже уже открыты.
  const turns = due?.[1].unchecked ? Math.max(3, retryTurns) : retryTurns;
  if (due && probe.retryStreak < turns) {
    probe.retryStreak += 1;
    return retryStep(due, lane);
  }
  if (!due) probe.retryLagAvg *= 0.9;
  probe.retryStreak = 0;
  return frontStep(lane);
}

// Один шаг для одного IP. Если IP несколько: главный только ищет новые номера (ему не
// мешает очередь — новые машины находятся за 1-3 сек), остальные сначала перепроверяют
// очередь, а когда она пуста — помогают искать. Главный IP на паузе — остальные делают всё.
async function probeTick(lane = olx) {
  diag.ticks += 1;
  if (isProbeBehind()) diag.behindTicks += 1;
  if (lanes.length === 1 || (lane !== olx && Date.now() < olx.blockedUntil)) return mixedStep(lane);
  if (lane === olx) return frontStep(lane);
  const due = isProbeBehind() ? null : pickDue(Date.now());
  if (due) return retryStep(due, lane);
  probe.retryLagAvg *= 0.9;
  return frontStep(lane);
}

function resetFront() {
  probe.nearOffset = 0;
  probe.farOffset = 0;
  probe.farOrder = [];
  probe.frontToggle = false;
  probe.lookahead = PROBE_LOOKAHEAD_MIN;
}

// Какой номер впереди проверить. Ближние 6 номеров — по кругу всегда. Если долго
// ничего не открывается (ночью, или OLX перескочил номера), круг расширяется до 60,
// но дальние номера идут через раз с ближними: ближний номер всё равно проверяется
// не реже чем раз в 12 проверок (раньше — раз в 60, отсюда ночные минуты задержки).
function nextFrontId() {
  const far = probe.lookahead > PROBE_LOOKAHEAD_MIN && probe.frontToggle;
  probe.frontToggle = !probe.frontToggle;
  if (!far) {
    // Самый следующий номер (cursor+1) — через раз: новое объявление чаще всего появляется именно там.
    // Между ними по кругу +2…+6: следующий номер может оказаться черновиком, а за ним уже опубликованы другие.
    probe.hammer = !probe.hammer;
    if (probe.hammer) return probe.cursor + 1;
    const offset = 1 + (probe.nearOffset % (PROBE_LOOKAHEAD_MIN - 1));
    probe.nearOffset = (probe.nearOffset + 1) % (PROBE_LOOKAHEAD_MIN - 1);
    if (probe.nearOffset === 0 && probe.lookahead === PROBE_LOOKAHEAD_MIN) growLookahead();
    return probe.cursor + 1 + offset;
  }
  // Дальние номера — не подряд, а «через три»: если OLX перескочил кусок номеров,
  // живое объявление за разрывом находится в разы быстрее.
  const offset = probe.farOrder[probe.farOffset];
  probe.farOffset += 1;
  if (probe.farOffset >= probe.farOrder.length) growLookahead();
  return probe.cursor + 1 + offset;
}

// Круг ничего не нашёл — смотрим вдвое дальше (6 → 12 → 24 → 48 → 60), а не на 6 номеров.
function growLookahead() {
  probe.lookahead = Math.min(PROBE_LOOKAHEAD_MAX, probe.lookahead * 2);
  probe.farOffset = 0;
  probe.farOrder = [];
  for (const start of [0, 2, 1, 3]) {
    for (let offset = PROBE_LOOKAHEAD_MIN + start; offset < probe.lookahead; offset += 4) probe.farOrder.push(offset);
  }
}

// Если OLX перескочил номера дальше, чем смотрит перебор, — прыгаем, пропущенное в очередь.
function unstickProbe(ids) {
  const highest = Math.max(0, ...ids.map(Number).filter(Number.isFinite));
  if (!probe.startCursor || highest <= probe.cursor + PROBE_LOOKAHEAD_MAX) return;
  if (Date.now() - Math.max(probe.lastFrontHitAt, probe.startedAt || 0) < PROBE_STUCK_MS) return;
  diag.jumps += 1;
  const from = Math.max(probe.cursor + 1, highest - PROBE_JUMP_MAX_SCHEDULE);
  for (let id = from; id < highest; id += 1) {
    if (!probe.retries.has(id)) scheduleRetry(id, 0);
  }
  console.warn(`⚠️ Перебор застрял на ${probe.cursor}, перехожу к ${highest}.`);
  probe.cursor = highest - 1;
  resetFront();
}

// ============================================================================
// Способ 2: список раздела раз в 30 сек (страховка + учит новые марки)
// ============================================================================

async function listSweep({ warmUp = false } = {}) {
  for (const categoryId of cars.parents) {
    const city = CITY_ID ? `&city_id=${CITY_ID}` : '';
    const { data } = await olxApi(`?offset=0&limit=${LIST_LIMIT}&category_id=${categoryId}${city}&sort_by=created_at:desc`);
    const ads = Array.isArray(data) ? data : [];
    for (const raw of ads) learnCategory(raw);
    if (!warmUp) unstickProbe(ads.filter((ad) => !ad.promotion?.top_ad).map((ad) => ad.id));
    for (const raw of ads) {
      if (warmUp && !isFresh(raw, 'list')) {
        rememberHandled(raw.id); // после запуска старое не шлём
        continue;
      }
      handleAd(raw, 'list');
    }
    await sleep(300);
  }
  if (warmUp) saveHandledSoon();
}

// ============================================================================
// Двигатель
// ============================================================================

// /diag — все гипотезы одним списком: ✅ не подтвердилась, ⚠️ есть такое.
function diagReport() {
  const d = diag;
  const ok = (bad) => (bad ? '⚠️' : '✅');
  const avg = (sum, count) => (count ? formatAge(sum / count) : '—');
  const skew = d.clockSkew === null ? null : Math.round(d.clockSkew / 1000);
  const behindPct = d.ticks ? Math.round((d.behindTicks * 100) / d.ticks) : 0;
  const lines = [
    `🩺 <b>Диагностика за ${formatAge(Date.now() - d.startedAt)} работы</b>`,
    '',
    `${ok(d.selfCheckFails)} 1. OLX прячет объявления от бота: ${d.selfCheckFails ? `самопроверка падала ${d.selfCheckFails} из ${d.selfChecks} раз` : `нет (самопроверок: ${d.selfChecks})`}`,
    `${ok(d.blocks)} 2. Блоки OLX (429/403): ${d.blocks}`,
    `${ok(d.notJson)} 3. Капча вместо данных: ${d.notJson}`,
    `${ok(d.netFails > 50)} 4. Сбои сети: ${d.netFails}`,
    `${ok(behindPct > 20 || d.lagReports)} 5. Перебор не успевает: догонял ${behindPct}% времени, перепроверки опаздывали в ${d.lagReports} из ${d.reports} отчётов`,
    `${ok(d.jumps)} 6. OLX перескакивал номера (перебор застревал): ${d.jumps}; больших прыжков фронта (больше 12 номеров): ${d.bigJumps}`,
    `ℹ️ 7. Черновики и модерация: из очереди открылось ${d.reopened} (машин ${d.reopenedCars}), ждали в среднем ${avg(d.reopenedWaitSum, d.reopened)}, дольше всего ${d.reopened ? formatAge(d.reopenedWaitMax) : '—'}`,
    `${ok(d.unknownCars)} 8. Транспорт в цене из незнакомых разделов: ${d.unknownCars}${d.unknownSamples.length ? `\n    ${d.unknownSamples.map(esc).join('\n    ')}` : ''}`,
    `${ok(d.ageCut)} 9. Машины в цене, отсечённые как «старые» (созданы больше 3 ч назад): ${d.ageCut}${d.ageSamples.length ? `\n    ${d.ageSamples.map(esc).join('\n    ')}` : ''}`,
    `ℹ️ 10. Машины без цены (пропущены): ${d.noPrice}`,
    `${ok(d.missed)} 11. Машины, которые бот увидел только опубликованными (на проверке OLX их не показал, не отправлено): ${d.missed}`,
    `ℹ️ 12. От создания объявления до отправки «на проверке»: в среднем ${avg(d.foundAgeSum, d.sent)}, дольше всего ${d.sent ? formatAge(d.foundAgeMax) : '—'} (отправлено ${d.sent})`,
    `${ok(d.deliverMax > 5_000 || d.photoFallbacks)} 13. Доставка в Telegram: в среднем ${d.sent ? `${(d.deliverSum / d.sent / 1000).toFixed(1)} сек` : '—'}, дольше всего ${(d.deliverMax / 1000).toFixed(1)} сек; фото не прошло ${d.photoFallbacks}, зависало ${d.timeouts}`,
    `${ok(d.sleeps)} 14. Mac спал / бот стоял: ${d.sleeps ? `${d.sleeps} раз, дольше всего ${formatAge(d.sleepMax)}` : 'нет'}`,
    `${ok(skew !== null && Math.abs(skew) > 30)} 15. Часы Mac: ${skew === null ? 'ещё не измерено' : Math.abs(skew) <= 30 ? `точные (разница с OLX ${skew} сек)` : `${skew > 0 ? 'отстают' : 'спешат'} на ${Math.abs(skew)} сек`}`,
    `${ok(!cars.parents.size)} 16. Список-страховка: ${cars.parents.size ? 'работает' : 'общий раздел легковых не найден — поздние объявления ловит только перебор'}`,
    `${ok(lanes.some((lane) => lane.blocks))} 17. IP-адресов работает: ${lanes.length} (${lanes.map((lane) => `${esc(lane.name)}${lane.blocks ? `, блоков ${lane.blocks}` : ''}`).join('; ')})`
  ];
  return lines.join('\n');
}

// Раз в 5 минут: 3 объявления, которые бот видел открытыми 5-60 мин назад, должны
// и сейчас открываться. Если OLX вдруг отвечает «нет такого» на все три — значит, он
// прячет объявления от бота. Тогда бот перезапускает браузер (новые куки).
let lastSelfCheck = 'ещё не было';
async function selfCheck() {
  const now = Date.now();
  const picked = recentOpen.filter((item) => now - item.at > 5 * 60_000 && now - item.at < 60 * 60_000).slice(-3);
  if (picked.length < 3) {
    lastSelfCheck = 'мало данных';
    return;
  }
  diag.selfChecks += 1;
  let visible = 0;
  for (const { id } of picked) {
    const { status } = await olxApi(`${id}/`);
    if (status === 200) visible += 1;
    await sleep(300);
  }
  if (visible > 0) {
    lastSelfCheck = `${visible} из 3 недавних объявлений открываются — OLX бота не прячет ✅`;
    return;
  }
  diag.selfCheckFails += 1;
  lastSelfCheck = '⚠️ 0 из 3 недавних объявлений открываются — похоже, OLX принял бота за робота';
  console.warn(`${lastSelfCheck}. Перезапускаю браузер с новыми куками.`);
  await openOlxSession();
}

function report() {
  const lag = probe.retryLagAvg;
  diag.reports += 1;
  if (lag >= 60_000) diag.lagReports += 1;
  const keepUp = isProbeBehind() ? '⚠️ догоняет новые номера'
    : lag < 60_000 ? 'успевает ✅' : `⚠️ перепроверки опаздывают на ${formatAge(lag)}`;
  const queue = [...probe.retries.values()];
  const watched = queue.filter((retry) => retry.watch).length;
  const review = queue.filter((retry) => !retry.watch && retry.fast).length;
  const reopened = stats.reopened
    ? `За 5 мин из очереди открылось ${stats.reopened} (машин среди них ${stats.reopenedCars}), ждали в среднем ${formatAge(stats.reopenedWait / stats.reopened)}.`
    : 'За 5 мин из очереди ничего не открылось.';
  console.log(`🚦 Бот ${keepUp}. Очередь: ${probe.retries.size} закрытых номеров — на проверке у OLX ${review}, «нет такого» (черновики) ${queue.length - review - watched}, наших машин на проверке ${watched}. ${reopened} Проверить любой номер: /why номер`);
  const total = Object.values(answers).reduce((sum, value) => sum + value, 0) || 1;
  const pct = (value) => `${Math.round((value * 100) / total)}%`;
  console.log(`🚦 Ответы OLX: открыто ${pct(answers.ok)}, «нет такого» ${pct(answers.notFound)}, «скрыто» ${pct(answers.hidden)}, `
    + `блок 429/403: ${answers.blocked}, капча/не данные: ${answers.notJson}, сбои сети: ${answers.failed}. Самопроверка: ${lastSelfCheck}.`);
  Object.assign(answers, { ok: 0, notFound: 0, hidden: 0, blocked: 0, notJson: 0, failed: 0 });
  if (lanes.length > 1) {
    const now = Date.now();
    console.log(`🌐 IP: ${lanes.map((lane) => `${lane.name} ${now < lane.blockedUntil ? `⛔ пауза ${formatAge(lane.blockedUntil - now)}` : '✅'} ${lane.requests} запр.${lane === olx ? ' (ищет новые)' : ' (очередь)'}`).join(' · ')}. Всего запросов в минуту: ~${Math.round(lanes.reduce((sum, lane) => sum + lane.requests, 0) / 5)}.`);
    for (const lane of lanes) lane.requests = 0;
  }
  console.log(`🚦 За 5 мин: проверено номеров ${stats.checked}, открытых объявлений ${stats.open}, из них машин (любой цены) ${stats.cars}. `
    + `Отправлено «на проверке» (цена: ${priceRangeText()}, модели: ${modelsText()}):${stats.sentPending} (из отправленных раньше замечено опубликованными ${stats.pendingPublished}); не отправлено — бот увидел их только опубликованными: ${stats.missed}. `
    + `Подписчиков: ${subscribers.size}. Перебор на номере ${probe.cursor}. `
    + `Темп: 1 запрос в ${(probeIntervalMs() * olx.pace / 1000).toFixed(1)} сек. Курс ≈ ${money(usdRate)} сум/$.`);
  Object.assign(stats, { checked: 0, open: 0, cars: 0, sentPending: 0, pendingPublished: 0, missed: 0, reopened: 0, reopenedCars: 0, reopenedWait: 0 });
}

function easePace(lane, now) {
  if (lane.pace > 1 && now - lane.lastBlockAt > 10 * 60_000 && now - lane.lastEaseAt > 10 * 60_000) {
    lane.pace = Math.max(1, lane.pace / 1.1);
    lane.lastEaseAt = now;
  }
}

// Отдельный цикл для каждого прокси: работает параллельно с главным IP.
async function laneWorker(lane) {
  let failStreak = 0;
  while (!shuttingDown) {
    const now = Date.now();
    if (now < lane.blockedUntil) {
      await sleep(Math.min(5_000, lane.blockedUntil - now));
      continue;
    }
    easePace(lane, now);
    try {
      if (!lane.shared && lane.runtime && now - lane.openedAt >= OLX_BROWSER_RESTART_MS) await openOlxSession(lane);
      await probeTick(lane);
      failStreak = 0;
    } catch (error) {
      if (shuttingDown) return;
      const blocked = String(error.message).match(/^OLX_BLOCKED (\d+)/);
      if (blocked) console.warn(`[OLX] ${lane.name}: ответ ${blocked[1]}, пауза ${Math.round((lane.blockedUntil - Date.now()) / 60_000)} мин, темп ×${lane.pace.toFixed(2)}.`);
      else {
        // Прокси не подключается (неверный пароль, провайдер режет прокси и т.п.) — ждём всё дольше.
        failStreak += 1;
        lane.blockedUntil = Date.now() + Math.min(5 * 60_000, 15_000 * 2 ** (failStreak - 1));
        if (failStreak <= 3 || failStreak % 10 === 0) console.warn(`⚠️ ${lane.name} не работает: ${String(error.message).split('\n')[0].slice(0, 150)}`);
      }
    }
    await sleep(Math.max(50, probeIntervalMs() * lane.pace - (Date.now() - now)));
  }
}

async function runEngine() {
  loadProbeState();
  let lastList = 0;
  let lastGeneral = Date.now();
  let lastSave = 0;
  let lastReport = Date.now();
  let started = false;
  while (!shuttingDown) {
    const now = Date.now();
    if (now < olx.blockedUntil) {
      await sleep(Math.min(5_000, olx.blockedUntil - now));
      continue;
    }
    easePace(olx, now);
    try {
      if (!started) {
        await ensureOlxSession();
        await detectCarCategories();
        if (!probe.cursor) await syncProbeStart();
        started = true;
        probe.startCursor = probe.cursor;
        probe.startedAt = Date.now();
        console.log(`🚀 Ловлю машины: перебор с номера ${probe.cursor + 1}${cars.parents.size ? ', список — раз в 30 сек' : ''}. IP: ${lanes.map((lane) => lane.name).join(', ')}.`);
        for (const lane of lanes.slice(1)) laneWorker(lane).catch((error) => console.error(`[${lane.name}] ${error.message}`));
      }
      if (olx.runtime && now - olx.openedAt >= OLX_BROWSER_RESTART_MS) {
        console.log('🔄 Плановый перезапуск браузера.');
        await openOlxSession();
      }
      if (!cars.parents.size && now - lastGeneral >= GENERAL_LIST_INTERVAL_MS) {
        // Без списка легковых: раз в минуту общий список OLX — только чтобы заметить,
        // что перебор застрял (OLX перескочил номера дальше, чем смотрит перебор).
        lastGeneral = now;
        const { data } = await olxApi('?offset=0&limit=50&sort_by=created_at:desc');
        if (Array.isArray(data)) unstickProbe(data.filter((ad) => !ad.promotion?.top_ad).map((ad) => ad.id));
      }
      if (cars.parents.size && now - lastList >= LIST_INTERVAL_MS) {
        const warmUp = lastList === 0;
        lastList = now;
        await listSweep({ warmUp });
      }
      await probeTick(olx);
      if (now - lastSave >= 30_000) {
        lastSave = now;
        saveProbeState();
      }
      if (now - lastReport >= REPORT_MS) {
        lastReport = now;
        await selfCheck();
        report();
      }
    } catch (error) {
      if (shuttingDown) return;
      const blocked = String(error.message).match(/^OLX_BLOCKED (\d+)/);
      if (blocked) console.warn(`[OLX] Ответ ${blocked[1]}: пауза ${Math.round((olx.blockedUntil - Date.now()) / 60_000)} мин, темп замедлен ×${olx.pace.toFixed(2)}.`);
      else {
        // Только первая строка: Playwright дописывает к ошибке километры логов браузера.
        console.error(`[OLX] Сбой: ${firstLine(error)}`);
        await sleep(10_000);
      }
    }
    await sleep(Math.max(50, probeIntervalMs() * olx.pace - (Date.now() - now)));
  }
}

async function main() {
  if (!TOKEN) {
    console.error('❌ В .env нет TELEGRAM_TOKEN');
    process.exit(1);
  }
  if (!chromium) {
    console.error('❌ Не найден playwright: npm i playwright && npx playwright install chromium');
    process.exit(1);
  }
  let me;
  try {
    me = await tg('getMe', {});
  } catch (error) {
    console.error(`❌ TELEGRAM_TOKEN не подходит: ${error.message}`);
    process.exit(1);
  }
  console.log(`🤖 @${me.username}: машины ${priceRangeText()}${MODEL_NAMES.length ? ` (${modelsText()})` : ''}, ${CITY_ID ? `город № ${CITY_ID}` : 'весь Узбекистан'}${ONLY_PRIVATE ? ', только частные' : ''} → подписчиков: ${subscribers.size}${CHAT_IDS.length ? `, постоянных чатов: ${CHAT_IDS.length}` : ''}`);
  console.log('⚙️ Настройки, которые бот реально взял из .env:');
  console.log(`   цена: ${priceRangeText()} (PRICE_MIN=${process.env.PRICE_MIN ?? 'нет строки'}, PRICE_MAX=${process.env.PRICE_MAX ?? 'нет строки'})`);
  console.log(`   модели: ${modelsText()} (MODELS=${process.env.MODELS ?? 'нет строки'})`);
  console.log(`   город: ${CITY_ID ? `только № ${CITY_ID}` : 'весь Узбекистан'} · только частные: ${ONLY_PRIVATE ? 'да' : 'нет'}`);
  console.log(`   темп: 1 запрос в ${PROBE_INTERVAL_MS} мс на поток · потоков: ${lanes.length} (≈${Math.round((60_000 / PROBE_INTERVAL_MS) * lanes.length)} запросов/мин)`);
  if (LOG_REQUESTS && LOG_REQUESTS !== '0') console.log(`🔬 Режим «вижу каждый запрос»: ${LOG_REQUESTS === '2' ? 'только открывшиеся номера' : 'все номера подряд'} (LOG_REQUESTS=${LOG_REQUESTS}). Чтобы выключить — уберите строку из .env.`);
  console.log('🕓 Шлю ТОЛЬКО машины «на проверке» у OLX — сразу, до публикации (со ссылкой). Уже опубликованные не шлю.');
  if (!recipients().length) console.warn(`⚠️ Пока никто не подписан: откройте @${me.username} в Telegram и нажмите /start.`);
  pollUpdates();
  await runEngine();
}

async function shutdown() {
  if (shuttingDown) process.exit(0); // второе Ctrl+C — выйти сразу
  shuttingDown = true;
  console.log('⏹ Останавливаюсь…');
  saveProbeState();
  saveJson(HANDLED_FILE, [...handledIds]);
  // Браузер закрываем не дольше 3 секунд, чтобы остановка не зависала.
  await withTimeout(Promise.all([...new Set(lanes.map((lane) => lane.shared || lane))].map((lane) => closeOlxSession(lane).catch(() => {}))), 3_000, null);
  console.log('✅ Остановлено. Прогресс сохранён — можно запускать новую версию.');
  process.exit(0);
}

if (require.main === module) {
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
  process.on('unhandledRejection', (error) => {
    if (!shuttingDown) console.error(`[unhandledRejection] ${error?.stack || error}`);
  });
  main();
}

module.exports = { alertPending, pendingAlerted, buildMessage, laneWorker, parseProxy, lanes, explainNumber, detectCarCategories, pollUpdates, subscribers, recipients, probeIntervalMs, olx, cars, probe, stats, handledIds, priceUsd, looksLikeOurCar, buildMessage, handleAd, probeTick, listSweep, onProbeHit };
