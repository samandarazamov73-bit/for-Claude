"""Symmetry and repetition analysis on closed boundaries.

* mirror axes (any direction through the area centroid, horizontal and
  vertical axes are tested explicitly),
* n-fold rotational symmetry (n = 2..12),
* repeated shapes: congruence under translation + rotation (+ reflection).

Symmetrisation averages every sample with the matched samples of its
transformed copies, producing an exactly invariant point set that is then
refitted with curves."""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
from scipy.spatial import cKDTree

from .primitives import Affine, signed_area
from .shapes import resample_closed


@dataclass
class SymmetryResult:
    mirror_axes: list[float]  # axis angles (radians) through the centroid
    rotation_order: int  # 1 = none
    center: tuple[float, float]
    mean_error: float

    @property
    def found(self) -> bool:
        return bool(self.mirror_axes) or self.rotation_order > 1

    def to_json(self) -> dict:
        def kind(a):
            a = a % math.pi
            if abs(a - math.pi / 2) < 1e-3:
                return "vertical"
            if a < 1e-3 or abs(a - math.pi) < 1e-3:
                return "horizontal"
            return "diagonal"

        return {
            "mirror": [{"angle": round(a, 5), "axis": kind(a)} for a in self.mirror_axes],
            "rotation": self.rotation_order,
            "center": [round(self.center[0], 3), round(self.center[1], 3)],
        }


def area_centroid(poly: np.ndarray) -> np.ndarray:
    x, y = poly[:, 0], poly[:, 1]
    xn, yn = np.roll(x, -1), np.roll(y, -1)
    cr = x * yn - xn * y
    a = cr.sum() / 2.0
    if abs(a) < 1e-9:
        return poly.mean(0)
    return np.array([((x + xn) * cr).sum() / (6 * a), ((y + yn) * cr).sum() / (6 * a)])


def _score(tree: cKDTree, pts: np.ndarray, m: Affine) -> tuple[float, float]:
    d, _ = tree.query(m.apply_array(pts))
    return float(d.mean()), float(np.percentile(d, 95))


def detect_symmetry(points: np.ndarray, tol: float, *, mirror: bool = True, rotation: bool = True, axis_aligned_only: bool = False) -> SymmetryResult:
    pts = resample_closed(points, 0.5)
    c = area_centroid(pts)
    tree = cKDTree(pts)
    mean_lim, p95_lim = 0.45 * tol, 1.2 * tol
    axes: list[float] = []
    errs = []
    if mirror:
        cand = [0.0, math.pi / 2]
        if not axis_aligned_only:
            coarse = np.linspace(0, math.pi, 72, endpoint=False)
            scores = np.array([_score(tree, pts, Affine.reflect(a, *c))[0] for a in coarse])
            for i in np.argsort(scores)[:6]:
                cand.append(float(coarse[i]))
        seen: list[float] = []
        for a0 in cand:
            best_a, best = a0, _score(tree, pts, Affine.reflect(a0, *c))
            if a0 not in (0.0, math.pi / 2):
                for step in (math.radians(1.25), math.radians(0.4), math.radians(0.12)):
                    for da in (-step, step):
                        s = _score(tree, pts, Affine.reflect(best_a + da, *c))
                        if s[0] < best[0]:
                            best_a, best = best_a + da, s
            if best[0] <= mean_lim and best[1] <= p95_lim:
                a = best_a % math.pi
                for t in (0.0, math.pi / 2, math.pi):
                    if abs(a - t) < math.radians(0.8):
                        a = t % math.pi
                if all(abs(((a - b) + math.pi / 2) % math.pi - math.pi / 2) > math.radians(2) for b in seen):
                    seen.append(a)
                    errs.append(best[0])
        axes = seen
    order = 1
    if rotation:
        for n in range(12, 1, -1):
            s = _score(tree, pts, Affine.rotate(2 * math.pi / n, *c))
            if s[0] <= mean_lim and s[1] <= p95_lim:
                # every power must also map the shape onto itself
                if all(_score(tree, pts, Affine.rotate(2 * math.pi * k / n, *c))[0] <= mean_lim for k in range(2, n)):
                    order = n
                    errs.append(s[0])
                    break
    return SymmetryResult(axes, order, (float(c[0]), float(c[1])), float(np.mean(errs)) if errs else 0.0)


