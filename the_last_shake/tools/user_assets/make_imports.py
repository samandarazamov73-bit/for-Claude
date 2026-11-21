"""Write Godot .import files for new images (VRAM-compressed, mipmaps — for 3D surfaces), so a fresh checkout
imports them right without the editor. Normal maps (*_normal.*) get the normal-map setting.
Usage: python3 make_imports.py <project root> <folder inside the project> [...]"""
import sys, os, re, hashlib

ROOT = sys.argv[1]
TPL = os.path.join(ROOT, "sanatorium/assets/tex/wall_tile_albedo.jpg.import")
TPL_N = os.path.join(ROOT, "sanatorium/assets/tex/wall_tile_normal.jpg.import")
for folder in sys.argv[2:]:
    for f in sorted(os.listdir(os.path.join(ROOT, folder))):
        if not re.search(r"\.(png|jpg|jpeg|webp)$", f, re.I):
            continue
        dst = os.path.join(ROOT, folder, f + ".import")
        if os.path.exists(dst):
            continue
        tpl = open(TPL_N if "_normal." in f else TPL).read()
        src_name = "wall_tile_normal.jpg" if "_normal." in f else "wall_tile_albedo.jpg"
        res = f"res://{folder}/{f}"
        h = hashlib.md5(res.encode()).hexdigest()
        t = tpl.replace(f"res://sanatorium/assets/tex/{src_name}", res).replace(src_name, f)
        t = re.sub(r"\.(jpg|png|jpeg|webp)-[0-9a-f]{32}\.", lambda m: f".{m.group(1)}-{h}.", t)
        t = re.sub(r'uid="uid://[^"]*"\n', "", t)
        open(dst, "w").write(t)
        print("import:", res)
