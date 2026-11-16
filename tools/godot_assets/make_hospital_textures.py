#!/usr/bin/env python3
"""Реалистичные текстуры больницы для «The Last Shake» (sanatorium/assets/tex/).

Берёт фото-текстуры Poly Haven (CC0, polyhaven.com) и собирает из них текстуры в ТОЙ ЖЕ раскладке, что у
материалов здания (UV не меняются):
  • стены (3 × 3 м на текстуру): сверху побелка (1,5 м), тёмная полоса, ниже масляная краска до плинтуса,
    плинтус 10 см; у краски — блеск, потёртости на высоте каталок и у пола;
  • кафель на стене: снизу белая плитка 15 × 15 см со швами;
  • обои: рисунок старых обоев остаётся, сверху — фактура старой бумаги;
  • пол (2 × 2 м): линолеум с швом рулона, паркет «ёлочка», метлахская плитка 10 см в шахматку, терраццо;
  • потолок и штукатурка; двери — потёртое тёмное дерево.
Для каждого: *_albedo.jpg, *_normal.jpg (OpenGL, как у Godot), *_orm.jpg (R — затенение, G — шероховатость,
B — металл), с файлами .import (сжатие в видеопамять, мипмапы).

Запуск: python3 make_hospital_textures.py <папка с фото Poly Haven 2k> <папка старых текстур glb> <выход>
Нужные фото (2k jpg: _diff, _nor, _rough): painted_plaster_wall, white_plaster_02, linoleum_brown,
herringbone_parquet, terrazzo_tiles, dark_wood, floor_tiles_08, decrepit_wallpaper.
"""
import os
import sys

import numpy as np
from PIL import Image, ImageFilter

SRC, OLD, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
N = int(os.environ.get("TEX_N", "4096"))   # размер текстур (4096 — для 4K-исходников Poly Haven)
SC = N / 2048.0                            # все размеры в пикселях ниже заданы для 2048
rng = np.random.default_rng(1975)
os.makedirs(OUT, exist_ok=True)


# ------------------------------------------------------------------ загрузка и запись
def load(name, kind, size=N, gray=False):
    im = Image.open(os.path.join(SRC, f"{name}_{kind}.jpg"))
    im = im.convert("L" if gray else "RGB")
    if im.size != (size, size):
        im = im.resize((size, size), Image.LANCZOS)
    return np.asarray(im).astype(np.float32) / 255.0


def old(name):
    im = Image.open(os.path.join(OLD, f"T_{name}_BaseColor.jpg")).convert("RGB").resize((N, N), Image.LANCZOS)
    return np.asarray(im).astype(np.float32) / 255.0


