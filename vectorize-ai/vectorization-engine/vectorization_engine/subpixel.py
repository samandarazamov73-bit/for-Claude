"""Stage 5 — sub-pixel boundary samples.

Anti-aliased rasterisation stores, in every edge pixel, the fraction of the
pixel covered by each side. For a crack between region A (west/north) and B
(east/south) we read the row (or column) of pixels across the crack,
estimate each pixel's A-coverage ``a = proj(c - cB, cA - cB)`` in
premultiplied sRGBA, and use the identity::

    sum_i coverage_i  =  t - x0      (box-filtered straight edge)

to recover the edge position ``t`` with sub-pixel precision. A crack
measures the boundary position along its normal axis, so a sample is only
trusted where the boundary crosses that axis steeply; elsewhere it is
down-weighted. Hard (aliased) edges fall back to crack midpoints.

``EdgeRefiner`` in ``ml.py`` allows replacing this with a learned model."""
from __future__ import annotations

import math

import numpy as np

from .graph import VectorGraph
from .topology import CrackField


def region_pm_colors(region_color: np.ndarray, palette: np.ndarray) -> np.ndarray:
    pal = np.zeros((palette.shape[0] + 1, 4), dtype=np.float64)
    if palette.shape[0]:
        pal[:-1, :3] = palette[:, :3] * (palette[:, 3:4] / 255.0)
        pal[:-1, 3] = palette[:, 3]
    idx = np.where(region_color >= 0, region_color, palette.shape[0])
    return pal[idx]


def crack_samples(cf: CrackField, rgba: np.ndarray, regions: np.ndarray, reg_pm: np.ndarray, enabled: bool = True):
    """Return (samples (n,2), soft (n,) bool, contrast (n,))."""
    mid = cf.midpoints()
    n = cf.n
    h, w = regions.shape
    contrast = np.zeros(n)
    soft = np.zeros(n, dtype=bool)
    if n == 0:
        return mid, soft, contrast
    ca, cb = reg_pm[cf.ra], reg_pm[cf.rb]
    d = ca - cb
    dd = (d * d).sum(1)
    contrast = np.sqrt(dd)
    if not enabled:
        return mid, soft, contrast
    pm = rgba.astype(np.float64)
    pm[..., :3] *= pm[..., 3:4] / 255.0
    border = (cf.ra == 0) | (cf.rb == 0)
    usable = (~border) & (contrast >= 15.0)
    vert = cf.kind == 0
    r, c = cf.r, cf.c
    # pixel positions along the crack normal: p[-2], p[-1] (side A), p[0], p[1] (side B)
    out_t = np.where(vert, c, r).astype(np.float64)
    pos = {}
    for k in (-2, -1, 0, 1):
        if True:
            yy = np.where(vert, r, r + k)
            xx = np.where(vert, c + k, c)
            inside = (yy >= 0) & (yy < h) & (xx >= 0) & (xx < w)
            yyc, xxc = np.clip(yy, 0, h - 1), np.clip(xx, 0, w - 1)
            pos[k] = (yyc, xxc, inside)
    alphas = {}
    safe_dd = np.maximum(dd, 1e-9)
    for k, (yy, xx, inside) in pos.items():
        px = pm[yy, xx]
        a = ((px - cb) * d).sum(1) / safe_dd
        alphas[k] = np.clip(a, 0.0, 1.0)
    reg_m2 = regions[pos[-2][0], pos[-2][1]]
    reg_p1 = regions[pos[1][0], pos[1][1]]
    k2 = pos[-2][2] & pos[1][2] & (reg_m2 == cf.ra) & (reg_p1 == cf.rb)
    t1 = out_t - 1 + alphas[-1] + alphas[0]
    t2 = out_t - 2 + alphas[-2] + alphas[-1] + alphas[0] + alphas[1]
    t = np.where(k2, t2, t1)
    t = np.clip(t, out_t - 1.0, out_t + 1.0)
    frac = ((alphas[-1] > 0.04) & (alphas[-1] < 0.96)) | ((alphas[0] > 0.04) & (alphas[0] < 0.96))
    soft = usable & frac
    samples = mid.copy()
    sx = np.where(vert, t, mid[:, 0])
    sy = np.where(vert, mid[:, 1], t)
    samples[soft, 0] = sx[soft]
    samples[soft, 1] = sy[soft]
    return samples, soft, contrast


