# Собирает story/i18n/strings.tsv (ru → en → uz) из tr_*.py и проверяет: каждый ключ есть в коде (или в записках,
# или в названиях комнат), в переводах нет кириллицы, плейсхолдеры %d/%s совпадают.
# Запуск из папки игры: python3 tools/i18n/build_tsv.py
import os, re, glob, json, sys
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
import tr_ui, tr_lines, tr_notes_rooms
root = os.path.join(here, "..", "..")
src = ""
for f in glob.glob(os.path.join(root, "story", "*.gd")) + glob.glob(os.path.join(root, "sanatorium", "scripts", "*.gd")):
    src += open(f, encoding="utf-8").read()
rooms = {r["name"] for r in json.load(open(os.path.join(root, "sanatorium", "assets", "level.json")))["rooms"]}
rows, bad = [], 0
cyr = re.compile("[А-Яа-яЁё]")
for table, kind in [(tr_ui.T, "code"), (tr_lines.T, "code"), (tr_notes_rooms.NOTES, "note"), (tr_notes_rooms.ROOMS, "room")]:
    for ru, (en, uz) in table.items():
        if kind == "code" and '"' + ru + '"' not in src:
            print("НЕТ В КОДЕ:", ru); bad += 1
        if kind == "room" and ru not in rooms:
            print("НЕТ КОМНАТЫ:", ru); bad += 1
        for t in (en, uz):
            if cyr.search(t):
                print("КИРИЛЛИЦА В ПЕРЕВОДЕ:", t); bad += 1
            if sorted(re.findall(r"%[ds]", t)) != sorted(re.findall(r"%[ds]", ru)):
                print("ПЛЕЙСХОЛДЕРЫ:", ru, "→", t); bad += 1
        rows.append((ru, en, uz))
for r in sorted(rooms - set(tr_notes_rooms.ROOMS)):
    print("КОМНАТА БЕЗ ПЕРЕВОДА:", r)
out = os.path.join(root, "story", "i18n", "strings.tsv")
with open(out, "w", encoding="utf-8") as f:
    f.write("ru\ten\tuz\n")
    for ru, en, uz in rows:
        f.write(f"{ru}\t{en}\t{uz}\n")
print(len(rows), "строк →", out, "| ошибок:", bad)
