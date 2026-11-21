"""Цитрамон box for the pharmacy kiosk scene, made from the Анальгин box of the user's medicine sheet."""
import sys, os, numpy as np, cv2
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage as ndi

SRC, OUT = sys.argv[1], sys.argv[2]           # fixed/pics/med_boxes, fixed/pics/med_citramon
MAPS = ("albedo", "normal_gl", "height", "roughness", "ao", "orm")
BOX = (22, 10, 780, 292)                     # the Анальгин box on the sheet
TITLE = (268, 60, 730, 130)                  # its red title
ims = {m: np.asarray(Image.open(os.path.join(SRC, m + ".png")).crop(BOX)).copy() for m in MAPS}
rgb = ims["albedo"][..., :3].astype(np.int16)
x0, y0, x1, y1 = (TITLE[0] - BOX[0], TITLE[1] - BOX[1], TITLE[2] - BOX[0], TITLE[3] - BOX[1])
red = (rgb[..., 0] - rgb[..., 1] > 55) & (rgb[..., 0] - rgb[..., 2] > 55)
tm = np.zeros(red.shape, bool); tm[y0:y1, x0:x1] = red[y0:y1, x0:x1]
tm = ndi.binary_dilation(tm, iterations=3)
ys, xs = np.nonzero(tm); tb = (xs.min(), ys.min(), xs.max(), ys.max())
strong = tm & (rgb[..., 0] - rgb[..., 1] > 90)
ink_col = np.median(rgb[strong], axis=0)
print("title bbox", tb, "ink", ink_col)
mask = tm.astype(np.uint8) * 255
# relief/roughness change of the print, to repeat it on the new word
core = ndi.binary_erosion(tm, iterations=4); ring = ndi.binary_dilation(tm, iterations=6) & ~tm
delta = {}
for m in ("height", "roughness", "ao"):
    v = ims[m].astype(np.float32); v = v if v.ndim == 2 else v[..., 0]
    delta[m] = v[core].mean() - v[ring].mean()
# erase the old word in every map; restore the paper grain on the albedo from a clean strip below it
paper = ims["albedo"][..., :3].astype(np.float32)
for m in MAPS:
    arr = ims[m][..., :3] if (m == "albedo" and ims[m].ndim == 3 and ims[m].shape[2] == 4) else ims[m]
    out = cv2.inpaint(np.ascontiguousarray(arr), mask, 7, cv2.INPAINT_TELEA)
    if m == "albedo":
        hf = paper - cv2.GaussianBlur(paper, (0, 0), 3)
        src = np.roll(hf, 0, 0)
        # grain from the paper just above the title (same paper, no print), tiled over the erased area
        gy0 = max(tb[1] - 46, 0); strip = hf[gy0:gy0 + 40, tb[0]:tb[2]]
        reps = int(np.ceil((tb[3] - tb[1] + 10) / 40)) + 1
        tile = np.concatenate([strip] * reps, 0)[:tb[3] - tb[1] + 1]
        g = np.zeros_like(hf); g[tb[1]:tb[3] + 1, tb[0]:tb[2]] = tile
        w = (mask > 0)[..., None]
        out = np.clip(out.astype(np.float32) + g * w, 0, 255).astype(np.uint8)
        ims[m] = np.dstack([out, ims[m][..., 3]]) if ims[m].shape[2] == 4 else out
    else:
        ims[m] = out
# new word, same box and weight
font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSerif-Bold.ttf", 120)
word = "ЦИТРАМОН"
tmp = Image.new("L", (1400, 220), 0); d = ImageDraw.Draw(tmp); d.text((10, 10), word, font=font, fill=255)
bb = tmp.getbbox(); tmp = tmp.crop(bb)
tw, th = tb[2] - tb[0] + 1, tb[3] - tb[1] + 1
tmp = tmp.resize((tw - 8, th - 8), Image.LANCZOS)
ink = np.zeros(red.shape, np.float32); ink[tb[1] + 4:tb[1] + 4 + tmp.height, tb[0] + 4:tb[0] + 4 + tmp.width] = np.asarray(tmp, np.float32) / 255
ink = ndi.gaussian_filter(ink, 0.6)
a = ims["albedo"]; c = a[..., :3].astype(np.float32)
paperL = c.mean(-1, keepdims=True) / max(c.mean(), 1)
inked = ink_col[None, None, :] * (0.85 + 0.15 * paperL)
c = c * (1 - ink[..., None] * 0.96) + inked * ink[..., None] * 0.96
ims["albedo"] = np.dstack([np.clip(c, 0, 255).astype(np.uint8), a[..., 3]]) if a.shape[2] == 4 else np.clip(c, 0, 255).astype(np.uint8)
for m, dv in delta.items():
    v = ims[m].astype(np.float32)
    v = v + (ink * dv)[..., None] if v.ndim == 3 else v + ink * dv
    ims[m] = np.clip(v, 0, 255).astype(np.uint8)
orm = ims["orm"].copy()
orm[..., 0] = ims["ao"] if ims["ao"].ndim == 2 else ims["ao"][..., 0]
orm[..., 1] = ims["roughness"] if ims["roughness"].ndim == 2 else ims["roughness"][..., 0]
ims["orm"] = orm
os.makedirs(OUT, exist_ok=True)
for m in MAPS:
    Image.fromarray(ims[m]).save(os.path.join(OUT, m + ".png"))
print("saved", OUT, ims["albedo"].shape)
