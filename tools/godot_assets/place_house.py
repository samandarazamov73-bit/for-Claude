#!/usr/bin/env python3
"""Ставит у остановки дом с аптекой (props/pharmacy_house.glb, модель автора игры): через дорогу от
остановки, фасадом к дороге, вход в аптеку — напротив начала тропинки к санаторию.

Работает на уже готовом мире the_last_shake (после prepare_world.py), меняет его на месте:
  * выравнивает землю под домом и двором (тротуар дома с бордюром — у края дороги);
  * убирает деревья, кусты, камни и траву с участка дома;
  * пересчитывает нормали земли на изменённом участке;
  * дописывает в story_site.json «house»: где дом (origin, yaw) и маршрут коляски от остановки к прилавку.

Координаты дома (как в glTF): +Z — к улице, вход в аптеку x = −6.35, z ≈ −0.2, пол аптеки y = 0.1;
тротуар до бордюра z = 5.35 (дальше улица модели срезана: tools cut_street.py в Blender).

Запуск: python3 place_house.py <папка проекта the_last_shake>
"""
import gzip
import json
import math
import os
import struct
import sys

import numpy as np
from PIL import Image

PROJ = sys.argv[1]
W = os.path.join(PROJ, "resources", "world")
N, O = 2049, -1024.0
STOP_S = 1986
EDGE = 5.0                      # обочина дороги от оси, м
KERB_Z = 5.35                   # бордюр дома (локально)
DOOR_X = -6.35                  # вход в аптеку (локально)
PAD = (-26.0, 26.0, -28.0, 5.2)  # участок дома (x0, x1, z0, z1) локально
BLEND = 9.0

site = json.load(open(os.path.join(W, "story_site.json")))
if "house" in site:
    print("house already placed — nothing to do"); sys.exit(0)
h = np.frombuffer(gzip.open(os.path.join(W, "heightmap.f32.gz")).read(), dtype="<f4").reshape(N, N).astype(np.float64)
h0 = h.copy()
road = np.array(json.load(open(os.path.join(W, "road.json")))["points"])
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
right = np.array([-t[1], t[0]])                 # вправо по ходу (там остановка и тропинка)
R = rxz[STOP_S]
# дом слева от дороги: его +Z смотрит на дорогу (= +right), его +X — по ходу (= +t)
ez, ex = right, t
yaw = math.atan2(ez[0], ez[1])                  # Godot: Basis(UP, yaw) переводит +Z в (sin, cos)


def to_w(org, lx, lz):
    lx = np.asarray(lx, float); lz = np.asarray(lz, float)
    return org + lx[..., None] * ex + lz[..., None] * ez


def to_l(org, wx, wz):
    rel = np.stack([np.asarray(wx) - org[0], np.asarray(wz) - org[1]], -1)
    return rel @ ex, rel @ ez


# где поставить: вход в аптеку напротив остановки; бордюр — не ближе обочины по всей длине дома
from scipy.spatial import cKDTree
rt = cKDTree(rxz)
_rt = np.roll(rxz, -1, 0) - np.roll(rxz, 1, 0)
_rt /= np.linalg.norm(_rt, axis=1, keepdims=True)
rright = np.stack([-_rt[:, 1], _rt[:, 0]], 1)
lat = EDGE + 0.25 + KERB_Z
for _ in range(40):
    org = R - right * lat - ex * DOOR_X
    kx = np.linspace(-24.0, 24.0, 97)
    kerb = to_w(org, kx, np.full_like(kx, KERB_Z))
    _, ri = rt.query(kerb)
    side = ((kerb - rxz[ri]) * rright[ri]).sum(1)         # < 0 — слева от оси
    worst = side.max()
    if worst <= -(EDGE + 0.2):
        break
    lat += (-(EDGE + 0.2) - worst) * -1.0 + 0.05
print("house lateral %.2f m, kerb closest to road axis %.2f m" % (lat, -worst))
cross_y = float(road[STOP_S, 1])
level = cross_y + 0.18                           # низ бордюрного съезда (−0.2) — вровень с дорогой
print("house origin %.2f %.2f level %.2f yaw %.4f" % (org[0], org[1], level, yaw))

# ---------------------------------------------------------------- земля под домом
X, Z = np.meshgrid(np.arange(N) + O, np.arange(N) + O)
sub = (np.abs(X - org[0]) < 80) & (np.abs(Z - org[1]) < 80)
lx, lz = to_l(org, X[sub], Z[sub])
dx = np.maximum(np.maximum(PAD[0] - lx, lx - PAD[1]), 0)
dz_back = np.maximum(PAD[2] - lz, 0)
dz_road = np.maximum(lz - PAD[3], 0)
dist = np.hypot(dx, dz_back + dz_road * 4.0)      # к дороге — короткий откос (под асфальт не лезть)
w = 1.0 - np.clip(dist / BLEND, 0, 1)
w = w * w * (3 - 2 * w)
target = np.where(lz > 3.0, level - 0.06 - (lz - 3.0) * 0.08, level - 0.05)
hs = h[sub]
hs = hs * (1 - w) + target * w
h[sub] = hs
h32 = h.astype(np.float32)
with gzip.open(os.path.join(W, "heightmap.f32.gz"), "wb", compresslevel=6) as f:
    f.write(h32.astype("<f4").tobytes())
