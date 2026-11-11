"""Recognition of whole parametric shapes from boundary samples.

Every candidate model is fitted, regularised (right angles, isosceles
triangles, regular stars, axis alignment) and accepted only when the
two-sided distance between model outline and samples stays within the
tolerance. The accepted model is exposed as a closed chain of exact pieces
(lines, circular and elliptic arcs) that can be cut between arbitrary
points – this is how the Vector Graph keeps shared borders consistent when a
recognised shape touches several neighbours."""
from __future__ import annotations

import math
from dataclasses import dataclass, field

import cv2
import numpy as np
from scipy.spatial import cKDTree

from .fitting import arc_length, fit_circle, fit_line_dir
from .primitives import TAU, Arc, EllipticArc, Line, Pt, Segment, signed_area

SHAPE_TYPES = ("circle", "ellipse", "rectangle", "rounded_rectangle", "triangle", "quadrilateral", "star")


@dataclass
class Primitive:
    kind: str
    params: dict
    pieces: list[Segment]  # closed chain, consistent orientation
    error: float = 0.0
    vertices: list[Pt] = field(default_factory=list)

    # --- parametrisation: (piece index, t) -> float u = k + t ------------
    def _dense(self):
        if not hasattr(self, "_cache"):
            us, pts = [], []
            for k, p in enumerate(self.pieces):
                n = 64 if p.kind in ("A", "E") else 16
                t = np.linspace(0, 1, n, endpoint=False)
                us.append(k + t)
                pts.append(p.points(t))
            object.__setattr__(self, "_cache", (np.concatenate(us), np.concatenate(pts)))
        return self._cache

    def project(self, p) -> tuple[float, tuple[float, float]]:
        us, pts = self._dense()
        d = ((pts - np.asarray(p)) ** 2).sum(1)
        i = int(np.argmin(d))
        # local refinement on the piece
        u = float(us[i])
        k = int(math.floor(u))
        piece = self.pieces[k]
        lo, hi = max(0.0, u - k - 0.1), min(1.0, u - k + 0.1)
        ts = np.linspace(lo, hi, 41)
        cand = piece.points(ts)
        j = int(np.argmin(((cand - np.asarray(p)) ** 2).sum(1)))
        t = float(ts[j])
        if t >= 1.0 - 1e-9:
            k, t = (k + 1) % len(self.pieces), 0.0
        q = self.pieces[k].point(t)
        return k + t, q

    def subpath(self, u0: float, u1: float) -> list[Segment]:
        """Pieces from u0 forward to u1 (wrapping). u0 == u1 -> full loop."""
        m = len(self.pieces)
        u0 %= m
        u1 %= m
        span = (u1 - u0) % m
        if span < 1e-9 or span > m - 1e-9:
            span = float(m)
        k = int(math.floor(u0)) % m
        t = u0 - math.floor(u0)
        out: list[Segment] = []
        remaining = span
        while remaining > 1e-9:
            step = min(1.0 - t, remaining)
            if step > 1e-9:
                out.append(_sub(self.pieces[k], t, t + step))
            remaining -= step
            k, t = (k + 1) % m, 0.0
        return out

    def to_json(self) -> dict:
        d = {"type": self.kind}
        d.update({k: (round(v, 4) if isinstance(v, float) else v) for k, v in self.params.items()})
        return d


def _sub(seg: Segment, t0: float, t1: float) -> Segment:
    if isinstance(seg, Line):
        return Line(seg.point(t0), seg.point(t1))
    if isinstance(seg, Arc):
        return Arc(seg.cx, seg.cy, seg.r, seg.start_angle + seg.sweep * t0, seg.sweep * (t1 - t0))
    if isinstance(seg, EllipticArc):
        return EllipticArc(seg.cx, seg.cy, seg.rx, seg.ry, seg.rotation, seg.start_angle + seg.sweep * t0, seg.sweep * (t1 - t0))
    raise TypeError(type(seg))


def _orient(pieces: list[Segment], ccw_area_sign: float) -> list[Segment]:
    """Make the chain's signed area sign match the samples' orientation."""
    pts = np.concatenate([p.flatten(0.2) for p in pieces])
    if np.sign(signed_area(pts)) != np.sign(ccw_area_sign):
        pieces = [p.reversed() for p in reversed(pieces)]
    return pieces


