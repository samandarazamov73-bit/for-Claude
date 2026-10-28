#!/bin/bash
set -euo pipefail

OLD=/root/olx-bot-v6
NEW=/root/apartments-bot
REV=beab31c3aadd1bdd6fdab45df5cd2ce9c0f84b5d
RAW=https://raw.githubusercontent.com/samandarazamov73-bit/for-Claude/$REV/apartments-bot
TG=${TG_API:-https://api.telegram.org}
DATA_FILES="users.json pending.json channels.json stats.json state.json seen_ads.json recent_ads.json authors.json maklers.json checked_authors.json olx_probe.json olx-session.json"
export DEBIAN_FRONTEND=noninteractive

step() { echo; echo "▶ $*"; }
fail() { echo; echo "❌ $*"; echo "Старый бот не тронут и продолжает работать."; exit 1; }
username() {
  local reply
  reply=$(curl -s --max-time 15 "$TG/bot$1/getMe" || true)
  if [[ $reply =~ \"username\":\"([^\"]+)\" ]]; then echo "${BASH_REMATCH[1]}"; fi
}

step "1/8 Проверяю старый бот"
[ -f "$OLD/index.js" ] && [ -f "$OLD/.env" ] && [ -f "$OLD/users.json" ] || fail "Не нашёл старый бот в $OLD"
for var in TELEGRAM_TOKEN ADMIN_TOKEN ADMIN_CHAT_ID GEMINI_API_KEY CARD_NUMBER CARD_NAME; do
  grep -qE "^[[:space:]]*(export[[:space:]]+)?$var[[:space:]]*=[[:space:]]*[^[:space:]]" "$OLD/.env" || fail "В $OLD/.env нет $var"
done
OLD_TOKEN=$(grep -E '^[[:space:]]*(export[[:space:]]+)?TELEGRAM_TOKEN[[:space:]]*=' "$OLD/.env" | head -1 | cut -d= -f2- | tr -d "\"' \r")
OLD_NAME=$(username "$OLD_TOKEN")
[ -n "$OLD_NAME" ] || fail "Не удалось проверить токен старого бота"
echo "Старый бот: @$OLD_NAME"
echo "Пользователей: $(node -e "console.log(Object.keys(require('$OLD/users.json')).length)" 2>/dev/null || echo '?')"
[ -e "$NEW" ] && fail "Папка $NEW уже есть — похоже, скрипт уже запускали. Напиши Claude, что вывел скрипт."

step "2/8 Новый бот"
NEW_TOKEN=${NEW_BOT_TOKEN:-}
if [ -z "$NEW_TOKEN" ]; then
  read -rsp "Вставь токен НОВОГО бота от @BotFather (символы не видны) и нажми Enter: " NEW_TOKEN
  echo
fi
NEW_TOKEN=$(echo "$NEW_TOKEN" | tr -d "\"' \r")
[ "$NEW_TOKEN" != "$OLD_TOKEN" ] || fail "Это токен старого бота, нужен токен нового"
NEW_NAME=$(username "$NEW_TOKEN")
[ -n "$NEW_NAME" ] || fail "Токен нового бота не подходит — проверь его в @BotFather"
curl -s --max-time 15 "$TG/bot$NEW_TOKEN/deleteWebhook" >/dev/null || true
UPDATES=$(curl -s --max-time 15 "$TG/bot$NEW_TOKEN/getUpdates?limit=1&timeout=0" || true)
if [[ $UPDATES == *'"error_code":409'* ]]; then
  fail "Новый бот @$NEW_NAME уже где-то запущен (например, на Mac). Останови его там и запусти скрипт снова."
fi
echo "Новый бот: @$NEW_NAME"

step "3/8 Скачиваю новый код"
mkdir -p "$NEW"
for file in index.js package.json farewell.js; do
  curl -fsSL "$RAW/$file" -o "$NEW/$file" || { rm -rf "$NEW"; fail "Не скачался $file"; }
done
printf '%s\n' "7648773c2c107a34274ef45c861239da  $NEW/index.js" "a8284ef762caa91762471716e2c7370e  $NEW/farewell.js" | md5sum -c - || { rm -rf "$NEW"; fail "Файлы скачались с ошибкой"; }

step "4/8 Ставлю зависимости и Chromium (старый бот пока работает)"
cd "$NEW"
npm install --no-audit --no-fund || { rm -rf "$NEW"; fail "npm install не прошёл"; }
npx playwright install --with-deps chromium || { rm -rf "$NEW"; fail "Chromium не установился"; }

step "5/8 Останавливаю старый бот и переношу данные"
pm2 stop olx-bot-v6
sleep 3
for file in $DATA_FILES; do
  if [ -f "$OLD/$file" ]; then cp -p "$OLD/$file" "$NEW/" && echo "  ✓ $file"; fi
done
grep -vE '^[[:space:]]*(export[[:space:]]+)?TELEGRAM_TOKEN[[:space:]]*=' "$OLD/.env" > "$NEW/.env"
echo "TELEGRAM_TOKEN=$NEW_TOKEN" >> "$NEW/.env"
chmod 600 "$NEW/.env"
echo "  ✓ .env (с токеном @$NEW_NAME)"

step "6/8 Запускаю новый бот @$NEW_NAME и проверяю его (60 сек)"
cd "$NEW"
pm2 start "$NEW/index.js" --name apartments-bot --cwd "$NEW" --kill-timeout 5000
sleep 60
STATUS=$(pm2 jlist | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const p=JSON.parse(s).find(x=>x.name==='apartments-bot');console.log(p?p.pm2_env.status+' '+p.pm2_env.restart_time:'missing 0')})")
echo "Статус: $STATUS"
pm2 logs apartments-bot --lines 25 --nostream
if [ "${STATUS%% *}" != "online" ] || [ "${STATUS##* }" -gt 2 ]; then
  echo
  echo "⚠️ Новый бот не запустился нормально — возвращаю старый. Рассылка НЕ отправлялась."
  pm2 delete apartments-bot || true
  pm2 start olx-bot-v6
  mv "$NEW" "$NEW-failed-$(date +%Y%m%d-%H%M)"
  exit 1
fi

step "7/8 Отключаю старый бот и удаляю его файлы (нужные сохраняю)"
pm2 delete olx-bot-v6
BACKUP="/root/old-bot-backup-$(date +%Y%m%d-%H%M)"
mkdir -p "$BACKUP"
for file in .env package.json $DATA_FILES; do
  if [ -f "$OLD/$file" ]; then cp -p "$OLD/$file" "$BACKUP/"; fi
done
find "$OLD" -maxdepth 1 -type f -name '*.js' -exec cp -p {} "$BACKUP/" \;
echo "Сохранено в $BACKUP: $(ls -A "$BACKUP" | wc -l) файлов, $(du -sh "$BACKUP" | cut -f1) — данные, .env и скрипты старого бота"
FREED=$(du -sh "$OLD" | cut -f1)
rm -rf "$OLD"
rm -f /root/.pm2/logs/olx-bot-v6-*.log
(cd "$NEW" && npx playwright install chromium >/dev/null 2>&1) || true
echo "Удалено: папка старого бота ($FREED), его логи и его старый Chromium"
pm2 start "$NEW/farewell.js" --name old-bot-redirect --cwd "$NEW" -- "$BACKUP" "$NEW_NAME"
pm2 save
pm2 startup systemd -u root --hp /root >/dev/null 2>&1 || true

step "8/8 Файл для отката"
cat > /root/rollback-old-bot.sh <<EOF
#!/bin/bash
set -e
pm2 stop apartments-bot old-bot-redirect || true
mkdir -p "$OLD"
cp -a "$BACKUP/." "$OLD/"
for file in users.json pending.json channels.json stats.json state.json; do
  [ -f "$NEW/\$file" ] && cp -p "$NEW/\$file" "$OLD/"
done
cd "$OLD"
if [ -f package.json ]; then npm install --no-audit --no-fund; else npm install --no-audit --no-fund playwright dotenv; fi
npx playwright install chromium
pm2 delete apartments-bot old-bot-redirect || true
pm2 start index.js --name olx-bot-v6
pm2 save
echo "✅ Старый бот @$OLD_NAME возвращён и запущен, новый остановлен."
EOF
chmod +x /root/rollback-old-bot.sh
sleep 15
pm2 logs old-bot-redirect --lines 10 --nostream
echo
echo "✅ Готово."
echo "   Новый бот: @$NEW_NAME — работает (pm2 logs apartments-bot)."
echo "   Старый бот @$OLD_NAME: старый скрипт удалён, вместо него маленький процесс рассылает"
echo "   пользователям ссылку на новый бот и дальше отвечает ею на любые сообщения."
echo "   Итог рассылки придёт в админ-бот. Нужные файлы старого бота: $BACKUP"
