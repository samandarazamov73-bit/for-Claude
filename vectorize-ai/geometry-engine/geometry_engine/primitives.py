"""Curve primitives used throughout the engine and exporters.

Coordinates follow the raster convention: x to the right, y downwards.
Arc angles are measured from +x towards +y (the HTML canvas convention);
a positive ``sweep`` therefore runs clockwise on screen."""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Iterable, Sequence

import numpy as np

Pt = tuple[float, float]
TAU = 2.0 * math.pi


def _r(v: float, nd: int = 3) -> float:
    r = round(float(v), nd)
    return 0.0 if r == 0 else r


@dataclass(frozen=True, slots=True)
class Affine:
    """x' = a*x + c*y + e ; y' = b*x + d*y + f   (SVG ``matrix(a b c d e f)``)."""

    a: float = 1.0
    b: float = 0.0
    c: float = 0.0
    d: float = 1.0
    e: float = 0.0
    f: float = 0.0

    @staticmethod
    def translate(tx: float, ty: float) -> "Affine":
        return Affine(1, 0, 0, 1, tx, ty)

    @staticmethod
    def scale(sx: float, sy: float | None = None) -> "Affine":
        return Affine(sx, 0, 0, sx if sy is None else sy, 0, 0)

    @staticmethod
    def rotate(theta: float, cx: float = 0.0, cy: float = 0.0) -> "Affine":
        co, si = math.cos(theta), math.sin(theta)
        return Affine.translate(cx, cy) @ Affine(co, si, -si, co, 0, 0) @ Affine.translate(-cx, -cy)

    @staticmethod
    def reflect(theta: float, cx: float = 0.0, cy: float = 0.0) -> "Affine":
        """Reflection about the line through (cx, cy) with direction angle theta."""
        co, si = math.cos(2 * theta), math.sin(2 * theta)
        return Affine.translate(cx, cy) @ Affine(co, si, si, -co, 0, 0) @ Affine.translate(-cx, -cy)

    def __matmul__(self, o: "Affine") -> "Affine":
        return Affine(
            self.a * o.a + self.c * o.b,
            self.b * o.a + self.d * o.b,
            self.a * o.c + self.c * o.d,
            self.b * o.c + self.d * o.d,
            self.a * o.e + self.c * o.f + self.e,
            self.b * o.e + self.d * o.f + self.f,
        )

    def apply(self, p: Sequence[float]) -> Pt:
        x, y = p[0], p[1]
        return (self.a * x + self.c * y + self.e, self.b * x + self.d * y + self.f)

    def apply_array(self, pts: np.ndarray) -> np.ndarray:
        out = np.empty_like(pts, dtype=np.float64)
        out[:, 0] = self.a * pts[:, 0] + self.c * pts[:, 1] + self.e
        out[:, 1] = self.b * pts[:, 0] + self.d * pts[:, 1] + self.f
        return out

    @property
    def det(self) -> float:
        return self.a * self.d - self.b * self.c

    def inverse(self) -> "Affine":
        det = self.det
        a, b, c, d = self.d / det, -self.b / det, -self.c / det, self.a / det
        e = -(a * self.e + c * self.f)
        f = -(b * self.e + d * self.f)
        return Affine(a, b, c, d, e, f)

    def is_similarity(self, eps: float = 1e-9) -> bool:
        rot = abs(self.a - self.d) < eps and abs(self.b + self.c) < eps
        ref = abs(self.a + self.d) < eps and abs(self.b - self.c) < eps
        return rot or ref

    @property
    def uniform_scale(self) -> float:
        return math.sqrt(abs(self.det))

    @property
    def angle(self) -> float:
        return math.atan2(self.b, self.a)


