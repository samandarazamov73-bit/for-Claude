"""Remove the baked specular glare from the painted wall sets (albedo + every map), recolour peach → beige."""
import sys, os, numpy as np
from scipy import ndimage as ndi
from PIL import Image
sys.path.insert(0, os.path.dirname(__file__))
from texlib import *

SRC = sys.argv[1]; OUT = sys.argv[2]
D = os.path.join(SRC, "Поте_ртая_стена_с_деревянным_плинтусом_1254x1254")

def band_rows(A):
    L = lum(A).mean(1); H = len(L)
    d = np.abs(np.diff(ndi.gaussian_filter1d(L, 1)))
    mid = int(np.argmax(d[int(H * .4):int(H * .6)])) + int(H * .4)
    plinth = int(np.argmax(d[int(H * .85):int(H * .99)])) + int(H * .85)
    return mid, plinth

def excess(a, r0, r1, sign=1.0):
    b = ndi.gaussian_filter(lum(a), 18)
    e = np.zeros_like(b)
    base = np.median(b[r0:r1], axis=1, keepdims=True)
    e[r0:r1] = sign * (b[r0:r1] - base)
    return e

def deglare(s, name):
    A = s["albedo"]; H, W = A.shape[:2]
    mid, plinth = band_rows(A)
    r0, r1 = mid + 14, plinth - 6
    e = excess(A, r0, r1) / 0.02 + excess(s["height"], r0, r1) / 0.03 + excess(s["roughness"], r0, r1, -1) / 0.03
    L = lum(A)
    spark = (L - ndi.median_filter(L, 9)) > 0.07
    spark[:r0 + 20] = False; spark[r1 - 20:] = False
    dens = ndi.gaussian_filter(spark.astype(np.float32), 14)
    dens_base = np.median(dens[r0:r1])
    ea = excess(A, r0, r1)
    dz = ndi.gaussian_filter(dens, 10); dz[:r0 + 30] = 0; dz[r1 - 30:] = 0
    core = (ea > 0.035) | (dz > 0.045)
    print('  core frac', core[r0:r1].mean(), 'dens_base', dens_base)
    core[:r0] = False; core[r1:] = False
    lab, n = ndi.label(core)
    sizes = ndi.sum(core, lab, range(1, n + 1))
    keep = np.isin(lab, 1 + np.flatnonzero(sizes > 3000))
    mask = ndi.binary_dilation(keep, iterations=30)
    mask[:r0] = False; mask[r1:] = False
    w = soft(mask, 18); w[:r0] = 0; w[r1:] = 0
    ring = ndi.binary_dilation(mask, iterations=25) & ~mask
    best = None
    for dx in range(60, W - 60, 6):
        sh = np.roll(mask, dx, 1)
        if (sh & mask).sum() > 0.02 * mask.sum():
            continue
        sc = np.abs(np.roll(A, dx, 1)[ring] - A[ring]).mean()
        if best is None or sc < best[0]:
            best = (sc, dx)
    dx = best[1]
    out = {m: blend(v, np.roll(v, dx, 1), w) for m, v in s.items()}
    print(f"{name}: mask frac {mask[r0:r1].mean():.3f}, band rows {mid}-{plinth}, glare px {int(keep.sum())}, patch from dx={dx}, ring err {best[0]:.4f}")
    return out, w

def recolor(A, mid, plinth, target_rgb):
    """shift chroma of the paint band toward target (Lab), keep lightness variation; plaster chips stay"""
    import cv2
    lab = cv2.cvtColor((A * 255).astype(np.uint8), cv2.COLOR_RGB2LAB).astype(np.float32)
    band = np.zeros(A.shape[:2], bool); band[mid + 8:plinth - 2] = True
    ab = lab[..., 1:] - 128
    paint_ab = np.median(ab[band], axis=0)
    t = cv2.cvtColor(np.uint8([[target_rgb]]), cv2.COLOR_RGB2LAB)[0, 0].astype(np.float32)
    paint_L = np.median(lab[..., 0][band])
    # weight: how close to the paint chroma (chips of plaster/old paint are far)
    dist = np.linalg.norm(ab - paint_ab, axis=-1)
    w = np.maximum(np.clip(1.2 - dist / 18.0, 0, 1), 0.45) * band
    w = soft(w > 0.5, 1.2) * w
    lab[..., 1:] = lab[..., 1:] + w[..., None] * ((t[1:] - 128) - paint_ab)
    lab[..., 0] = lab[..., 0] + w * (t[0] - paint_L) * 0.8
    rgb = cv2.cvtColor(np.clip(lab, 0, 255).astype(np.uint8), cv2.COLOR_LAB2RGB).astype(np.float32) / 255
    return rgb

peach = load_set(D, "Старая_стена_с_облупившеи_ся_краскои", "M_Paint_WallBeige.png")
blue = load_set(D, "Поте_ртая_стена_с_деревянным_плинтусом", "M_Paint_WallBlue.png")
peach, wp = deglare(peach, "peach")
blue, wb = deglare(blue, "blue")
save_set(peach, os.path.join(OUT, "M_Paint_WallPeach"))
save_set(blue, os.path.join(OUT, "M_Paint_WallBlue"))
mid, plinth = band_rows(peach["albedo"])
beige = dict(peach)
beige["albedo"] = recolor(peach["albedo"], mid, plinth, (204, 182, 150))
save_set(beige, os.path.join(OUT, "M_Paint_WallBeige"))
np.save(os.path.join(OUT, "_glare_mask.npy"), wp)
