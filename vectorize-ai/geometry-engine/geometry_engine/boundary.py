"""Fit a complete boundary (an interface between two regions).

Corner detection splits the boundary into sections; restored sharp corners
become exact C0 vertices (support lines are extended to their intersection
and the raster-rounded samples next to the corner are excluded), everything
else is fitted with G1 continuous curves."""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .fitting import (
    CornerInfo,
    CornerOptions,
    CurveOptions,
    arc_length,
    center_tangent,
    detect_corners,
    fit_section,
    smooth_points,
)
from .primitives import Line, Segment


@dataclass
class BoundaryFit:
    segments: list[Segment]
    corners: list[CornerInfo]


def _trimmed_section(pts, w, s, i0, i1, trim0, trim1):
    """Points strictly between indices i0..i1 excluding the trimmed zones."""
    sub = pts[i0 : i1 + 1]
    ws = w[i0 : i1 + 1]
    ss = s[i0 : i1 + 1] - s[i0]
    total = ss[-1] if ss.shape[0] else 0.0
    keep = (ss >= trim0) & (ss <= total - trim1)
    keep[0] = keep[-1] = True
    return sub[keep], ws[keep]


def fit_open(pts: np.ndarray, w: np.ndarray, copts: CurveOptions, kopts: CornerOptions, sigma: float, max_radius: float) -> BoundaryFit:
    n = pts.shape[0]
    if n <= 2:
        return BoundaryFit([Line(tuple(pts[0]), tuple(pts[-1]))], [])
    sm = smooth_points(pts, sigma)
    corners = detect_corners(sm, False, kopts)
    s = arc_length(sm)
    breaks = [(0, sm[0], 0.0)] + [(c.index, c.point, c.trim) for c in corners] + [(n - 1, sm[-1], 0.0)]
    segs: list[Segment] = []
    for (i0, p0, tr0), (i1, p1, tr1) in zip(breaks[:-1], breaks[1:]):
        if i1 <= i0:
            continue
        sec, ws = _trimmed_section(sm, w, s, i0, i1, tr0, tr1)
        sec = sec.copy()
        sec[0], sec[-1] = p0, p1
        segs.extend(fit_section(sec, ws, copts, max_radius=max_radius))
    return BoundaryFit(_stitch(segs), corners)


def fit_closed(pts: np.ndarray, w: np.ndarray, copts: CurveOptions, kopts: CornerOptions, sigma: float, max_radius: float) -> BoundaryFit:
    if pts.shape[0] > 1 and np.allclose(pts[0], pts[-1]):
        pts, w = pts[:-1], w[:-1]
    n = pts.shape[0]
    if n < 3:
        p = tuple(pts[0])
        return BoundaryFit([Line(p, p)], [])
    sm = smooth_points(pts, sigma, closed=True)
    corners = detect_corners(sm, True, kopts)
    if corners:
        first = corners[0].index
        sm = np.roll(sm, -first, axis=0)
        w = np.roll(w, -first)
        corners = [CornerInfo((c.index - first) % n, c.point, c.sharp, c.angle, c.trim) for c in corners]
        corners.sort(key=lambda c: c.index)
        loop = np.concatenate([sm, sm[:1]])
        wl = np.concatenate([w, w[:1]])
        s = arc_length(loop)
        breaks = [(c.index, c.point, c.trim) for c in corners] + [(n, corners[0].point, corners[0].trim)]
        segs: list[Segment] = []
        for (i0, p0, tr0), (i1, p1, tr1) in zip(breaks[:-1], breaks[1:]):
            sec, ws = _trimmed_section(loop, wl, s, i0, i1, tr0, tr1)
            sec = sec.copy()
            sec[0], sec[-1] = p0, p1
            segs.extend(fit_section(sec, ws, copts, max_radius=max_radius))
        return BoundaryFit(_stitch(segs, closed=True), corners)
    # No corners: two halves joined with matched tangents (G1 everywhere).
    half = n // 2
    loop = np.concatenate([sm, sm[:1]])
    wl = np.concatenate([w, w[:1]])
    total = float(arc_length(loop)[-1])
    window = max(1.5, min(4.0, total / 8))
    ext = np.concatenate([sm[-8:], sm, sm[:8]]) if n > 8 else np.concatenate([sm, sm, sm])
    off = 8 if n > 8 else n
    t0 = center_tangent(ext, off, window)
    th = center_tangent(ext, off + half, window)
    a = fit_section(loop[: half + 1], wl[: half + 1], copts, t0, th, max_radius)
    b = fit_section(loop[half:], wl[half:], copts, th, t0, max_radius)
    return BoundaryFit(_stitch(a + b, closed=True), [])


def _stitch(segs: list[Segment], closed: bool = False) -> list[Segment]:
    """Force exact endpoint continuity between consecutive segments."""
    from .primitives import move_endpoint

    if not segs:
        return segs
    out = [segs[0]]
    for s in segs[1:]:
        prev_end = out[-1].end()
        if s.start() != prev_end:
            fixed = move_endpoint(s, prev_end, at_end=False)
            out.extend(fixed)
        else:
            out.append(s)
    if closed and out[-1].end() != out[0].start():
        tail = move_endpoint(out[-1], out[0].start(), at_end=True)
        out = out[:-1] + tail
    return out
