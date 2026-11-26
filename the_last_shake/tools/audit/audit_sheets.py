# Листы обхода: кадр + подсветка (красное — видно другой этаж, синее — улица), 3×3 на лист; сводка по красному.
import sys, os, numpy as np
from scipy import ndimage
from PIL import Image, ImageDraw, ImageFont
src, dst = sys.argv[1], sys.argv[2]
os.makedirs(dst, exist_ok=True)
font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 17)
rows = [l.rstrip("\n").split("\t") for l in open(os.path.join(src, "manifest.txt")) if l.strip()]
W, H = 640, 360
tiles, report = [], []
for nm, rid, name, kind, pos in rows:
    a = np.asarray(Image.open(f"{src}/{nm}.jpg").convert("RGB")).astype(int)
    x = np.asarray(Image.open(f"{src}/{nm}_x.jpg").convert("RGB")).astype(int)
    red = (x[..., 0] > 90) & (x[..., 0] > 2 * x[..., 1] + 20) & (x[..., 0] > 2 * x[..., 2] + 20)
    blue = (x[..., 2] > 90) & (x[..., 2] > 1.6 * x[..., 0] + 20)
    thin = blue & ~ndimage.binary_opening(blue, structure=np.ones((7, 7)))
    lab, nl = ndimage.label(thin, structure=np.ones((3, 3)))
    sizes = ndimage.sum(thin, lab, range(1, nl + 1)) if nl else []
    big = [i + 1 for i, sz in enumerate(sizes) if sz >= 30]
    slit = np.isin(lab, big)
    o = a.copy()
    o[blue] = (o[blue] * 0.45 + np.array([0, 60, 255]) * 0.55).astype(int)
    o[red] = (o[red] * 0.3 + np.array([255, 0, 0]) * 0.7).astype(int)
    o[slit] = np.array([255, 0, 255])
    im = Image.fromarray(o.clip(0, 255).astype(np.uint8)).resize((W, H))
    d = ImageDraw.Draw(im)
    nr, nb, ns = int(red.sum()), int(blue.sum()), int(slit.sum())
    t = f"{nm.split('_')[0]} {rid} {name[:34]}" + (f"  RED {nr}" if nr > 40 else "") + (f"  SLIT {ns}" if ns else "")
    d.rectangle([0, 0, d.textlength(t, font=font) + 10, 24], fill=(0, 0, 0))
    d.text((5, 2), t, fill=(255, 90, 90) if nr > 40 else (255, 230, 120), font=font)
    tiles.append(im)
    report.append((nr, ns, nb, nm, rid, name, pos))
for i in range(0, len(tiles), 9):
    s = Image.new("RGB", (W * 3, H * 3))
    for j, t in enumerate(tiles[i:i + 9]):
        s.paste(t, ((j % 3) * W, (j // 3) * H))
    s.save(f"{dst}/sheet_{i // 9:03d}.jpg", quality=80)
with open(f"{dst}/report.txt", "w") as f:
    for r in sorted(report, reverse=True):
        f.write("%6d red %5d slit %7d blue  %s  %s  %s  %s\n" % r)
print(len(tiles), "views,", (len(tiles) + 8) // 9, "sheets")
