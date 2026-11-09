"""Маршрут коляски от конца лесной тропинки по пандусу к входной двери санатория (пролог «The Last Shake»).

Пандус здания — с разворотом: нижний марш (вдоль −X), площадка, верхний марш (вдоль +X), площадка у входа.
Точки задаются вручную (середина маршей, между бортиками), сглаживаются сплайном Катмулла — Рома и
берутся через 0,3 м; высота — с поверхности пандуса/площадки из sanatorium.glb, а на земле — с ландшафта
(флаг g = 1, высоту считает игра).
Координаты — здания (как в sanatorium/assets/level.json): x вдоль фасада, y вверх, z от фасада.
Запуск: python3 make_entrance_route.py <the_last_shake>  → resources/world/entrance_route.json
"""
import json
import os
import struct
import sys

import numpy as np

PROJ = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "..", "the_last_shake")
STEP = 0.3

# (x, z, на земле?) — от конца тропинки (2.0, 2.9) вдоль пандуса снаружи, к подножию нижнего марша, вверх,
# разворот на средней площадке, верхний марш, площадка у входа, дверь «А» (z = 4.27) и тамбур.
CONTROL = [
    (2.0, 2.9, 1), (3.4, 4.6, 1), (5.6, 6.0, 1), (8.0, 6.45, 1), (12.0, 6.5, 1), (16.0, 6.5, 1),
    (17.9, 6.35, 1), (18.85, 5.75, 1), (19.0, 5.0, 1), (18.6, 4.4, 1),
    (17.6, 4.3, 0), (14.0, 4.3, 0), (10.6, 4.3, 0),
    (9.55, 4.2, 0), (9.0, 3.65, 0), (8.85, 2.85, 0), (9.0, 2.05, 0), (9.55, 1.5, 0),
    (10.6, 1.38, 0), (14.0, 1.38, 0), (18.0, 1.38, 0), (21.6, 1.38, 0),
    (22.6, 1.45, 0), (23.7, 1.75, 0), (24.6, 2.35, 0), (25.35, 3.3, 0), (25.9, 4.05, 0), (26.5, 4.27, 0),
    (27.2, 4.27, 0), (27.9, 4.27, 0), (28.75, 4.27, 0),
]


def load_glb(path):
    b = open(path, "rb").read()
    ln, = struct.unpack_from("<I", b, 12)
    js = json.loads(b[20:20 + ln])
    bl, = struct.unpack_from("<I", b, 20 + ln)
    return js, b[20 + ln + 8: 20 + ln + 8 + bl]


def tris(js, bin_, name):
    comp = {5126: np.float32, 5123: np.uint16, 5125: np.uint32}
    ncomp = {"SCALAR": 1, "VEC3": 3}

    def acc(ai):
        a = js["accessors"][ai]
        v = js["bufferViews"][a["bufferView"]]
        n = ncomp[a["type"]]
        return np.frombuffer(bin_, dtype=comp[a["componentType"]], count=a["count"] * n,
                             offset=v.get("byteOffset", 0) + a.get("byteOffset", 0)).reshape(a["count"], n)
    node = [n for n in js["nodes"] if n.get("name") == name][0]
    out = []
    for p in js["meshes"][node["mesh"]]["primitives"]:
        out.append(acc(p["attributes"]["POSITION"])[acc(p["indices"]).reshape(-1)].reshape(-1, 3, 3))
    return np.concatenate(out).astype(np.float64)


def surface_y(T, x, z):
    """Самая высокая точка поверхности над (x, z) или None."""
    a, b, c = T[:, 0], T[:, 1], T[:, 2]
    v0 = c - a
    v1 = b - a
    v2x = x - a[:, 0]
    v2z = z - a[:, 2]
    d00 = v0[:, 0] ** 2 + v0[:, 2] ** 2
    d01 = v0[:, 0] * v1[:, 0] + v0[:, 2] * v1[:, 2]
    d11 = v1[:, 0] ** 2 + v1[:, 2] ** 2
    d20 = v2x * v0[:, 0] + v2z * v0[:, 2]
    d21 = v2x * v1[:, 0] + v2z * v1[:, 2]
    den = d00 * d11 - d01 * d01
    ok = np.abs(den) > 1e-9
    den = np.where(ok, den, 1.0)
    u = (d11 * d20 - d01 * d21) / den
    v = (d00 * d21 - d01 * d20) / den
    inside = ok & (u >= -1e-4) & (v >= -1e-4) & (u + v <= 1 + 1e-4)
    if not inside.any():
        return None
    y = a[:, 1] + u * v0[:, 1] + v * v1[:, 1]
    return float(y[inside].max())


def catmull(points, step):
    p = np.array(points, dtype=np.float64)
    p = np.vstack([p[0] * 2 - p[1], p, p[-1] * 2 - p[-2]])
    dense = []
    for i in range(1, len(p) - 2):
        p0, p1, p2, p3 = p[i - 1], p[i], p[i + 1], p[i + 2]
        for t in np.linspace(0, 1, 24, endpoint=False):
            t2, t3 = t * t, t * t * t
            dense.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3))
    dense.append(p[-2])
    dense = np.array(dense)
    seg = np.linalg.norm(np.diff(dense, axis=0), axis=1)
    cum = np.concatenate([[0], np.cumsum(seg)])
    ss = np.arange(0, cum[-1], step)
    ss = np.append(ss, cum[-1])
    return np.stack([np.interp(ss, cum, dense[:, 0]), np.interp(ss, cum, dense[:, 1])], -1)


def main():
    js, bin_ = load_glb(os.path.join(PROJ, "sanatorium", "assets", "sanatorium.glb"))
    ramp = tris(js, bin_, "Ramp_Structure")
    landing = tris(js, bin_, "Entrance_Landing_Stairs")
    xz = catmull([(c[0], c[1]) for c in CONTROL], STEP)
    # где начинается пандус: первая контрольная точка без флага «земля»
    first_ramp = next(i for i, c in enumerate(CONTROL) if c[2] == 0)
    ramp_start = np.array(CONTROL[first_ramp][:2])
    on_ground = True
    out = []
    for x, z in xz:
        if on_ground and np.hypot(x - ramp_start[0], z - ramp_start[1]) < STEP * 0.75:
            on_ground = False
        if on_ground:
            out.append([round(float(x), 3), 0.0, round(float(z), 3), 1])
            continue
        if x > 27.3:                                        # дверь и тамбур: пол 1-го этажа
            y = 1.2
        else:
            ys = [v for v in (surface_y(ramp, x, z), surface_y(landing, x, z)) if v is not None]
            y = max(ys) if ys else 0.0
        out.append([round(float(x), 3), round(y, 3), round(float(z), 3), 0])
    # подножие пандуса: высота плавно от земли
    data = {
        "about": "маршрут коляски по пандусу к двери санатория, координаты здания; [x, y, z, на_земле]",
        "points": out,
    }
    dst = os.path.join(PROJ, "resources", "world", "entrance_route.json")
    json.dump(data, open(dst, "w"), separators=(",", ":"))
    ys = [p[1] for p in out if not p[3]]
    print("%d points, %.1f m, ramp y %.2f..%.2f -> %s" % (len(out), STEP * (len(out) - 1), min(ys), max(ys), dst))
    # проверка: подъём не круче 9 % на шаге
    prev = None
    worst = 0.0
    for p in out:
        if prev is not None and not p[3] and not prev[3]:
            d = np.hypot(p[0] - prev[0], p[2] - prev[2])
            worst = max(worst, abs(p[1] - prev[1]) / max(d, 1e-6))
        prev = p
    print("steepest step %.1f %%" % (worst * 100))


main()
