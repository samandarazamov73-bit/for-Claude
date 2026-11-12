"""Stage 6 — curve optimisation for every interface of the graph."""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from geometry_engine import CornerOptions, CurveOptions, Line, fit_closed, fit_open, move_endpoint
from geometry_engine.fitting import merge_collinear

from .graph import VectorGraph
from .options import ProcessingOptions


@dataclass
class FitParams:
    tolerance: float
    sigma: float
    curve: CurveOptions
    corner: CornerOptions
    hard_edges: bool


def fit_parameters(opts: ProcessingOptions, soft_edge_ratio: float, compressed: bool, edge_width: float) -> FitParams:
    hard = soft_edge_ratio < 0.12
    if opts.fit_tolerance > 0:
        tol = float(opts.fit_tolerance)
    else:
        tol = 0.75 if hard else 0.5
        if compressed:
            tol += 0.15
        tol *= (1.0, 0.85, 0.7)[opts.detail_level]
    sigma = 1.6 if hard else (1.2 if compressed else 0.9)
    scale = max(2.0, min(4.0, 1.1 * edge_width + 0.9)) + (0.5 if hard else 0.0)
    curve = CurveOptions(
        tolerance=tol,
        allow_cubic=opts.curves_cubic,
        allow_quadratic=opts.curves_quadratic,
        allow_arcs=opts.curves_arcs,
    )
    corner = CornerOptions(mode=opts.corners_mode, strength=opts.corners_strength, scale=scale)
    return FitParams(tol, sigma, curve, corner, hard)


def _weakness(contrast: float) -> float:
    return float(np.clip((70.0 - contrast) / 70.0, 0.0, 1.0))


def adaptive_tolerance(base: float, contrast: float) -> float:
    """Weak (low-contrast) boundaries are simplified more aggressively."""
    return base * (1.0 + 0.9 * _weakness(contrast))


def adaptive_sigma(base: float, contrast: float) -> float:
    """Low-contrast boundaries are iso-lines of smooth shading: their pixel
    position is noisy (a small colour error moves them far), so they are
    faired more strongly; strong edges keep the base smoothing."""
    return base * (1.0 + 1.6 * _weakness(contrast))


def fit_interface(f, g: VectorGraph, p: FitParams, max_radius: float) -> None:
    if f.border:
        a, b = g.nodes[f.start].pt, g.nodes[f.end].pt
        f.segments = [Line(a, b)]
        return
    pts, w = f.samples, f.weights
    tol = adaptive_tolerance(p.tolerance, f.contrast)
    sigma = adaptive_sigma(p.sigma, f.contrast)
    copts = CurveOptions(tolerance=tol, allow_cubic=p.curve.allow_cubic, allow_quadratic=p.curve.allow_quadratic, allow_arcs=p.curve.allow_arcs)
    if f.closed:
        if pts.shape[0] < 3:
            q = tuple(pts[0])
            f.segments = [Line(q, q)]
            return
        f.segments = fit_closed(pts, w, copts, p.corner, sigma, max_radius).segments
        return
    a, b = g.nodes[f.start].pt, g.nodes[f.end].pt
    length = float(np.sqrt((np.diff(pts, axis=0) ** 2).sum(1)).sum())
    if pts.shape[0] <= 3 or length < 1.5:
        f.segments = [Line(a, b)]
        return
    segs = fit_open(pts, w, copts, p.corner, sigma, max_radius).segments
    # guarantee exact attachment to the (refined) junctions
    if segs[0].start() != a:
        segs = move_endpoint(segs[0], a, at_end=False) + segs[1:]
    if segs[-1].end() != b:
        segs = segs[:-1] + move_endpoint(segs[-1], b, at_end=True)
    f.segments = segs


def fit_all(g: VectorGraph, p: FitParams, progress=None) -> None:
    max_radius = 4.0 * max(g.width, g.height)
    items = list(g.interfaces.values())
    total = max(1, len(items))
    step = max(1, total // 40)
    for i, f in enumerate(items):
        fit_interface(f, g, p, max_radius)
        if progress and i % step == 0:
            progress(i / total, f"fitting curves {i}/{total}")


def finalize_interfaces(g: VectorGraph, tol: float) -> None:
    for f in g.interfaces.values():
        segs = [s for s in f.segments]
        if len(segs) > 1:
            segs = merge_collinear(segs, tol * 0.25)
        # drop degenerate pieces while keeping continuity
        clean = [s for s in segs if s.kind != "L" or math.dist(s.start(), s.end()) > 1e-7]
        if not clean:
            clean = segs[:1]
        f.segments = clean
