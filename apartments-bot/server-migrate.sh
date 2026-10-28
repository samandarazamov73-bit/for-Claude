#!/bin/bash
set -euo pipefail

OLD=/root/olx-bot-v6
NEW=/root/apartments-bot
ARCHIVE=/root/old-bots-archive
REV=d463c9f213f8cc267826390075b5ef09bbf0848d
RAW=https://raw.githubusercontent.com/samandarazamov73-bit/for-Claude/$REV/apartments-bot
DATA_FILES=".env users.json pending.json channels.json stats.json state.json seen_ads.json recent_ads.json authors.json maklers.json checked_authors.json olx_probe.json olx-session.json"
export DEBIAN_FRONTEND=noninteractive

step() { echo; echo "▶ $*"; }
fail() { echo; echo "❌ $*"; echo "Старый бот не тронут и продолжает работать."; exit 1; }

step "1/7 Проверяю старый бот"
[ -f "$OLD/index.js" ] && [ -f "$OLD/.env" ] && [ -f "$OLD/users.json" ] || fail "Не нашёл старый бот в $OLD"
for var in TELEGRAM_TOKEN ADMIN_TOKEN ADMIN_CHAT_ID GEMINI_API_KEY CARD_NUMBER CARD_NAME; do
  grep -qE "^[[:space:]]*(export[[:space:]]+)?$var[[:space:]]*=[[:space:]]*[^[:space:]]" "$OLD/.env" || fail "В $OLD/.env нет $var"
done
TOKEN=$(grep -E '^[[:space:]]*(export[[:space:]]+)?TELEGRAM_TOKEN[[:space:]]*=' "$OLD/.env" | head -1 | cut -d= -f2- | tr -d "\"' \r")
echo "Бот: $(curl -s --max-time 10 "https://api.telegram.org/bot$TOKEN/getMe" | grep -o '"username":"[^"]*"' || echo 'не удалось узнать')"
echo "Пользователей в users.json: $(node -e "console.log(Object.keys(require('$OLD/users.json')).length)" 2>/dev/null || echo '?')"
echo "Старый index.js: $(md5sum "$OLD/index.js" | cut -d' ' -f1) (версия, с которой делался новый: 7f5e2790971e6b0e07c400645e434396)"
[ -e "$NEW" ] && fail "Папка $NEW уже есть — похоже, скрипт уже запускали. Напиши Claude, что вывел скрипт."

step "2/7 Скачиваю новый код"
mkdir -p "$NEW"
curl -fsSL "$RAW/index.js" -o "$NEW/index.js" || fail "Не скачался index.js"
curl -fsSL "$RAW/package.json" -o "$NEW/package.json" || fail "Не скачался package.json"
echo "0a0b8eb59298bd163936af2ab6995558  $NEW/index.js" | md5sum -c - || fail "index.js скачался с ошибкой"
node --check "$NEW/index.js" || fail "index.js не проходит проверку"

step "3/7 Ставлю зависимости и Chromium (старый бот пока работает)"
cd "$NEW"
npm install --no-audit --no-fund || fail "npm install не прошёл"
npx playwright install --with-deps chromium || fail "Chromium не установился"

step "4/7 Останавливаю старый бот"
pm2 stop olx-bot-v6
sleep 3

step "5/7 Переношу данные"
for file in $DATA_FILES; do
  if [ -f "$OLD/$file" ]; then cp -p "$OLD/$file" "$NEW/" && echo "  ✓ $file"; fi
done

step "6/7 Запускаю новый бот"
cd "$NEW"
pm2 start "$NEW/index.js" --name apartments-bot --cwd "$NEW" --kill-timeout 5000
pm2 delete olx-bot-v6
pm2 save
pm2 startup systemd -u root --hp /root >/dev/null 2>&1 || true

step "7/7 Убираю старый бот в архив"
mkdir -p "$ARCHIVE"
OLD_SAVED="$ARCHIVE/olx-bot-v6-$(date +%Y%m%d-%H%M)"
mv "$OLD" "$OLD_SAVED"
cat > /root/rollback-old-bot.sh <<EOF
#!/bin/bash
set -e
pm2 stop apartments-bot || true
for file in users.json pending.json channels.json stats.json state.json; do
  [ -f "$NEW/\$file" ] && cp -p "$NEW/\$file" "$OLD_SAVED/"
done
mv "$OLD_SAVED" "$OLD"
pm2 delete apartments-bot || true
cd "$OLD" && pm2 start index.js --name olx-bot-v6
pm2 save
echo "✅ Старый бот возвращён и запущен, новый остановлен."
EOF
chmod +x /root/rollback-old-bot.sh
echo "Старый бот лежит в $OLD_SAVED"
echo "Вернуть его: bash /root/rollback-old-bot.sh"

step "Проверяю, что новый бот работает (60 сек)"
sleep 60
STATUS=$(pm2 jlist | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const p=JSON.parse(s).find(x=>x.name==='apartments-bot');console.log(p?p.pm2_env.status+' '+p.pm2_env.restart_time:'missing 0')})")
echo "Статус: $STATUS"
pm2 logs apartments-bot --lines 30 --nostream
if [ "${STATUS%% *}" != "online" ] || [ "${STATUS##* }" -gt 2 ]; then
  echo
  echo "⚠️ Новый бот не запустился нормально — возвращаю старый."
  bash /root/rollback-old-bot.sh
  exit 1
fi
echo
echo "✅ Готово: новый бот работает. Лог: pm2 logs apartments-bot"
