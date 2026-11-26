# Пары «кадр | маска» для выбранных номеров: pairs.py src out.jpg 028 043 ...
import sys, glob
from PIL import Image, ImageDraw, ImageFont
src, out, ids = sys.argv[1], sys.argv[2], sys.argv[3:]
font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 16)
tiles = []
for i in ids:
    f = sorted(g for g in glob.glob(f"{src}/{i}_*.jpg") if not g.endswith("_x.jpg"))[0]
    a = Image.open(f).convert("RGB").resize((640, 360)); x = Image.open(f[:-4] + "_x.jpg").convert("RGB").resize((640, 360))
    s = Image.new("RGB", (640, 720)); s.paste(a, (0, 0)); s.paste(x, (0, 360))
    d = ImageDraw.Draw(s); t = f.split("/")[-1][:-4]; d.rectangle([0, 0, d.textlength(t, font=font) + 8, 20], fill=(0, 0, 0)); d.text((4, 1), t, fill=(255, 230, 120), font=font)
    tiles.append(s)
W = Image.new("RGB", (640 * min(3, len(tiles)), 720 * ((len(tiles) + 2) // 3)))
for k, t in enumerate(tiles):
    W.paste(t, ((k % 3) * 640, (k // 3) * 720))
W.save(out, quality=82)