class Segment:
    kind = "?"

    def start(self) -> Pt: ...
    def end(self) -> Pt: ...
    def point(self, t: float) -> Pt: ...
    def points(self, ts: np.ndarray) -> np.ndarray: ...
    def derivative(self, t: float) -> Pt: ...
    def reversed(self) -> "Segment": ...
    def transformed(self, m: Affine) -> list["Segment"]: ...
    def to_cubics(self) -> list["CubicBezier"]: ...
    def flatten(self, tol: float = 0.1) -> np.ndarray: ...
    def to_json(self) -> list: ...

    def length(self) -> float:
        pts = self.flatten(0.05)
        return float(np.sqrt((np.diff(pts, axis=0) ** 2).sum(1)).sum())

    def start_tangent(self) -> Pt:
        return _unit(self.derivative(0.0), self)

    def end_tangent(self) -> Pt:
        return _unit(self.derivative(1.0), self, at_end=True)


def _unit(v: Pt, seg: Segment, at_end: bool = False) -> Pt:
    n = math.hypot(v[0], v[1])
    if n > 1e-12:
        return (v[0] / n, v[1] / n)
    # Degenerate derivative (coincident control points): use the chord.
    p = seg.points(np.array([0.0, 0.02, 0.98, 1.0]))
    dv = (p[1] - p[0]) if not at_end else (p[3] - p[2])
    n = float(np.hypot(*dv))
    if n < 1e-12:
        dv = p[3] - p[0]
        n = float(np.hypot(*dv)) or 1.0
    return (float(dv[0] / n), float(dv[1] / n))


@dataclass(slots=True)
class Line(Segment):
    p0: Pt
    p1: Pt
    kind = "L"

    def start(self):
        return self.p0

    def end(self):
        return self.p1

    def point(self, t):
        return (self.p0[0] + (self.p1[0] - self.p0[0]) * t, self.p0[1] + (self.p1[1] - self.p0[1]) * t)

    def points(self, ts):
        p0, p1 = np.asarray(self.p0), np.asarray(self.p1)
        return p0[None, :] + (p1 - p0)[None, :] * np.asarray(ts)[:, None]

    def derivative(self, t):
        return (self.p1[0] - self.p0[0], self.p1[1] - self.p0[1])

    def reversed(self):
        return Line(self.p1, self.p0)

    def transformed(self, m):
        return [Line(m.apply(self.p0), m.apply(self.p1))]

    def to_cubics(self):
        p0, p1 = self.p0, self.p1
        return [CubicBezier(p0, _lerp(p0, p1, 1 / 3), _lerp(p0, p1, 2 / 3), p1)]

    def flatten(self, tol=0.1):
        return np.array([self.p0, self.p1], dtype=np.float64)

    def length(self):
        return math.dist(self.p0, self.p1)

    def to_json(self):
        return ["L", _r(self.p1[0]), _r(self.p1[1])]


@dataclass(slots=True)
class QuadBezier(Segment):
    p0: Pt
    p1: Pt
    p2: Pt
    kind = "Q"

    def start(self):
        return self.p0

    def end(self):
        return self.p2

    def points(self, ts):
        t = np.asarray(ts, dtype=np.float64)[:, None]
        u = 1 - t
        p0, p1, p2 = (np.asarray(p) for p in (self.p0, self.p1, self.p2))
        return u * u * p0 + 2 * u * t * p1 + t * t * p2

    def point(self, t):
        p = self.points(np.array([t]))[0]
        return (float(p[0]), float(p[1]))

    def derivative(self, t):
        return (
            2 * (1 - t) * (self.p1[0] - self.p0[0]) + 2 * t * (self.p2[0] - self.p1[0]),
            2 * (1 - t) * (self.p1[1] - self.p0[1]) + 2 * t * (self.p2[1] - self.p1[1]),
        )

    def reversed(self):
        return QuadBezier(self.p2, self.p1, self.p0)

    def transformed(self, m):
        return [QuadBezier(m.apply(self.p0), m.apply(self.p1), m.apply(self.p2))]

    def to_cubics(self):
        p0, p1, p2 = self.p0, self.p1, self.p2
        return [CubicBezier(p0, _lerp(p0, p1, 2 / 3), _lerp(p2, p1, 2 / 3), p2)]

    def flatten(self, tol=0.1):
        dd = math.hypot(self.p0[0] - 2 * self.p1[0] + self.p2[0], self.p0[1] - 2 * self.p1[1] + self.p2[1])
        n = max(1, min(256, int(math.ceil(math.sqrt(dd / (4 * max(tol, 1e-4)))))))
        return self.points(np.linspace(0, 1, n + 1))

    def to_json(self):
        return ["Q", _r(self.p1[0]), _r(self.p1[1]), _r(self.p2[0]), _r(self.p2[1])]


