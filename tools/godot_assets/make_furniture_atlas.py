#!/usr/bin/env python3
"""Реалистичный атлас мебели здания (M_Atlas_Furniture: кровати, тумбочки, шкафы, кресла, ковры, шторы…).

Атлас модели — сетка плиток 256 × 256 (4096 × 2048), раскраска рисованная: «волнистое» дерево без волокон,
ткани без фактуры. Здесь атлас становится вдвое крупнее (8192 × 4096), и в каждой плитке:
  • «деревянные» пиксели (коричневые по цвету) — настоящий шпон грецкого ореха (Poly Haven, CC0) того же
    оттенка; нарисованные контуры, ручки, надписи остаются как были; дерево под лаком — с бликом и рельефом;
  • ткани (шторы, покрывала, матрасы, ковры, обивка, сукно) — свой рисунок остаётся, сверху фактура плетения
    (лён, бархат, ковёр, букле) и её рельеф; кожаный чемодан — кожа.
Раскладка UV модели не меняется. Выход: furniture_albedo.jpg, furniture_normal.jpg, furniture_orm.jpg (+ .import).

Запуск: python3 make_furniture_atlas.py <фото Poly Haven 2k> <старые карты атласа (png)> <выход>
"""
import os
import sys

import numpy as np
from PIL import Image

SRC, OLD, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
K = 2                       # во сколько раз крупнее
T = 256                     # плитка старого атласа
rng = np.random.default_rng(7)

IMPORT = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "make_hospital_textures.py")).read()
IMPORT = IMPORT[IMPORT.index('IMPORT = """') + len('IMPORT = """'):]
IMPORT = IMPORT[:IMPORT.index('"""')]


def load(name, kind, gray=False):
    im = Image.open(os.path.join(SRC, f"{name}_{kind}.jpg")).convert("L" if gray else "RGB")
    return np.asarray(im).astype(np.float32) / 255.0


