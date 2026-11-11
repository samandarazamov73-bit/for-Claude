import math

import numpy as np
import pytest

from geometry_engine import (
    SHAPE_TYPES,
    Affine,
    Arc,
    CornerOptions,
    CubicBezier,
    CurveOptions,
    EllipticArc,
    Line,
    detect_symmetry,
    fit_closed,
    fit_open,
    match_congruent,
    recognize,
    signature,
)

RNG = np.random.default_rng(7)


def poly_samples(verts, step=0.5, noise=0.08):
    out = []
    for i in range(len(verts)):
        a, b = np.array(verts[i], float), np.array(verts[(i + 1) % len(verts)], float)
        n = max(2, int(np.hypot(*(b - a)) / step))
        out += [a + (b - a) * k / n for k in range(n)]
    return np.array(out) + RNG.normal(0, noise, (len(out), 2))


def circle_samples(cx, cy, r, n=300, noise=0.08):
    t = np.linspace(0, 2 * math.pi, n, endpoint=False)
    return np.stack([cx + r * np.cos(t), cy + r * np.sin(t)], 1) + RNG.normal(0, noise, (n, 2))


def max_dev(segments, pts):
    dense = np.concatenate([s.points(np.linspace(0, 1, 1500)) for s in segments])
    d = np.sqrt(((pts[:, None, :] - dense[None, :, :]) ** 2).sum(-1)).min(1)
    return d.max()


def test_arc_to_cubic_accuracy():
    arc = Arc(10, 20, 50, 0.3, 4.0)
    cubs = arc.to_cubics()
    for c in cubs:
        for t in np.linspace(0, 1, 11):
            p = c.point(t)
            assert abs(math.dist(p, (10, 20)) - 50) < 0.02
    assert math.dist(cubs[0].start(), arc.start()) < 1e-9 and math.dist(cubs[-1].end(), arc.end()) < 1e-9


def test_affine_transforms_keep_arcs_exact():
    arc = EllipticArc(0, 0, 10, 5, 0.3, 0.2, 2.0)
    for m in (Affine.rotate(0.7, 3, 4), Affine.reflect(0.4, 1, 2) @ Affine.scale(2.0)):
        tr = arc.transformed(m)
        assert len(tr) == 1
        for t in (0.0, 0.3, 0.7, 1.0):
            a = m.apply(arc.point(t))
            b = tr[0].point(t)
            assert math.dist(a, b) < 1e-6


def test_fit_closed_circle_within_tolerance():
    pts = circle_samples(50, 40, 30)
    fit = fit_closed(pts, np.ones(len(pts)), CurveOptions(0.5), CornerOptions(), 1.0, 1e4)
    assert len(fit.corners) == 0
    # tolerance 0.5 px (measured on faired samples) plus sample noise
    assert max_dev(fit.segments, pts) < 0.5 + 3 * 0.08
    assert len(fit.segments) <= 4


def test_sharp_corners_are_restored():
    verts = [(10, 10), (70, 10), (70, 50), (10, 50)]
    pts = poly_samples(verts)
    fit = fit_closed(pts, np.ones(len(pts)), CurveOptions(0.5), CornerOptions(), 1.0, 1e4)
    assert all(s.kind == "L" for s in fit.segments)
    assert len(fit.segments) == 4
    corners = sorted(tuple(np.round(c.point, 0)) for c in fit.corners)
    assert corners == sorted(tuple(map(float, v)) for v in verts)


def test_rounded_mode_keeps_curves():
    pts = poly_samples([(10, 10), (70, 10), (70, 50), (10, 50)])
    fit = fit_closed(pts, np.ones(len(pts)), CurveOptions(0.5), CornerOptions(mode="rounded"), 1.0, 1e4)
    assert len(fit.corners) == 0


