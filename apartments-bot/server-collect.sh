#!/bin/bash
# Собирает код, настройки (без секретов), логи и сведения о сервере в один текстовый файл.

OUT="/root/server-dump-$(date +%Y%m%d-%H%M).txt"
MASK_SECRETS='s/[0-9]{8,10}:[A-Za-z0-9_-]{30,}/<токен бота скрыт>/g; s/AIza[0-9A-Za-z_-]{20,}/<ключ Google скрыт>/g; s/(\+?998)[ -]?[0-9]{2}[ -]?[0-9]{3}[ -]?[0-9]{2}[ -]?[0-9]{2}/<телефон скрыт>/g; s/\b[0-9]{4}[ -]?[0-9]{4}[ -]?[0-9]{4}[ -]?[0-9]{4}\b/<номер карты скрыт>/g'
MASK_IDS='s/\b[0-9]{9,10}\b/<tg-id>/g'

section() { printf '\n\n==================== %s ====================\n' "$*"; }

show_env() {
  local file=$1
  [ -f "$file" ] || return
  section "НАСТРОЙКИ $file (секреты скрыты)"
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      key=${BASH_REMATCH[2]}
      value=${BASH_REMATCH[3]}
      if [[ $key =~ TOKEN|KEY|SECRET|PASS|CARD|CHAT_ID|PROXIES|PROXY ]]; then
        echo "$key=<скрыто, ${#value} символов>"
      else
        echo "$key=$value"
      fi
    elif [[ $line =~ ^[[:space:]]*# || -z ${line// } ]]; then
      echo "$line"
    else
      echo "<строка без =, скрыта>"
    fi
  done < "$file"
}

summarize_json() {
  local file=$1
  node -e "
const fs=require('fs');const f=process.argv[1];let d;
try{d=JSON.parse(fs.readFileSync(f,'utf8'))}catch(e){console.log('  не читается как JSON:',e.message);process.exit(0)}
const size=fs.statSync(f).size;
if(Array.isArray(d)){console.log('  массив, элементов:',d.length,'· размер',size,'байт');process.exit(0)}
if(!d||typeof d!=='object'){console.log('  значение:',typeof d);process.exit(0)}
const vals=Object.values(d);const fields={};
for(const v of vals)if(v&&typeof v==='object'&&!Array.isArray(v))for(const k of Object.keys(v))fields[k]=(fields[k]||0)+1;
console.log('  записей:',vals.length,'· размер',size,'байт');
if(Object.keys(fields).length)console.log('  поля (сколько записей их имеют):',JSON.stringify(fields));
if(f.endsWith('users.json')){const now=Date.now();let act=0,blocked=0;const roles={},langs={},cats={},authors={};
for(const u of vals){if(!u||typeof u!=='object')continue;if(Date.parse(u.until)>now)act++;if(u.blockedAt)blocked++;roles[u.role||'-']=(roles[u.role||'-']||0)+1;langs[u.lang||'-']=(langs[u.lang||'-']||0)+1;
const c=u.filters&&u.filters.category||'-';cats[c]=(cats[c]||0)+1;const a=u.filters&&u.filters.author||'-';authors[a]=(authors[a]||0)+1;}
console.log('  активных подписок:',act,'· помечены «заблокировал / не открыл бот»:',blocked);
console.log('  роли:',JSON.stringify(roles),'· языки:',JSON.stringify(langs));
console.log('  категория в поиске:',JSON.stringify(cats),'· автор в поиске:',JSON.stringify(authors));}
" "$file" 2>&1
}

{
  echo "Снимок сервера $(hostname) — $(date '+%Y-%m-%d %H:%M:%S %Z')"

  section "СИСТЕМА"
  uname -a
  grep PRETTY_NAME /etc/os-release 2>/dev/null
  uptime
  echo "ядер: $(nproc)"
  free -h
  df -h /
  echo "node $(node -v 2>/dev/null) · npm $(npm -v 2>/dev/null) · pm2 $(pm2 -v 2>/dev/null | tail -1)"
  [ -f /var/run/reboot-required ] && echo "⚠️ система ждёт перезагрузки"

  section "PM2"
  pm2 list 2>/dev/null || echo "pm2 нет"

  section "ЗАПУСК ПРИ СТАРТЕ И CRON"
  systemctl is-enabled pm2-root 2>/dev/null | sed 's/^/pm2-root: /'
  crontab -l 2>/dev/null || echo "crontab пуст"
  systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | awk '{print $1}' | grep -viE "systemd|ssh|cron|dbus|snap|getty|udev|polkit|rsyslog|unattended|networkd|resolved|timesyncd|multipathd|qemu|droplet|do-agent|chrony|fwupd|udisks|Modem|packagekit|accounts|irqbalance|serial|user@|setvtrgb|apport|ufw"

  section "ФАЙЛЫ В /root (без node_modules и скрытых папок)"
  find /root -maxdepth 3 -not -path '*/node_modules*' -not -path '/root/.*' -printf '%TY-%Tm-%Td %TH:%TM  %10s  %p\n' 2>/dev/null | sort -k3 | head -400
  echo
  du -sh /root/* 2>/dev/null
  du -sh /root/.cache/ms-playwright/* 2>/dev/null

  for env in /root/*/.env; do show_env "$env"; done

  section "ДАННЫЕ (только счётчики и названия полей, без содержимого)"
  for json in /root/*/*.json; do
    case "$json" in *package.json|*package-lock.json) continue ;; esac
    echo "$json"
    summarize_json "$json"
  done

  section "УСТАНОВЛЕННЫЕ ПАКЕТЫ"
  for dir in /root/*/; do
    [ -f "$dir/package.json" ] || continue
    echo "$dir"
    (cd "$dir" && npm ls --depth=0 2>/dev/null | tail -n +2)
  done

  section "ЛОГ apartments-bot (последние 4000 строк вывода)"
  tail -n 4000 /root/.pm2/logs/apartments-bot-out.log 2>/dev/null
  section "ОШИБКИ apartments-bot (последние 1500 строк)"
  tail -n 1500 /root/.pm2/logs/apartments-bot-error.log 2>/dev/null
  section "ЛОГ old-bot-redirect (последние 200 строк)"
  tail -n 200 /root/.pm2/logs/old-bot-redirect-out.log /root/.pm2/logs/old-bot-redirect-error.log 2>/dev/null

  section "КОД"
  find /root -maxdepth 3 -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.sh' -o -name '*.py' -o -name 'package.json' -o -name '*.md' \) \
    -not -path '*/node_modules/*' -not -path '/root/.*' -not -name 'server-dump-*' 2>/dev/null | sort | while read -r file; do
    printf '\n\n----- ФАЙЛ %s (%s байт, изменён %s, md5 %s) -----\n' "$file" "$(stat -c %s "$file")" "$(stat -c %y "$file" | cut -d. -f1)" "$(md5sum "$file" | cut -d' ' -f1)"
    cat "$file"
  done
} 2>&1 | sed -E "$MASK_SECRETS" | sed -E "$MASK_IDS" > "$OUT"

echo "✅ Готово: $OUT ($(du -h "$OUT" | cut -f1))"
echo "Скачай его на Mac (в терминале Mac, не сервера):"
echo "  scp root@$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'):$OUT ~/Downloads/"
