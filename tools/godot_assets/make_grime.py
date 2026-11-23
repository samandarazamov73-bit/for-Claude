#!/usr/bin/env python3
"""Грязь для стен и потолков санатория (sanatorium/assets/grime_wall.png, grime_ceiling.png).

Кладётся поверх текстур умножением (белое — без изменений), в координатах мира (game.gd, _grime): стена —
одна высота этажа (3,3 м) на текстуру по вертикали, 12 м по горизонтали; низ картинки — пол. Потолок —
10 × 10 м. Повторяется по X (и по Z у потолка) без шва.

Как в жизни, а не нарисовано: протечки — мягкие неровные пятна (тёплый жёлто-бурый, к краю бледнее, край
чуть темнее, но без контура), под ними — размытый потёк; под потолком — пыльная полоса; у пола — затёртая
полоса и редкие следы от тележек и колёс; краска — едва заметно неровная. Всё бледно: стены не «в пятнах».

Запуск: python3 make_grime.py <папка sanatorium/assets>
"""
import os
import sys

import numpy as np
from PIL import Image, ImageFilter

OUT = sys.argv[1]
rng = np.random.default_rng(1980)


def noise(h, w, cells, octaves=5, wrap_y=False):
    """Сумма слоёв value-шума, бесшовная по X (и по Y, если wrap_y). 0..1."""
    out = np.zeros((h, w))
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        cy, cx = max(2, int(cells[0] * 2 ** o)), max(2, int(cells[1] * 2 ** o))
        g = rng.random((cy + 1, cx + 1))
        g[:, -1] = g[:, 0]
        if wrap_y:
            g[-1, :] = g[0, :]
        ys = np.linspace(0, cy, h, endpoint=False) if wrap_y else np.linspace(0, cy, h)
        xs = np.linspace(0, cx, w, endpoint=False)
        y0 = np.clip(ys.astype(int), 0, cy - 1); x0 = np.clip(xs.astype(int), 0, cx - 1)
        ty = (ys - y0)[:, None]; tx = (xs - x0)[None, :]
        ty = ty * ty * (3 - 2 * ty); tx = tx * tx * (3 - 2 * tx)
        a = g[y0][:, x0]; b = g[y0][:, x0 + 1]; c = g[y0 + 1][:, x0]; d = g[y0 + 1][:, x0 + 1]
        out += amp * ((a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty)
        tot += amp
        amp *= 0.5
    return out / tot


def save(rgb, name):
    img = Image.fromarray(np.clip(rgb * 255, 0, 255).astype(np.uint8), "RGB")
    img = img.filter(ImageFilter.GaussianBlur(0.6))
    img.save(os.path.join(OUT, name), optimize=True)
    print("wrote", name, img.size)


def wrapped_dx(xx, cx, w):
    d = np.abs(xx - cx)
    return np.minimum(d, w - d)


# ---------------------------------------------------------------- стена: 12 м × 3,3 м
W, H = 1536, 512
yy, xx = np.mgrid[0:H, 0:W].astype(float)
hm = (H - 1 - yy) / H * 3.3                       # высота над полом, м
rgb = np.ones((H, W, 3))
# неровная старая краска: очень слабо
n = noise(H, W, (2, 6), 5)
rgb *= (0.975 + 0.025 * n)[..., None]
# пыль под потолком (верхние ~12 см)
top = np.clip(1 - (3.3 - hm) / 0.14, 0, 1) ** 1.6
rgb *= (1 - 0.06 * top * (0.7 + 0.3 * noise(H, W, (2, 24), 3)))[..., None]
# у пола: затёртая полоса (до ~30 см) и следы колёс / тележек
low = np.clip(1 - hm / 0.32, 0, 1) ** 1.4
band = noise(H, W, (3, 40), 4)
rgb *= (1 - (0.10 + 0.08 * band) * low)[..., None] * np.array([1.0, 0.99, 0.975])
for _ in range(14):
    cx = rng.uniform(0, W); ln = rng.uniform(60, 260); hgt = rng.uniform(0.08, 0.26)
    cy = H - 1 - hgt / 3.3 * H
    d = np.exp(-((yy - cy) / rng.uniform(1.2, 3.0)) ** 2) * np.exp(-(wrapped_dx(xx, cx, W) / ln) ** 4)
    rgb *= (1 - 0.10 * d)[..., None]
# протечки: 2–3 на 12 м, от потолка вниз, мягкие и неровные
for k in range(3):
    cx = (k + rng.uniform(0.15, 0.85)) * W / 3
    r_m = rng.uniform(0.25, 0.55)                    # радиус пятна, м
    cy_m = 3.3 - rng.uniform(0.05, 0.25)
    dx = wrapped_dx(xx, cx, W) / (W / 12.0)
    dy = (hm - cy_m) * rng.uniform(0.9, 1.3)
    dist = np.sqrt(dx ** 2 + dy ** 2) / r_m
    edge = noise(H, W, (6, 36), 4)
    f = dist + (edge - 0.5) * 0.7                    # неровный край
    inside = np.clip((1.0 - f) / 0.35, 0, 1) ** 1.3  # мягкий спад к краю, без контура
    rim = np.exp(-((f - 0.95) / 0.10) ** 2) * 0.35   # край чуть темнее (высохшая вода), размыто
    mottled = 0.75 + 0.25 * noise(H, W, (10, 60), 3)
    strength = rng.uniform(0.10, 0.18)
    stain = np.clip(inside * mottled + rim, 0, 1) * strength
    tint = np.array([0.18, 0.32, 0.62])              # тёплый жёлто-бурый: синий уходит сильнее
    rgb *= (1 - stain[..., None] * tint / 0.62 * np.array([0.55, 0.75, 1.0]))
    # потёк вниз: широкий, мягкий, бледнеет
    run = np.exp(-(dx / rng.uniform(0.05, 0.12)) ** 2) * np.clip(1 - (cy_m - r_m * 0.6 - hm) / rng.uniform(0.4, 0.9), 0, 1)
    run *= (hm < cy_m - r_m * 0.4) * 0.07
    rgb *= (1 - run[..., None] * np.array([0.5, 0.7, 1.0]))
save(rgb, "grime_wall.png")

# ---------------------------------------------------------------- потолок: 10 × 10 м
S = 1024
yy, xx = np.mgrid[0:S, 0:S].astype(float)
rgb = np.ones((S, S, 3))
n = noise(S, S, (3, 3), 5, wrap_y=True)
rgb *= (0.97 + 0.03 * n)[..., None]
for k in range(3):
    cx, cy = rng.uniform(0, S), rng.uniform(0, S)
    r = rng.uniform(0.3, 0.7) * S / 10
    dx = np.minimum(np.abs(xx - cx), S - np.abs(xx - cx)); dy = np.minimum(np.abs(yy - cy), S - np.abs(yy - cy))
    f = np.sqrt(dx ** 2 + dy ** 2) / r + (noise(S, S, (8, 8), 4, wrap_y=True) - 0.5) * 0.7
    inside = np.clip((1.0 - f) / 0.35, 0, 1) ** 1.3
    rim = np.exp(-((f - 0.95) / 0.10) ** 2) * 0.35
    stain = np.clip(inside * (0.75 + 0.25 * noise(S, S, (14, 14), 3, wrap_y=True)) + rim, 0, 1) * rng.uniform(0.08, 0.14)
    rgb *= (1 - stain[..., None] * np.array([0.3, 0.55, 1.0]))
save(rgb, "grime_ceiling.png")
