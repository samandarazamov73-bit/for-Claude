"""Fixed pictures (fix_pics / fix_dial / make_citramon output) → sanatorium/assets/pics/.
Prints with transparency stay PNG, the rest become JPG. Paintings also keep their normal map (brush strokes)."""
import sys, os
from PIL import Image

SRC, DST = sys.argv[1], sys.argv[2]
ALPHA = {"fire_label", "chess_board", "med_boxes", "dials", "phone_dial", "radio_front", "clock_face", "tv_badge",
         "electro_sign", "key_tag", "notices", "med_citramon"}
NORMAL = {"painting_1", "painting_2", "painting_3", "mosaic"}
MAX = 1536
os.makedirs(DST, exist_ok=True)
for pid in sorted(os.listdir(SRC)):
    d = os.path.join(SRC, pid)
    if not os.path.isdir(d) or pid.startswith("_"):
        continue
    im = Image.open(os.path.join(d, "albedo.png"))
    k = min(1.0, MAX / max(im.size))
    size = (max(4, int(im.width * k) // 4 * 4), max(4, int(im.height * k) // 4 * 4))
    if pid in ALPHA:
        im.convert("RGBA").resize(size, Image.LANCZOS).save(os.path.join(DST, pid + ".png"), optimize=True)
    else:
        im.convert("RGB").resize(size, Image.LANCZOS).save(os.path.join(DST, pid + ".jpg"), quality=92, subsampling=0)
    if pid in NORMAL:
        n = Image.open(os.path.join(d, "normal_gl.png")).convert("RGB").resize(size, Image.LANCZOS)
        n.save(os.path.join(DST, pid + "_normal.jpg"), quality=94, subsampling=0)
    print(pid, size)