def assign_samples(g: VectorGraph, cf: CrackField, samples: np.ndarray, soft: np.ndarray, contrast: np.ndarray) -> None:
    mid = cf.midpoints()
    for f in g.interfaces.values():
        ch = f.cracks
        m = mid[ch]
        nk = ch.shape[0]
        if nk >= 3:
            idx = np.arange(nk)
            if f.closed:
                a, b = (idx + 3) % nk, (idx - 3) % nk
            else:
                a, b = np.minimum(idx + 3, nk - 1), np.maximum(idx - 3, 0)
            tg = m[a] - m[b]
            tn = np.hypot(tg[:, 0], tg[:, 1])
            tn[tn == 0] = 1.0
            vert = cf.kind[ch] == 0
            wdir = np.where(vert, np.abs(tg[:, 1]) / tn, np.abs(tg[:, 0]) / tn)
        else:
            wdir = np.ones(nk)
        s = samples[ch]
        sf = soft[ch]
        wgt = np.where(sf, wdir, 1.0)
        keep = (~sf) | (wdir >= 0.3)
        # crisp cracks on a soft boundary are kept but down-weighted
        if keep.sum() < 2:
            keep[:] = True
        pts, ww = s[keep], np.maximum(wgt[keep], 0.15)
        if not f.closed:
            pts = np.concatenate([f.raw[:1], pts, f.raw[-1:]])
            ww = np.concatenate([[1.0], ww, [1.0]])
        f.samples = pts
        f.weights = ww
        f.contrast = float(np.median(contrast[ch])) if nk else 255.0


def refine_junctions(g: VectorGraph, max_move: float = 0.9) -> None:
    """Move each junction to the least-squares intersection of the local
    boundary lines of its interfaces (sub-pixel junction positions)."""
    incident: dict[int, list[np.ndarray]] = {}
    for f in g.interfaces.values():
        if f.closed or f.samples is None or f.samples.shape[0] < 3:
            continue
        head = f.samples[1 : min(5, f.samples.shape[0] - 1)]
        tail = f.samples[max(1, f.samples.shape[0] - 5) : -1]
        if head.shape[0] >= 2:
            incident.setdefault(f.start, []).append(head)
        if tail.shape[0] >= 2:
            incident.setdefault(f.end, []).append(tail)
    for nid, groups in incident.items():
        node = g.nodes[nid]
        a = np.zeros((2, 2))
        b = np.zeros(2)
        for pts in groups:
            c = pts.mean(0)
            dv = pts[-1] - pts[0]
            ln = math.hypot(*dv)
            if ln < 1e-6:
                continue
            dv = dv / ln
            m = np.eye(2) - np.outer(dv, dv)
            a += m
            b += m @ c
        if np.linalg.cond(a) > 1e3:
            continue
        p = np.linalg.solve(a, b)
        orig = np.array([node.x, node.y])
        if node.border:
            # stay on the image border
            if node.x in (0.0, float(g.width)):
                p[0] = node.x
            if node.y in (0.0, float(g.height)):
                p[1] = node.y
        mv = p - orig
        dist = math.hypot(*mv)
        if dist > max_move:
            p = orig + mv * (max_move / dist)
        node.x, node.y = float(p[0]), float(p[1])
    for f in g.interfaces.values():
        if f.closed or f.samples is None:
            continue
        f.samples = f.samples.copy()
        f.samples[0] = g.nodes[f.start].pt
        f.samples[-1] = g.nodes[f.end].pt
