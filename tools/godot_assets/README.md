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

## Люди автора (мама и пассажиры)
`prep_people.py` (+ `glbmesh.py`) готовит модели автора: вырезает «табуретки» (ровные коробки под сидящими),
переводит в метры, поворачивает лицом в −Z, ставит начало координат на сиденье (сидящие) или на пол (мама),
сжимает текстуру в JPG и отделяет у мамы голени ниже подола (узлы `LegL` / `LegR`) для шага.
Запуск: `python3 prep_people.py <папка с scripts/glbmesh.py и up2/*.glb> <куда сохранить>`.

## Скелет мамы (Blender)
`rig_mom.py` — запускается Python-модулем Blender (`pip install bpy==4.2.0`, нужен Python 3.11):
`python rig_mom.py <мама автора.glb> <выход.glb>`. Ставит 19 костей по замерам модели, считает веса
(автоматически, как Blender «With Automatic Weights»), разрезает сросшиеся туфли, делает анимации
`hold_loop` (правая рука на верхнем поручне), `idle_loop`, `walk_loop`.
Потом `strip_anim.py <вход.glb> <выход.glb>` убирает из анимаций кости шеи и головы — их поворачивает игра.

## Превью леса
`preview/forest_scene.py` + `preview/forest.html` + `preview/forest_shot.js` — та же дорога, деревья и свет,
что в игре, но в браузере (three.js). Нужны для снимков, игре не нужны.

## «The Last Shake»: персонажи и вход в санаторий
- `merge_chars.py` склеивает анимации персонажа в один GLB. Окончание имени `@секунда` (например
  `mom_injection.glb::idle_loop@0`) делает **спокойную стойку**: поза из этого кадра замирает, голова прямо,
  остаётся только еле заметное дыхание (цикл 8 с без шва). Команды, которыми собраны `characters/*.glb`:
  ```
  python3 merge_chars.py mom.glb mom_walk.glb mom_walk.glb::walk_loop mom_injection.glb::inject "mom_fall.glb::fall+root" "mom_injection.glb::idle_loop@0" grandpa_talk.glb::talk_loop psycho_hit.glb::attack psycho_run.glb:Running:run_loop
  python3 merge_chars.py psycho.glb psycho_run.glb psycho_run.glb:Running:run_loop psycho_run.glb:Walking:walk_loop psycho_hit.glb::hit psycho_run.glb:run_fast_10:sprint_loop "grandpa_stand.glb::idle_loop@2.4" grandpa_talk.glb::talk_loop
  python3 merge_chars.py grandpa.glb grandpa_stand.glb "grandpa_stand.glb::idle_loop@2.4" grandpa_talk.glb::talk_loop grandpa_run.glb::run_loop grandpa_push.glb::push grandpa_walk_slow.glb::walk_loop psycho_hit.glb::hit "mom_fall.glb::fall+root"
  ```
- `make_entrance_route.py <the_last_shake>` — маршрут коляски от конца тропинки вверх по пандусу (с разворотом)
  к входной двери и в тамбур, высоты — с поверхности пандуса из `sanatorium.glb`
  (→ `resources/world/entrance_route.json`).
