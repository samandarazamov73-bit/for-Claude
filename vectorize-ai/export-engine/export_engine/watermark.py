"""Vector watermark used by the API ``test`` / ``preview`` modes.

The watermark is made of plain polygons, so it survives in every output
format (SVG, PDF, EPS, DXF and PNG) exactly like the artwork itself."""
from __future__ import annotations

import math

from .common import DrawItem, polyline_segments


def watermark_items(width: float, height: float, kind: str) -> list[DrawItem]:
    diag = math.hypot(width, height)
    band = max(diag * 0.018, 2.0)
    gap = band * (3.0 if kind == "test" else 6.0)
    alpha = 110 if kind == "test" else 70
    color = (128, 128, 128, alpha) if kind == "test" else (90, 90, 90, alpha)
    items: list[DrawItem] = []
    ang = math.radians(-35)
    dx, dy = math.cos(ang), math.sin(ang)
    nx, ny = -dy, dx
    cx, cy = width / 2, height / 2
    k = -diag
    i = 0
    while k <= diag:
        p0 = (cx + nx * k - dx * diag, cy + ny * k - dy * diag)
        p1 = (cx + nx * k + dx * diag, cy + ny * k + dy * diag)
        p2 = (p1[0] + nx * band, p1[1] + ny * band)
        p3 = (p0[0] + nx * band, p0[1] + ny * band)
        poly = _clip_rect([p0, p1, p2, p3], width, height)
        if len(poly) >= 3:
            items.append(DrawItem(-1000 - i, color, -1, [polyline_segments(poly)], -1, 0))
        k += band + gap
        i += 1
    return items


def _clip_rect(poly, w, h):
    """Sutherland–Hodgman clipping against [0,w]x[0,h]."""
    def clip(pts, inside, inter):
        out = []
        for i in range(len(pts)):
            a, b = pts[i - 1], pts[i]
            ia, ib = inside(a), inside(b)
            if ib:
                if not ia:
                    out.append(inter(a, b))
                out.append(b)
            elif ia:
                out.append(inter(a, b))
        return out

    def ix(x0):
        return lambda a, b: (x0, a[1] + (b[1] - a[1]) * (x0 - a[0]) / (b[0] - a[0]))

    def iy(y0):
        return lambda a, b: (a[0] + (b[0] - a[0]) * (y0 - a[1]) / (b[1] - a[1]), y0)

    pts = poly
    for inside, inter in (
        (lambda p: p[0] >= 0, ix(0.0)),
        (lambda p: p[0] <= w, ix(w)),
        (lambda p: p[1] >= 0, iy(0.0)),
        (lambda p: p[1] <= h, iy(h)),
    ):
        if not pts:
            break
        pts = clip(pts, inside, inter)
    return pts
