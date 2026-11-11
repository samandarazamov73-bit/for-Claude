import io
import shutil
import subprocess
from xml.etree import ElementTree as ET

import ezdxf
import numpy as np
import pytest
from PIL import Image

from export_engine import ExportError, ExportOptions, export, parse_export_public, render_graph

SVG_NS = "{http://www.w3.org/2000/svg}"


def opts(**kw):
    return ExportOptions.from_dict(kw)


@pytest.mark.parametrize("version", ["svg_1_0", "svg_1_1", "svg_tiny_1_2"])
def test_svg_versions(logo_result, version):
    data = export(logo_result.graph, opts(file_format="svg", svg_version=version))
    root = ET.fromstring(data)
    assert root.tag == SVG_NS + "svg"
    assert root.get("version") == {"svg_1_0": "1.0", "svg_1_1": "1.1", "svg_tiny_1_2": "1.2"}[version]
    text = data.decode()
    assert "<image" not in text  # never a raster inside the SVG
    if version == "svg_tiny_1_2":
        for p in root.iter(SVG_NS + "path"):
            assert "A" not in p.get("d")  # no arcs in Tiny 1.2


def test_svg_native_primitives_and_grouping(logo_result):
    text = export(logo_result.graph, opts(file_format="svg", shape_stacking="stacked", group_by="parent")).decode()
    assert "<circle" in text and "<polygon" in text and "<rect" in text
    root = ET.fromstring(text)
    assert len(list(root.iter(SVG_NS + "g"))) >= 2
    no_prims = export(logo_result.graph, opts(file_format="svg", use_primitives=False)).decode()
    assert "<circle" not in no_prims


def test_svg_stroke_edges(logo_result):
    root = ET.fromstring(export(logo_result.graph, opts(file_format="svg", draw_style="stroke_edges")))
    paths = list(root.iter(SVG_NS + "path"))
    assert len(paths) == len([f for f in logo_result.graph.interfaces.values()])


def test_svg_physical_size(logo_result):
    root = ET.fromstring(export(logo_result.graph, opts(file_format="svg", size_unit="in", size_dpi=100)))
    assert root.get("width") == "3.2in" and root.get("height") == "2.4in"


def test_pdf_is_valid_and_renders(logo_result, tmp_path):
    from pypdf import PdfReader

    data = export(logo_result.graph, opts(file_format="pdf"))
    assert data.startswith(b"%PDF-1.4") and data.rstrip().endswith(b"%%EOF")
    r = PdfReader(io.BytesIO(data))
    box = r.pages[0].mediabox
    assert float(box.width) == pytest.approx(320) and float(box.height) == pytest.approx(240)
    if shutil.which("pdftoppm"):
        p = tmp_path / "a.pdf"
        p.write_bytes(data)
        subprocess.run(["pdftoppm", "-png", "-r", "72", "-singlefile", str(p), str(tmp_path / "r")], check=True)
        img = np.asarray(Image.open(tmp_path / "r.png").convert("RGB")).astype(int)
        ref = render_graph(logo_result.graph)[..., :3].astype(int)
        assert np.abs(img - ref).mean() < 1.5


def test_eps_structure(logo_result):
    text = export(logo_result.graph, opts(file_format="eps")).decode("ascii")
    assert text.startswith("%!PS-Adobe-3.0 EPSF-3.0")
    assert "%%BoundingBox: 0 0 320 240" in text
    assert "%%LanguageLevel: 3" in text and text.rstrip().endswith("%%EOF")
    assert text.count(" c") > 10 and "eofill" in text
    assert max(len(line) for line in text.splitlines()) < 255


@pytest.mark.parametrize("level,types", [("lines", {"LWPOLYLINE"}), ("lines_arcs", {"LWPOLYLINE"}), ("lines_arcs_splines", {"LWPOLYLINE", "SPLINE"})])
def test_dxf_levels(level, types):
    from synthetic import png_bytes, touching_scene
    from vectorization_engine import vectorize

    g = vectorize(png_bytes(touching_scene())).graph
    data = export(g, opts(file_format="dxf", dxf_compatibility=level))
    doc = ezdxf.read(io.StringIO(data.decode()))
    assert len(doc.audit().errors) == 0
    got = {e.dxftype() for e in doc.modelspace()}
    assert got <= types and "LWPOLYLINE" in got
    if level == "lines_arcs":
        assert any(any(b != 0 for b in e.get_points("b")) for e in doc.modelspace() if e.dxftype() == "LWPOLYLINE")


def test_png_export_sizes(logo_result):
    data = export(logo_result.graph, opts(file_format="png", png_scale=2.0))
    im = Image.open(io.BytesIO(data))
    assert im.size == (640, 480) and im.mode == "RGBA"
    data = export(logo_result.graph, opts(file_format="png", png_antialias=False))
    arr = np.asarray(Image.open(io.BytesIO(data)))
    # without anti-aliasing only palette colours appear
    assert len({tuple(p) for p in arr.reshape(-1, 4)}) <= 4


def test_watermark_present(logo_result):
    clean = render_graph(logo_result.graph)
    marked_png = export(logo_result.graph, opts(file_format="png", watermark="test"))
    marked = np.asarray(Image.open(io.BytesIO(marked_png)))
    assert np.abs(marked.astype(int) - clean.astype(int)).mean() > 3


def test_export_option_validation():
    with pytest.raises(ExportError):
        parse_export_public({"output.file_format": "jpg"})
    with pytest.raises(ExportError):
        parse_export_public({"output.size.scale": "0"})
    o = parse_export_public({"output.file_format": "pdf", "output.size.unit": "mm", "output.size.width": "100"})
    assert o.file_format == "pdf" and o.size_width == 100


def test_png_has_no_conflation_seams():
    """Two light shapes sharing a diagonal border inside a dark parent: the
    composited renderer lets the parent shine through the shared edge, the
    seamless renderer must not."""
    import dataclasses

    from export_engine import build_drawing
    from export_engine.png import rasterize_composited, rasterize_seamless
    from synthetic import Scene, png_bytes
    from vectorization_engine import ProcessingOptions, vectorize

    s = Scene(200, 200, (10, 40, 20, 255))
    s.polygon([(20, 20), (180, 20), (20, 180)], (200, 230, 190, 255))
    s.polygon([(180, 20), (180, 180), (20, 180)], (150, 200, 240, 255))
    g = vectorize(png_bytes(s.image()), ProcessingOptions(shapes_enabled=False, gradients=False)).graph
    d = build_drawing(g, dataclasses.replace(ExportOptions(), shape_stacking="stacked"))
    seam = [(100 + t, 99 - t) for t in range(-60, 61, 3)]  # pixels the shared diagonal cuts in half
    darkest = lambda img: min(int(img[y, x, :3].astype(int).sum()) for x, y in seam)  # noqa: E731
    light = min(200 + 230 + 190, 150 + 200 + 240)
    assert darkest(rasterize_seamless(d, 1.0)) >= light - 12
    assert darkest(rasterize_composited(d, 1.0)) < darkest(rasterize_seamless(d, 1.0))
