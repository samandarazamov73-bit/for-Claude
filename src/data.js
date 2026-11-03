// Мост между редактируемыми файлами (src/config.js, src/story.js — обычные скрипты,
// подключаются в index.html раньше игры) и модулями игры.
if (!window.STORY || !window.GAME_CONFIG) {
  throw new Error('Не загрузились src/config.js или src/story.js — проверь, что они рядом с index.html и без ошибок.');
}
export const STORY = window.STORY;
export const CONFIG = window.GAME_CONFIG;
