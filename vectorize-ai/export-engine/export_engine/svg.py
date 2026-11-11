"""SVG export (1.0, 1.1, Tiny 1.2) – real vector paths only."""
from __future__ import annotations

import math
from xml.sax.saxutils import quoteattr

from geometry_engine import Arc, CubicBezier, EllipticArc, Line, QuadBezier, Segment

from .common import DrawItem, Drawing, ExportOptions, build_drawing, fmt

HEADERS = {
    "svg_1_0": (
        '<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n'
        '<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.0//EN" "http://www.w3.org/TR/2001/REC-SVG-20010904/DTD/svg10.dtd">\n',
        'version="1.0"',
    ),
    "svg_1_1": (
        '<?xml version="1.0" encoding="UTF-8" standalone="no"?>\n'
        '<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">\n',
        'version="1.1"',
    ),
    "svg_tiny_1_2": ('<?xml version="1.0" encoding="UTF-8"?>\n', 'version="1.2" baseProfile="tiny"'),
}


def _hex(c) -> str:
    return "#%02x%02x%02x" % (int(c[0]), int(c[1]), int(c[2]))


def _arc_cmd(seg, allow_arcs: bool) -> list[str]:
    if not allow_arcs:
        return [_seg_cmd(c, True) for c in seg.to_cubics()]
    if abs(seg.sweep) >= 2 * math.pi - 1e-6:  # full ellipse: two halves
        if isinstance(seg, Arc):
            h1 = Arc(seg.cx, seg.cy, seg.r, seg.start_angle, seg.sweep / 2)
            h2 = Arc(seg.cx, seg.cy, seg.r, seg.start_angle + seg.sweep / 2, seg.sweep / 2)
        else:
            h1 = EllipticArc(seg.cx, seg.cy, seg.rx, seg.ry, seg.rotation, seg.start_angle, seg.sweep / 2)
            h2 = EllipticArc(seg.cx, seg.cy, seg.rx, seg.ry, seg.rotation, seg.start_angle + seg.sweep / 2, seg.sweep / 2)
        return _arc_cmd(h1, True) + _arc_cmd(h2, True)
    end = seg.end()
    large = 1 if abs(seg.sweep) > math.pi else 0
    sweep = 1 if seg.sweep > 0 else 0
    if isinstance(seg, Arc):
        rx = ry = seg.r
        rot = 0.0
    else:
        rx, ry, rot = seg.rx, seg.ry, math.degrees(seg.rotation)
    return [f"A{fmt(rx)} {fmt(ry)} {fmt(rot)} {large} {sweep} {fmt(end[0])} {fmt(end[1])}"]


def _seg_cmd(seg: Segment, allow_arcs: bool) -> str:
    if isinstance(seg, Line):
        return f"L{fmt(seg.p1[0])} {fmt(seg.p1[1])}"
    if isinstance(seg, QuadBezier):
        return f"Q{fmt(seg.p1[0])} {fmt(seg.p1[1])} {fmt(seg.p2[0])} {fmt(seg.p2[1])}"
    if isinstance(seg, CubicBezier):
        return f"C{fmt(seg.p1[0])} {fmt(seg.p1[1])} {fmt(seg.p2[0])} {fmt(seg.p2[1])} {fmt(seg.p3[0])} {fmt(seg.p3[1])}"
    if isinstance(seg, (Arc, EllipticArc)):
        return "".join(_arc_cmd(seg, allow_arcs))
    raise TypeError(type(seg))


def path_data(loops: list[list[Segment]], allow_arcs: bool = True, close: bool = True) -> str:
    parts = []
    for lp in loops:
        if not lp:
            continue
        p = lp[0].start()
        parts.append(f"M{fmt(p[0])} {fmt(p[1])}")
        for s in lp:
            parts.append(_seg_cmd(s, allow_arcs))
        if close:
            parts.append("Z")
    return "".join(parts)


def _paint(item: DrawItem, style: str, stroke_w: float) -> str:
    c = item.color
    op = c[3] / 255.0
    if style == "fill_shapes" and getattr(item, "paint", None) is not None:
        return f'fill="url(#g{item.shape_id})"'.replace("#g-", "#gm")
    if style == "stroke_shapes":
        a = f'fill="none" stroke="{_hex(c)}" stroke-width="{fmt(stroke_w)}" stroke-linejoin="round"'
        if op < 1:
            a += f' stroke-opacity="{fmt(op)}"'
        return a
    a = f'fill="{_hex(c)}"'
    if op < 1:
        a += f' fill-opacity="{fmt(op)}"'
    return a


