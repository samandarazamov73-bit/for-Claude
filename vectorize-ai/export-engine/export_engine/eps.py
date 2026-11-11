"""EPS export: Encapsulated PostScript, EPSF-3.0 / PostScript Language
Level 3. PostScript has no transparency, so translucent colours are
composited over white."""
from __future__ import annotations

import math

from .common import ExportOptions, build_drawing, cubic_path, paint_ops


def _n(v: float) -> str:
    s = f"{v:.4f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def _flatten_alpha(c) -> tuple[float, float, float]:
    a = c[3] / 255.0
    return tuple((v / 255.0) * a + (1.0 - a) for v in c[:3])  # type: ignore[return-value]


def write_eps(graph, opts: ExportOptions) -> bytes:
    d = build_drawing(graph, opts)
    k = d.geometry.points_per_px
    w_pt, h_pt = d.width * k, d.height * k
    lines = [
        "%!PS-Adobe-3.0 EPSF-3.0",
        f"%%BoundingBox: 0 0 {int(math.ceil(w_pt))} {int(math.ceil(h_pt))}",
        f"%%HiResBoundingBox: 0 0 {_n(w_pt)} {_n(h_pt)}",
        "%%Creator: Vectorize AI",
        "%%Title: (Vectorize AI result)",
        "%%LanguageLevel: 3",
        "%%Pages: 1",
        "%%DocumentData: Clean7Bit",
        "%%EndComments",
        "%%BeginProlog",
        "/vzdict 16 dict def vzdict begin",
        "/m {moveto} bind def /l {lineto} bind def /c {curveto} bind def /h {closepath} bind def",
        "/f {eofill} bind def /s {stroke} bind def /rgb {setrgbcolor} bind def /w {setlinewidth} bind def",
        "end",
        "%%EndProlog",
        "%%Page: 1 1",
        "vzdict begin",
        "gsave",
        f"0 {_n(h_pt)} translate {_n(k)} {_n(-k)} scale",
        "1 setlinecap 1 setlinejoin",
    ]
    for op in paint_ops(d, opts):
        r, g, b = _flatten_alpha(op.color)
        lines.append(f"{_n(r)} {_n(g)} {_n(b)} rgb")
        lines.append("newpath")
        for lp in op.loops:
            if not lp:
                continue
            p = lp[0].start()
            buf = [f"{_n(p[0])} {_n(p[1])} m"]
            for cmd in cubic_path(lp):
                if cmd[0] == "L":
                    buf.append(f"{_n(cmd[1][0])} {_n(cmd[1][1])} l")
                else:
                    (a, b2), (c2, d2), (e, f) = cmd[1], cmd[2], cmd[3]
                    buf.append(f"{_n(a)} {_n(b2)} {_n(c2)} {_n(d2)} {_n(e)} {_n(f)} c")
            if op.close:
                buf.append("h")
            lines.extend(_wrap(buf))
        if op.kind == "fill":
            lines.append("f")
        else:
            lines.append(f"{_n(op.width)} w s")
    lines += ["grestore", "end", "showpage", "%%Trailer", "%%EOF", ""]
    return "\n".join(lines).encode("ascii")


def _wrap(tokens: list[str], width: int = 200) -> list[str]:
    """DSC recommends lines shorter than 255 characters."""
    out, cur = [], ""
    for t in tokens:
        if cur and len(cur) + 1 + len(t) > width:
            out.append(cur)
            cur = t
        else:
            cur = f"{cur} {t}" if cur else t
    if cur:
        out.append(cur)
    return out