def _polyline_pieces(verts: np.ndarray) -> list[Segment]:
    v = [tuple(map(float, p)) for p in verts]
    return [Line(v[i], v[(i + 1) % len(v)]) for i in range(len(v))]


def _corner_allowance(samples: np.ndarray, verts: np.ndarray, base: float) -> np.ndarray:
    """Extra distance allowed for samples near polygon vertices (raster
    rounding of sharp corners)."""
    allow = np.full(samples.shape[0], base)
    m = verts.shape[0]
    for i in range(m):
        a, b, c = verts[i - 1], verts[i], verts[(i + 1) % m]
        v1, v2 = a - b, c - b
        cosang = np.dot(v1, v2) / max(np.hypot(*v1) * np.hypot(*v2), 1e-9)
        interior = math.acos(float(np.clip(cosang, -1, 1)))
        extra = 0.75 * (1.0 / max(math.sin(interior / 2), 0.1) - 1.0) + 0.35
        near = np.hypot(samples[:, 0] - b[0], samples[:, 1] - b[1]) < 1.5 + 2.0 * extra
        allow[near] = np.maximum(allow[near], base + extra)
    return allow


def dense_outline(pieces, spacing: float = 0.25) -> np.ndarray:
    out = []
    for p in pieces:
        n = max(2, int(math.ceil(p.length() / spacing)))
        out.append(p.points(np.linspace(0, 1, n, endpoint=False)))
    return np.concatenate(out)


def _two_sided_ok(prim_pieces, samples, tree, tol, allowance=None, vert_excl=None):
    dense = dense_outline(prim_pieces)
    # samples -> outline
    t_out = cKDTree(dense)
    d1, _ = t_out.query(samples)
    lim = allowance if allowance is not None else tol
    if (d1 > lim).any():
        return False, float(d1.max())
    if float(np.sqrt((d1 ** 2).mean())) > tol * 0.5:
        return False, float(d1.max())
    # outline -> samples (coverage)
    if vert_excl is not None and len(vert_excl):
        dv = np.min(np.hypot(dense[:, None, 0] - vert_excl[None, :, 0], dense[:, None, 1] - vert_excl[None, :, 1]), 1)
        dense = dense[dv > 2.5]
    if dense.shape[0]:
        d2, _ = tree.query(dense)
        if d2.max() > tol * 1.6:
            return False, float(d2.max())
    return True, float(d1.max())


def _circle(samples, tree, tol, area_sign):
    c = fit_circle(samples)
    if c is None:
        return None
    cx, cy, r = c
    if r < 1.2:
        return None
    ang = np.sort(np.arctan2(samples[:, 1] - cy, samples[:, 0] - cx))
    gaps = np.diff(np.concatenate([ang, ang[:1] + TAU]))
    if gaps.max() > math.radians(35):
        return None
    pieces = _orient([Arc(cx, cy, r, 0.0, TAU)], area_sign)
    ok, err = _two_sided_ok(pieces, samples, tree, tol)
    if not ok:
        return None
    return Primitive("circle", {"cx": cx, "cy": cy, "r": r}, pieces, err)


def _ellipse(samples, tree, tol, area_sign):
    if samples.shape[0] < 6:
        return None
    try:
        (cx, cy), (w, h), ang = cv2.fitEllipseDirect(samples.astype(np.float32))
    except cv2.error:
        return None
    rx, ry = w / 2.0, h / 2.0
    if not (np.isfinite(rx) and np.isfinite(ry)) or min(rx, ry) < 1.2:
        return None
    if max(rx, ry) / min(rx, ry) < 1.04:
        return None  # a circle
    rot = math.radians(ang)
    # snap to axis alignment when close
    for target in (0.0, math.pi / 2, math.pi, -math.pi / 2):
        if abs(((rot - target) + math.pi) % TAU - math.pi) < math.radians(1.2):
            rot = target
    pieces = _orient([EllipticArc(float(cx), float(cy), float(rx), float(ry), rot, 0.0, TAU)], area_sign)
    ok, err = _two_sided_ok(pieces, samples, tree, tol)
    if not ok:
        return None
    return Primitive("ellipse", {"cx": float(cx), "cy": float(cy), "rx": float(rx), "ry": float(ry), "rotation": rot}, pieces, err)


