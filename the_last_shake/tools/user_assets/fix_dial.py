"""Rotary dial had 9 holes (no 9). Rebuild the ring with 10 holes 1-9,0 between the old 1 and 0 positions."""
import sys, os, numpy as np, cv2
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage as ndi

D = sys.argv[1]                      # fixed/pics/phone_dial
MAPS = ("albedo", "normal_gl", "height", "roughness", "ao", "orm")
ims = {m: np.asarray(Image.open(os.path.join(D, m + ".png"))).copy() for m in MAPS}
alb = ims["albedo"]; rgb = alb[..., :3].astype(np.float32); alpha = alb[..., 3]

# hole circles found with a Hough transform on the original (1, 2, 3, 4, 5, 6, 7, 8, 0)
holes = np.array([(762, 220), (570, 148), (370, 182), (220, 322), (148, 502), (182, 694), (296, 844), (482, 926), (684, 896)], np.float64)
A = np.c_[2 * holes, np.ones(len(holes))]; b = (holes ** 2).sum(1)
cx, cy, c = np.linalg.lstsq(A, b, rcond=None)[0]; rc = np.sqrt(c + cx ** 2 + cy ** 2)
ang = np.degrees(np.arctan2(-(holes[:, 1] - cy), holes[:, 0] - cx)) % 360
a1, a0 = ang[0], ang[-1]
print(f"ring centre ({cx:.1f},{cy:.1f}) r {rc:.1f}, 1 at {a1:.1f}°, 0 at {a0:.1f}°")
def pos(a): return cx + rc * np.cos(np.radians(a)), cy - rc * np.sin(np.radians(a))
old = [tuple(h) for h in holes]
new_ang = np.linspace(a1, a0, 10); new = [pos(a) for a in new_ang]
digits = "1234567890"

# 1) erase every old hole (all maps) by inpainting
H, W = alpha.shape
yy, xx = np.mgrid[:H, :W]
hole_r = 100
erase = np.zeros((H, W), np.uint8)
for (x, y) in old:
    erase[(xx - x) ** 2 + (yy - y) ** 2 < hole_r ** 2] = 255
def inpaint(arr, mask, r=12):
    if arr.ndim == 2:
        return cv2.inpaint(arr, mask, r, cv2.INPAINT_TELEA)
    return cv2.inpaint(np.ascontiguousarray(arr), mask, r, cv2.INPAINT_TELEA)

# 2) clean stamp from the "5" hole (old k=4), digit removed
sx, sy = old[4]; S = 116
def crop(arr, x, y): return arr[int(y) - S:int(y) + S, int(x) - S:int(x) + S].copy()
st_rgb = crop(rgb.astype(np.uint8), sx, sy)
L = st_rgb.mean(-1)
dig = ndi.binary_dilation(L < 110, iterations=5).astype(np.uint8) * 255
stamps = {}
for m in MAPS:
    arr = ims[m][..., :3] if m == "albedo" else ims[m]
    st = crop(arr, sx, sy)
    stamps[m] = inpaint(st, dig, 6)
# measure how the printed digit changes each map (to print the new digits the same way)
dmask = ndi.distance_transform_edt(L < 110) > 1.5
ring = ndi.binary_dilation(dmask, iterations=8) & ~ndi.binary_dilation(dmask, iterations=3)
delta = {}
for m in ("height", "roughness", "ao"):
    st = crop(ims[m] if ims[m].ndim == 2 else ims[m][..., 0], sx, sy).astype(np.float32)
    delta[m] = st[dmask].mean() - st[ring].mean()
print("digit deltas", {k: round(float(v), 1) for k, v in delta.items()})

for m in MAPS:
    arr = ims[m][..., :3] if m == "albedo" else ims[m]
    out = inpaint(np.ascontiguousarray(arr), erase, 14)
    if m == "albedo":
        ims[m] = np.dstack([out, alpha])
    else:
        ims[m] = out

# 3) paste the clean hole at the 10 new positions (scaled 0.95), soft circular mask
sc = 0.93
r_m = (hole_r - 4) * sc
k = np.arange(2 * S); X, Y = np.meshgrid(k, k)
for m in MAPS:
    st = stamps[m]
    st = cv2.resize(st, None, fx=sc, fy=sc, interpolation=cv2.INTER_AREA)
    n = st.shape[0]; c0 = (n - 1) / 2
    yy2, xx2 = np.mgrid[:n, :n]
    w = np.clip((r_m - np.hypot(xx2 - c0, yy2 - c0)) / 5.0 + 0.5, 0, 1)
    tgt = ims[m] if m != "albedo" else ims[m][..., :3]
    tgt = tgt.astype(np.float32)
    for (x, y) in new:
        x0, y0 = int(round(x - c0)), int(round(y - c0))
        reg = tgt[y0:y0 + n, x0:x0 + n]
        ww = w if reg.ndim == 2 else w[..., None]
        tgt[y0:y0 + n, x0:x0 + n] = reg * (1 - ww) + st.astype(np.float32) * ww
    if m == "albedo":
        ims[m] = np.dstack([np.clip(tgt, 0, 255).astype(np.uint8), alpha])
    else:
        ims[m] = np.clip(tgt, 0, 255).astype(np.uint8)

# 4) print digits: ink multiplies the albedo, and the same relief/roughness change as the original print
font = ImageFont.truetype("/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf", 118)
ink = Image.new("L", (W, H), 0); dr = ImageDraw.Draw(ink)
for d, (x, y) in zip(digits, new):
    bb = dr.textbbox((0, 0), d, font=font)
    dr.text((x - (bb[0] + bb[2]) / 2, y - (bb[1] + bb[3]) / 2), d, font=font, fill=255)
ink = ndi.gaussian_filter(np.asarray(ink, np.float32) / 255, 0.7)
col = np.array([28, 24, 20], np.float32)
a3 = ink[..., None] * 0.93
ims["albedo"] = np.dstack([np.clip(ims["albedo"][..., :3] * (1 - a3) + col * a3, 0, 255).astype(np.uint8), alpha])
for m, dv in delta.items():
    v = ims[m].astype(np.float32)
    if v.ndim == 3:
        v += (ink * dv)[..., None]
    else:
        v += ink * dv
    ims[m] = np.clip(v, 0, 255).astype(np.uint8)
hgt = ink * delta["height"]
gy, gx = np.gradient(ndi.gaussian_filter(hgt, 1.0))
nrm = ims["normal_gl"].astype(np.float32) / 127.5 - 1
nrm[..., 0] -= gx * 0.04; nrm[..., 1] += gy * 0.04
nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True) + 1e-6
ims["normal_gl"] = ((nrm + 1) * 127.5).clip(0, 255).astype(np.uint8)
# ORM keeps R=AO, G=roughness in sync with the separate maps
orm = ims["orm"].copy(); orm[..., 0] = ims["ao"] if ims["ao"].ndim == 2 else ims["ao"][..., 0]
orm[..., 1] = ims["roughness"] if ims["roughness"].ndim == 2 else ims["roughness"][..., 0]; ims["orm"] = orm
for m in MAPS:
    Image.fromarray(ims[m]).save(os.path.join(D, m + ".png"))
print("new hole angles", np.round(new_ang, 1))
