"""Shared export model: options, unit handling and the drawable item list."""
from __future__ import annotations

import math
from dataclasses import dataclass, field, fields

from geometry_engine import Affine, Line, Segment

FORMATS = ("svg", "pdf", "eps", "dxf", "png")
MIME = {
    "svg": "image/svg+xml",
    "pdf": "application/pdf",
    "eps": "application/postscript",
    "dxf": "application/dxf",
    "png": "image/png",
}
UNITS = ("px", "pt", "in", "cm", "mm")


@dataclass
class ExportOptions:
    file_format: str = "svg"
    svg_version: str = "svg_1_1"  # svg_1_0 | svg_1_1 | svg_tiny_1_2
    svg_illustrator: bool = False  # Adobe Illustrator compatibility tweaks
    use_primitives: bool = True  # native <circle>/<rect>/... where possible
    shape_stacking: str = "cutouts"  # cutouts | stacked
    group_by: str = "none"  # none | color | parent | layer
    draw_style: str = "fill_shapes"  # fill_shapes | stroke_shapes | stroke_edges
    stroke_width: float = 1.0
    gap_filler: bool = True
    gap_filler_width: float = 1.5
    size_scale: float = 1.0
    size_width: float = 0.0
    size_height: float = 0.0
    size_unit: str = "px"
    size_dpi: float = 72.0
    png_antialias: bool = True
    png_scale: float = 0.0  # 0 = derive from size options
    dxf_compatibility: str = "lines_arcs_splines"  # lines | lines_arcs | lines_arcs_splines
    watermark: str = "none"  # none | test | preview

    @classmethod
    def from_dict(cls, d: dict | None) -> "ExportOptions":
        d = d or {}
        names = {f.name for f in fields(cls)}
        o = cls(**{k: v for k, v in d.items() if k in names})
        return validate_export(o)


class ExportError(ValueError):
    def __init__(self, name: str, message: str):
        super().__init__(f"{name}: {message}")
        self.name = name
        self.message = message


EXPORT_SPECS = (
    ("output.file_format", "file_format", "enum", FORMATS, "Output file format."),
    ("output.svg.version", "svg_version", "enum", ("svg_1_0", "svg_1_1", "svg_tiny_1_2"), "SVG version."),
    ("output.svg.adobe_compatibility_mode", "svg_illustrator", "boolean", None, "Adobe Illustrator compatibility (no arcs, explicit units)."),
    ("output.shape_primitives", "use_primitives", "boolean", None, "Emit native circle/ellipse/rect/polygon elements for recognised shapes."),
    ("output.shape_stacking", "shape_stacking", "enum", ("cutouts", "stacked"), "cutouts: shapes are cut out of each other; stacked: shapes are layered on top of each other."),
    ("output.group_by", "group_by", "enum", ("none", "color", "parent", "layer"), "Grouping of shapes in SVG/DXF output."),
    ("output.draw_style", "draw_style", "enum", ("fill_shapes", "stroke_shapes", "stroke_edges"), "Fill shapes, outline shapes, or stroke each shared edge once."),
    ("output.strokes.width", "stroke_width", "number", (0.01, 100), "Stroke width for stroke draw styles (output units)."),
    ("output.gap_filler.enabled", "gap_filler", "boolean", None, "Hide anti-aliasing seams between adjacent cut-out shapes."),
    ("output.gap_filler.stroke_width", "gap_filler_width", "number", (0.1, 5), "Gap filler stroke width."),
    ("output.size.scale", "size_scale", "number", (0.001, 1000), "Uniform scale applied to the result."),
    ("output.size.width", "size_width", "number", (0, 1e6), "Target width (0 = automatic, aspect ratio is preserved)."),
    ("output.size.height", "size_height", "number", (0, 1e6), "Target height (0 = automatic)."),
    ("output.size.unit", "size_unit", "enum", UNITS, "Unit of the output size."),
    ("output.size.dpi", "size_dpi", "number", (1, 10000), "Resolution used to convert pixels to physical units."),
    ("output.bitmap.anti_aliasing", "png_antialias", "boolean", None, "Anti-aliased PNG rendering."),
    ("output.dxf.compatibility_level", "dxf_compatibility", "enum", ("lines", "lines_arcs", "lines_arcs_splines"), "DXF primitives: lines only, lines and arcs, or lines, arcs and splines."),
)