def test_fit_open_keeps_endpoints_fixed():
    t = np.linspace(0, math.pi, 120)
    pts = np.stack([t * 20, np.sin(t) * 15], 1)
    fit = fit_open(pts, np.ones(len(pts)), CurveOptions(0.3), CornerOptions(), 0.5, 1e4)
    assert fit.segments[0].start() == tuple(pts[0])
    assert fit.segments[-1].end() == tuple(pts[-1])
    assert max_dev(fit.segments, pts) < 0.4
    for a, b in zip(fit.segments, fit.segments[1:]):  # G1 continuity
        ta, tb = np.array(a.end_tangent()), np.array(b.start_tangent())
        assert np.dot(ta, tb) > 0.99


@pytest.mark.parametrize(
    "kind,pts",
    [
        ("circle", circle_samples(60, 50, 25)),
        ("rectangle", poly_samples([(10, 10), (90, 10), (90, 50), (10, 50)])),
        ("triangle", poly_samples([(10, 60), (40, 8), (80, 60)])),
        ("quadrilateral", poly_samples([(10, 10), (80, 20), (70, 70), (5, 50)])),
        ("star", poly_samples([(100 + (40 if i % 2 == 0 else 16) * math.cos(-math.pi / 2 + i * math.pi / 5), 100 + (40 if i % 2 == 0 else 16) * math.sin(-math.pi / 2 + i * math.pi / 5)) for i in range(10)])),
    ],
)
def test_shape_recognition(kind, pts):
    p = recognize(pts, 0.75, set(SHAPE_TYPES))
    assert p is not None and p.kind == kind


def test_ellipse_and_rounded_rect_recognition():
    t = np.linspace(0, 2 * math.pi, 400, endpoint=False)
    ell = np.stack([50 + 30 * np.cos(t), 40 + 14 * np.sin(t)], 1)
    p = recognize(ell, 0.75, set(SHAPE_TYPES))
    assert p.kind == "ellipse" and abs(max(p.params["rx"], p.params["ry"]) - 30) < 0.3
    rr = []
    for x, y, a0 in ((80, 20, -math.pi / 2), (80, 50, 0), (20, 50, math.pi / 2), (20, 20, math.pi)):
        for a in np.linspace(a0, a0 + math.pi / 2, 30):
            rr.append((x + 10 * math.cos(a), y + 10 * math.sin(a)))
    rr = np.array(rr)
    p = recognize(rr, 0.75, set(SHAPE_TYPES))
    assert p.kind == "rounded_rectangle" and abs(p.params["radius"] - 10) < 0.6


def test_disabled_types_are_not_returned():
    pts = circle_samples(60, 50, 25)
    p = recognize(pts, 0.75, {"rectangle"})
    assert p is None or p.kind != "circle"


def test_symmetry_detection():
    star = poly_samples([(100 + (40 if i % 2 == 0 else 16) * math.cos(-math.pi / 2 + i * math.pi / 5), 100 + (40 if i % 2 == 0 else 16) * math.sin(-math.pi / 2 + i * math.pi / 5)) for i in range(10)])
    sym = detect_symmetry(star, 0.8)
    assert sym.rotation_order == 5
    assert any(abs(a - math.pi / 2) < 0.02 for a in sym.mirror_axes)
    lop = poly_samples([(0, 0), (60, 0), (60, 10), (10, 10), (10, 40), (0, 40)])  # L shape
    assert not detect_symmetry(lop, 0.8).found or detect_symmetry(lop, 0.8).rotation_order == 1


def test_congruence_matching():
    base = np.array([(0, 0), (50, 0), (50, 10), (20, 10), (20, 35), (0, 35)], float)
    m = Affine.translate(100, 40) @ Affine.rotate(1.1)
    a = poly_samples([tuple(p) for p in base])
    b = poly_samples([m.apply(p) for p in base])
    t = match_congruent(signature(a), signature(b), 0.8)
    assert t is not None
    assert math.dist(t.apply((50, 0)), m.apply((50, 0))) < 1.0
