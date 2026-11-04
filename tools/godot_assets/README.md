# Инструменты для моделей начала игры (Godot)

Не нужны, чтобы играть. Нужны, чтобы пересобрать модели.

- `source/liaz677_bus.html` — исходная страница автобуса ЛиАЗ-677 (от автора игры).
- `export_bus.js` — открывает страницу в браузере без окна (Playwright) и нажимает «Download .GLB».
- `prep_bus.py` — готовит выгрузку для Godot: поворот (нос в −Z, двери в +X), прозрачные стёкла,
  без ламп, PNG → JPG, метки `anchor_wheelchair`, `anchor_mom`, `anchor_driver`, `seat_NN_*`.
- `people_gen.js` + `people_page.js` + `people.html` + `people.js` — генератор лоу-поли людей:
  мама, водитель, пассажиры (Ташкент, 1975). Состав и внешность — в `people_page.js` (`ROSTER`).

Порядок (нужны Node.js, `npm i three@0.160.0 playwright`, Python с Pillow):
1. Положи `three` в `www/three`, страницы — в `www/` (как в `people.html`), запусти `node export_bus.js out/liaz.glb`.
2. `python3 prep_bus.py out/liaz.glb ../../godot_intro/intro/assets/models/bus.glb`
3. `node people.js out/people` и скопируй `*.glb` в `godot_intro/intro/assets/models/people/`.