def _refine_polygon(samples: np.ndarray, approx_idx: np.ndarray) -> np.ndarray | None:
    m = approx_idx.shape[0]
    n = samples.shape[0]
    lines = []
    for i in range(m):
        a, b = approx_idx[i], approx_idx[(i + 1) % m]
        idx = np.arange(a, b + 1) if b > a else np.concatenate([np.arange(a, n), np.arange(0, b + 1)])
        k = idx.shape[0]
        if k < 3:
            sub = samples[idx]
        else:
            lo, hi = int(round(k * 0.18)), int(round(k * 0.82))
            sub = samples[idx[lo : max(hi, lo + 2)]]
        if sub.shape[0] < 2:
            return None
        lines.append(fit_line_dir(sub))
    verts = []
    for i in range(m):
        (c1, d1), (c2, d2) = lines[i - 1], lines[i]
        cross = d1[0] * d2[1] - d1[1] * d2[0]
        if abs(cross) < 1e-6:
            return None
        t = ((c2 - c1)[0] * d2[1] - (c2 - c1)[1] * d2[0]) / cross
        verts.append(c1 + d1 * t)
    return np.array(verts)


def _approx(samples, eps):
    contour = samples.reshape(-1, 1, 2).astype(np.float32)
    ap = cv2.approxPolyDP(contour, eps, True).reshape(-1, 2)
    tree = cKDTree(samples)
    _, idx = tree.query(ap)
    return np.sort(idx)


def _snap_axis(theta: float) -> float:
    q = round(theta / (math.pi / 2)) * (math.pi / 2)
    return q if abs(theta - q) < math.radians(1.0) else theta


def _rect_from(center, theta, w, h):
    co, si = math.cos(theta), math.sin(theta)
    ux, uy = np.array([co, si]) * w / 2, np.array([-si, co]) * h / 2
    c = np.asarray(center)
    return np.array([c - ux - uy, c + ux - uy, c + ux + uy, c - ux + uy])


def _polygons(samples, tree, tol, area_sign, enabled):
    perim = float(arc_length(np.concatenate([samples, samples[:1]]))[-1])
    results = []
    for eps_k in (1.6, 2.6, 4.0):
        idx = _approx(samples, max(tol * eps_k, perim * 0.004))
        m = idx.shape[0]
        if m < 3 or m > 16:
            continue
        verts = _refine_polygon(samples, idx)
        if verts is None:
            continue
        cands = []
        if m == 4:
            if "rectangle" in enabled:
                sides = [verts[(i + 1) % 4] - verts[i] for i in range(4)]
                angs = []
                for i in range(4):
                    a, b = sides[i - 1], sides[i]
                    angs.append(abs(math.degrees(math.acos(np.clip(np.dot(-a, b) / (np.hypot(*a) * np.hypot(*b)), -1, 1))) - 90))
                if max(angs) < 4.0:
                    th0 = math.atan2(sides[0][1], sides[0][0])
                    offs = []
                    for sd in sides:
                        d = (math.atan2(sd[1], sd[0]) - th0) % (math.pi / 2)
                        offs.append(d - math.pi / 2 if d > math.pi / 4 else d)
                    theta = th0 + float(np.mean(offs))
                    w = (np.hypot(*sides[0]) + np.hypot(*sides[2])) / 2
                    h = (np.hypot(*sides[1]) + np.hypot(*sides[3])) / 2
                    theta = (theta + math.pi / 2) % math.pi - math.pi / 2
                    if abs(abs(theta) - math.pi / 2) < math.radians(1.0):
                        theta, w, h = 0.0, h, w
                    theta = _snap_axis(theta)
                    if abs(w - h) < tol:
                        w = h = (w + h) / 2
                    ctr = verts.mean(0)
                    # rebuild with the first side along theta
                    rv = _rect_from(ctr, theta, w, h)
                    cands.append(("rectangle", rv, {"cx": float(ctr[0]), "cy": float(ctr[1]), "width": float(w), "height": float(h), "rotation": theta}))
            if "quadrilateral" in enabled:
                cands.append(("quadrilateral", verts, {"points": verts.round(3).tolist()}))
        elif m == 3:
            if "triangle" in enabled:
                tv = _regular_triangle(verts, tol)
                cands.append(("triangle", tv, {"points": tv.round(3).tolist()}))
        elif m % 2 == 0 and 6 <= m <= 16 and "star" in enabled:
            sv = _regular_star(verts, tol)
            if sv is not None:
                sverts, prm = sv
                cands.append(("star", sverts, prm))
        for kind, vv, prm in cands:
            pieces = _orient(_polyline_pieces(vv), area_sign)
            allow = _corner_allowance(samples, vv, tol)
            ok, err = _two_sided_ok(pieces, samples, tree, tol, allowance=allow, vert_excl=vv)
            if ok:
                if kind == "rectangle" and abs(prm["width"] - prm["height"]) < 1e-9:
                    prm = dict(prm, square=True)
                results.append(Primitive(kind, prm, pieces, err, [tuple(map(float, p)) for p in vv]))
        if results:
            break
    if not results:
        return None
    order = {"rectangle": 0, "triangle": 1, "star": 2, "quadrilateral": 3}
    results.sort(key=lambda p: order.get(p.kind, 9))
    return results[0]