@dataclass(slots=True)
class CubicBezier(Segment):
    p0: Pt
    p1: Pt
    p2: Pt
    p3: Pt
    kind = "C"

    def start(self):
        return self.p0

    def end(self):
        return self.p3

    def ctrl(self) -> np.ndarray:
        return np.array([self.p0, self.p1, self.p2, self.p3], dtype=np.float64)

    def points(self, ts):
        t = np.asarray(ts, dtype=np.float64)[:, None]
        u = 1 - t
        c = self.ctrl()
        return u ** 3 * c[0] + 3 * u * u * t * c[1] + 3 * u * t * t * c[2] + t ** 3 * c[3]

    def point(self, t):
        p = self.points(np.array([t]))[0]
        return (float(p[0]), float(p[1]))

    def derivative(self, t):
        c = self.ctrl()
        u = 1 - t
        d = 3 * u * u * (c[1] - c[0]) + 6 * u * t * (c[2] - c[1]) + 3 * t * t * (c[3] - c[2])
        return (float(d[0]), float(d[1]))

    def reversed(self):
        return CubicBezier(self.p3, self.p2, self.p1, self.p0)

    def transformed(self, m):
        return [CubicBezier(m.apply(self.p0), m.apply(self.p1), m.apply(self.p2), m.apply(self.p3))]

    def to_cubics(self):
        return [self]

    def split(self, t: float) -> tuple["CubicBezier", "CubicBezier"]:
        c = self.ctrl()
        a = c[:-1] + (c[1:] - c[:-1]) * t
        b = a[:-1] + (a[1:] - a[:-1]) * t
        m = b[0] + (b[1] - b[0]) * t
        tp = lambda v: (float(v[0]), float(v[1]))  # noqa: E731
        return (
            CubicBezier(tp(c[0]), tp(a[0]), tp(b[0]), tp(m)),
            CubicBezier(tp(m), tp(b[1]), tp(a[2]), tp(c[3])),
        )

    def flatten(self, tol=0.1):
        c = self.ctrl()
        dd = max(np.hypot(*(c[0] - 2 * c[1] + c[2])), np.hypot(*(c[1] - 2 * c[2] + c[3])))
        n = max(1, min(512, int(math.ceil(math.sqrt(3.0 * dd / (4.0 * max(tol, 1e-4)))))))
        return self.points(np.linspace(0, 1, n + 1))

    def as_quadratic(self, tol: float) -> "QuadBezier | None":
        """Exact degree reduction when the cubic is (nearly) a quadratic."""
        c = self.ctrl()
        q = (3 * (c[1] + c[2]) - (c[0] + c[3])) / 4.0
        quad = QuadBezier(self.p0, (float(q[0]), float(q[1])), self.p3)
        ts = np.linspace(0, 1, 9)
        err = np.sqrt(((self.points(ts) - quad.points(ts)) ** 2).sum(1)).max()
        return quad if err <= tol else None

    def to_json(self):
        return ["C", _r(self.p1[0]), _r(self.p1[1]), _r(self.p2[0]), _r(self.p2[1]), _r(self.p3[0]), _r(self.p3[1])]


def _arc_cubics(cx, cy, rx, ry, rot, start, sweep) -> list[CubicBezier]:
    n = max(1, int(math.ceil(abs(sweep) / (math.pi / 2) - 1e-9)))
    step = sweep / n
    k = 4.0 / 3.0 * math.tan(step / 4.0)
    co, si = math.cos(rot), math.sin(rot)

    def pt(t):
        x, y = rx * math.cos(t), ry * math.sin(t)
        return (cx + co * x - si * y, cy + si * x + co * y)

    def dv(t):
        x, y = -rx * math.sin(t), ry * math.cos(t)
        return (co * x - si * y, si * x + co * y)

    out = []
    for i in range(n):
        t0 = start + i * step
        t1 = t0 + step
        p0, p3 = pt(t0), pt(t1)
        d0, d1 = dv(t0), dv(t1)
        out.append(
            CubicBezier(p0, (p0[0] + k * d0[0], p0[1] + k * d0[1]), (p3[0] - k * d1[0], p3[1] - k * d1[1]), p3)
        )
    return out