def validate_export(o: ExportOptions) -> ExportOptions:
    for name, attr, kind, extra, _ in EXPORT_SPECS:
        v = getattr(o, attr)
        if kind == "enum":
            if v not in extra:
                raise ExportError(name, f"expected one of {', '.join(extra)}")
        elif kind == "boolean":
            if isinstance(v, str):
                s = v.strip().lower()
                if s in ("true", "1", "yes", "on"):
                    v = True
                elif s in ("false", "0", "no", "off"):
                    v = False
                else:
                    raise ExportError(name, "expected true or false")
            setattr(o, attr, bool(v))
        elif kind == "number":
            try:
                v = float(v)
            except (TypeError, ValueError) as exc:
                raise ExportError(name, "expected a number") from exc
            lo, hi = extra
            if not (lo <= v <= hi):
                raise ExportError(name, f"must be between {lo:g} and {hi:g}")
            setattr(o, attr, v)
    if o.watermark not in ("none", "test", "preview"):
        raise ExportError("watermark", "invalid watermark")
    return o


def parse_export_public(params: dict) -> ExportOptions:
    o = ExportOptions()
    by_name = {s[0]: s for s in EXPORT_SPECS}
    for k, v in params.items():
        spec = by_name.get(k)
        if spec is None or v is None or v == "":
            continue
        setattr(o, spec[1], v)
    return validate_export(o)


UNIT_PER_INCH = {"in": 1.0, "pt": 72.0, "cm": 2.54, "mm": 25.4}


@dataclass
class OutputGeometry:
    """Working-resolution pixels -> output "user pixels" (+ physical size)."""

    transform: Affine
    width: float  # user px
    height: float
    unit: str
    unit_per_px: float  # physical units per user px
    dpi: float

    @property
    def physical_width(self) -> float:
        return self.width * self.unit_per_px

    @property
    def physical_height(self) -> float:
        return self.height * self.unit_per_px

    @property
    def points_per_px(self) -> float:
        return 72.0 / self.dpi


def output_geometry(graph, opts: ExportOptions) -> OutputGeometry:
    base = 1.0 / graph.scale if graph.scale > 0 else 1.0
    w_px, h_px = graph.width * base, graph.height * base
    unit_per_px = 1.0 if opts.size_unit == "px" else UNIT_PER_INCH[opts.size_unit] / opts.size_dpi
    s = opts.size_scale
    if opts.size_width > 0 or opts.size_height > 0:
        sx = (opts.size_width / unit_per_px) / w_px if opts.size_width > 0 else math.inf
        sy = (opts.size_height / unit_per_px) / h_px if opts.size_height > 0 else math.inf
        s = min(sx, sy)
    k = base * s
    return OutputGeometry(Affine.scale(k), graph.width * k, graph.height * k, opts.size_unit, unit_per_px, opts.size_dpi)


@dataclass
class DrawItem:
    shape_id: int
    color: tuple[int, int, int, int]
    color_index: int
    loops: list[list[Segment]]
    parent: int
    depth: int
    primitive: dict | None = None
    has_holes: bool = False


@dataclass
class EdgeItem:
    interface_id: int
    segments: list[Segment]
    color: tuple[int, int, int, int]


@dataclass
class Drawing:
    width: float
    height: float
    items: list[DrawItem] = field(default_factory=list)
    edges: list[EdgeItem] = field(default_factory=list)
    background: list[DrawItem] = field(default_factory=list)  # gap filler underlay
    overlay: list[DrawItem] = field(default_factory=list)  # watermark
    transform: Affine = field(default_factory=Affine)
    geometry: OutputGeometry | None = None


def _tx(segs: list[Segment], m: Affine) -> list[Segment]:
    if m == Affine():
        return segs
    return [t for s in segs for t in s.transformed(m)]