def group_transforms(sym: SymmetryResult) -> list[Affine]:
    cx, cy = sym.center
    rots = [Affine.rotate(2 * math.pi * k / sym.rotation_order, cx, cy) for k in range(sym.rotation_order)]
    out = list(rots)
    if sym.mirror_axes:
        m = Affine.reflect(sym.mirror_axes[0], cx, cy)
        out += [r @ m for r in rots]
        if sym.rotation_order == 1:
            for a in sym.mirror_axes[1:]:
                out.append(Affine.reflect(a, cx, cy))
    return out


def symmetrize(points: np.ndarray, transforms: list[Affine]) -> np.ndarray:
    """Average each point with the matched points of its transformed copies.

    For a point p and group element g, q = nearest(g(p)) is p's partner and
    g^-1(q) its "vote". The average over the group is exactly invariant."""
    if len(transforms) <= 1:
        return points
    tree = cKDTree(points)
    acc = np.zeros_like(points, dtype=np.float64)
    for g in transforms:
        _, idx = tree.query(g.apply_array(points))
        acc += g.inverse().apply_array(points[idx])
    return acc / len(transforms)


# --------------------------------------------------------------------------
# repeated shapes
# --------------------------------------------------------------------------

@dataclass
class ShapeSignature:
    centroid: np.ndarray
    area: float
    perimeter: float
    orientation: float
    anisotropy: float
    points: np.ndarray  # resampled boundary


def signature(points: np.ndarray) -> ShapeSignature:
    pts = resample_closed(points, 0.5)
    c = area_centroid(pts)
    d = pts - c
    cov = d.T @ d / d.shape[0]
    vals, vecs = np.linalg.eigh(cov)
    major = vecs[:, 1]
    ani = float((vals[1] - vals[0]) / max(vals[1] + vals[0], 1e-9))
    per = float(np.sqrt((np.diff(np.concatenate([pts, pts[:1]]), axis=0) ** 2).sum(1)).sum())
    return ShapeSignature(c, abs(signed_area(pts)), per, math.atan2(major[1], major[0]), ani, pts)


def match_congruent(a: ShapeSignature, b: ShapeSignature, tol: float, allow_reflection: bool = True) -> Affine | None:
    """Find T with T(a) ~= b (translation, rotation, optional reflection)."""
    if abs(a.area - b.area) > 0.04 * max(a.area, b.area) + 2 * tol * a.perimeter * 0.5:
        return None
    if abs(a.perimeter - b.perimeter) > 0.04 * max(a.perimeter, b.perimeter) + 4 * tol:
        return None
    tree_b = cKDTree(b.points)
    tree_a = cKDTree(a.points)
    mean_lim, p95_lim = 0.45 * tol, 1.3 * tol
    best: tuple[float, Affine] | None = None
    for reflect in ((False, True) if allow_reflection else (False,)):
        base = Affine.translate(-a.centroid[0], -a.centroid[1])
        oa = a.orientation
        if reflect:
            base = Affine.reflect(0.0) @ base
            oa = -oa
        if a.anisotropy > 0.08:
            angles = [b.orientation - oa, b.orientation - oa + math.pi]
        else:
            angles = list(np.linspace(0, 2 * math.pi, 120, endpoint=False))
        for th in angles:
            m = Affine.translate(b.centroid[0], b.centroid[1]) @ Affine.rotate(th) @ base
            d, _ = tree_b.query(m.apply_array(a.points))
            s = float(d.mean())
            if best is None or s < best[0]:
                best = (s, m)
    if best is None:
        return None
    # refine rotation locally around the best candidate
    s, m = best
    d1, _ = tree_b.query(m.apply_array(a.points))
    d2, _ = tree_a.query(m.inverse().apply_array(b.points))
    if d1.mean() <= mean_lim and np.percentile(d1, 95) <= p95_lim and d2.mean() <= mean_lim and np.percentile(d2, 95) <= p95_lim:
        return m
    return None
