"""PDF 1.4 export (hand-written, FlateDecode content stream)."""
from __future__ import annotations

import datetime as _dt
import zlib

from .common import ExportOptions, build_drawing, cubic_path, paint_ops


def _n(v: float) -> str:
    s = f"{v:.4f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def _path_ops(loops, close: bool) -> list[str]:
    out = []
    for lp in loops:
        if not lp:
            continue
        p = lp[0].start()
        out.append(f"{_n(p[0])} {_n(p[1])} m")
        for cmd in cubic_path(lp):
            if cmd[0] == "L":
                out.append(f"{_n(cmd[1][0])} {_n(cmd[1][1])} l")
            else:
                (a, b), (c, d), (e, f) = cmd[1], cmd[2], cmd[3]
                out.append(f"{_n(a)} {_n(b)} {_n(c)} {_n(d)} {_n(e)} {_n(f)} c")
        if close:
            out.append("h")
    return out


def ps_function(stops) -> str:
    """PDF/PostScript function dictionary for gradient stops (type 2 for one
    interval, type 3 stitching for several)."""
    def c(col):
        return "[" + " ".join(_n(v / 255.0) for v in col[:3]) + "]"

    if len(stops) == 1:
        stops = [stops[0], (1.0, stops[0][1])]
    parts = [f"<< /FunctionType 2 /Domain [0 1] /C0 {c(a[1])} /C1 {c(b[1])} /N 1 >>" for a, b in zip(stops[:-1], stops[1:])]
    if len(parts) == 1:
        return parts[0]
    bounds = " ".join(_n(o) for o, _ in stops[1:-1])
    encode = " ".join(["0 1"] * len(parts))
    return f"<< /FunctionType 3 /Domain [0 1] /Functions [{' '.join(parts)}] /Bounds [{bounds}] /Encode [{encode}] >>"


def shading_dict(paint) -> str:
    fn = ps_function(paint.stops)
    if paint.kind == "linear":
        return f"<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [{_n(paint.x1)} {_n(paint.y1)} {_n(paint.x2)} {_n(paint.y2)}] /Function {fn} /Extend [true true] >>"
    return f"<< /ShadingType 3 /ColorSpace /DeviceRGB /Coords [0 0 0 0 0 1] /Function {fn} /Extend [true true] >>"


def write_pdf(graph, opts: ExportOptions) -> bytes:
    d = build_drawing(graph, opts)
    geo = d.geometry
    k = geo.points_per_px
    w_pt, h_pt = d.width * k, d.height * k
    alphas: dict[int, str] = {}
    shadings: list[str] = []
    content = [f"q {_n(k)} 0 0 {_n(-k)} 0 {_n(h_pt)} cm", "1 J 1 j"]
    for op in paint_ops(d, opts):
        r, g, b, a = (c / 255.0 for c in op.color)
        content.append("q")
        if op.kind == "fill" and op.paint is not None:
            name = f"Sh{len(shadings)}"
            shadings.append(shading_dict(op.paint))
            content.extend(_path_ops(op.loops, True))
            content.append("W* n")
            if op.paint.kind == "radial":
                content.append(" ".join(_n(v) for v in op.paint.m) + " cm")
            content.append(f"/{name} sh")
            content.append("Q")
            continue
        if op.color[3] < 255:
            name = alphas.setdefault(op.color[3], f"GS{len(alphas)}")
            content.append(f"/{name} gs")
        if op.kind == "fill":
            content.append(f"{_n(r)} {_n(g)} {_n(b)} rg")
            content.extend(_path_ops(op.loops, True))
            content.append("f*")
        else:
            content.append(f"{_n(r)} {_n(g)} {_n(b)} RG {_n(op.width)} w")
            content.extend(_path_ops(op.loops, op.close))
            content.append("S")
        content.append("Q")
    content.append("Q")
    stream = zlib.compress("\n".join(content).encode("ascii"), 6)

    first_extra = 6
    gs_ids = {name: first_extra + i for i, name in enumerate(alphas.values())}
    sh_first = first_extra + len(alphas)
    res = []
    if alphas:
        res.append("/ExtGState << " + " ".join(f"/{nm} {oid} 0 R" for nm, oid in gs_ids.items()) + " >>")
    if shadings:
        res.append("/Shading << " + " ".join(f"/Sh{i} {sh_first + i} 0 R" for i in range(len(shadings))) + " >>")
    resources = "<< " + " ".join(res) + " >>"
    objs: list[bytes] = []
    objs.append(b"<< /Type /Catalog /Pages 2 0 R >>")
    objs.append(b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    objs.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {_n(w_pt)} {_n(h_pt)}] /Contents 4 0 R /Resources {resources} >>".encode())
    objs.append(f"<< /Length {len(stream)} /Filter /FlateDecode >>\nstream\n".encode() + stream + b"\nendstream")
    now = _dt.datetime.now(_dt.timezone.utc).strftime("D:%Y%m%d%H%M%SZ")
    objs.append(f"<< /Producer (Vectorize AI) /Creator (Vectorize AI) /CreationDate ({now}) >>".encode())
    for alpha in alphas:
        av = _n(alpha / 255.0)
        objs.append(f"<< /Type /ExtGState /ca {av} /CA {av} >>".encode())
    for sh in shadings:
        objs.append(sh.encode())

    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for i, body in enumerate(objs, start=1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n".encode() + body + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode()
    for off in offsets:
        out += f"{off:010d} 00000 n \n".encode()
    out += f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R /Info 5 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    return bytes(out)
