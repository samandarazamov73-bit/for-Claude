#!/usr/bin/env python3
"""Суставы для статичной модели человека в A-позе (Meshy, без скелета): где таз, позвоночник, плечи, локти,
кисти, колени, лодыжки и носки — по форме самой модели (срезы по высоте) и обычным пропорциям тела.

Модель приводится к метрам: рост `height`, ступни на полу (y = 0), лицом в +Z, x — влево персонажа.
Возвращает словарь {имя кости Mixamo: (x, y, z)} и преобразование исходных координат → метры.
"""
import numpy as np

# высоты суставов в долях роста (как в скелетах Meshy/Mixamo у наших персонажей)
Y = {"Hips": 0.560, "Spine": 0.635, "Spine1": 0.705, "Spine2": 0.775, "Neck": 0.830, "Head": 0.880,
     "HeadTop_End": 0.995, "LeftShoulder": 0.800, "LeftUpLeg": 0.505, "LeftLeg": 0.287, "LeftFoot": 0.066,
     "LeftToeBase": 0.022}
UPPER, FORE = 0.180, 0.148           # плечо и предплечье, доли роста


def normalize(pos, height):
    """Исходные вершины → метры: рост height, ступни на полу, середина между ступнями — x = z = 0."""
    lo, hi = pos[:, 1].min(), pos[:, 1].max()
    k = height / (hi - lo)
    p = (pos - [0, lo, 0]) * k
    feet = p[p[:, 1] < 0.04 * height]
    c = (feet.min(0) + feet.max(0)) * 0.5
    off = np.array([-c[0], 0.0, -c[2]])
    return p + off, k, np.array([0, -lo * k, 0]) + off


def surface(p, tris, n=400000, seed=7):
    """Точки по поверхности (равномерно по площади) — в тонких срезах вершин мало, точек — много."""
    rng = np.random.default_rng(seed)
    a, b, c = p[tris[:, 0]], p[tris[:, 1]], p[tris[:, 2]]
    area = np.linalg.norm(np.cross(b - a, c - a), axis=1)
    k = rng.choice(len(tris), n, p=area / area.sum())
    u, v = rng.random(n), rng.random(n)
    f = u + v > 1
    u[f], v[f] = 1 - u[f], 1 - v[f]
    return a[k] + (b[k] - a[k]) * u[:, None] + (c[k] - a[k]) * v[:, None]


def _slab(p, y, h, d=0.012):
    return p[np.abs(p[:, 1] - y * h) < d * h]


def _torso_center(p, y, h, half=0.05):
    s = _slab(p, y, h)
    s = s[np.abs(s[:, 0]) < half * h]
    if len(s) < 3:
        return 0.0
    return float((s[:, 2].min() + s[:, 2].max()) * 0.5)


def _leg_line(p, h, side):
    """Ось ноги по срезам, где нога видна отдельно (между ногами — щель, ширина как у ноги): x(y), z(y)."""
    rows = []
    for y in np.linspace(0.08, 0.46, 39):
        sl = _slab(p, y, h, 0.004)
        sl = sl[(sl[:, 0] * side > 0) & (np.abs(sl[:, 0]) < 0.13 * h)]       # без трости и сумки
        if len(sl) < 20:
            continue
        x0, x1 = np.abs(sl[:, 0]).min(), np.abs(sl[:, 0]).max()
        if x0 < 0.008 * h or x1 - x0 > 0.085 * h:
            continue                                                       # юбка / полы пальто
        rows.append([y * h, side * (x0 + x1) * 0.5, (sl[:, 2].min() + sl[:, 2].max()) * 0.5])
    return np.array(rows)


def _shoulder(p, h, side):
    """Плечевой сустав: внешний край плеча на его высоте минус толщина дельтовидной мышцы."""
    ys = 0.792
    sl = _slab(p, ys, h, 0.01)
    sl = sl[(sl[:, 0] * side > 0) & (sl[:, 0] * side < 0.16 * h)]
    x_out = np.abs(sl[:, 0]).max()
    return np.array([side * (x_out - 0.05 * h), ys * h, _torso_center(p, ys, h)])


PX = 0.002                           # силуэт: 2 мм на пиксель


def silhouette(p, tris):
    """Силуэт спереди (x, y) — маска; строка 0 — y = 0, столбец c — x = (c − c0)·PX."""
    from PIL import Image, ImageDraw
    w = int(np.abs(p[:, 0]).max() / PX) * 2 + 8
    hh = int(p[:, 1].max() / PX) + 4
    img = Image.new("1", (w, hh), 0)
    d = ImageDraw.Draw(img)
    c0 = w // 2
    xy = np.stack([p[:, 0] / PX + c0, p[:, 1] / PX], 1)
    for t in tris:
        d.polygon([tuple(xy[t[0]]), tuple(xy[t[1]]), tuple(xy[t[2]])], fill=1, outline=1)
    return np.array(img, dtype=bool), c0


