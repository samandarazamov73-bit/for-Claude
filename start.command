#!/bin/sh
# Дорога — запуск через локальный сервер (Mac).
# Нужен ТОЛЬКО чтобы подключить свои модели/текстуры/звуки из папки assets/.
# Просто поиграть — двойной щелчок по index.html.
cd "$(dirname "$0")" || exit 1
PORT=8080
if command -v python3 >/dev/null 2>&1; then
  echo "Игра: http://localhost:$PORT   (закрыть — Ctrl+C или закрыть это окно)"
  (sleep 1; open "http://localhost:$PORT") &
  python3 -m http.server $PORT
else
  echo "Нужен Python 3 (python.org). Без него просто открой index.html двойным щелчком."
  read -r _
fi