def s2l(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def l2s(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def lum(c):
    return c[..., 0] * 0.2126 + c[..., 1] * 0.7152 + c[..., 2] * 0.0722


def box(a, r):
    """Размытие окном (2r+1) по обеим осям, края — повтор крайних пикселей."""
    if r < 1:
        return a
    pad = [(r + 1, r), (r + 1, r)] + ([(0, 0)] if a.ndim == 3 else [])
    p = np.pad(a, pad, mode="edge")
    c = np.cumsum(np.cumsum(p, 0), 1)
    n = 2 * r + 1
    return (c[n:, n:] - c[:-n, n:] - c[n:, :-n] + c[:-n, :-n]) / (n * n)


def blur(a, r):
    return box(box(box(a, r), r), r)


def detail(rgb, contrast, r=48):
    lm = lum(s2l(rgb))
    return 1.0 + (lm / np.maximum(blur(lm, r), 1e-3) - 1.0) * contrast


def crop(a, size, seed):
    g = np.random.default_rng(seed)
    y = g.integers(0, a.shape[0] - size)
    x = g.integers(0, a.shape[1] - size)
    return a[y:y + size, x:x + size]


def hsv(rgb):
    mx = rgb.max(-1)
    mn = rgb.min(-1)
    d = mx - mn
    h = np.zeros_like(mx)
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    nz = d > 1e-6
    hr = nz & (mx == r)
    hg = nz & (mx == g) & ~hr
    hb = nz & ~hr & ~hg
    h[hr] = ((g - b)[hr] / d[hr]) % 6
    h[hg] = (b - r)[hg] / d[hg] + 2
    h[hb] = (r - g)[hb] / d[hb] + 4
    return h / 6.0, np.where(mx > 1e-6, d / np.maximum(mx, 1e-6), 0), mx


def n_dec(c):
    return c * 2.0 - 1.0


def n_mix(base, det, w):
    """Сложить два рельефа (наклоны), det — с весом w (0..1 по пикселям)."""
    x = base[..., 0] / np.maximum(base[..., 2], 0.2) + det[..., 0] / np.maximum(det[..., 2], 0.2) * w
    y = base[..., 1] / np.maximum(base[..., 2], 0.2) + det[..., 1] / np.maximum(det[..., 2], 0.2) * w
    v = np.stack([x, y, np.ones_like(x)], -1)
    return v / np.linalg.norm(v, axis=-1, keepdims=True)


print("loading")
alb = Image.open(os.path.join(OLD, "T_Atlas_Furniture_BaseColor.png")).convert("RGB")
nor = Image.open(os.path.join(OLD, "T_Atlas_Furniture_Normal.png")).convert("RGB")
orm = Image.open(os.path.join(OLD, "T_Atlas_Furniture_ORM.png")).convert("RGB")
W, H = alb.size
alb = alb.resize((W * K, H * K), Image.LANCZOS)
nor = nor.resize((W * K, H * K), Image.BICUBIC)
orm = orm.resize((W * K, H * K), Image.BICUBIC)
A = np.asarray(alb).copy()
N = np.asarray(nor).copy()
O = np.asarray(orm).copy()

wood_d = load("natural_walnut_veneer", "diff")
wood_n = n_dec(load("natural_walnut_veneer", "nor"))
wood_r = load("natural_walnut_veneer", "rough", True)
FAB = {
    "linen": (load("rough_linen", "diff"), n_dec(load("rough_linen", "nor")), 0.55),
    "velvet": (load("velour_velvet", "diff"), n_dec(load("velour_velvet", "nor")), 0.45),
    "carpet": (load("dirty_carpet", "diff"), n_dec(load("dirty_carpet", "nor")), 0.32),
    "boucle": (load("wool_boucle", "diff"), n_dec(load("wool_boucle", "nor")), 0.45),
    "leather": (load("brown_leather", "diff"), n_dec(load("brown_leather", "nor")), 0.5),
}
# ткани: (колонка, строка, ширина, высота в плитках 256, фактура, шероховатость). Плитки проверены глазами:
# рёбра батарей (3–4, 2), серый металл (15, 2), картон (13, 4), плитка с телефонным диском (14, 5) — не ткани.
FABRIC_TILES = [
    (12, 0, 1, 2, "velvet", 0.9),      # красная бархатная штора (сцена)
    (15, 0, 1, 2, "linen", 0.9),       # тёмно-красная ткань в точку
    (4, 3, 1, 1, "linen", 0.85),       # матрас в синюю полоску
    (7, 2, 2, 1, "velvet", 0.92),      # сукно бильярда
    (8, 3, 1, 1, "velvet", 0.92),      # зелёное сукно
    (9, 4, 1, 1, "carpet", 0.95),      # ковёр с ромбом
    (10, 4, 1, 1, "carpet", 0.95),     # красная дорожка
    (11, 4, 1, 1, "carpet", 0.95),     # бежевый ковёр
    (12, 4, 1, 1, "boucle", 0.92),     # клетчатый плед
    (14, 4, 1, 1, "velvet", 0.9),      # красная ткань (обивка)
    (9, 5, 1, 1, "linen", 0.85),       # белая простыня
    (10, 5, 1, 1, "linen", 0.88),      # мятная штора в полоску
    (3, 5, 1, 1, "boucle", 0.9),       # клетчатый чемодан
    (2, 5, 1, 1, "leather", 0.55),     # кожаный чемодан
]
fab_mask = np.zeros((H * K, W * K), bool)
for (c, r, w, h, kind, rough) in FABRIC_TILES:
    fab_mask[r * T * K:(r + h) * T * K, c * T * K:(c + w) * T * K] = True

print("wood")
S = T * K
cols, rows = W // T, H // T
for ty in range(rows):
    for tx in range(cols):
        y0, x0 = ty * S, tx * S
        if fab_mask[y0 + 2, x0 + 2]:
            continue
        a = A[y0:y0 + S, x0:x0 + S].astype(np.float32) / 255.0
        if a.max() < 0.02:
            continue
        h, s, v = hsv(a)
        m = ((h > 0.025) & (h < 0.13) & (s > 0.28) & (s < 0.92) & (v > 0.1) & (v < 0.8)).astype(np.float32)
        # нарисованные линии (контуры филёнок, ромбы, щели) заметно темнее своего окружения — их не трогаем
        lv = lum(a)
        lines = (lv < blur(lv, 3 * K) * 0.8).astype(np.float32)
        m *= 1.0 - np.clip(blur(lines, 1) * 1.5, 0, 1)
        if m.mean() < 0.06:
            continue
        m = np.clip(blur(m, 1) * 1.2 - 0.1, 0, 1)
        # свой цвет дерева, без нарисованных «волн»: размытие только по деревянным пикселям
        num = blur(s2l(a) * m[..., None], 10 * K)
        den = blur(m, 10 * K)[..., None]
        base = num / np.maximum(den, 1e-3)
        seed = ty * 97 + tx
        wd = crop(wood_d, S, seed)
        wdet = detail(wd, 0.75)
        new = l2s(base * wdet[..., None])
        a2 = a * (1 - m[..., None]) + new * m[..., None]
        A[y0:y0 + S, x0:x0 + S] = (np.clip(a2, 0, 1) * 255 + 0.5).astype(np.uint8)
        nb = n_dec(N[y0:y0 + S, x0:x0 + S].astype(np.float32) / 255.0)
        nn = n_mix(nb, crop(wood_n, S, seed), 0.6 * m)
        N[y0:y0 + S, x0:x0 + S] = (np.clip(nn * 0.5 + 0.5, 0, 1) * 255 + 0.5).astype(np.uint8)
        o = O[y0:y0 + S, x0:x0 + S].astype(np.float32) / 255.0
        wr = crop(wood_r, S, seed)
        o[..., 1] = o[..., 1] * (1 - m) + np.clip(0.4 + (wr - wr.mean()) * 0.5, 0.2, 0.8) * m
        o[..., 2] = o[..., 2] * (1 - m)
        O[y0:y0 + S, x0:x0 + S] = (np.clip(o, 0, 1) * 255 + 0.5).astype(np.uint8)

print("fabrics")
for i, (c, r, w, h, kind, rough) in enumerate(FABRIC_TILES):
    y0, x0, hh, ww = r * S, c * S, h * S, w * S
    fd, fn, contrast = FAB[kind]
    reps = (int(np.ceil(hh / fd.shape[0])) + 1, int(np.ceil(ww / fd.shape[1])) + 1)
    d_full = detail(np.tile(fd, (reps[0], reps[1], 1))[:hh, :ww], contrast, 10 if kind == "carpet" else 48)
    n_full = np.tile(fn, (reps[0], reps[1], 1))[:hh, :ww]
    a = A[y0:y0 + hh, x0:x0 + ww].astype(np.float32) / 255.0
    if kind == "leather":
        lc = s2l(a)
        a = l2s(lc * d_full[..., None])
    else:
        a = l2s(s2l(a) * d_full[..., None])
    A[y0:y0 + hh, x0:x0 + ww] = (np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8)
    nb = n_dec(N[y0:y0 + hh, x0:x0 + ww].astype(np.float32) / 255.0)
    nn = n_mix(nb, n_full, np.full((hh, ww), 0.8, np.float32))
    N[y0:y0 + hh, x0:x0 + ww] = (np.clip(nn * 0.5 + 0.5, 0, 1) * 255 + 0.5).astype(np.uint8)
    o = O[y0:y0 + hh, x0:x0 + ww].astype(np.float32) / 255.0
    o[..., 1] = rough + (d_full - 1.0) * 0.2
    o[..., 2] = 0.0
    O[y0:y0 + hh, x0:x0 + ww] = (np.clip(o, 0, 1) * 255 + 0.5).astype(np.uint8)

os.makedirs(OUT, exist_ok=True)
for name, arr, nm in (("furniture_albedo", A, 0), ("furniture_normal", N, 1), ("furniture_orm", O, 0)):
    path = os.path.join(OUT, name + ".jpg")
    Image.fromarray(arr).save(path, quality=90, subsampling=0 if nm else 2)
    with open(path + ".import", "w") as f:
        f.write(IMPORT.format(nm=nm))
    print("wrote", name)