def _arm(p, h, side, sh, sil):
    """Средняя линия руки — по силуэту спереди: в строке рука — крайний отрезок, отделённый от туловища
    фоном (сумки и трость — ниже кисти, их не берём); глубина — по вершинам этого отрезка. Локоть и запястье —
    на этой линии по длинам костей от плечевого сустава."""
    mask, c0 = sil
    pts = []
    for y in np.linspace(0.75, 0.42, 60):
        r = int(y * h / PX)
        row = mask[r]
        xs = np.nonzero(row)[0]
        if len(xs) == 0:
            continue
        runs = np.split(xs, np.nonzero(np.diff(xs) > 1)[0] + 1)
        runs = [ru for ru in runs if (ru.mean() - c0) * side > 0]
        if len(runs) < 2 and not (len(runs) == 1 and y < 0.5):
            continue
        ru = max(runs, key=lambda q: (q.mean() - c0) * side)
        if min(abs(ru[0] - c0), abs(ru[-1] - c0)) * PX < 0.06 * h:
            continue                                        # это туловище или нога, а не рука
        x0, x1 = sorted([(ru[0] - c0) * PX, (ru[-1] - c0) * PX])
        m = (np.abs(p[:, 1] - y * h) < 0.012 * h) & (p[:, 0] >= x0) & (p[:, 0] <= x1)
        if m.sum() < 2:
            continue
        pts.append([(x0 + x1) * 0.5, y * h, (p[m, 2].min() + p[m, 2].max()) * 0.5])
    line = np.vstack([sh, np.array(pts)])

    def at(dist):
        acc_ = 0.0
        for i in range(len(line) - 1):
            seg = line[i + 1] - line[i]
            L = np.linalg.norm(seg)
            if L > 0 and acc_ + L >= dist:
                return line[i] + seg * ((dist - acc_) / L)
            acc_ += L
        d = line[-1] - line[max(0, len(line) - 6)]
        return line[-1] + d / np.linalg.norm(d) * (dist - acc_)

    elbow = at(UPPER * h)
    wrist = at((UPPER + FORE) * h)
    d = wrist - at((UPPER + FORE - 0.05) * h)
    return elbow, wrist, wrist + d / np.linalg.norm(d) * 0.10 * h


def landmarks(p, h, tris):
    sil = silhouette(p, tris)
    sp = surface(p, tris)
    J = {}
    for nm in ["Hips", "Spine", "Spine1", "Spine2", "Neck", "Head", "HeadTop_End"]:
        J[nm] = np.array([0.0, Y[nm] * h, _torso_center(sp, Y[nm], h, 0.03 if nm in ("Neck", "Head") else 0.04)])
    J["HeadTop_End"][2] = J["Head"][2]
    for side, pre in [(1, "Left"), (-1, "Right")]:
        sh = _shoulder(sp, h, side)
        e, w, tip = _arm(sp, h, side, sh, sil)
        J[pre + "Shoulder"] = np.array([side * 0.022 * h, Y["LeftShoulder"] * h, sh[2]])
        J[pre + "Arm"] = sh
        J[pre + "ForeArm"], J[pre + "Hand"], J[pre + "HandMiddle1"] = e, w, w + (tip - w) * 0.45
        J[pre + "HandTip"] = tip
        # ноги: ось ноги по видимым срезам (голень, у брюк — и бедро); бедренный сустав — по пропорциям
        rows = _leg_line(sp, h, side)
        yk, yh = Y["LeftLeg"] * h, Y["LeftUpLeg"] * h
        if len(rows) >= 3:
            A = np.stack([rows[:, 0], np.ones(len(rows))], 1)
            kx, *_ = np.linalg.lstsq(A, rows[:, 1], rcond=None)
            kz, *_ = np.linalg.lstsq(A, rows[:, 2], rcond=None)
            knee = np.array([kx[0] * yk + kx[1], yk, kz[0] * yk + kz[1]])
            hx = np.clip(abs(kx[0] * yh + kx[1]), 0.045 * h, 0.062 * h)
        else:
            knee = np.array([side * 0.05 * h, yk, 0.0])
            hx = 0.05 * h
        hip = np.array([side * hx, yh, _torso_center(sp, Y["LeftUpLeg"], h)])
        J[pre + "UpLeg"] = hip
        J[pre + "Leg"] = knee
        foot = sp[(sp[:, 1] < 0.03 * h) & (sp[:, 0] * side > 0) & (np.abs(sp[:, 0]) < 0.13 * h)]
        heel, toe = foot[:, 2].min(), foot[:, 2].max()
        fx = (foot[:, 0].min() + foot[:, 0].max()) * 0.5
        J[pre + "Foot"] = np.array([fx, Y["LeftFoot"] * h, heel + 0.22 * (toe - heel)])
        J[pre + "ToeBase"] = np.array([fx, Y["LeftToeBase"] * h, heel + 0.74 * (toe - heel)])
        J[pre + "Toe_End"] = np.array([fx, Y["LeftToeBase"] * h, toe - 0.01 * h])
    return J
