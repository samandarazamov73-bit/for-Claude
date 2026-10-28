'use strict';

const fs = require('fs');
const path = require('path');

const [oldDir, newBotArg] = process.argv.slice(2);
if (!oldDir || !newBotArg) {
  console.error('Запуск: node farewell.js <папка старого бота> <username нового бота>');
  process.exit(1);
}
const NEW_BOT = newBotArg.replace(/^@/, '');
const NEW_LINK = `https://t.me/${NEW_BOT}?start=moved`;
const API = process.env.TG_API || 'https://api.telegram.org';
const PROGRESS_FILE = path.join(oldDir, 'farewell-progress.json');
const BATCH = 20;

function readEnv(file) {
  const env = {};
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const match = line.match(/^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$/);
    if (match) env[match[1]] = match[2].trim().replace(/^(['"])(.*)\1$/, '$2');
  }
  return env;
}

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

const env = readEnv(path.join(oldDir, '.env'));
const OLD_TOKEN = env.TELEGRAM_TOKEN;
if (!OLD_TOKEN) {
  console.error(`В ${oldDir}/.env нет TELEGRAM_TOKEN`);
  process.exit(1);
}
const users = readJson(path.join(oldDir, 'users.json'), {});
const channels = readJson(path.join(oldDir, 'channels.json'), {});
const progress = readJson(PROGRESS_FILE, { done: false, sent: [], unreachable: [], failed: [] });

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function tg(token, method, body, attempts = 3) {
  for (let attempt = 1; ; attempt += 1) {
    try {
      const response = await fetch(`${API}/bot${token}/${method}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(method === 'getUpdates' ? 40_000 : 15_000)
      });
      const json = await response.json().catch(() => ({}));
      if (json.ok) return json.result;
      const retryAfter = Number(json.parameters?.retry_after);
      if (response.status === 429 && retryAfter && attempt < attempts) {
        await sleep((retryAfter + 1) * 1000);
        continue;
      }
      throw new Error(json.description || `HTTP ${response.status}`);
    } catch (error) {
      if (attempt >= attempts || /Forbidden|chat not found|deactivated|Bad Request/i.test(error.message)) throw error;
      await sleep(2_000 * attempt);
    }
  }
}

function dateOf(until) {
  const time = Date.parse(until);
  return Number.isFinite(time) && time > Date.now() ? new Date(time).toLocaleDateString('ru-RU', { timeZone: 'Asia/Tashkent' }) : null;
}

const TEXTS = {
  ru: {
    title: '📢 <b>Бот переехал!</b>',
    body: `Этот бот больше не работает. Новые квартиры теперь приходят в новый бот: @${NEW_BOT}`,
    kept: (until) => `✅ Ваши настройки поиска${until ? ` и подписка до <b>${until}</b>` : ''} уже перенесены — откройте новый бот и нажмите «Старт».`,
    channel: (name) => `📢 Ваш канал «${name}»: добавьте @${NEW_BOT} в администраторы канала, чтобы объявления в нём продолжали выходить.`,
    button: '➡️ Перейти в новый бот',
    about: `⚠️ Этот бот больше не работает. Новый бот: @${NEW_BOT}`
  },
  uz: {
    title: '📢 <b>Bot ko‘chdi!</b>',
    body: `Bu bot endi ishlamaydi. Yangi kvartiralar endi yangi botga keladi: @${NEW_BOT}`,
    kept: (until) => `✅ Qidiruv sozlamalaringiz${until ? ` va obuna (<b>${until}</b> gacha)` : ''} allaqachon ko‘chirildi — yangi botni oching va «Start» tugmasini bosing.`,
    channel: (name) => `📢 «${name}» kanalingiz: e’lonlar chiqishda davom etishi uchun @${NEW_BOT} ni kanal administratorlariga qo‘shing.`,
    button: '➡️ Yangi botga o‘tish',
    about: `⚠️ Bu bot endi ishlamaydi. Yangi bot: @${NEW_BOT}`
  }
};

const escapeHtml = (value) => String(value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

function messageFor(chatId) {
  const user = users[chatId] || {};
  const t = TEXTS[user.lang === 'uz' ? 'uz' : 'ru'];
  const parts = [t.title, t.body];
  if (user.role) parts.push(t.kept(dateOf(user.until)));
  for (const channel of Object.values(channels)) {
    if (channel && String(channel.ownerId) === String(chatId)) parts.push(t.channel(escapeHtml(channel.name || 'канал')));
  }
  return {
    chat_id: chatId,
    text: parts.join('\n\n'),
    parse_mode: 'HTML',
    reply_markup: { inline_keyboard: [[{ text: t.button, url: NEW_LINK }]] }
  };
}

function genericMessage(chatId, lang) {
  const t = TEXTS[lang === 'uz' ? 'uz' : 'ru'];
  return {
    chat_id: chatId,
    text: `${t.title}\n\n${t.body}`,
    parse_mode: 'HTML',
    reply_markup: { inline_keyboard: [[{ text: t.button, url: NEW_LINK }]] }
  };
}

function saveProgress() {
  fs.writeFileSync(PROGRESS_FILE, JSON.stringify(progress));
}

async function setProfile() {
  for (const [lang, t] of [['', TEXTS.ru], ['ru', TEXTS.ru], ['uz', TEXTS.uz]]) {
    const language = lang ? { language_code: lang } : {};
    await tg(OLD_TOKEN, 'setMyShortDescription', { short_description: t.about, ...language }).catch((error) => console.error(`[Профиль] ${error.message}`));
    await tg(OLD_TOKEN, 'setMyDescription', { description: t.about, ...language }).catch((error) => console.error(`[Профиль] ${error.message}`));
    await tg(OLD_TOKEN, 'deleteMyCommands', { ...language }).catch(() => {});
  }
}

async function broadcast() {
  if (progress.done) {
    console.log(`Рассылка уже была: доставлено ${progress.sent.length}.`);
    return;
  }
  const handled = new Set([...progress.sent, ...progress.unreachable, ...progress.failed].map(String));
  const targets = Object.keys(users).filter((id) => /^\d+$/.test(id) && users[id] && !users[id].blockedAt && !handled.has(id));
  console.log(`📣 Рассылка о переезде: ${targets.length} пользователей.`);
  for (let index = 0; index < targets.length; index += BATCH) {
    const batch = targets.slice(index, index + BATCH);
    await Promise.all(batch.map(async (chatId) => {
      try {
        await tg(OLD_TOKEN, 'sendMessage', messageFor(chatId));
        progress.sent.push(chatId);
      } catch (error) {
        if (/blocked|deactivated|chat not found|initiate conversation/i.test(error.message)) progress.unreachable.push(chatId);
        else {
          progress.failed.push(chatId);
          console.error(`[Рассылка] ${chatId}: ${error.message}`);
        }
      }
    }));
    saveProgress();
    if ((index / BATCH) % 10 === 0) console.log(`  ${Math.min(index + BATCH, targets.length)} из ${targets.length}`);
    await sleep(1_000);
  }
  progress.done = true;
  saveProgress();
  const summary = `📣 <b>Рассылка о переезде в @${NEW_BOT} закончена</b>\n\n✅ Доставлено: ${progress.sent.length}\n🚫 Заблокировали старый бот: ${progress.unreachable.length}\n⚠️ Ошибки: ${progress.failed.length}\n\nСтарый бот теперь на любое сообщение отвечает ссылкой на новый.`;
  console.log(summary.replace(/<[^>]+>/g, ''));
  if (env.ADMIN_TOKEN && env.ADMIN_CHAT_ID) await tg(env.ADMIN_TOKEN, 'sendMessage', { chat_id: env.ADMIN_CHAT_ID, text: summary, parse_mode: 'HTML' }).catch(() => {});
}

const lastReply = new Map();

async function answerUpdate(update) {
  const callback = update.callback_query;
  const message = update.message;
  const from = callback?.from || message?.from;
  const chat = callback?.message?.chat || message?.chat;
  if (!from || chat?.type !== 'private') return;
  const lang = users[String(from.id)]?.lang || (String(from.language_code || '').startsWith('uz') ? 'uz' : 'ru');
  if (callback) await tg(OLD_TOKEN, 'answerCallbackQuery', { callback_query_id: callback.id, text: TEXTS[lang === 'uz' ? 'uz' : 'ru'].about, show_alert: true }, 1).catch(() => {});
  const now = Date.now();
  if (now - (lastReply.get(from.id) || 0) < 10_000) return;
  lastReply.set(from.id, now);
  await tg(OLD_TOKEN, 'sendMessage', genericMessage(from.id, lang), 1).catch(() => {});
}

async function redirectLoop() {
  let offset = 0;
  console.log(`↪️ Старый бот отвечает на сообщения ссылкой на @${NEW_BOT}.`);
  while (true) {
    try {
      const updates = await tg(OLD_TOKEN, 'getUpdates', { offset, timeout: 25, allowed_updates: ['message', 'callback_query'] }, 1);
      for (const update of updates || []) {
        offset = update.update_id + 1;
        await answerUpdate(update).catch((error) => console.error(`[Ответ] ${error.message}`));
      }
      if (lastReply.size > 10_000) lastReply.clear();
    } catch (error) {
      console.error(`[Старый бот] ${error.message}`);
      await sleep(10_000);
    }
  }
}

(async () => {
  await setProfile();
  const loop = redirectLoop();
  await broadcast().catch((error) => console.error(`[Рассылка] ${error.stack || error.message}`));
  await loop;
})();
