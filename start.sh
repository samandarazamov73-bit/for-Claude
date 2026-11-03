#!/usr/bin/env sh
# Запускает игру на http://localhost:8080 (нужен Python 3).
cd "$(dirname "$0")"
echo "Игра: http://localhost:8080   (остановить: Ctrl+C)"
if command -v python3 >/dev/null 2>&1; then python3 -m http.server 8080; else python -m http.server 8080; fi