def _tx_primitive(prim: dict | None, m: Affine) -> dict | None:
    if not prim:
        return None
    k = m.a  # uniform scale only
    p = dict(prim)
    for key in ("cx", "cy", "r", "rx", "ry", "width", "height", "radius", "outer_radius", "inner_radius"):
        if key in p:
            p[key] = p[key] * k
    if "points" in p and isinstance(p["points"], list):
        p["points"] = [[x * k, y * k] for x, y in p["points"]]
    return p


def build_drawing(graph, opts: ExportOptions) -> Drawing:
    geo = output_geometry(graph, opts)
    m, w, h = geo.transform, geo.width, geo.height
    stacked = opts.shape_stacking == "stacked"
    d = Drawing(width=w, height=h, transform=m, geometry=geo)
    for s in graph.drawable_shapes():
        loops_he = graph.shape_loops(s, stacked)
        loops = [_tx(graph.loop_segments(lp), m) for lp in loops_he]
        loops = [lp for lp in loops if lp]
        if not loops:
            continue
        col = graph.color_of(s)
        item = DrawItem(s.id, col, s.color, loops, s.parent, s.depth, _tx_primitive(s.primitive, m), has_holes=len(loops) > 1)
        d.items.append(item)
    if opts.draw_style == "stroke_edges":
        for f in graph.interfaces.values():
            l_draw = f.left >= 0 and not graph.shapes[f.left].transparent
            r_draw = f.right >= 0 and not graph.shapes[f.right].transparent
            if not (l_draw or r_draw):
                continue
            cols = [graph.color_of(graph.shapes[x]) for x, ok in ((f.left, l_draw), (f.right, r_draw)) if ok]
            # darker side colour reads best as an outline
            col = min(cols, key=lambda c: 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2])
            d.edges.append(EdgeItem(f.id, _tx(f.segments, m), col))
    if opts.watermark != "none":
        from .watermark import watermark_items

        d.overlay = watermark_items(w, h, opts.watermark)
    return d


def fmt(v: float) -> str:
    s = f"{v:.3f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def polyline_segments(points: list[tuple[float, float]], closed: bool = True) -> list[Segment]:
    segs = [Line(points[i], points[i + 1]) for i in range(len(points) - 1)]
    if closed and points[0] != points[-1]:
        segs.append(Line(points[-1], points[0]))
    return segs


@dataclass
class PaintOp:
    """A format-neutral painting instruction (used by PDF and EPS)."""

    kind: str  # fill | stroke
    loops: list[list[Segment]]
    color: tuple[int, int, int, int]
    width: float = 0.0
    close: bool = True


def paint_ops(d: Drawing, opts: ExportOptions) -> list[PaintOp]:
    ops: list[PaintOp] = []
    if opts.draw_style == "stroke_edges":
        for e in d.edges:
            ops.append(PaintOp("stroke", [e.segments], e.color, opts.stroke_width, close=False))
    else:
        if opts.draw_style == "fill_shapes" and opts.gap_filler and opts.shape_stacking == "cutouts":
            for it in d.items:
                if it.color[3] == 255:
                    ops.append(PaintOp("stroke", it.loops, it.color, opts.gap_filler_width))
        for it in d.items:
            if opts.draw_style == "stroke_shapes":
                ops.append(PaintOp("stroke", it.loops, it.color, opts.stroke_width))
            else:
                ops.append(PaintOp("fill", it.loops, it.color))
    for it in d.overlay:
        ops.append(PaintOp("fill", it.loops, it.color))
    return ops


def cubic_path(loop: list[Segment]) -> list:
    """Loop as a list of ('L', p) / ('C', p1, p2, p3) commands (arcs and
    quadratics converted exactly / to cubics)."""
    from geometry_engine import CubicBezier, QuadBezier

    out = []
    for s in loop:
        if isinstance(s, Line):
            out.append(("L", s.p1))
        elif isinstance(s, (CubicBezier, QuadBezier)) or s.kind in ("A", "E"):
            for c in s.to_cubics():
                out.append(("C", c.p1, c.p2, c.p3))
        else:  # pragma: no cover
            raise TypeError(type(s))
    return out