changed = np.abs(h32 - h0.astype(np.float32)) > 1e-4
ys, xs = np.nonzero(changed)
ry0, ry1, rx0, rx1 = max(ys.min() - 3, 1), min(ys.max() + 4, N - 1), max(xs.min() - 3, 1), min(xs.max() + 4, N - 1)
print("changed %d cells" % changed.sum())
nimg = np.array(Image.open(os.path.join(W, "terrain_normal.png")).convert("RGB"))
blk = h[ry0 - 1:ry1 + 1, rx0 - 1:rx1 + 1]
gz_, gx_ = np.gradient(blk)
nrm = np.stack([-gx_, np.ones_like(gx_), -gz_], -1)
nrm /= np.linalg.norm(nrm, axis=-1, keepdims=True)
enc = (np.stack([nrm[..., 0], nrm[..., 2], nrm[..., 1]], -1) * 127.5 + 127.5).clip(0, 255).astype(np.uint8)[1:-1, 1:-1]
nimg[ry0:ry1, rx0:rx1] = enc
Image.fromarray(nimg).save(os.path.join(W, "terrain_normal.png"), optimize=True)

# ---------------------------------------------------------------- растительность с участка
for set_name in ["trees", "understory", "bushes", "rocks", "props", "cover"]:
    fn = "inst_%s.bin.gz" % set_name
    raw = gzip.open(os.path.join(W, fn)).read()
    assert raw[:4] == b"FDI1"
    hl = struct.unpack_from("<I", raw, 4)[0]
    header = json.loads(raw[8:8 + hl])
    floats = np.frombuffer(raw[8 + hl:], dtype="<f4").reshape(-1, 16)
    gridn = int(header["grid"]); cell = float(header["cell"])
    margin = 3.5 if set_name == "trees" else 1.5
    blobs = []; off = 0; removed = 0; variants = []
    for v in header["variants"]:
        rows = floats[v["offset"]:v["offset"] + v["count"]]
        ix_, iz_ = to_l(org, rows[:, 3].astype(np.float64), rows[:, 11].astype(np.float64))
        inside = (ix_ > PAD[0] - margin) & (ix_ < PAD[1] + margin) & (iz_ > PAD[2] - margin) & (iz_ < KERB_Z + 6.0)
        rows = rows[~inside].copy()
        removed += int(inside.sum())
        if len(rows):
            nh = bil(h, rows[:, 3], rows[:, 11]); oh = bil(h0, rows[:, 3], rows[:, 11])
            rows[:, 7] += (nh - oh).astype(np.float32)
        cx = np.clip(((rows[:, 3] - O) // cell).astype(int), 0, gridn - 1)
        cz = np.clip(((rows[:, 11] - O) // cell).astype(int), 0, gridn - 1)
        cid = cz * gridn + cx
        if len(cid) and np.any(np.diff(cid) < 0):
            order = np.argsort(cid, kind="stable"); rows = rows[order]; cid = cid[order]
        uniq, start, cnt = np.unique(cid, return_index=True, return_counts=True)
        variants.append({"name": v["name"], "offset": off, "count": int(len(rows)),
                         "cells": np.stack([uniq, start, cnt], 1).astype(int).tolist() if len(rows) else []})
        blobs.append(rows.astype("<f4").tobytes()); off += len(rows)
    header["variants"] = variants
    js = json.dumps(header, separators=(",", ":")).encode()
    with gzip.open(os.path.join(W, fn), "wb", compresslevel=6) as f:
        f.write(b"FDI1" + struct.pack("<I", len(js)) + js + b"".join(blobs))
    print("%-11s removed %6d, kept %7d" % (set_name, removed, off))

# ---------------------------------------------------------------- маршрут коляски: прилавок → дверь → тротуар → дорога → тропинка
local_route = [  # x, y, z — локально (y — пол дома), последний — у остановки (мир)
    (-5.75, 0.10, -3.35),   # у прилавка (окошко провизора)
    (-6.05, 0.10, -2.2),
    (-6.30, 0.10, -0.9),
    (-6.35, 0.10, -0.2),    # дверь
    (-6.35, 0.06, 0.6),     # пандус
    (-6.35, 0.02, 1.45),
    (-6.35, 0.12, 2.6),     # тротуар
    (-6.35, 0.12, 4.4),
    (-6.35, -0.18, 5.6),    # бордюрный съезд → дорога
]
route = []
for x, y, z in local_route:
    p = to_w(org, x, z)
    route.append([round(float(p[0]), 3), round(float(level + y), 3), round(float(p[1]), 3)])
p0 = site["path"][0]
mid = [(route[-1][0] + p0[0]) * 0.5, cross_y + 0.02, (route[-1][2] + p0[2]) * 0.5]
route.append([round(mid[0], 3), round(mid[1], 3), round(mid[2], 3)])
site["house"] = {"origin": [round(float(org[0]), 3), round(level, 3), round(float(org[1]), 3)], "yaw": round(yaw, 5),
                 "route": route}
json.dump(site, open(os.path.join(W, "story_site.json"), "w"), indent=1)
print("story_site.json: house + %d route points" % len(route))