def srgb_to_lin(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def lin_to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


IMPORT = """[remap]

importer="texture"
type="CompressedTexture2D"

[params]

compress/mode=2
compress/high_quality=false
compress/lossy_quality=0.7
compress/uastc_level=0
compress/rdo_quality_loss=0.0
compress/hdr_compression=1
compress/normal_map={nm}
compress/channel_pack=0
mipmaps/generate=true
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/channel_remap/red=0
process/channel_remap/green=1
process/channel_remap/blue=2
process/channel_remap/alpha=3
process/fix_alpha_border=true
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=0
"""


def save(arr, name, normal=False, q=90):
    img = Image.fromarray((np.clip(arr, 0, 1) * 255 + 0.5).astype(np.uint8))
    path = os.path.join(OUT, name + ".jpg")
    img.save(path, quality=q, subsampling=0 if normal else 2)
    with open(path + ".import", "w") as f:
        f.write(IMPORT.format(nm=1 if normal else 0))
    print("wrote", name)


# ------------------------------------------------------------------ помощники
def blur(a, r):
    """Гаусс через FFT (с переносом по краям — бесшовные текстуры остаются бесшовными); r — в пикселях 2048."""
    r = r * SC
    if a.ndim == 3:
        return np.stack([blur(a[..., i], r / SC) for i in range(a.shape[2])], -1)
    h, w = a.shape
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.rfftfreq(w)[None, :]
    g = np.exp(-2.0 * (np.pi * r) ** 2 * (fx ** 2 + fy ** 2))
    return np.fft.irfft2(np.fft.rfft2(a) * g, s=a.shape).astype(np.float32)


def lum(rgb):
    return rgb[..., 0] * 0.2126 + rgb[..., 1] * 0.7152 + rgb[..., 2] * 0.0722


def detail(rgb, contrast=1.0, flat_r=None):
    """Множитель «фактуры» вокруг 1: светлое/тёмное фото без общего цвета."""
    lm = lum(srgb_to_lin(rgb))
    base = blur(lm, flat_r) if flat_r else np.full_like(lm, lm.mean())
    d = lm / np.maximum(base, 1e-3)
    return 1.0 + (d - 1.0) * contrast


def tint(color_srgb, mult):
    """Цвет (0..255, sRGB) × фактура — в линейном пространстве."""
    c = srgb_to_lin(np.array(color_srgb, np.float32) / 255.0)
    return lin_to_srgb(c[None, None, :] * mult[..., None])


def nmap(rgb):
    return rgb * 2.0 - 1.0


def nflat(n, s):
    out = n.copy()
    out[..., 0:2] *= s
    return out


def n_from_height(h, k):
    k = k * SC
    """Нормаль (OpenGL: +Y вверх по картинке) из высоты h (м) с силой k."""
    dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5
    dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5
    return np.stack([-dx * k, dy * k, np.ones_like(h)], -1)


def ncombine(*ns):
    x = sum(n[..., 0] / np.maximum(n[..., 2], 0.2) for n in ns)
    y = sum(n[..., 1] / np.maximum(n[..., 2], 0.2) for n in ns)
    v = np.stack([x, y, np.ones_like(x)], -1)
    return v / np.linalg.norm(v, axis=-1, keepdims=True)


def nencode(n):
    n = n / np.linalg.norm(n, axis=-1, keepdims=True)
    return n * 0.5 + 0.5


def orm(ao, rough, metal=0.0):
    return np.stack([ao, rough, np.full_like(rough, metal)], -1)


def rows(a, b):
    """Маска полосы по высоте (доля текстуры, 0 — верх), с мягкими краями в 1 пиксель."""
    y = (np.arange(N) + 0.5) / N
    m = np.clip((y - a) * N + 0.5, 0, 1) * np.clip((b - y) * N + 0.5, 0, 1)
    return np.repeat(m[:, None], N, 1)


def noise(scale_px, octaves=4, seed=0):
    g = np.random.default_rng(seed)
    out = np.zeros((N, N), np.float32)
    amp = 1.0
    s = scale_px * SC
    for _ in range(octaves):
        small = g.standard_normal((max(2, N // int(s)), max(2, N // int(s)))).astype(np.float32)
        big = np.asarray(Image.fromarray(small, "F").resize((N, N), Image.BICUBIC))
        out += big * amp
        amp *= 0.5
        s = max(2, s / 2)
    return out / 1.9


def tileable_noise(scale_px, seed=0):
    """Шум, который повторяется по краям (для полов)."""
    g = np.random.default_rng(seed)
    k = max(2, N // int(scale_px * SC))
    small = g.standard_normal((k, k)).astype(np.float32)
    tiled = np.tile(small, (3, 3))
    big = np.asarray(Image.fromarray(tiled, "F").resize((N * 3, N * 3), Image.BICUBIC))
    return big[N:2 * N, N:2 * N]


# ------------------------------------------------------------------ фото
print("loading photos")
plaster_d = load("painted_plaster_wall", "diff")
plaster_n = nmap(load("painted_plaster_wall", "nor"))
plaster_r = load("painted_plaster_wall", "rough", gray=True)
white_d = load("white_plaster_02", "diff")
white_n = nmap(load("white_plaster_02", "nor"))
white_r = load("white_plaster_02", "rough", gray=True)

# ------------------------------------------------------------------ стены с масляной краской
# раскладка как у старых текстур: побелка 0…0,497, полоса до 0,503, краска до 0,965, кромка, плинтус 0,967…1
UP_END, LINE_END, PAINT_END, SKIRT = 0.497, 0.503, 0.965, 0.967
y_m = (np.arange(N)[:, None] + 0.5) / N * 3.0            # метры от верха стены
h_floor = 3.0 - y_m                                        # высота над полом
up = rows(0.0, UP_END)
line = rows(UP_END, LINE_END)
paint = rows(LINE_END, PAINT_END)
edge = rows(PAINT_END, SKIRT)
skirt = rows(SKIRT, 1.01)
det_up = detail(plaster_d, 0.9, flat_r=120)
det_low = detail(plaster_d, 0.45, flat_r=60)
# потёртости краски: полоса на высоте каталок и коек (0,6…0,95 м) и у самого пола
scuff_band = np.exp(-((h_floor - 0.78) / 0.12) ** 2) * 0.9 + np.exp(-((h_floor - 0.14) / 0.06) ** 2) * 0.6
chips = (noise(40, 4, 11) + noise(9, 2, 12) * 0.5) * np.broadcast_to(scuff_band, (N, N))
chip_mask = np.clip((chips - 0.9) * 3.0, 0, 1) * paint
scratch = np.clip((noise(3, 1, 13) - 1.6) * 2.0, 0, 1) * np.broadcast_to(scuff_band, (N, N)) * paint * 0.6
ao_wall = 1.0 - 0.35 * np.exp(-((y_m - SKIRT * 3.0) / 0.012) ** 2)        # тень под кромкой плинтуса


def paint_wall(upper, lower, out_name):
    col = tint(upper, det_up) * up[..., None]
    lowc = tint(lower, det_low)
    under = tint(upper, det_up * 0.92)                     # из-под сколов видна побелка/штукатурка
    lowc = lowc * (1 - chip_mask[..., None]) + under * chip_mask[..., None]
    lowc = lowc * (1 - scratch[..., None] * 0.25)
    col += lowc * paint[..., None]
    dark = np.array(lower, np.float32) * 0.5
    col += tint(dark, det_low) * line[..., None]
    col += tint(np.array(lower) * 0.62, det_low) * edge[..., None]
    col += tint((72, 50, 38), detail(plaster_d, 0.35, flat_r=40)) * skirt[..., None]
    save(col * ao_wall[..., None] ** 0.5, out_name + "_albedo")


paint_wall((214, 208, 192), (186, 164, 128), "wall_beige")
paint_wall((210, 210, 202), (132, 154, 160), "wall_blue")
paint_wall((214, 205, 190), (190, 152, 128), "wall_peach")
# общие нормаль и шероховатость для всех крашеных стен
h = (plaster_r * 0.0)
h += (skirt * 0.012 + edge * 0.006 + line * 0.0015)
h -= chip_mask * 0.0008
n_wall = ncombine(nflat(plaster_n, 1.0) * (up + skirt * 0.3)[..., None] + np.stack([0 * up, 0 * up, 1 - up - skirt * 0.3], -1),
                  nflat(plaster_n, 0.35) * paint[..., None] + np.stack([0 * up, 0 * up, 1 - paint], -1),
                  n_from_height(h, 900.0))
save(nencode(n_wall), "wall_paint_normal", normal=True)
r = up * (0.82 + (plaster_r - plaster_r.mean()) * 0.5) + paint * (0.36 + (plaster_r - plaster_r.mean()) * 0.35)
r = r + chip_mask * 0.45 + scratch * 0.25 + line * 0.3 + edge * 0.45 + skirt * 0.5
save(orm(np.broadcast_to(ao_wall, (N, N)), np.clip(r, 0.05, 1.0)), "wall_paint_orm")

# ------------------------------------------------------------------ стена с кафелем (снизу белая плитка 15 см)
TILE0, TILE1 = 0.516, 0.966
tile_px = N / 20.0
xx = np.arange(N)[None, :] + 0.5
yy = np.arange(N)[:, None] + 0.5
tx = np.mod(xx, tile_px)
ty = np.mod(yy - TILE0 * N, tile_px)
grout_w = 3.2 * SC
in_tiles = rows(TILE0, TILE1)
dgx = np.minimum(tx, tile_px - tx)
dgy = np.minimum(ty, tile_px - ty)
dg = np.minimum(np.broadcast_to(dgx, (N, N)), np.broadcast_to(dgy, (N, N)))
grout = np.clip(grout_w * 0.5 - dg + 0.5, 0, 1) * in_tiles
bevel = np.clip(1.0 - (dg - grout_w * 0.5) / (4.0 * SC), 0, 1) * in_tiles * (1 - grout)
col_i = np.floor(xx / tile_px).astype(int)
row_i = np.floor((yy - TILE0 * N) / tile_px).astype(int)
cell = np.broadcast_to(col_i, (N, N)) * 131 + np.broadcast_to(row_i, (N, N)) * 977
var = (np.sin(cell * 12.9898) * 43758.5453) % 1.0
glaze = tint((228, 228, 220), 1.0 + (var - 0.5) * 0.06 + noise(6, 2, 21) * 0.01)
dirt = np.clip(blur(noise(80, 3, 22), 8) * 0.5 + 0.5, 0, 1)
grout_c = tint((150, 146, 134), 1.0 - dirt * 0.25)
col = tint((214, 208, 192), det_up) * up[..., None] + tint((214, 208, 192), det_up) * rows(UP_END, TILE0)[..., None]
tiles_c = glaze * (1 - grout[..., None]) + grout_c * grout[..., None]
col += tiles_c * in_tiles[..., None]
col += tint((72, 50, 38), detail(plaster_d, 0.35, flat_r=40)) * rows(TILE1, 1.01)[..., None]
ao_t = 1.0 - grout * 0.35 - bevel * 0.08
save(col * ao_t[..., None] ** 0.5, "wall_tile_albedo")
h = -grout * 0.0025 - bevel * 0.0006 + rows(TILE1, 1.01) * 0.012
tilt = np.stack([((var * 7.1) % 1.0 - 0.5) * 0.02, ((var * 3.3) % 1.0 - 0.5) * 0.02, np.ones_like(var)], -1)
n_t = ncombine(nflat(plaster_n, 1.0) * (1 - in_tiles)[..., None] + np.stack([0 * up, 0 * up, in_tiles], -1),
               tilt * in_tiles[..., None] * (1 - grout[..., None]) + np.stack([0 * up, 0 * up, 1 - in_tiles * (1 - grout)], -1),
               n_from_height(h, 900.0))
save(nencode(n_t), "wall_tile_normal", normal=True)
r = (1 - in_tiles) * (0.82 + (plaster_r - plaster_r.mean()) * 0.5) + in_tiles * (0.12 + var * 0.06 + dirt * 0.12)
r = r * (1 - grout) + grout * 0.92
save(orm(ao_t, np.clip(r, 0.05, 1.0)), "wall_tile_orm")

# ------------------------------------------------------------------ обои: рисунок старых обоев + бумага
paper_d = load("decrepit_wallpaper", "diff")
paper_n = nmap(load("decrepit_wallpaper", "nor"))
paper_r = load("decrepit_wallpaper", "rough", gray=True)
paper_det = detail(paper_d, 0.55, flat_r=200)
paper_low = np.clip(blur(lum(paper_d), 60) / lum(paper_d).mean(), 0.75, 1.15)
WP_END = 0.966
for nm in ("Wallpaper_Floral", "Wallpaper_Geometric"):
    o = old(nm)
    base = srgb_to_lin(o) * (paper_det * paper_low)[..., None] * 0.97
    col = lin_to_srgb(base) * rows(0.0, WP_END)[..., None]
    col += tint((72, 50, 38), detail(plaster_d, 0.35, flat_r=40)) * rows(WP_END, 1.01)[..., None]
    save(col, nm.lower().replace("wallpaper_", "wallpaper_") + "_albedo")
n_p = nflat(paper_n, 0.7) * rows(0.0, WP_END)[..., None] + nflat(plaster_n, 0.3) * rows(WP_END, 1.01)[..., None]
save(nencode(ncombine(n_p, n_from_height(rows(WP_END, 1.01) * 0.012, 900.0))), "wallpaper_normal", normal=True)
save(orm(np.ones((N, N), np.float32), np.clip(0.78 + (paper_r - paper_r.mean()) * 0.4, 0.3, 1.0)), "wallpaper_orm")

# ------------------------------------------------------------------ потолок и белая штукатурка
det_c = detail(white_d, 0.5, flat_r=150)
stain = np.clip(1.0 + (blur(lum(white_d), 40) / lum(white_d).mean() - 1.0) * 0.4, 0.93, 1.04)
save(tint((236, 233, 224), det_c * stain), "ceiling_albedo")
save(tint((226, 222, 210), detail(white_d, 0.7, flat_r=120) * stain), "plaster_albedo")
save(nencode(nflat(white_n, 0.6)), "plaster_normal", normal=True)
save(orm(np.ones((N, N), np.float32), np.clip(0.88 + (white_r - white_r.mean()) * 0.3, 0.6, 1.0)), "plaster_orm")

# ------------------------------------------------------------------ линолеум (2 × 2 м, шов рулона по краю)
lin_d = load("linoleum_brown", "diff")
lin_n = nmap(load("linoleum_brown", "nor"))
lin_r = load("linoleum_brown", "rough", gray=True)
wear = np.clip(tileable_noise(300, 31) * 0.5 + 0.5, 0, 1)
seam = np.exp(-(np.minimum(xx, N - xx) / (1.2 * SC)) ** 2)
mottle = 1.0 + tileable_noise(60, 32) * 0.05 + tileable_noise(14, 33) * 0.03
col = tint((112, 62, 46), detail(lin_d, 1.8, flat_r=None) * mottle * (1.0 - wear * 0.16))
col = col * (1 - np.broadcast_to(seam, (N, N))[..., None] * 0.45)
save(col, "linoleum_albedo")
save(nencode(ncombine(nflat(lin_n, 0.8), n_from_height(-np.broadcast_to(seam, (N, N)) * 0.0006, 900.0))), "linoleum_normal", normal=True)
save(orm(np.ones((N, N), np.float32), np.clip(0.42 + (lin_r - lin_r.mean()) * 0.6 + wear * 0.18, 0.15, 0.95)), "linoleum_orm")

# ------------------------------------------------------------------ паркет «ёлочка»
par_d = load("herringbone_parquet", "diff")
par_n = nmap(load("herringbone_parquet", "nor"))
par_r = load("herringbone_parquet", "rough", gray=True)
pl = srgb_to_lin(par_d)
target = srgb_to_lin(np.array([138, 98, 62], np.float32) / 255.0)
pl = pl / pl.reshape(-1, 3).mean(0)[None, None, :] * target[None, None, :]
pl *= (1.0 - np.clip(tileable_noise(400, 41) * 0.5 + 0.5, 0, 1) * 0.12)[..., None]
save(lin_to_srgb(pl), "parquet_albedo")
save(nencode(par_n), "parquet_normal", normal=True)
save(orm(np.ones((N, N), np.float32), np.clip(0.45 + (par_r - par_r.mean()) * 0.8, 0.2, 0.95)), "parquet_orm")

# ------------------------------------------------------------------ метлахская плитка 10 см, шахматка
ft_d = load("floor_tiles_08", "diff")
ft_r = load("floor_tiles_08", "rough", gray=True)
cell_px = N / 20.0
cx = np.floor(xx / cell_px).astype(int)
cy = np.floor(yy / cell_px).astype(int)
checker = ((np.broadcast_to(cx, (N, N)) + np.broadcast_to(cy, (N, N))) % 2).astype(np.float32)
fx = np.mod(xx, cell_px)
fy = np.mod(yy, cell_px)
dgf = np.minimum(np.broadcast_to(np.minimum(fx, cell_px - fx), (N, N)), np.broadcast_to(np.minimum(fy, cell_px - fy), (N, N)))
grout = np.clip(2.6 * SC * 0.5 - dgf + 0.5, 0, 1)
bev = np.clip(1.0 - (dgf - 1.3 * SC) / (3.0 * SC), 0, 1) * (1 - grout)
cid = np.broadcast_to(cx, (N, N)) * 37 + np.broadcast_to(cy, (N, N)) * 101
v2 = (np.sin(cid * 78.233) * 12345.678) % 1.0
surf = detail(ft_d, 0.6, flat_r=10)
red = tint((150, 64, 46), surf * (1 + (v2 - 0.5) * 0.12))
cream = tint((206, 186, 152), surf * (1 + (v2 - 0.5) * 0.08))
grime = np.clip(tileable_noise(250, 51) * 0.5 + 0.5, 0, 1)
col = red * checker[..., None] + cream * (1 - checker[..., None])
col = col * (1 - grime[..., None] * 0.15)
col = col * (1 - grout[..., None]) + tint((92, 82, 72), 1.0 - grime * 0.2) * grout[..., None]
ao_f = 1 - grout * 0.3 - bev * 0.08
save(col * ao_f[..., None] ** 0.5, "floor_ceramic_albedo")
hf = -grout * 0.002 - bev * 0.0005
save(nencode(n_from_height(hf, 1100.0)), "floor_ceramic_normal", normal=True)
save(orm(ao_f, np.clip(0.55 + (ft_r - ft_r.mean()) * 0.4 + grime * 0.15 + grout * 0.35, 0.2, 1.0)), "floor_ceramic_orm")

# ------------------------------------------------------------------ терраццо (плиты 1 м)
tz_d = load("terrazzo_tiles", "diff")
tz_n = nmap(load("terrazzo_tiles", "nor"))
tz_r = load("terrazzo_tiles", "rough", gray=True)
tl = srgb_to_lin(tz_d)
g = lum(tl)[..., None]
tl = tl * 0.45 + g * 0.55                                 # меньше рыжины — серое терраццо
tl = tl / tl.reshape(-1, 3).mean(0)[None, None, :] * srgb_to_lin(np.array([150, 144, 132], np.float32) / 255.0)[None, None, :]
save(lin_to_srgb(tl), "terrazzo_albedo")
save(nencode(tz_n), "terrazzo_normal", normal=True)
save(orm(np.ones((N, N), np.float32), np.clip(0.32 + (tz_r - tz_r.mean()) * 0.6, 0.12, 0.9)), "terrazzo_orm")

# ------------------------------------------------------------------ двери: потёртое тёмное дерево под лаком
# шпон: волокна вдоль двери (фото повёрнуто на 90°)
wd = np.rot90(load("dark_wood", "diff")).copy()
wn = np.rot90(nmap(load("dark_wood", "nor"))).copy()
wn = np.stack([-wn[..., 1], wn[..., 0], wn[..., 2]], -1)          # поворот нормали вместе с картинкой
wr = np.rot90(load("dark_wood", "rough", gray=True)).copy()
wl = srgb_to_lin(wd)
wl = wl * 0.6 + lum(wl)[..., None] * 0.4
wl = wl / wl.reshape(-1, 3).mean(0)[None, None, :] * srgb_to_lin(np.array([74, 47, 30], np.float32) / 255.0)[None, None, :]
wl *= (1.0 - np.clip(noise(200, 3, 61) * 0.5 + 0.5, 0, 1) * 0.15)[..., None]
save(lin_to_srgb(wl), "door_albedo")
save(nencode(nflat(wn, 0.6)), "door_normal", normal=True)
save(orm(np.ones((N, N), np.float32), np.clip(0.4 + (wr - wr.mean()) * 0.7, 0.15, 0.95)), "door_orm")
print("done")
