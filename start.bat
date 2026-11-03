@echo off
rem Запускает игру на http://localhost:8080 (нужен Python 3: python.org)
cd /d "%~dp0"
start "" http://localhost:8080
python -m http.server 8080
if errorlevel 1 py -m http.server 8080
pause
