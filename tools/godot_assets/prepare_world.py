#!/usr/bin/env python3
"""Готовит лес forest_drive для «The Last Shake»: ставит санаторий на поляну у дороги.

Что делает (на копии resources/world проекта the_last_shake):
  * выравнивает землю под зданием (площадка + плавный откос 16 м вокруг);
  * прокладывает лесную тропинку от автобусной остановки до пандуса у входа (земля по тропинке —
    ровный уклон, на карте материалов — утоптанная земля с гравием);
  * убирает деревья, кусты, камни, траву с площадки, с тропинки и у остановки;
  * пересчитывает карту нормалей земли на изменённом участке;
  * пишет resources/world/story_site.json — где здание, остановка, тропинка (читает игра).

Запуск: python3 prepare_world.py <исходная resources/world> <папка проекта the_last_shake>
"""
import gzip
import json
import math
import os
import struct
import sys

import numpy as np
from PIL import Image

SRC, PROJ = sys.argv[1], sys.argv[2]
OUT = os.path.join(PROJ, "resources", "world")
N, O = 2049, -1024.0

# выбранное место (нашёл site_search: ровно, 110 м от дороги, прямой участок)
STOP_S = 1986            # метр дороги, где остановка (направление движения — рост s)
STOP_LAT = 7.0           # от оси дороги вправо до начала тропинки
PATH_D = 115.0           # от остановки до подножия пандуса по прямой
BUILD_FOOT = (3.0, 2.9)  # подножие пандуса в координатах здания (x, z); здание входом смотрит в -X
FP = (-7.0, 82.0, -28.0, 31.0)     # площадка здания с запасом (x0, x1, z0, z1), координаты здания
PAVE = (-1.0, 76.0, -22.2, 25.0)   # мощение вокруг здания (Site_Paving)
BLEND = 16.0             # ширина плавного откоса вокруг площадки

h = np.frombuffer(gzip.open(os.path.join(SRC, "heightmap.f32.gz")).read(), dtype="<f4").reshape(N, N).astype(np.float64)
h0_map = h.copy()
road = np.array(json.load(open(os.path.join(SRC, "road.json")))["points"])
rxz = road[:, [0, 2]]
L = len(road)


def tang(i):
    t = rxz[(i + 1) % L] - rxz[(i - 1) % L]
    return t / np.linalg.norm(t)


def bil(a, x, z):
    fx = np.clip(np.asarray(x) - O, 0, N - 1.001)
    fz = np.clip(np.asarray(z) - O, 0, N - 1.001)
    ix = fx.astype(int); iz = fz.astype(int); tx = fx - ix; tz = fz - iz
    return (a[iz, ix] * (1 - tx) + a[iz, ix + 1] * tx) * (1 - tz) + (a[iz + 1, ix] * (1 - tx) + a[iz + 1, ix + 1] * tx) * tz


t = tang(STOP_S)
right = np.array([-t[1], t[0]])                 # справа по ходу (как в Godot: (-fwd.z, fwd.x))
stop = rxz[STOP_S] + right * STOP_LAT
d = right.copy()                                # тропинка уходит от дороги вправо
foot = stop + d * PATH_D
yaw = math.atan2(-d[1], d[0])                   # поворот здания: его +X смотрит вдоль d
cy, sy = math.cos(yaw), math.sin(yaw)


def to_w(lx, lz):
    lx = np.asarray(lx, float); lz = np.asarray(lz, float)
    return np.stack([lx * cy + lz * sy, -lx * sy + lz * cy], -1)


def to_l(wx, wz, org):
    rx = np.asarray(wx) - org[0]; rz = np.asarray(wz) - org[1]
    return rx * cy - rz * sy, rx * sy + rz * cy


org = foot - to_w(BUILD_FOOT[0], BUILD_FOOT[1])
# высота площадки: середина высот под зданием
gx, gz = np.meshgrid(np.linspace(FP[0], FP[1], 60), np.linspace(FP[2], FP[3], 40))
pts = org + to_w(gx.ravel(), gz.ravel())
level = float(np.median(bil(h, pts[:, 0], pts[:, 1])))
print("building origin %.2f %.2f yaw %.4f level %.2f" % (org[0], org[1], yaw, level))