def _regular_triangle(v: np.ndarray, tol: float) -> np.ndarray:
    lens = [np.hypot(*(v[(i + 1) % 3] - v[i])) for i in range(3)]  # side i: v[i]->v[i+1]
    if max(lens) - min(lens) < tol * 1.2:  # equilateral
        c = v.mean(0)
        r = float(np.mean([np.hypot(*(p - c)) for p in v]))
        a0 = math.atan2(v[0][1] - c[1], v[0][0] - c[0])
        sgn = 1 if signed_area(v) > 0 else -1
        for kk in range(3):
            ak = a0 + sgn * kk * TAU / 3
            for target in (-math.pi / 2, math.pi / 2):
                dd = (ak - target + math.pi) % TAU - math.pi
                if abs(dd) < math.radians(1.2):
                    a0 -= dd
                    break
        return np.array([[c[0] + r * math.cos(a0 + sgn * k * TAU / 3), c[1] + r * math.sin(a0 + sgn * k * TAU / 3)] for k in range(3)])
    for apex in range(3):
        b1, b2 = v[(apex + 1) % 3], v[(apex + 2) % 3]
        l1, l2 = np.hypot(*(b1 - v[apex])), np.hypot(*(b2 - v[apex]))
        if abs(l1 - l2) < tol * 1.2:
            mid = (b1 + b2) / 2
            base = b2 - b1
            half = np.hypot(*base) / 2
            bu = base / max(np.hypot(*base), 1e-9)
            axis = np.array([-bu[1], bu[0]])
            height = float(np.dot(v[apex] - mid, axis))
            out = v.copy()
            out[apex] = mid + axis * height
            out[(apex + 1) % 3] = mid - bu * half
            out[(apex + 2) % 3] = mid + bu * half
            return out
    return v


def _regular_star(v: np.ndarray, tol: float):
    m = v.shape[0]
    k = m // 2
    if k < 3 or k > 8:
        return None
    c = v.mean(0)
    r = np.hypot(v[:, 0] - c[0], v[:, 1] - c[1])
    ang = np.arctan2(v[:, 1] - c[1], v[:, 0] - c[0])
    for off in (0, 1):
        outer = r[off::2]
        inner = r[1 - off :: 2]
        if outer.mean() <= inner.mean() * 1.15:
            continue
        if outer.std() > max(tol, 0.04 * outer.mean()) or inner.std() > max(tol, 0.06 * inner.mean()):
            continue
        # angles evenly spaced?
        sgn = 1 if signed_area(v) > 0 else -1
        base = ang[off]
        expected = base + sgn * np.arange(m) * (math.pi / k)
        idx = np.roll(np.arange(m), -off)
        diff = (ang[idx] - expected + math.pi) % TAU - math.pi
        if np.abs(diff).max() > math.radians(6):
            continue
        a0 = base + float(np.mean(diff))
        a0n = _snap_axis(a0 + math.pi / 2) - math.pi / 2
        a0 = a0n if abs(a0n - a0) < math.radians(1.2) else a0
        # canonical rotation: the outer point closest to "up" (-pi/2)
        step = TAU / k
        a0 = -math.pi / 2 + ((a0 + math.pi / 2 + step / 2) % step) - step / 2
        a0 = float(a0)
        ro, ri = float(outer.mean()), float(inner.mean())
        pts = []
        for i in range(m):
            rr = ro if i % 2 == 0 else ri
            a = a0 + sgn * i * math.pi / k
            pts.append([c[0] + rr * math.cos(a), c[1] + rr * math.sin(a)])
        return np.array(pts), {"cx": float(c[0]), "cy": float(c[1]), "points": k, "outer_radius": ro, "inner_radius": ri, "rotation": a0}
    return None


