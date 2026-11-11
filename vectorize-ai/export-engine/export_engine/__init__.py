"""Export engine: SVG, PDF, EPS, DXF and PNG writers."""
from .common import EXPORT_SPECS, FORMATS, MIME, ExportError, ExportOptions, build_drawing, parse_export_public
from .png import RasterTooLarge, rasterize_drawing, render_graph, write_png
from .svg import write_svg


def export(graph, opts: ExportOptions) -> bytes:
    fmt = opts.file_format
    if fmt == "svg":
        return write_svg(graph, opts)
    if fmt == "png":
        return write_png(graph, opts)
    if fmt == "pdf":
        from .pdf import write_pdf

        return write_pdf(graph, opts)
    if fmt == "eps":
        from .eps import write_eps

        return write_eps(graph, opts)
    if fmt == "dxf":
        from .dxf import write_dxf

        return write_dxf(graph, opts)
    raise ExportError("output.file_format", f"unsupported format {fmt}")


__all__ = [
    "EXPORT_SPECS",
    "FORMATS",
    "MIME",
    "ExportError",
    "ExportOptions",
    "RasterTooLarge",
    "build_drawing",
    "export",
    "parse_export_public",
    "rasterize_drawing",
    "render_graph",
    "write_png",
    "write_svg",
]