@dataclass(slots=True)
class Arc(Segment):
    """Circular arc: centre, radius, start angle and signed sweep (radians)."""

    cx: float
    cy: float
    r: float
    start_angle: float
    sweep: float
    kind = "A"

    def point(self, t):
        a = self.start_angle + self.sweep * t
        return (self.cx + self.r * math.cos(a), self.cy + self.r * math.sin(a))

    def start(self):
        return self.point(0.0)

    def end(self):
        return self.point(1.0)

    def points(self, ts):
        a = self.start_angle + self.sweep * np.asarray(ts, dtype=np.float64)
        return np.stack([self.cx + self.r * np.cos(a), self.cy + self.r * np.sin(a)], 1)

    def derivative(self, t):
        a = self.start_angle + self.sweep * t
        return (-self.r * math.sin(a) * self.sweep, self.r * math.cos(a) * self.sweep)

    def reversed(self):
        return Arc(self.cx, self.cy, self.r, self.start_angle + self.sweep, -self.sweep)

    def transformed(self, m):
        if not m.is_similarity():
            return [c for cub in self.to_cubics() for c in cub.transformed(m)]
        c = m.apply((self.cx, self.cy))
        s = m.apply(self.start())
        start = math.atan2(s[1] - c[1], s[0] - c[0])
        sweep = self.sweep if m.det > 0 else -self.sweep
        return [Arc(c[0], c[1], self.r * m.uniform_scale, start, sweep)]

    def to_cubics(self):
        return _arc_cubics(self.cx, self.cy, self.r, self.r, 0.0, self.start_angle, self.sweep)

    def flatten(self, tol=0.1):
        tol = max(min(tol, self.r * 0.5), 1e-4)
        step = 2.0 * math.acos(max(-1.0, 1.0 - tol / max(self.r, 1e-9)))
        n = max(2, min(1024, int(math.ceil(abs(self.sweep) / max(step, 1e-3)))))
        return self.points(np.linspace(0, 1, n + 1))

    def length(self):
        return abs(self.sweep) * self.r

    def to_json(self):
        return ["A", _r(self.cx), _r(self.cy), _r(self.r), _r(self.start_angle, 6), _r(self.sweep, 6)]


@dataclass(slots=True)
class EllipticArc(Segment):
    cx: float
    cy: float
    rx: float
    ry: float
    rotation: float
    start_angle: float  # parametric angle
    sweep: float
    kind = "E"

    def point(self, t):
        p = self.points(np.array([t]))[0]
        return (float(p[0]), float(p[1]))

    def start(self):
        return self.point(0.0)

    def end(self):
        return self.point(1.0)

    def points(self, ts):
        a = self.start_angle + self.sweep * np.asarray(ts, dtype=np.float64)
        co, si = math.cos(self.rotation), math.sin(self.rotation)
        x, y = self.rx * np.cos(a), self.ry * np.sin(a)
        return np.stack([self.cx + co * x - si * y, self.cy + si * x + co * y], 1)

    def derivative(self, t):
        a = self.start_angle + self.sweep * t
        co, si = math.cos(self.rotation), math.sin(self.rotation)
        x, y = -self.rx * math.sin(a) * self.sweep, self.ry * math.cos(a) * self.sweep
        return (co * x - si * y, si * x + co * y)

    def reversed(self):
        return EllipticArc(self.cx, self.cy, self.rx, self.ry, self.rotation, self.start_angle + self.sweep, -self.sweep)

    def transformed(self, m):
        if not m.is_similarity():
            return [c for cub in self.to_cubics() for c in cub.transformed(m)]
        c = m.apply((self.cx, self.cy))
        s = m.uniform_scale
        if m.det > 0:
            return [EllipticArc(c[0], c[1], self.rx * s, self.ry * s, self.rotation + m.angle, self.start_angle, self.sweep)]
        return [EllipticArc(c[0], c[1], self.rx * s, self.ry * s, m.angle - self.rotation, -self.start_angle, -self.sweep)]

    def to_cubics(self):
        return _arc_cubics(self.cx, self.cy, self.rx, self.ry, self.rotation, self.start_angle, self.sweep)

    def flatten(self, tol=0.1):
        r = max(self.rx, self.ry)
        tol = max(min(tol, r * 0.5), 1e-4)
        step = 2.0 * math.acos(max(-1.0, 1.0 - tol / max(r, 1e-9)))
        n = max(2, min(1024, int(math.ceil(abs(self.sweep) / max(step, 1e-3)))))
        return self.points(np.linspace(0, 1, n + 1))

    def to_json(self):
        return [
            "E",
            _r(self.cx),
            _r(self.cy),
            _r(self.rx),
            _r(self.ry),
            _r(self.rotation, 6),
            _r(self.start_angle, 6),
            _r(self.sweep, 6),
        ]