def _rounded_rect(samples, tree, tol, area_sign):
    (cx, cy), (w, h), ang = cv2.minAreaRect(samples.astype(np.float32))
    if min(w, h) < 4:
        return None
    area = abs(signed_area(samples))
    deficit = w * h - area
    if deficit <= 0:
        return None
    r = math.sqrt(deficit / (4 - math.pi))
    if r < 1.0 or r > min(w, h) / 2 * 1.02:
        return None
    r = min(r, min(w, h) / 2)
    theta = math.radians(ang)
    theta = (theta + math.pi / 2) % math.pi - math.pi / 2
    if abs(theta) > math.pi / 4:  # describe with the smaller rotation
        theta = theta - math.copysign(math.pi / 2, theta)
        w, h = h, w
    theta = _snap_axis(theta)
    co, si = math.cos(theta), math.sin(theta)
    hx, hy = w / 2 - r, h / 2 - r

    def P(x, y):
        return (cx + co * x - si * y, cy + si * x + co * y)

    pieces: list[Segment] = []
    corners = [(hx, -hy, -math.pi / 2), (hx, hy, 0.0), (-hx, hy, math.pi / 2), (-hx, -hy, math.pi)]
    for i, (x, y, a) in enumerate(corners):
        ctr = P(x, y)
        arc = Arc(ctr[0], ctr[1], r, a + theta, math.pi / 2)
        if pieces and math.dist(pieces[-1].end(), arc.start()) > 1e-9:
            pieces.append(Line(pieces[-1].end(), arc.start()))
        pieces.append(arc)
    if math.dist(pieces[-1].end(), pieces[0].start()) > 1e-9:
        pieces.append(Line(pieces[-1].end(), pieces[0].start()))
    pieces = _orient(pieces, area_sign)
    ok, err = _two_sided_ok(pieces, samples, tree, tol)
    if not ok:
        return None
    return Primitive("rounded_rectangle", {"cx": float(cx), "cy": float(cy), "width": float(w), "height": float(h), "radius": float(r), "rotation": theta}, pieces, err)


def resample_closed(pts: np.ndarray, spacing: float = 0.5) -> np.ndarray:
    loop = np.concatenate([pts, pts[:1]])
    s = arc_length(loop)
    total = s[-1]
    n = max(16, int(total / spacing))
    t = np.linspace(0, total, n, endpoint=False)
    x = np.interp(t, s, loop[:, 0])
    y = np.interp(t, s, loop[:, 1])
    return np.stack([x, y], 1)


def recognize(samples: np.ndarray, tol: float, enabled: set[str]) -> Primitive | None:
    """Return the simplest accepted parametric model for a closed boundary."""
    if samples.shape[0] < 8 or not enabled:
        return None
    if np.allclose(samples[0], samples[-1]):
        samples = samples[:-1]
    area_sign = signed_area(samples)
    if abs(area_sign) < 6.0:
        return None
    pts = resample_closed(samples, 0.5)
    tree = cKDTree(pts)
    if "circle" in enabled:
        p = _circle(pts, tree, tol, area_sign)
        if p:
            return p
    if "ellipse" in enabled:
        p = _ellipse(pts, tree, tol, area_sign)
        if p:
            return p
    poly = _polygons(pts, tree, tol, area_sign, enabled)
    if poly and poly.kind == "rectangle":
        return poly
    if "rounded_rectangle" in enabled:
        p = _rounded_rect(pts, tree, tol, area_sign)
        if p:
            return p
    return poly
