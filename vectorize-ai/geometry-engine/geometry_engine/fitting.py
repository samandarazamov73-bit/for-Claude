"""Curve fitting: point sequences -> lines, circular arcs and Bezier curves.

* ``fit_cubics``   – weighted least-squares cubic Bezier fitting with
  Newton-Raphson reparameterisation and recursive splitting (after
  P. J. Schneider, *An Algorithm for Automatically Fitting Digitized Curves*).
  Splits use a shared centre tangent, so consecutive pieces are G1
  continuous ("tangent matching").
* ``fit_section``  – chooses the simplest adequate model for a corner-free
  run of points: a line, a circular arc, or a G1 chain of cubics, then
  honours the allowed curve types (quadratic / line-only output).
* ``smooth_points`` – Gaussian fairing of noisy boundary samples.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

from .primitives import Arc, CubicBezier, Line, Pt, QuadBezier, Segment


@dataclass
class CurveOptions:
    tolerance: float = 0.5  # max deviation in px
    allow_cubic: bool = True
    allow_quadratic: bool = True
    allow_arcs: bool = True
    min_arc_sweep: float = math.radians(25)
    max_depth: int = 24


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def arc_length(pts: np.ndarray) -> np.ndarray:
    if pts.shape[0] == 0:
        return np.zeros(0)
    d = np.sqrt((np.diff(pts, axis=0) ** 2).sum(1))
    return np.concatenate([[0.0], np.cumsum(d)])


def smooth_points(pts: np.ndarray, sigma: float, *, closed: bool = False, fixed: np.ndarray | None = None) -> np.ndarray:
    """Gaussian smoothing along the sequence (index domain). ``fixed`` marks
    indices that must not move (junctions, corners)."""
    n = pts.shape[0]
    if sigma <= 0 or n < 3:
        return pts.copy()
    if closed:
        sigma = min(sigma, n / 6.0)  # small loops would otherwise shrink to a point
    rad = int(math.ceil(3 * sigma))
    k = np.exp(-0.5 * (np.arange(-rad, rad + 1) / sigma) ** 2)
    k /= k.sum()
    if closed:
        # circular padding by modular indices: valid for loops shorter than
        # the kernel radius too (tiny regions at high detail)
        ext = pts[np.arange(-rad, n + rad) % n]
        out = np.stack([np.convolve(ext[:, c], k, mode="valid") for c in range(2)], 1)[:n]
    else:
        # Reflect around the end points (keeps the ends in place).
        r = min(rad, n - 1)
        head = 2 * pts[0] - pts[1 : r + 1][::-1]
        tail = 2 * pts[-1] - pts[-r - 1 : -1][::-1]
        ext = np.concatenate([head, pts, tail])
        kk = k if r == rad else k[rad - r : rad + r + 1] / k[rad - r : rad + r + 1].sum()
        out = np.stack([np.convolve(ext[:, c], kk, mode="valid") for c in range(2)], 1)
        out[0], out[-1] = pts[0], pts[-1]
    if fixed is not None and fixed.any():
        out[fixed] = pts[fixed]
    return out


def fit_line_dir(pts: np.ndarray, w: np.ndarray | None = None) -> tuple[np.ndarray, np.ndarray]:
    """Weighted total-least-squares line: (centroid, unit direction)."""
    if w is None:
        w = np.ones(pts.shape[0])
    ws = w.sum()
    c = (pts * w[:, None]).sum(0) / max(ws, 1e-12)
    d = pts - c
    cov = (d * w[:, None]).T @ d
    vals, vecs = np.linalg.eigh(cov)
    direction = vecs[:, np.argmax(vals)]
    return c, direction


def _unit(v):
    n = np.hypot(v[0], v[1])
    return v / n if n > 1e-12 else np.array([1.0, 0.0])


def tangent_at(pts: np.ndarray, idx: int, forward: bool, window: float) -> np.ndarray:
    """One-sided tangent at ``pts[idx]`` from points within ``window`` px of
    arc length, pointing along the travel direction."""
    n = pts.shape[0]
    if forward:
        j = idx + 1
        while j < n - 1 and np.hypot(*(pts[j] - pts[idx])) < window:
            j += 1
        sub = pts[idx : j + 1]
    else:
        j = idx - 1
        while j > 0 and np.hypot(*(pts[j] - pts[idx])) < window:
            j -= 1
        sub = pts[j : idx + 1]
    if sub.shape[0] < 2:
        return _unit(pts[-1] - pts[0])
    chord = sub[-1] - sub[0]
    if sub.shape[0] == 2:
        return _unit(chord)
    _, d = fit_line_dir(sub)
    if np.dot(d, chord) < 0:
        d = -d
    return _unit(d)


def center_tangent(pts: np.ndarray, idx: int, window: float) -> np.ndarray:
    a = tangent_at(pts, idx, False, window)
    b = tangent_at(pts, idx, True, window)
    t = a + b
    if np.hypot(*t) < 1e-9:
        t = pts[min(idx + 1, len(pts) - 1)] - pts[max(idx - 1, 0)]
    return _unit(t)


# --------------------------------------------------------------------------
# Bezier fitting (Schneider)
# --------------------------------------------------------------------------

def _bez(ctrl: np.ndarray, u: np.ndarray) -> np.ndarray:
    t = u[:, None]
    s = 1 - t
    return s ** 3 * ctrl[0] + 3 * s * s * t * ctrl[1] + 3 * s * t * t * ctrl[2] + t ** 3 * ctrl[3]


def _bez_d1(ctrl, u):
    t = u[:, None]
    s = 1 - t
    return 3 * s * s * (ctrl[1] - ctrl[0]) + 6 * s * t * (ctrl[2] - ctrl[1]) + 3 * t * t * (ctrl[3] - ctrl[2])


def _bez_d2(ctrl, u):
    t = u[:, None]
    return 6 * (1 - t) * (ctrl[2] - 2 * ctrl[1] + ctrl[0]) + 6 * t * (ctrl[3] - 2 * ctrl[2] + ctrl[1])


def _chord_param(pts):
    s = arc_length(pts)
    return s / s[-1] if s[-1] > 0 else np.linspace(0, 1, pts.shape[0])


def _generate(pts, w, u, t1, t2):
    p0, p3 = pts[0], pts[-1]
    t = u[:, None]
    s = 1 - t
    b0, b1, b2, b3 = s ** 3, 3 * s * s * t, 3 * s * t * t, t ** 3
    a1 = t1[None, :] * b1
    a2 = t2[None, :] * b2
    c00 = (w * (a1 * a1).sum(1)).sum()
    c01 = (w * (a1 * a2).sum(1)).sum()
    c11 = (w * (a2 * a2).sum(1)).sum()
    tmp = pts - (b0 + b1) * p0 - (b2 + b3) * p3
    x0 = (w * (a1 * tmp).sum(1)).sum()
    x1 = (w * (a2 * tmp).sum(1)).sum()
    det = c00 * c11 - c01 * c01
    seg_len = np.hypot(*(p3 - p0))
    eps = 1e-6 * max(seg_len, 1e-6)
    if abs(det) > 1e-12:
        al = (x0 * c11 - x1 * c01) / det
        ar = (c00 * x1 - c01 * x0) / det
    else:
        al = ar = -1.0
    if al < eps or ar < eps or al > 3 * seg_len + 2 or ar > 3 * seg_len + 2:
        al = ar = seg_len / 3.0
    return np.array([p0, p0 + t1 * al, p3 + t2 * ar, p3])


def _reparam(ctrl, pts, u):
    p = _bez(ctrl, u)
    d1 = _bez_d1(ctrl, u)
    d2 = _bez_d2(ctrl, u)
    diff = p - pts
    num = (diff * d1).sum(1)
    den = (d1 * d1).sum(1) + (diff * d2).sum(1)
    ok = np.abs(den) > 1e-12
    nu = u.copy()
    nu[ok] = u[ok] - num[ok] / den[ok]
    nu = np.clip(nu, 0.0, 1.0)
    nu[0], nu[-1] = 0.0, 1.0
    return np.maximum.accumulate(nu)


def _max_err(ctrl, pts, u):
    d = np.sqrt(((_bez(ctrl, u) - pts) ** 2).sum(1))
    i = int(np.argmax(d[1:-1])) + 1 if d.shape[0] > 2 else d.shape[0] // 2
    return float(d.max()), i


def _true_max_err(ctrl, pts, u, tol):
    """Max distance from samples to the curve, checking only the samples
    whose parametric error exceeds ``tol`` against a dense polyline (robust
    to parameterisation artefacts, cheap because few points qualify)."""
    d = np.sqrt(((_bez(ctrl, u) - pts) ** 2).sum(1))
    bad = pts[d > tol]
    if bad.shape[0] == 0:
        return float(d.max())
    dense = _bez(ctrl, np.linspace(0, 1, max(32, pts.shape[0] * 3)))
    d2 = ((bad[:, None, :] - dense[None, :, :]) ** 2).sum(-1).min(1)
    return float(np.sqrt(d2.max()))


def fit_cubics(pts: np.ndarray, w: np.ndarray, tol: float, t1: np.ndarray, t2: np.ndarray, depth: int = 0, max_depth: int = 24) -> list[np.ndarray]:
    n = pts.shape[0]
    if n <= 2:
        d = np.hypot(*(pts[-1] - pts[0])) / 3.0
        return [np.array([pts[0], pts[0] + t1 * d, pts[-1] + t2 * d, pts[-1]])]
    if n == 3:
        pass
    u = _chord_param(pts)
    ctrl = _generate(pts, w, u, t1, t2)
    err, split = _max_err(ctrl, pts, u)
    if err <= tol:
        return [ctrl]
    if err <= tol * 6:
        for _ in range(6):
            u = _reparam(ctrl, pts, u)
            ctrl = _generate(pts, w, u, t1, t2)
            err, split = _max_err(ctrl, pts, u)
            if err <= tol:
                return [ctrl]
        if _true_max_err(ctrl, pts, u, tol) <= tol:
            return [ctrl]
    if depth >= max_depth or n < 4:
        return [ctrl]
    split = int(np.clip(split, 1, n - 2))
    window = max(1.5, min(4.0, 0.25 * float(arc_length(pts)[-1])))
    tc = center_tangent(pts, split, window)
    left = fit_cubics(pts[: split + 1], w[: split + 1], tol, t1, -tc, depth + 1, max_depth)
    right = fit_cubics(pts[split:], w[split:], tol, tc, t2, depth + 1, max_depth)
    return left + right


def _to_pt(v) -> Pt:
    return (float(v[0]), float(v[1]))


def _cubic_is_straight(ctrl: np.ndarray, tol: float) -> bool:
    a, b = ctrl[0], ctrl[3]
    ln = np.hypot(*(b - a))
    if ln < 1e-9:
        return True
    n = np.array([-(b - a)[1], (b - a)[0]]) / ln
    d1 = abs(np.dot(ctrl[1] - a, n))
    d2 = abs(np.dot(ctrl[2] - a, n))
    # inner control points must also lie between the ends
    t1 = np.dot(ctrl[1] - a, b - a) / (ln * ln)
    t2 = np.dot(ctrl[2] - a, b - a) / (ln * ln)
    return max(d1, d2) * 0.75 <= tol and -0.05 <= t1 <= 1.05 and -0.05 <= t2 <= 1.05


# --------------------------------------------------------------------------
# circles / arcs
# --------------------------------------------------------------------------

def fit_circle(pts: np.ndarray, w: np.ndarray | None = None) -> tuple[float, float, float] | None:
    """Algebraic (Kasa) circle fit with Gauss-Newton refinement."""
    if pts.shape[0] < 3:
        return None
    if w is None:
        w = np.ones(pts.shape[0])
    x, y = pts[:, 0], pts[:, 1]
    mx, my = np.average(x, weights=w), np.average(y, weights=w)
    u, v = x - mx, y - my
    sw = np.sqrt(w)
    a = np.stack([u, v, np.ones_like(u)], 1) * sw[:, None]
    b = (u * u + v * v) * sw
    try:
        sol, *_ = np.linalg.lstsq(a, b, rcond=None)
    except np.linalg.LinAlgError:
        return None
    cx, cy = sol[0] / 2, sol[1] / 2
    r2 = sol[2] + cx * cx + cy * cy
    if not np.isfinite(r2) or r2 <= 0:
        return None
    cx, cy, r = cx + mx, cy + my, math.sqrt(r2)
    for _ in range(6):  # geometric refinement
        dx, dy = x - cx, y - cy
        d = np.sqrt(dx * dx + dy * dy)
        d = np.maximum(d, 1e-9)
        j = np.stack([-dx / d, -dy / d, -np.ones_like(d)], 1) * sw[:, None]
        res = (d - r) * sw
        try:
            step, *_ = np.linalg.lstsq(j, -res, rcond=None)
        except np.linalg.LinAlgError:
            break
        cx, cy, r = cx + step[0], cy + step[1], r + step[2]
        if np.abs(step).max() < 1e-7:
            break
    if not (np.isfinite(cx) and np.isfinite(cy) and np.isfinite(r)) or r <= 0:
        return None
    return float(cx), float(cy), float(abs(r))


def fit_arc(pts: np.ndarray, w: np.ndarray, tol: float, min_sweep: float, max_radius: float) -> Arc | None:
    """Circular arc through the exact end points of ``pts`` or None."""
    if pts.shape[0] < 5:
        return None
    c = fit_circle(pts, w)
    if c is None:
        return None
    cx, cy, r = c
    if r > max_radius or r < 1.0:
        return None
    p0, p1 = pts[0], pts[-1]
    mid = (p0 + p1) / 2
    chord = p1 - p0
    cl = np.hypot(*chord)
    if cl < 1e-6:  # closed arcs are handled by shape recognition
        return None
    nrm = np.array([-chord[1], chord[0]]) / cl
    # Centre constrained to the perpendicular bisector of the end points.
    t = float(np.dot(np.array([cx, cy]) - mid, nrm))
    ctr = mid + nrm * t
    r = float(np.hypot(*(p0 - ctr)))
    if r > max_radius:
        return None
    a0 = math.atan2(p0[1] - ctr[1], p0[0] - ctr[0])
    a1 = math.atan2(p1[1] - ctr[1], p1[0] - ctr[0])
    am = pts[pts.shape[0] // 2]
    amid = math.atan2(am[1] - ctr[1], am[0] - ctr[0])
    # choose sweep direction passing through the middle sample
    sweep_pos = (a1 - a0) % (2 * math.pi)
    mid_pos = (amid - a0) % (2 * math.pi)
    sweep = sweep_pos if mid_pos <= sweep_pos else sweep_pos - 2 * math.pi
    if abs(sweep) < min_sweep or abs(sweep) > math.radians(340):
        return None
    d = np.abs(np.sqrt(((pts - ctr) ** 2).sum(1)) - r)
    if d.max() > tol:
        return None
    # samples must progress monotonically around the arc
    ang = np.arctan2(pts[:, 1] - ctr[1], pts[:, 0] - ctr[0])
    rel = (ang - a0) % (2 * math.pi) if sweep > 0 else (a0 - ang) % (2 * math.pi)
    rel[rel > abs(sweep) + 0.3] -= 2 * math.pi
    if (np.diff(rel) < -0.35).any():
        return None
    return Arc(float(ctr[0]), float(ctr[1]), r, a0, sweep)


# --------------------------------------------------------------------------
# section fitting
# --------------------------------------------------------------------------

def _max_line_dev(pts: np.ndarray) -> float:
    a, b = pts[0], pts[-1]
    ln = np.hypot(*(b - a))
    if ln < 1e-9:
        return float(np.sqrt(((pts - a) ** 2).sum(1)).max())
    n = np.array([-(b - a)[1], (b - a)[0]]) / ln
    d = np.abs((pts - a) @ n)
    t = (pts - a) @ (b - a) / (ln * ln)
    over = np.maximum(np.maximum(-t, t - 1), 0) * ln
    return float(np.maximum(d, over).max())


def _is_straight(pts: np.ndarray, tol: float) -> bool:
    chord = float(np.hypot(*(pts[-1] - pts[0])))
    tol_line = max(tol, min(1.4, 0.008 * chord))
    dev = _max_line_dev(pts)
    return dev <= tol or (dev <= tol_line and _rms_line_dev(pts) <= 0.4 * tol_line)


def _straight_polyline(pts: np.ndarray, tol: float, max_pieces: int = 3, min_len: float = 8.0, min_turn_deg: float = 15.0):
    """A run that is a polyline of two or three long straight pieces – a
    diagonal meeting a vertical stem at a shallow knee the corner detector
    did not flag – is returned as its vertices (end points kept, inner
    vertices at the intersection of the pieces' least-squares lines).
    Smooth curves fail the per-piece straightness test, because every
    piece of an arc bows; None is returned then."""
    n = pts.shape[0]
    if n < 2 * min_len:
        return None
    cuts = [0, n - 1]
    while len(cuts) - 1 < max_pieces:
        worst, worst_i = None, -1
        for k in range(len(cuts) - 1):
            a, b = cuts[k], cuts[k + 1]
            sec = pts[a : b + 1]
            if _is_straight(sec, tol):
                continue
            ch = sec[-1] - sec[0]
            ln = float(np.hypot(*ch))
            if ln < 1e-9:
                return None
            nrm = np.array([-ch[1], ch[0]]) / ln
            d = np.abs((sec - sec[0]) @ nrm)
            j = int(np.argmax(d[1:-1])) + 1 if sec.shape[0] > 2 else 0
            if worst is None or d[j] > worst:
                worst, worst_i = d[j], (k, a + j)
        if worst is None:
            break
        k, j = worst_i
        cuts.insert(k + 1, j)
    if len(cuts) < 3:
        return None
    lines = []
    for a, b in zip(cuts[:-1], cuts[1:]):
        sec = pts[a : b + 1]
        if float(np.hypot(*(sec[-1] - sec[0]))) < min_len or not _is_straight(sec, tol):
            return None
        lines.append(fit_line_dir(sec))
    verts = [pts[0].astype(np.float64)]
    for k in range(len(lines) - 1):
        (c1, d1), (c2, d2) = lines[k], lines[k + 1]
        cos_t = abs(float(d1 @ d2))
        if cos_t > math.cos(math.radians(min_turn_deg)):
            return None  # too shallow to be a corner
        m = np.array([[d1[0], -d2[0]], [d1[1], -d2[1]]])
        try:
            t = np.linalg.solve(m, c2 - c1)
        except np.linalg.LinAlgError:
            return None
        v = c1 + t[0] * d1
        if float(np.hypot(*(v - pts[cuts[k + 1]]))) > 3.0:
            return None
        verts.append(v)
    verts.append(pts[-1].astype(np.float64))
    return verts


def _orthogonal_polyline(pts: np.ndarray, tol: float, max_transition: float = 2.4, min_run: float = 1.0):
    """Rebuild a run of horizontal and vertical edges with exact right
    angles.

    Strokes of small text (E, T, L, H, the end of a bar) are axis-aligned,
    but at a few pixels' size blur rounds every corner and corner detection
    cannot separate two corners three pixels apart. The points are split
    into horizontal and vertical runs by their direction; the short turns
    between runs may be no longer than blur makes them (``max_transition``,
    a genuinely rounded corner or a circle has longer ones). Each run
    becomes an axis-parallel line, consecutive lines meet at right angles.
    Returns the vertices (end points kept) or None."""
    n = pts.shape[0]
    if n < 6:
        return None
    s = arc_length(pts)
    total = float(s[-1])
    if total < 2 * min_run:
        return None
    # direction from neighbours about 1 px away on each side
    back = np.stack([np.interp(np.maximum(s - 1.0, 0.0), s, pts[:, 0]), np.interp(np.maximum(s - 1.0, 0.0), s, pts[:, 1])], 1)
    fwd = np.stack([np.interp(np.minimum(s + 1.0, total), s, pts[:, 0]), np.interp(np.minimum(s + 1.0, total), s, pts[:, 1])], 1)
    d = fwd - back
    ang = np.degrees(np.arctan2(d[:, 1], d[:, 0])) % 180.0
    cls = np.full(n, 2, dtype=np.int64)  # 0 horizontal, 1 vertical, 2 transition
    cls[(ang < 20.0) | (ang > 160.0)] = 0
    cls[np.abs(ang - 90.0) < 20.0] = 1
    # runs of equal class
    runs = []
    start = 0
    for i in range(1, n + 1):
        if i == n or cls[i] != cls[start]:
            runs.append((int(cls[start]), start, i - 1))
            start = i
    lines = []  # (class, value, first index, last index)
    for c, a, b in runs:
        length = float(s[b] - s[a])
        if c == 2:
            if length > max_transition:
                return None
            continue
        if length < min_run:
            if length > max_transition:
                return None
            continue  # too short to be a side: part of a turn
        val = float(np.median(pts[a : b + 1, 1 if c == 0 else 0]))
        if lines and lines[-1][0] == c:
            if abs(lines[-1][1] - val) <= tol:
                # the same side, interrupted by noise
                lines[-1] = (c, 0.5 * (lines[-1][1] + val), lines[-1][2], b)
                continue
            # a step too short to show its own direction (the end of a
            # thin slot): a perpendicular side through the turn's centre
            mid = pts[lines[-1][3] + 1 : a]
            if mid.shape[0] == 0:
                return None
            pc = 1 - c
            pval = float(np.mean(mid[:, 1 if pc == 0 else 0]))
            lines.append((pc, pval, lines[-1][3] + 1, a - 1))
        lines.append((c, val, a, b))
    if len(lines) < 2:
        return None
    covered = sum(float(s[b] - s[a]) for _, _, a, b in lines)
    if covered < 0.6 * total:
        return None
    # each run must be straight around its line
    for c, val, a, b in lines:
        if b < a:
            continue
        seg_c = cls[a : b + 1]
        sel = seg_c == c
        if not sel.any():
            continue  # inserted step: its points are the turn itself
        dev = np.abs(pts[a : b + 1, 1 if c == 0 else 0][sel] - val)
        if float(dev.max()) > max(tol, 0.9):
            return None
    verts = [pts[0].astype(np.float64)]
    for (c1, v1, _, _), (c2, v2, _, _) in zip(lines[:-1], lines[1:]):
        verts.append(np.array([v2, v1]) if c1 == 0 else np.array([v1, v2]))
    verts.append(pts[-1].astype(np.float64))
    # the fixed end points must lie close to the first and last line
    for (c, val, _, _), p in ((lines[0], pts[0]), (lines[-1], pts[-1])):
        if abs(float(p[1 if c == 0 else 0]) - val) > 1.5:
            return None
    # drop zero-length pieces
    out = [verts[0]]
    for v in verts[1:]:
        if float(np.hypot(*(v - out[-1]))) > 1e-6:
            out.append(v)
    return out if len(out) >= 3 else None


def _rms_line_dev(pts: np.ndarray) -> float:
    a, b = pts[0], pts[-1]
    ln = np.hypot(*(b - a))
    if ln < 1e-9:
        return float(np.sqrt(((pts - a) ** 2).sum(1).mean()))
    n = np.array([-(b - a)[1], (b - a)[0]]) / ln
    return float(np.sqrt((((pts - a) @ n) ** 2).mean()))


def rdp(pts: np.ndarray, tol: float) -> np.ndarray:
    """Ramer-Douglas-Peucker simplification (returns kept indices)."""
    n = pts.shape[0]
    if n <= 2:
        return np.arange(n)
    keep = np.zeros(n, dtype=bool)
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        i, j = stack.pop()
        if j <= i + 1:
            continue
        a, b = pts[i], pts[j]
        ln = np.hypot(*(b - a))
        seg = pts[i + 1 : j]
        if ln < 1e-12:
            d = np.sqrt(((seg - a) ** 2).sum(1))
        else:
            d = np.abs((seg[:, 0] - a[0]) * (b - a)[1] - (seg[:, 1] - a[1]) * (b - a)[0]) / ln
        k = int(np.argmax(d))
        if d[k] > tol:
            m = i + 1 + k
            keep[m] = True
            stack.append((i, m))
            stack.append((m, j))
    return np.nonzero(keep)[0]


def _cubic_to_quads(c: CubicBezier, tol: float, depth: int = 0) -> list[Segment]:
    q = c.as_quadratic(tol)
    if q is not None or depth > 6:
        return [q if q is not None else QuadBezier(c.p0, _to_pt((np.array(c.p1) + np.array(c.p2)) / 2), c.p3)]
    a, b = c.split(0.5)
    return _cubic_to_quads(a, tol, depth + 1) + _cubic_to_quads(b, tol, depth + 1)


def restrict_types(segs: list[Segment], opts: CurveOptions) -> list[Segment]:
    if opts.allow_cubic and opts.allow_arcs:
        return segs
    out: list[Segment] = []
    for s in segs:
        if isinstance(s, Arc) and not opts.allow_arcs:
            cubs = s.to_cubics()
        elif isinstance(s, CubicBezier):
            cubs = [s]
        else:
            out.append(s)
            continue
        for c in cubs:
            if opts.allow_cubic:
                out.append(c)
            elif opts.allow_quadratic:
                out.extend(_cubic_to_quads(c, opts.tolerance * 0.5))
            else:
                pts = c.flatten(opts.tolerance * 0.25)
                idx = rdp(pts, opts.tolerance * 0.5)
                out.extend(Line(_to_pt(pts[a]), _to_pt(pts[b])) for a, b in zip(idx[:-1], idx[1:]))
    return out


def fit_section(
    pts: np.ndarray,
    w: np.ndarray,
    opts: CurveOptions,
    t_start: np.ndarray | None = None,
    t_end: np.ndarray | None = None,
    max_radius: float = 1e5,
) -> list[Segment]:
    """Fit a corner-free run of points whose first/last points are fixed.
    ``t_start`` / ``t_end`` are forced unit tangents (travel direction)."""
    n = pts.shape[0]
    p0, p1 = _to_pt(pts[0]), _to_pt(pts[-1])
    if n <= 2 or float(arc_length(pts)[-1]) < 1e-6:
        return [Line(p0, p1)]
    tol = opts.tolerance
    free_ends = t_start is None and t_end is None
    # Long straight runs carry more sampling noise (JPEG, scans) than the
    # point tolerance allows, and a chain of cubics then makes them wavy.
    # A long run counts as straight when it stays within a length-scaled
    # band and does not bow systematically (the RMS of a real arc is a large
    # fraction of its sagitta, that of noise is not).
    if _is_straight(pts, tol):
        if free_ends or _tangents_compatible(pts, t_start, t_end):
            return [Line(p0, p1)]
    if free_ends:
        verts = _straight_polyline(pts, tol)
        if verts is None:
            verts = _orthogonal_polyline(pts, tol)
        if verts is not None:
            return [Line(_to_pt(a), _to_pt(b)) for a, b in zip(verts[:-1], verts[1:])]
    if opts.allow_arcs and free_ends:
        arc = fit_arc(pts, w, tol * 0.9, opts.min_arc_sweep, max_radius)
        if arc is not None:
            return restrict_types([_snap_arc(arc, p0, p1)], opts)
    window = max(1.5, min(4.0, 0.3 * float(arc_length(pts)[-1])))
    t1 = t_start if t_start is not None else tangent_at(pts, 0, True, window)
    t2 = -(t_end if t_end is not None else tangent_at(pts, n - 1, False, window))
    ctrls = fit_cubics(pts, w, tol, t1, t2, 0, opts.max_depth)
    segs: list[Segment] = []
    for c in ctrls:
        if _cubic_is_straight(c, tol * 0.2):
            segs.append(Line(_to_pt(c[0]), _to_pt(c[3])))
        else:
            segs.append(CubicBezier(_to_pt(c[0]), _to_pt(c[1]), _to_pt(c[2]), _to_pt(c[3])))
    segs = merge_collinear(segs, tol * 0.25)
    return restrict_types(segs, opts)


def _tangents_compatible(pts, t_start, t_end) -> bool:
    chord = _unit(pts[-1] - pts[0])
    for t in (t_start, t_end):
        if t is not None and np.dot(t, chord) < math.cos(math.radians(4)):
            return False
    return True


def _snap_arc(arc: Arc, p0: Pt, p1: Pt) -> Arc:
    # The constructed arc already passes through p0/p1 up to rounding.
    return arc


def merge_collinear(segs: list[Segment], tol: float) -> list[Segment]:
    out: list[Segment] = []
    for s in segs:
        if out and isinstance(s, Line) and isinstance(out[-1], Line):
            a, m, b = np.array(out[-1].p0), np.array(out[-1].p1), np.array(s.p1)
            ln = np.hypot(*(b - a))
            if ln > 1e-9:
                n = np.array([-(b - a)[1], (b - a)[0]]) / ln
                t = np.dot(m - a, b - a) / (ln * ln)
                if abs(np.dot(m - a, n)) <= tol and 0 <= t <= 1:
                    out[-1] = Line(out[-1].p0, s.p1)
                    continue
        if isinstance(s, Line) and math.dist(s.p0, s.p1) < 1e-9:
            continue
        out.append(s)
    return out or segs[:1]


@dataclass
class CornerInfo:
    index: int
    point: np.ndarray  # final (possibly restored) corner position
    sharp: bool
    angle: float  # turning angle in radians
    trim: float = 0.0  # arc length excluded on each side of a restored corner


@dataclass
class CornerOptions:
    mode: str = "auto"  # auto | sharp | rounded
    strength: float = 0.5  # 0..1 correction strength
    scale: float = 2.0  # analysis scale in px


def _turn_all(pts: np.ndarray, s: np.ndarray, L: float, closed: bool, total: float) -> np.ndarray:
    """Signed turning angle at every point, measured between the points at
    arc distance -L and +L (vectorised)."""
    if closed:
        ss = np.concatenate([s, [total]])
        px = np.concatenate([pts[:, 0], pts[:1, 0]])
        py = np.concatenate([pts[:, 1], pts[:1, 1]])
        back = (s - L) % total
        fwd = (s + L) % total
    else:
        ss, px, py = s, pts[:, 0], pts[:, 1]
        back = np.clip(s - L, 0, total)
        fwd = np.clip(s + L, 0, total)
    a = np.stack([np.interp(back, ss, px), np.interp(back, ss, py)], 1)
    b = np.stack([np.interp(fwd, ss, px), np.interp(fwd, ss, py)], 1)
    v1, v2 = pts - a, b - pts
    cross = v1[:, 0] * v2[:, 1] - v1[:, 1] * v2[:, 0]
    dot = (v1 * v2).sum(1)
    ang = np.arctan2(cross, dot)
    bad = (np.hypot(v1[:, 0], v1[:, 1]) < 1e-9) | (np.hypot(v2[:, 0], v2[:, 1]) < 1e-9)
    ang[bad] = 0.0
    return ang


def detect_corners(pts: np.ndarray, closed: bool, opts: CornerOptions, raw: np.ndarray | None = None) -> list[CornerInfo]:
    """Corners of a faired point sequence ``pts``. ``raw`` (same indexing,
    before fairing) is used for the support lines of each corner: fairing
    helps to find corners but rounds them, which matters for small text."""
    n = pts.shape[0]
    if n < 5 or opts.mode == "rounded":
        return []
    drop_last = closed and np.allclose(pts[0], pts[-1])
    work = pts[:-1] if drop_last else pts
    support = work if raw is None or raw.shape[0] != pts.shape[0] else (raw[:-1] if drop_last else raw)
    n = work.shape[0]
    if closed:
        s = arc_length(np.concatenate([work, work[:1]]))
        total = float(s[-1])
        s = s[:-1]
        ext = work
    else:
        s = arc_length(work)
        total = float(s[-1])
        ext = work
    L = opts.scale
    if total < 4 * L:
        return []
    strength = float(np.clip(opts.strength, 0.0, 1.0))
    thr = math.radians(42.0 - 22.0 * strength)
    ang1 = _turn_all(ext, s, L, closed, total)
    ang2 = _turn_all(ext, s, 2 * L, closed, total)
    ang_h = _turn_all(ext, s, 0.5 * L, closed, total)
    ok = np.abs(ang1) >= thr
    if not closed:
        ok &= (s >= L * 1.2) & (s <= total - L * 1.2)
    # Turning spread evenly over 2L means a smooth curve, not a corner. Two
    # corners close together (the square end of a thin stroke, the arm of a
    # small "E") also turn a lot over 2L, so a turn concentrated within L/2
    # – an arc turns in proportion to its length, a corner does not –
    # identifies a corner as well.
    ok &= (np.abs(ang1) >= 0.72 * np.abs(ang2)) | (np.abs(ang_h) >= 0.75 * np.abs(ang1))
    cand = np.nonzero(ok)[0]
    # greedy non-maximum suppression within +-L
    corners: list[CornerInfo] = []
    taken: list[float] = []
    for i in cand[np.argsort(-np.abs(ang1[cand]), kind="stable")]:
        si = s[i]
        clash = False
        for sj in taken:
            dd = ((sj - si + total / 2) % total - total / 2) if closed else (sj - si)
            if abs(dd) <= L:
                clash = True
                break
        if not clash:
            taken.append(si)
            corners.append(CornerInfo(int(i), work[i].copy(), True, float(ang1[i])))
    corners.sort(key=lambda c: c.index)
    # classification + restoration
    out: list[CornerInfo] = []
    m = len(corners)
    for k, c in enumerate(corners):
        gap_b = gap_a = None
        si = s[c.index]
        if m > 1 and (closed or k > 0):
            gap_b = (si - s[corners[k - 1].index]) % total if closed else si - s[corners[k - 1].index]
        if m > 1 and (closed or k < m - 1):
            gap_a = (s[corners[(k + 1) % m].index] - si) % total if closed else s[corners[k + 1].index] - si
        res = _restore_corner(support, s, c.index, L, closed, total, strength, opts.mode, gap_b, gap_a)
        if res is None:
            continue
        x, sharp, trim = res
        if not sharp:
            continue
        out.append(CornerInfo(c.index, x, True, c.angle, trim))
    return out


def _side_points(pts, s, i, lo, hi, closed, total):
    """Points with arc distance from i in [lo, hi] (negative = before)."""
    if closed:
        rel = (s - s[i] + total / 2) % total - total / 2
    else:
        rel = s - s[i]
    m = (rel >= lo) & (rel <= hi)
    idx = np.nonzero(m)[0]
    if idx.size == 0:
        return np.zeros((0, 2))
    order = np.argsort(rel[idx])
    return pts[idx[order]]


def _side_tangent(side: np.ndarray, at_end: bool):
    """Support line of one side of a corner. A straight side gives its
    least-squares line. A curved side (the arc of a "C" meeting the flat
    cut of its terminal) would give a chord, so a parabola is fitted along
    the side and its tangent at the corner end is used instead."""
    c, d = fit_line_dir(side)
    if side.shape[0] < 5:
        return c, d
    nrm = np.array([-d[1], d[0]])
    resid = (side - c) @ nrm
    if float(np.sqrt((resid * resid).mean())) < 0.12:
        return c, d
    u = (side - c) @ d
    try:
        coef = np.polyfit(u, resid, 2)
    except (np.linalg.LinAlgError, ValueError):
        return c, d
    u0 = float(u[-1] if at_end else u[0])  # the end nearest to the corner
    slope = 2.0 * coef[0] * u0 + coef[1]
    p0 = c + u0 * d + float(np.polyval(coef, u0)) * nrm
    t = d + slope * nrm
    t = t / max(float(np.hypot(*t)), 1e-12)
    return p0, t


def _restore_corner(pts, s, i, L, closed, total, strength, mode, gap_before=None, gap_after=None):
    """Support lines on both sides of corner i, intersected. ``gap_*`` is
    the distance along the boundary to the neighbouring corner candidate:
    the support points stop short of it (the square end of a thin stroke
    has two corners a few pixels apart), and for small features they start
    closer to the corner so that a few remain."""

    def window(gap):
        if gap is None:
            return 0.8 * L, 3.5 * L
        inner = min(0.8 * L, 0.28 * gap)
        return inner, max(min(3.5 * L, gap - inner), inner + 0.6)

    ib, rb = window(gap_before)
    ia, ra = window(gap_after)
    before = _side_points(pts, s, i, -rb, -ib, closed, total)
    after = _side_points(pts, s, i, ia, ra, closed, total)
    if before.shape[0] < 2 or after.shape[0] < 2:
        return None
    c1, d1 = _side_tangent(before, at_end=True)
    c2, d2 = _side_tangent(after, at_end=False)
    if np.dot(d1, before[-1] - before[0]) < 0:
        d1 = -d1
    if np.dot(d2, after[-1] - after[0]) < 0:
        d2 = -d2
    cross = d1[0] * d2[1] - d1[1] * d2[0]
    dot = float(np.dot(d1, d2))
    turn = math.atan2(cross, dot)
    if abs(turn) < math.radians(18):
        return None
    if abs(cross) < 1e-6:
        return None
    # intersection of the two support lines
    t = ((c2 - c1)[0] * d2[1] - (c2 - c1)[1] * d2[0]) / cross
    x = c1 + d1 * t
    d = float(np.hypot(*(x - pts[i])))
    interior = math.pi - abs(turn)
    expected = 1.0 / max(math.sin(interior / 2.0), 0.08)
    limit = (0.45 + 1.1 * strength) * expected
    if d > max(5.0 * L, 8.0):
        return None
    sharp = mode == "sharp" or d <= limit
    trim = min(max(0.9 * L, d * 1.2), 2.5 * L)
    return x, sharp, trim