# ---------------------------------------------------------------- выравнивание под зданием
X, Z = np.meshgrid(np.arange(N) + O, np.arange(N) + O)
lx, lz = to_l(X, Z, org)
dx = np.maximum(np.maximum(FP[0] - lx, lx - FP[1]), 0)
dz = np.maximum(np.maximum(FP[2] - lz, lz - FP[3]), 0)
dist = np.hypot(dx, dz)
w = 1.0 - np.clip(dist / BLEND, 0, 1)
w = w * w * (3 - 2 * w)
inside_pave = (lx > PAVE[0] - 0.5) & (lx < PAVE[1] + 0.5) & (lz > PAVE[2] - 0.5) & (lz < PAVE[3] + 0.5)
target = np.where(inside_pave, level - 0.06, level - 0.02)
h = h * (1 - w) + target * w

# ---------------------------------------------------------------- тропинка
p0 = stop
p3 = foot - to_w(1.0, 0.0) + to_w(0.0, 0.0) * 0     # за метр до пандуса
dir_end = to_w(1.0, 0.0)
side = np.array([-d[1], d[0]])
p1 = p0 + d * 30.0 + side * 9.0
p2 = p3 - dir_end * 30.0 - side * 7.0
tt = np.linspace(0, 1, 600)
bez = ((1 - tt) ** 3)[:, None] * p0 + (3 * (1 - tt) ** 2 * tt)[:, None] * p1 + (3 * (1 - tt) * tt ** 2)[:, None] * p2 + (tt ** 3)[:, None] * p3
seg = np.linalg.norm(np.diff(bez, axis=0), axis=1)
cum = np.concatenate([[0], np.cumsum(seg)])
plen = cum[-1]
ss = np.arange(0, plen, 1.0)
path = np.stack([np.interp(ss, cum, bez[:, 0]), np.interp(ss, cum, bez[:, 1])], -1)
path = np.vstack([path, p3[None]])
# высоты тропинки: сглаженная земля, уклон не круче 7 %, концы — край обочины и площадка
ph = bil(h, path[:, 0], path[:, 1])
road_y = road[STOP_S, 1]
ph[0] = road_y - 0.05
k = 9
pad = np.concatenate([np.full(k, ph[0]), ph, np.full(k, ph[-1])])
ph = np.convolve(pad, np.ones(2 * k + 1) / (2 * k + 1), mode="valid")
ph[0] = road_y - 0.05
ph[-1] = level - 0.02
for _ in range(3):
    for i in range(1, len(ph)):
        ph[i] = np.clip(ph[i], ph[i - 1] - 0.07, ph[i - 1] + 0.07)
    for i in range(len(ph) - 2, -1, -1):
        ph[i] = np.clip(ph[i], ph[i + 1] - 0.07, ph[i + 1] + 0.07)
print("path length %.0f m, height %.2f .. %.2f" % (plen, ph.min(), ph.max()))

# расстояние от каждой клетки рядом с тропинкой до неё и высота ближайшей точки
x0, x1 = int(path[:, 0].min() - 12 - O), int(path[:, 0].max() + 12 - O)
z0, z1 = int(path[:, 1].min() - 12 - O), int(path[:, 1].max() + 12 - O)
sub_x, sub_z = np.meshgrid(np.arange(x0, x1) + O, np.arange(z0, z1) + O)
best = np.full(sub_x.shape, 1e9)
bh = np.zeros(sub_x.shape)
for i in range(len(path) - 1):
    a = path[i]; b = path[i + 1]
    ab = b - a
    tq = np.clip(((sub_x - a[0]) * ab[0] + (sub_z - a[1]) * ab[1]) / (ab @ ab), 0, 1)
    px = a[0] + ab[0] * tq; pz = a[1] + ab[1] * tq
    dd = np.hypot(sub_x - px, sub_z - pz)
    m = dd < best
    best[m] = dd[m]
    bh[m] = (ph[i] * (1 - tq) + ph[i + 1] * tq)[m]
