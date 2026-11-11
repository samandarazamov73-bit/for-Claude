"""DXF export (AutoCAD R2010 via ezdxf).

Compatibility levels:
* ``lines``               – closed LWPOLYLINEs, curves flattened within tolerance;
* ``lines_arcs``          – LWPOLYLINEs with bulges: circular arcs are exact,
                            Bezier curves are approximated by arcs;
* ``lines_arcs_splines``  – lines/arcs as LWPOLYLINE bulges and Bezier curves as
                            exact cubic B-SPLINE entities.

The y axis is flipped (DXF is y-up) and coordinates are written in the
requested physical unit. One layer per colour carries the true colour."""
from __future__ import annotations

import io
import math

import ezdxf

from geometry_engine import Arc, CubicBezier, Line, Segment, path_flatten
from geometry_engine.fitting import fit_circle

from .common import ExportOptions, build_drawing

INSUNITS = {"px": 0, "pt": 0, "in": 1, "mm": 4, "cm": 5}


def _arc_through(p0, pm, p1):
    import numpy as np

    c = fit_circle(np.array([p0, pm, p1]))
    if c is None:
        return None
    cx, cy, r = c
    a0 = math.atan2(p0[1] - cy, p0[0] - cx)
    a1 = math.atan2(p1[1] - cy, p1[0] - cx)
    am = math.atan2(pm[1] - cy, pm[0] - cx)
    sp = (a1 - a0) % (2 * math.pi)
    mp = (am - a0) % (2 * math.pi)
    sweep = sp if mp <= sp else sp - 2 * math.pi
    return Arc(cx, cy, r, a0, sweep)


def cubic_to_arcs(c: CubicBezier, tol: float, depth: int = 0) -> list[Segment]:
    p0, p1 = c.start(), c.end()
    pm = c.point(0.5)
    chord = math.dist(p0, p1)
    # straight enough -> line
    if chord > 1e-12:
        dev = abs((p1[0] - p0[0]) * (p0[1] - pm[1]) - (p0[0] - pm[0]) * (p1[1] - p0[1])) / chord
        if dev <= tol and max(_dev_line(c, p0, p1, chord)) <= tol:
            return [Line(p0, p1)]
    arc = _arc_through(p0, pm, p1)
    if arc is not None and depth < 12:
        ok = True
        for t in (0.25, 0.75, 0.125, 0.875):
            q = c.point(t)
            if abs(math.dist(q, (arc.cx, arc.cy)) - arc.r) > tol:
                ok = False
                break
        if ok and arc.r < 1e7:
            return [Arc(arc.cx, arc.cy, arc.r, arc.start_angle, arc.sweep)]
    if depth >= 12:
        return [Line(p0, p1)]
    a, b = c.split(0.5)
    return cubic_to_arcs(a, tol, depth + 1) + cubic_to_arcs(b, tol, depth + 1)


def _dev_line(c, p0, p1, chord):
    for t in (0.25, 0.75):
        q = c.point(t)
        yield abs((p1[0] - p0[0]) * (p0[1] - q[1]) - (p0[0] - q[0]) * (p1[1] - p0[1])) / chord


class _Writer:
    def __init__(self, msp, height: float, k: float, compat: str, tol: float):
        self.msp, self.h, self.k, self.compat, self.tol = msp, height, k, compat, tol

    def pt(self, p):
        return (p[0] * self.k, (self.h - p[1]) * self.k)

    def emit(self, loop: list[Segment], closed: bool, attribs: dict):
        if self.compat == "lines":
            pts = path_flatten(loop, self.tol)
            pts = [self.pt(p) for p in pts]
            if closed and len(pts) > 1 and math.dist(pts[0], pts[-1]) < 1e-9:
                pts = pts[:-1]
            self.msp.add_lwpolyline(pts, close=closed, dxfattribs=attribs)
            return
        run: list[tuple[float, float, float]] = []
        pieces = 0

        def flush(final: bool):
            nonlocal run, pieces
            if len(run) >= 2:
                close = closed and final and pieces == 0
                pts = run[:-1] if close else run
                self.msp.add_lwpolyline(pts, format="xyb", close=close, dxfattribs=attribs)
                pieces += 1
            run = []

        for seg in loop:
            parts: list[Segment]
            if isinstance(seg, (Line, Arc)):
                parts = [seg]
            elif self.compat == "lines_arcs":
                parts = [a for cub in seg.to_cubics() for a in cubic_to_arcs(cub, self.tol)]
            else:
                parts = []
                flush(False)
                for cub in seg.to_cubics():
                    cps = [self.pt(p) for p in (cub.p0, cub.p1, cub.p2, cub.p3)]
                    self.msp.add_open_spline(cps, degree=3, dxfattribs=attribs)
                    pieces += 1
                continue
            for part in parts:
                bulge = math.tan(part.sweep / 4.0) if isinstance(part, Arc) else 0.0
                s, e = self.pt(part.start()), self.pt(part.end())
                if not run:
                    run.append((s[0], s[1], bulge))
                else:
                    x, y, _ = run[-1]
                    run[-1] = (x, y, bulge)
                run.append((e[0], e[1], 0.0))
        flush(True)


def write_dxf(graph, opts: ExportOptions) -> bytes:
    d = build_drawing(graph, opts)
    geo = d.geometry
    doc = ezdxf.new("R2010", setup=False)
    doc.header["$INSUNITS"] = INSUNITS.get(geo.unit, 0)
    doc.header["$EXTMIN"] = (0, 0, 0)
    doc.header["$EXTMAX"] = (geo.physical_width, geo.physical_height, 0)
    msp = doc.modelspace()
    k = geo.unit_per_px
    tol = 0.05 * k  # 0.05 output px expressed in the physical unit
    w = _Writer(msp, d.height, k, opts.dxf_compatibility, max(tol, 1e-4))
    layers: dict[tuple, str] = {}

    def layer_for(color, idx) -> str:
        key = tuple(color[:3])
        name = layers.get(key)
        if name is None:
            name = "COLOR_%02X%02X%02X" % key if idx >= 0 else "WATERMARK"
            lay = doc.layers.add(name)
            lay.rgb = key
            layers[key] = name
        return name

    if opts.draw_style == "stroke_edges":
        for e in d.edges:
            w.emit(e.segments, False, {"layer": layer_for(e.color, 0), "true_color": ezdxf.colors.rgb2int(e.color[:3])})
    else:
        for it in d.items + d.overlay:
            attribs = {"layer": layer_for(it.color, it.color_index), "true_color": ezdxf.colors.rgb2int(it.color[:3])}
            for lp in it.loops:
                w.emit(lp, True, attribs)
    buf = io.StringIO()
    doc.write(buf)
    return buf.getvalue().encode("utf-8")


__all__ = ["write_dxf", "cubic_to_arcs"]
