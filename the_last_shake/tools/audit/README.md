# Обход здания ботом

1. Снять все комнаты (два угла каждого прямоугольника, длинные коридоры кусками по 8 м; второй кадр — маска):
   `godot --path . --rendering-driver vulkan --resolution 960x540 res://tests/shots.tscn -- --case=roomaudit --out=OUT --levels=0,1,2 [--cp=глава] [--rooms=L1.F2,…]`
   Маска: красное — видно другой этаж сквозь пол/потолок (ближе 9 м), синее — улица (окна — нормально, щели — нет).
2. Листы 3×3 и сводка: `python3 tools/audit/audit_sheets.py OUT SHEETS` → `SHEETS/sheet_NNN.jpg`, `SHEETS/report.txt`
   (RED — дыра в другой этаж, SLIT — тонкая синяя щель).
3. Где щель в здании: `python3 tools/audit/slit_locate.py OUT 028 216` (номера кадров).
4. Кадр и маска рядом: `python3 tools/audit/pairs.py OUT out.jpg 028 216`.

Ещё проверки (печатают список): `--case=floataudit` — что висит над опорой, `--case=clipaudit` — мебель друг в
друге, `--case=camviews --views="x,y,z>x,y,z;…"` — кадры свободной камерой.