def _primitive_element(item: DrawItem, paint: str) -> str | None:
    p = item.primitive
    if not p:
        return None
    t = p.get("type")
    rot = math.degrees(p.get("rotation", 0.0))
    if t == "circle":
        return f'<circle cx="{fmt(p["cx"])}" cy="{fmt(p["cy"])}" r="{fmt(p["r"])}" {paint}/>'
    if t == "ellipse":
        tr = f' transform="rotate({fmt(rot)} {fmt(p["cx"])} {fmt(p["cy"])})"' if abs(rot) > 1e-6 else ""
        return f'<ellipse cx="{fmt(p["cx"])}" cy="{fmt(p["cy"])}" rx="{fmt(p["rx"])}" ry="{fmt(p["ry"])}"{tr} {paint}/>'
    if t in ("rectangle", "rounded_rectangle"):
        w, h = p["width"], p["height"]
        x, y = p["cx"] - w / 2, p["cy"] - h / 2
        tr = f' transform="rotate({fmt(rot)} {fmt(p["cx"])} {fmt(p["cy"])})"' if abs(rot) > 1e-6 else ""
        rr = f' rx="{fmt(p["radius"])}" ry="{fmt(p["radius"])}"' if t == "rounded_rectangle" else ""
        return f'<rect x="{fmt(x)}" y="{fmt(y)}" width="{fmt(w)}" height="{fmt(h)}"{rr}{tr} {paint}/>'
    if t in ("triangle", "quadrilateral") and isinstance(p.get("points"), list):
        pts = " ".join(f"{fmt(x)},{fmt(y)}" for x, y in p["points"])
        return f'<polygon points="{pts}" {paint}/>'
    if t == "star":
        k = int(p["points"])
        pts = []
        for i in range(2 * k):
            r = p["outer_radius"] if i % 2 == 0 else p["inner_radius"]
            a = p["rotation"] + i * math.pi / k
            pts.append(f"{fmt(p['cx'] + r * math.cos(a))},{fmt(p['cy'] + r * math.sin(a))}")
        return f'<polygon points="{" ".join(pts)}" {paint}/>'
    return None


def _element(item: DrawItem, opts: ExportOptions, allow_arcs: bool) -> str:
    paint = _paint(item, opts.draw_style, opts.stroke_width)
    if opts.use_primitives and not item.has_holes:
        el = _primitive_element(item, paint)
        if el:
            return el
    rule = ' fill-rule="evenodd"' if item.has_holes and opts.draw_style == "fill_shapes" else ""
    return f'<path d="{path_data(item.loops, allow_arcs)}"{rule} {paint}/>'


def _gradient_def(item: DrawItem, tiny: bool) -> str:
    p = item.paint
    gid = f"g{item.shape_id}".replace("g-", "gm")
    stops = "".join(
        f'<stop offset="{fmt(o)}" stop-color="{_hex(c)}"' + (f' stop-opacity="{fmt(c[3] / 255)}"' if c[3] < 255 else "") + "/>"
        for o, c in p.stops
    )
    if p.kind == "linear":
        return f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" x1="{fmt(p.x1)}" y1="{fmt(p.y1)}" x2="{fmt(p.x2)}" y2="{fmt(p.y2)}">{stops}</linearGradient>'
    a, b, c, d, e, f = p.m
    if tiny or p.is_circular():
        # SVG Tiny 1.2 has no gradientTransform: use the equivalent circle
        return f'<radialGradient id="{gid}" gradientUnits="userSpaceOnUse" cx="{fmt(e)}" cy="{fmt(f)}" r="{fmt(p.radius)}">{stops}</radialGradient>'
    return (
        f'<radialGradient id="{gid}" gradientUnits="userSpaceOnUse" cx="0" cy="0" r="1" '
        f'gradientTransform="matrix({" ".join(fmt(v) for v in (a, b, c, d, e, f))})">{stops}</radialGradient>'
    )


def write_svg(graph, opts: ExportOptions) -> bytes:
    d = build_drawing(graph, opts)
    return render_svg(d, opts).encode("utf-8")