wp = 1.0 - np.clip((best - 1.9) / 7.5, 0, 1)
wp = wp * wp * (3 - 2 * wp)
h[z0:z1, x0:x1] = h[z0:z1, x0:x1] * (1 - wp) + (bh - 0.03) * wp
path_dist = np.full((N, N), 1e9)
path_dist[z0:z1, x0:x1] = best

# ---------------------------------------------------------------- запись высот и нормалей
h32 = h.astype(np.float32)
os.makedirs(OUT, exist_ok=True)
with gzip.open(os.path.join(OUT, "heightmap.f32.gz"), "wb", compresslevel=6) as f:
    f.write(h32.astype("<f4").tobytes())
changed = np.abs(h32 - h0_map.astype(np.float32)) > 1e-4
ys, xs = np.nonzero(changed)
ry0, ry1, rx0, rx1 = max(ys.min() - 3, 0), min(ys.max() + 4, N), max(xs.min() - 3, 0), min(xs.max() + 4, N)
print("changed region rows %d..%d cols %d..%d (%d cells)" % (ry0, ry1, rx0, rx1, changed.sum()))
nimg = np.array(Image.open(os.path.join(SRC, "terrain_normal.png")).convert("RGB"))
sub = h[ry0 - 1:ry1 + 1, rx0 - 1:rx1 + 1]
gz_, gx_ = np.gradient(sub)
nrm = np.stack([-gx_, np.ones_like(gx_), -gz_], -1)
nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
enc = (np.stack([nrm[..., 0], nrm[..., 2], nrm[..., 1]], -1) * 127.5 + 127.5).clip(0, 255).astype(np.uint8)[1:-1, 1:-1]
nimg[ry0:ry1, rx0:rx1] = enc
Image.fromarray(nimg).save(os.path.join(OUT, "terrain_normal.png"), optimize=True)

# ---------------------------------------------------------------- карты материалов
c0 = np.array(Image.open(os.path.join(SRC, "control0.png")).convert("RGBA")).astype(np.float64)
c1 = np.array(Image.open(os.path.join(SRC, "control1.png")).convert("RGBA")).astype(np.float64)
clear = np.clip(1.0 - dist / 10.0, 0, 1)            # поляна: трава, мало хвои, открытое небо
for ch, v in ((0, 45), (1, 20), (2, 30), (3, 235)):
    c0[..., ch] = c0[..., ch] * (1 - clear) + v * clear
for ch, v in ((0, 40), (1, 0), (2, 0)):
    c1[..., ch] = c1[..., ch] * (1 - clear) + v * clear
pw = np.clip(1.0 - (path_dist - 0.9) / 1.4, 0, 1)    # тропинка: земля и мелкий гравий
for ch, v in ((0, 70), (1, 25), (2, 0), (3, 10)):
    c0[..., ch] = c0[..., ch] * (1 - pw) + v * pw
for ch, v in ((0, 255), (1, 150)):
    c1[..., ch] = c1[..., ch] * (1 - pw) + v * pw
c1[..., 2] = c1[..., 2] * (1 - 0.6 * pw)
Image.fromarray(c0.clip(0, 255).astype(np.uint8), "RGBA").save(os.path.join(OUT, "control0.png"), optimize=True)
Image.fromarray(c1.clip(0, 255).astype(np.uint8), "RGBA").save(os.path.join(OUT, "control1.png"), optimize=True)

# ---------------------------------------------------------------- растительность
s_dir = np.array([t[0], t[1]])
stop_c = rxz[STOP_S] + right * 8.0
CLEAR_PATH = {"trees": 3.2, "understory": 2.4, "bushes": 2.4, "rocks": 2.2, "props": 2.4, "cover": 1.25}