def _lerp(a: Pt, b: Pt, t: float) -> Pt:
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)


def segment_from_json(item: list, start: Pt) -> Segment:
    k = item[0]
    if k == "L":
        return Line(start, (item[1], item[2]))
    if k == "Q":
        return QuadBezier(start, (item[1], item[2]), (item[3], item[4]))
    if k == "C":
        return CubicBezier(start, (item[1], item[2]), (item[3], item[4]), (item[5], item[6]))
    if k == "A":
        return Arc(item[1], item[2], item[3], item[4], item[5])
    if k == "E":
        return EllipticArc(item[1], item[2], item[3], item[4], item[5], item[6], item[7])
    raise ValueError(f"unknown segment type {k!r}")


def path_flatten(segments: Iterable[Segment], tol: float = 0.1) -> np.ndarray:
    pts: list[np.ndarray] = []
    for i, s in enumerate(segments):
        p = s.flatten(tol)
        pts.append(p if i == 0 else p[1:])
    if not pts:
        return np.zeros((0, 2))
    return np.concatenate(pts, 0)


def reverse_path(segments: Sequence[Segment]) -> list[Segment]:
    return [s.reversed() for s in reversed(segments)]


def signed_area(poly: np.ndarray) -> float:
    if poly.shape[0] < 3:
        return 0.0
    x, y = poly[:, 0], poly[:, 1]
    return 0.5 * float((x * np.roll(y, -1) - np.roll(x, -1) * y).sum())


def move_endpoint(seg: Segment, new: Pt, at_end: bool) -> list[Segment]:
    """Move one end of a segment, dragging the adjacent control point along
    so the tangent direction is preserved. Arcs are converted to cubics."""
    if isinstance(seg, (Arc, EllipticArc)):
        cubs = seg.to_cubics()
        if at_end:
            return cubs[:-1] + move_endpoint(cubs[-1], new, True)
        return move_endpoint(cubs[0], new, False) + cubs[1:]
    if isinstance(seg, Line):
        return [Line(seg.p0, new) if at_end else Line(new, seg.p1)]
    if isinstance(seg, QuadBezier):
        return [QuadBezier(seg.p0, seg.p1, new) if at_end else QuadBezier(new, seg.p1, seg.p2)]
    if isinstance(seg, CubicBezier):
        if at_end:
            dx, dy = new[0] - seg.p3[0], new[1] - seg.p3[1]
            return [CubicBezier(seg.p0, seg.p1, (seg.p2[0] + dx, seg.p2[1] + dy), new)]
        dx, dy = new[0] - seg.p0[0], new[1] - seg.p0[1]
        return [CubicBezier(new, (seg.p1[0] + dx, seg.p1[1] + dy), seg.p2, seg.p3)]
    raise TypeError(type(seg))