def render_svg(d: Drawing, opts: ExportOptions) -> str:
    head, ver = HEADERS[opts.svg_version]
    allow_arcs = opts.svg_version != "svg_tiny_1_2" and not opts.svg_illustrator
    geo = d.geometry
    unit = "" if geo is None or geo.unit == "px" else geo.unit
    pw = geo.physical_width if geo else d.width
    ph = geo.physical_height if geo else d.height
    if opts.svg_illustrator and unit == "":
        unit = "px"
    out = [head]
    out.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" {ver} width="{fmt(pw)}{unit}" height="{fmt(ph)}{unit}" '
        f'viewBox="0 0 {fmt(d.width)} {fmt(d.height)}">\n'
    )
    out.append("<title>Vectorize AI result</title>\n" if opts.svg_version != "svg_1_0" else "")
    style = opts.draw_style
    painted = [it for it in d.items if getattr(it, "paint", None) is not None] if style == "fill_shapes" else []
    if painted:
        out.append("<defs>\n")
        out.extend(_gradient_def(it, opts.svg_version == "svg_tiny_1_2") + "\n" for it in painted)
        out.append("</defs>\n")
    if style == "stroke_edges":
        out.append(f'<g fill="none" stroke-width="{fmt(opts.stroke_width)}" stroke-linecap="round" stroke-linejoin="round">\n')
        for e in d.edges:
            op = e.color[3] / 255.0
            extra = f' stroke-opacity="{fmt(op)}"' if op < 1 else ""
            out.append(f'<path d="{path_data([e.segments], allow_arcs, close=False)}" stroke="{_hex(e.color)}"{extra}/>\n')
        out.append("</g>\n")
    else:
        if style == "fill_shapes" and opts.gap_filler and opts.shape_stacking == "cutouts" and d.items:
            out.append(f'<g fill="none" stroke-width="{fmt(opts.gap_filler_width)}" stroke-linejoin="round">\n')
            for it in d.items:
                if it.color[3] < 255:
                    continue
                out.append(f'<path d="{path_data(it.loops, allow_arcs)}" stroke="{_hex(it.color)}"/>\n')
            out.append("</g>\n")
        out.extend(_grouped(d.items, opts, allow_arcs))
    for it in d.overlay:
        out.append(_element(it, opts, allow_arcs) + "\n")
    out.append("</svg>\n")
    return "".join(out)


def _grouped(items: list[DrawItem], opts: ExportOptions, allow_arcs: bool) -> list[str]:
    out: list[str] = []
    gb = opts.group_by
    if gb == "none":
        return [_element(it, opts, allow_arcs) + "\n" for it in items]
    if gb == "color":
        if opts.shape_stacking == "cutouts":
            groups: dict[int, list[DrawItem]] = {}
            for it in items:
                groups.setdefault(it.color_index, []).append(it)
            for ci, its in groups.items():
                out.append(f"<g id={quoteattr(f'color-{ci}')}>\n")
                out.extend(_element(it, opts, allow_arcs) + "\n" for it in its)
                out.append("</g>\n")
            return out
        # stacked: keep paint order, group consecutive runs of one colour
        run: list[DrawItem] = []
        for it in items + [None]:
            if it is None or (run and it.color_index != run[0].color_index):
                if run:
                    out.append(f"<g id={quoteattr(f'color-{run[0].color_index}-{run[0].shape_id}')}>\n")
                    out.extend(_element(x, opts, allow_arcs) + "\n" for x in run)
                    out.append("</g>\n")
                run = []
            if it is not None:
                run.append(it)
        return out
    if gb == "layer":
        layers: dict[int, list[DrawItem]] = {}
        for it in items:
            layers.setdefault(it.depth, []).append(it)
        for depth in sorted(layers):
            out.append(f'<g id="layer-{depth}">\n')
            out.extend(_element(it, opts, allow_arcs) + "\n" for it in layers[depth])
            out.append("</g>\n")
        return out
    # parent: nested groups following the containment tree
    children: dict[int, list[DrawItem]] = {}
    ids = {it.shape_id for it in items}
    for it in items:
        children.setdefault(it.parent if it.parent in ids else -1, []).append(it)

    def emit(it: DrawItem):
        kids = children.get(it.shape_id, [])
        if not kids:
            out.append(_element(it, opts, allow_arcs) + "\n")
            return
        out.append(f'<g id="shape-{it.shape_id}">\n')
        out.append(_element(it, opts, allow_arcs) + "\n")
        for k in kids:
            emit(k)
        out.append("</g>\n")

    for root in children.get(-1, []):
        emit(root)
    return out