def keep_mask(x, z, set_name):
    lxx, lzz = to_l(x, z, org)
    in_site = (lxx > FP[0] + 1) & (lxx < FP[1] - 1) & (lzz > FP[2] + 1) & (lzz < FP[3] - 1)
    if set_name == "cover":   # трава остаётся на откосах, но не на мощении
        in_site = (lxx > PAVE[0] - 1.5) & (lxx < PAVE[1] + 1.5) & (lzz > PAVE[2] - 1.5) & (lzz < PAVE[3] + 1.5)
    ix = np.clip((x - O).round().astype(int), 0, N - 1)
    iz = np.clip((z - O).round().astype(int), 0, N - 1)
    near_path = path_dist[iz, ix] < CLEAR_PATH[set_name]
    rel = np.stack([x - stop_c[0], z - stop_c[1]], -1)
    along = rel @ s_dir
    lat = rel @ right
    at_stop = (np.abs(along) < 16) & (lat > -3.5) & (lat < 7)
    return ~(in_site | near_path | at_stop)


for set_name in ["trees", "understory", "bushes", "rocks", "props", "cover"]:
    fn = "inst_%s.bin.gz" % set_name
    raw = gzip.open(os.path.join(SRC, fn)).read()
    assert raw[:4] == b"FDI1"
    hl = struct.unpack_from("<I", raw, 4)[0]
    header = json.loads(raw[8:8 + hl])
    floats = np.frombuffer(raw[8 + hl:], dtype="<f4").reshape(-1, 16)
    gridn = int(header["grid"]); cell = float(header["cell"])
    blobs = []
    off = 0
    removed = 0
    variants = []
    for v in header["variants"]:
        rows = floats[v["offset"]:v["offset"] + v["count"]]
        # строки уже упорядочены по клеткам; фильтр сохраняет порядок
        m = keep_mask(rows[:, 3].astype(np.float64), rows[:, 11].astype(np.float64), set_name)
        # снять с площадки и приподнять до новой земли то, что осталось на откосе
        rows = rows[m].copy()
        removed += int((~m).sum())
        if len(rows):
            nh = bil(h, rows[:, 3], rows[:, 11])
            oh = bil(h0_map, rows[:, 3], rows[:, 11])
            rows[:, 7] += (nh - oh).astype(np.float32)
        cx = np.clip(((rows[:, 3] - O) // cell).astype(int), 0, gridn - 1)
        cz = np.clip(((rows[:, 11] - O) // cell).astype(int), 0, gridn - 1)
        cid = cz * gridn + cx
        if len(cid) and np.any(np.diff(cid) < 0):
            order = np.argsort(cid, kind="stable")
            rows = rows[order]; cid = cid[order]
        uniq, start, cnt = np.unique(cid, return_index=True, return_counts=True)
        variants.append({"name": v["name"], "offset": off, "count": int(len(rows)),
                         "cells": np.stack([uniq, start, cnt], 1).astype(int).tolist() if len(rows) else []})
        blobs.append(rows.astype("<f4").tobytes())
        off += len(rows)
    header["variants"] = variants
    js = json.dumps(header, separators=(",", ":")).encode()
    with gzip.open(os.path.join(OUT, fn), "wb", compresslevel=6) as f:
        f.write(b"FDI1" + struct.pack("<I", len(js)) + js + b"".join(blobs))
    print("%-11s removed %6d, kept %7d" % (set_name, removed, off))

# ---------------------------------------------------------------- данные для игры
site = {
    "building": {"origin": [round(float(org[0]), 3), round(level, 3), round(float(org[1]), 3)], "yaw": round(yaw, 5),
                 "entrance_local": [3.0, 0.0, 2.9], "door_local": [27.2, 1.2, 6.3]},
    "stop": {"s": STOP_S, "lateral": STOP_LAT, "point": [round(float(stop[0]), 3), round(float(road_y), 3), round(float(stop[1]), 3)]},
    "path": [[round(float(p[0]), 2), round(float(y), 3), round(float(p[1]), 2)] for p, y in zip(path, ph)],
    "road_length": float(L),
}
json.dump(site, open(os.path.join(OUT, "story_site.json"), "w"), indent=1)
print("story_site.json: %d path points" % len(site["path"]))
