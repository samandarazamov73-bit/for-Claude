"""Fit a complete boundary (an interface between two regions).

Corner detection splits the boundary into sections; restored sharp corners
become exact C0 vertices (support lines are extended to their intersection
and the raster-rounded samples next to the corner are excluded), everything
else is fitted with G1 continuous curves."""
from __future__ import annotations

from dataclasses import dataclass

import math

import numpy as np

from .fitting import (
    CornerInfo,
    CornerOptions,
    CurveOptions,
    arc_length,
    center_tangent,
    detect_corners,
    fit_line_dir,
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


def _section_line(sec: np.ndarray, tol: float):
    """Least-squares line of a section's interior if the section is
    straight (same length-scaled test as the line fit), else None."""
    if sec.shape[0] < 6:
        return None
    chord = float(np.hypot(*(sec[-1] - sec[0])))
    if chord < 10.0:
        return None
    inner = sec[1:-1]
    c, d = fit_line_dir(inner)
    dev = (inner - c) @ np.array([-d[1], d[0]])
    tol_line = max(tol, min(1.4, 0.008 * chord))
    if np.abs(dev).max() > tol_line or float(np.sqrt((dev * dev).mean())) > 0.4 * tol_line:
        return None
    # Edges within a fraction of a degree of horizontal or vertical are
    # meant to be exactly that (stems, bars, frames); keep them so when the
    # points still fit the axis-aligned line through the centroid.
    ang = math.degrees(math.atan2(d[1], d[0])) % 90.0
    off = min(ang, 90.0 - ang)
    if off < 0.8:
        axis = np.array([1.0, 0.0]) if abs(d[0]) >= abs(d[1]) else np.array([0.0, 1.0])
        dev_a = (inner - c) @ np.array([-axis[1], axis[0]])
        if np.abs(dev_a).max() <= tol_line:
            d = axis
    return c, d


def _snap_corners(secs: list, corner_pts: list, tol: float, cyclic: bool) -> list:
    """Move corners that join two straight sections to the intersection of
    the sections' long least-squares lines. Corner points restored from
    short support lines can sit a pixel off, which tilts both edges; the
    long lines fix that and give exactly straight edges and crisp corners.
    ``corner_pts[i]`` is the corner between section i-1 and section i."""
    lines = [_section_line(sec, tol) for sec in secs]
    out = list(corner_pts)
    m = len(secs)
    for i in range(len(corner_pts)):
        a, b = (i - 1) % m if cyclic else i - 1, i
        if a < 0 or b >= m or lines[a] is None or lines[b] is None:
            continue
        (c1, d1), (c2, d2) = lines[a], lines[b]
        if abs(float(d1 @ d2)) > math.cos(math.radians(10.0)):
            continue
        mat = np.array([[d1[0], -d2[0]], [d1[1], -d2[1]]])
        try:
            t = np.linalg.solve(mat, c2 - c1)
        except np.linalg.LinAlgError:
            continue
        v = c1 + t[0] * d1
        if float(np.hypot(*(v - np.asarray(corner_pts[i])))) <= 2.5:
            out[i] = v
    return out


def fit_open(pts: np.ndarray, w: np.ndarray, copts: CurveOptions, kopts: CornerOptions, sigma: float, max_radius: float) -> BoundaryFit:
    n = pts.shape[0]
    if n <= 2:
        return BoundaryFit([Line(tuple(pts[0]), tuple(pts[-1]))], [])
    sm = smooth_points(pts, sigma)
    corners = detect_corners(sm, False, kopts)
    s = arc_length(sm)
    breaks = [(0, sm[0], 0.0)] + [(c.index, c.point, c.trim) for c in corners] + [(n - 1, sm[-1], 0.0)]
    secs = []
    for (i0, p0, tr0), (i1, p1, tr1) in zip(breaks[:-1], breaks[1:]):
        if i1 <= i0:
            continue
        sec, ws = _trimmed_section(sm, w, s, i0, i1, tr0, tr1)
        sec = sec.copy()
        sec[0], sec[-1] = p0, p1
        secs.append((sec, ws))
    if len(secs) == len(breaks) - 1 and corners:
        # inner break points are corners (the open ends are fixed junctions)
        pts_c = [np.asarray(b[1], dtype=np.float64) for b in breaks[1:-1]]
        snapped = _snap_corners([x[0] for x in secs], [None] + pts_c, copts.tolerance, cyclic=False)[1:]
        for k, v in enumerate(snapped):
            secs[k][0][-1] = v
            secs[k + 1][0][0] = v
    segs: list[Segment] = []
    for sec, ws in secs:
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
        secs = []
        for (i0, p0, tr0), (i1, p1, tr1) in zip(breaks[:-1], breaks[1:]):
            sec, ws = _trimmed_section(loop, wl, s, i0, i1, tr0, tr1)
            sec = sec.copy()
            sec[0], sec[-1] = p0, p1
            secs.append((sec, ws))
        # corner i sits between section i-1 and section i (cyclically)
        snapped = _snap_corners([x[0] for x in secs], [np.asarray(c.point, dtype=np.float64) for c in corners], copts.tolerance, cyclic=True)
        m = len(secs)
        for i, v in enumerate(snapped):
            secs[(i - 1) % m][0][-1] = v
            secs[i][0][0] = v
        segs: list[Segment] = []
        for sec, ws in secs:
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
