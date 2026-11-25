#!/usr/bin/env python3
"""Наклейки грязи (Godot Decal) из коллажей автора: протечка на потолке, потёки со стены, облупленная краска,
трещины, затёртая полоса у пола, пятно на полу — каждая вырезается из коллажа на белом фоне отдельно.

Коллаж нарисован так, что белое — «ничего». Наклейка Godot не умножает, а смешивает: цвет = стена·(1−a) + d·a.
Чтобы на любой стене получалось как умножение на цвет коллажа m (белое — без изменений), берём
  a = 1 − min(m)  (насколько темнеет),  d = s0·(m − min(m)) / a  (оттенок пятна; s0 — средняя стена),
тогда для стены s0 выходит ровно s0·m, а серое (трещины, сажа) просто затемняет стену её же цветом:
облупленная краска на зелёной стене — зелёные чешуйки с тёмными краями, а не кремовая заплатка.
Карта нормалей коллажа — рельеф чешуек и трещин.

  python3 make_decals.py <папка коллажа A> <папка коллажа B> <выход sanatorium/assets/decals>
"""
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

S0 = 0.5            # средняя яркость стены (линейная)
MAXSIDE = 1024


def lin(c):
    c = c / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055) * 255.0


def find(folder, suffix):
    for f in os.listdir(folder):
        if f.endswith(suffix):
            return os.path.join(folder, f)
    raise FileNotFoundError(suffix)


def pieces(folder):
    """Куски коллажа: крупные пятна на белом + мелкие отделившиеся капли/чешуйки — к ближайшему крупному."""
    alb = np.array(Image.open(find(folder, "_albedo.png")).convert("RGB")).astype(np.float64)
    nrm = np.array(Image.open(find(folder, "_normal_gl.png")).convert("RGB"))
    H, W = alb.shape[:2]
    content = ndimage.binary_closing(alb.min(-1) < 238, iterations=2)
    lab, n = ndimage.label(content)
    areas = ndimage.sum(content, lab, range(1, n + 1))
    major = [i + 1 for i in np.argsort(-areas) if areas[i] > 0.012 * H * W]
    dist = [ndimage.distance_transform_edt(lab != k) for k in major]
    owner = {k: k for k in major}
    for k in range(1, n + 1):
        if k in owner:
            continue
        m = lab == k
        owner[k] = major[int(np.argmin([d[m].min() for d in dist]))]
    out = {}
    for k in major:
        mask_full = np.isin(lab, [c for c, o in owner.items() if o == k])
        ys, xs = np.nonzero(mask_full)
        y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
        cy, cx = (y0 + y1) / 2 / H, (x0 + x1) / 2 / W
        w, h = (x1 - x0) / W, (y1 - y0) / H
        if h > 0.45:
            continue                                   # два куска слиплись — не берём
        if w > 0.8:
            name = "scuffs"
        elif cy > 0.72:
            name = "floor"
        elif cy < 0.3:
            name = "ceiling_leak" if cx < 0.5 else "wall_leak"
        else:
            name = "peeling" if cx < 0.5 else "cracks"
        m = 10
        y0, y1, x0, x1 = max(y0 - m, 0), min(y1 + m, H), max(x0 - m, 0), min(x1 + m, W)
        mask = ndimage.binary_dilation(mask_full[y0:y1, x0:x1], iterations=3)
        out[name] = (alb[y0:y1, x0:x1], nrm[y0:y1, x0:x1], mask)
    return out


SAT = {"ceiling_leak": 1.0, "wall_leak": 1.0, "cracks": 0.0, "peeling": 0.0, "floor": 0.0, "scuffs": 0.0}


def convert(name, alb, nrm, mask):
    if name == "floor":                                  # сетка плитки коллажа — не наша: убрать тонкие линии
        alb = np.stack([ndimage.median_filter(alb[..., c], size=9) for c in range(3)], -1)
    mm = lin(alb)
    # цвет самой краски/побелки в куске (светлые 25 %) — нейтральный: остаются только пятна, трещины, сколы
    inside = mm[mask]
    ref = np.percentile(inside, 80, axis=0)
    mm = np.where(mask[..., None], np.clip(mm / np.maximum(ref, 1e-3), 0, 1), 1.0)
    # оттенок оставляем только у протечек (ржаво-бурые); серое (штукатурка, сажа, трещины) — почти без цвета,
    # иначе деление на кремовую краску делает его синим
    lum = (mm * [0.2126, 0.7152, 0.0722]).sum(-1, keepdims=True)
    mm = lum + (mm - lum) * SAT.get(name, 0.0)
    mm[..., 2] = np.minimum(mm[..., 2], mm[..., 1])        # пятна только тёплые: синий не светлее зелёного
    mm[..., 1] = np.minimum(mm[..., 1], mm[..., 0])
    mn = mm.min(-1)
    a = np.clip(1.0 - mn, 0.0, 1.0)
    d = S0 * (mm - mn[..., None]) / np.maximum(a, 1e-3)[..., None]
    soft = ndimage.gaussian_filter(mask.astype(np.float64), 2.0)
    a = a * soft
    a[a < 0.015] = 0.0
    rgba = np.dstack([srgb(d), a * 255.0]).round().clip(0, 255).astype(np.uint8)
    flat = np.array([128, 128, 255], np.float64)
    w = np.clip(a * 3.0, 0, 1)[..., None]
    n2 = (flat * (1 - w) + nrm.astype(np.float64) * w).round().astype(np.uint8)
    img, nimg = Image.fromarray(rgba, "RGBA"), Image.fromarray(n2, "RGB")
    k = MAXSIDE / max(img.size)
    if k < 1:
        sz = (int(img.size[0] * k), int(img.size[1] * k))
        img, nimg = img.resize(sz, Image.LANCZOS), nimg.resize(sz, Image.LANCZOS)
    return img, nimg


A, B, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(OUT, exist_ok=True)
for tag, folder, skip in [("a", A, ()), ("b", B, ("cracks",))]:
    for name, (alb, nrm, mask) in sorted(pieces(folder).items()):
        if name in skip:
            continue
        img, nimg = convert(name, alb, nrm, mask)
        img.save(os.path.join(OUT, "%s_%s.png" % (name, tag)), optimize=True)
        nimg.save(os.path.join(OUT, "%s_%s_n.png" % (name, tag)), optimize=True)
        print("%s_%s %s" % (name, tag, img.size))
