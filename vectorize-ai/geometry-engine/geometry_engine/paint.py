"""Gradient paints (linear and elliptical radial) shared by the engine, the
exporters and the PNG rasteriser.

* linear: colour varies along the segment (x1, y1) -> (x2, y2); points are
  projected onto it, offsets outside [0, 1] are clamped ("pad").
* radial: ``m`` maps the unit circle to an ellipse in user space
  (SVG ``gradientTransform``); the offset of a point is its distance from the
  centre in unit-circle coordinates.

Stops are ``(offset, (r, g, b, a))`` with offsets increasing from 0 to 1."""
from __future__ import annotations

import math
from dataclasses import dataclass, field

import numpy as np

from .primitives import Affine


@dataclass
class GradientPaint:
    kind: str  # linear | radial
    stops: list[tuple[float, tuple[int, int, int, int]]]
    x1: float = 0.0
    y1: float = 0.0
    x2: float = 1.0
    y2: float = 0.0
    m: tuple[float, float, float, float, float, float] = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
    extra: dict = field(default_factory=dict)

    # ------------------------------------------------------------------
    @property
    def affine(self) -> Affine:
        return Affine(*self.m)

    def mean_color(self) -> tuple[int, int, int, int]:
        """Offset-weighted average colour (used where gradients are not
        supported, e.g. DXF, and as the palette colour)."""
        offs = np.array([o for o, _ in self.stops])
        cols = np.array([c for _, c in self.stops], dtype=np.float64)
        if len(offs) == 1:
            return tuple(int(round(v)) for v in cols[0])  # type: ignore[return-value]
        w = np.zeros(len(offs))
        seg = np.diff(offs)
        w[:-1] += seg / 2
        w[1:] += seg / 2
        if self.kind == "radial":  # area grows with the radius
            w = w * np.maximum(offs, 0.05)
        w = w / max(w.sum(), 1e-9)
        return tuple(int(round(v)) for v in (cols * w[:, None]).sum(0))  # type: ignore[return-value]

    def offsets_at(self, x: np.ndarray, y: np.ndarray) -> np.ndarray:
        if self.kind == "linear":
            dx, dy = self.x2 - self.x1, self.y2 - self.y1
            ln2 = dx * dx + dy * dy
            if ln2 < 1e-12:
                return np.zeros_like(x, dtype=np.float64)
            t = ((x - self.x1) * dx + (y - self.y1) * dy) / ln2
        else:
            inv = self.affine.inverse()
            u = inv.a * x + inv.c * y + inv.e
            v = inv.b * x + inv.d * y + inv.f
            t = np.sqrt(u * u + v * v)
        return np.clip(t, 0.0, 1.0)

    def colors_at(self, x: np.ndarray, y: np.ndarray) -> np.ndarray:
        """RGBA (float, 0..255) at the given user-space points."""
        t = self.offsets_at(np.asarray(x, dtype=np.float64), np.asarray(y, dtype=np.float64))
        offs = np.array([o for o, _ in self.stops], dtype=np.float64)
        cols = np.array([c for _, c in self.stops], dtype=np.float64)
        return np.stack([np.interp(t, offs, cols[:, k]) for k in range(4)], -1)

    def transformed(self, a: Affine) -> "GradientPaint":
        if self.kind == "linear":
            p1, p2 = a.apply((self.x1, self.y1)), a.apply((self.x2, self.y2))
            return GradientPaint("linear", self.stops, p1[0], p1[1], p2[0], p2[1], extra=dict(self.extra))
        n = a @ self.affine
        return GradientPaint("radial", self.stops, m=(n.a, n.b, n.c, n.d, n.e, n.f), extra=dict(self.extra))

    def is_circular(self, rel_tol: float = 0.02) -> bool:
        a, b, c, d = self.m[:4]
        r1, r2 = math.hypot(a, b), math.hypot(c, d)
        ortho = abs(a * c + b * d) / max(r1 * r2, 1e-12)
        return abs(r1 - r2) <= rel_tol * max(r1, r2) and ortho < rel_tol

    @property
    def radius(self) -> float:
        a, b, c, d = self.m[:4]
        return math.sqrt(abs(a * d - b * c))

    # ------------------------------------------------------------------
    def to_json(self) -> dict:
        stops = [[round(o, 4), *[int(v) for v in c]] for o, c in self.stops]
        if self.kind == "linear":
            return {"type": "linear", "x1": round(self.x1, 3), "y1": round(self.y1, 3), "x2": round(self.x2, 3), "y2": round(self.y2, 3), "stops": stops}
        return {"type": "radial", "m": [round(v, 5) for v in self.m], "stops": stops}

    @classmethod
    def from_json(cls, d: dict) -> "GradientPaint":
        stops = [(float(s[0]), tuple(int(v) for v in s[1:5])) for s in d["stops"]]
        if d["type"] == "linear":
            return cls("linear", stops, float(d["x1"]), float(d["y1"]), float(d["x2"]), float(d["y2"]))
        return cls("radial", stops, m=tuple(float(v) for v in d["m"]))  # type: ignore[arg-type]


def sample_stops(color_at, n: int = 6, tol: float = 1.5) -> list[tuple[float, tuple[int, int, int, int]]]:
    """Build a compact stop list from a colour function on [0, 1]: start with
    ``n`` samples, then drop stops that linear interpolation reproduces
    within ``tol`` (keeps the ends)."""
    ts = np.linspace(0.0, 1.0, max(2, n))
    cols = np.array([np.clip(color_at(t), 0, 255) for t in ts], dtype=np.float64)
    keep = [0]
    for i in range(1, len(ts) - 1):
        j = i + 1
        a = keep[-1]
        w = (ts[i] - ts[a]) / (ts[j] - ts[a])
        interp = cols[a] * (1 - w) + cols[j] * w
        if np.abs(interp - cols[i]).max() > tol:
            keep.append(i)
    keep.append(len(ts) - 1)
    return [(float(ts[i]), tuple(int(round(v)) for v in cols[i])) for i in keep]  # type: ignore[misc]
