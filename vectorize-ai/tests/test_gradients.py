import io
import shutil
import subprocess

import numpy as np
import pytest

from export_engine import ExportOptions, export, render_graph
from geometry_engine.paint import GradientPaint
from synthetic import Scene, label_scene, logo_scene, png_bytes
from vectorization_engine import ProcessingOptions, VectorGraph, vectorize
from vectorization_engine.edits import EditState, apply_edits


def _err(a, b):
    m = (a[..., 3] > 8) | (b[..., 3] > 8)
    pa = a[..., :3].astype(float) * a[..., 3:4] / 255
    pb = b[..., :3].astype(float) * b[..., 3:4] / 255
    return float(np.abs(pa - pb)[m].mean())


def ramp(w=300, h=200):
    x = np.linspace(0, 1, w)[None, :, None]
    img = np.zeros((h, w, 4), np.uint8)
    img[..., :3] = np.clip(np.array([30, 80, 200]) * (1 - x) + np.array([250, 210, 60]) * x, 0, 255)
    img[..., 3] = 255
    return img


def test_paint_math_roundtrip():
    p = GradientPaint("radial", [(0.0, (255, 0, 0, 255)), (1.0, (0, 0, 255, 255))], m=(10, 0, 0, 5, 50, 40))
    c = p.colors_at(np.array([50.0, 60.0, 50.0]), np.array([40.0, 40.0, 45.0]))
    assert c[0][0] == pytest.approx(255) and c[1][2] == pytest.approx(255) and c[2][2] == pytest.approx(255)
    q = GradientPaint.from_json(p.to_json())
    assert q.kind == "radial" and q.m == p.m
    from geometry_engine import Affine

    t = p.transformed(Affine.scale(2.0))
    assert t.colors_at(np.array([120.0]), np.array([80.0]))[0][2] == pytest.approx(255)


def test_linear_ramp_becomes_one_gradient():
    res = vectorize(png_bytes(ramp()))
    g = res.graph
    shapes = g.drawable_shapes()
    assert len(shapes) == 1 and shapes[0].fill and shapes[0].fill["type"] == "linear"
    assert _err(res.prepared.rgba, render_graph(g)) < 1.5
    flat = vectorize(png_bytes(ramp()), ProcessingOptions(gradients=False))
    assert len(flat.graph.drawable_shapes()) > 5  # bands without the gradient stage


def test_flat_logo_is_unchanged():
    g = vectorize(png_bytes(logo_scene())).graph
    assert g.stats["gradient_shapes"] == 0
    assert g.stats["primitives"] == 4


def test_two_tone_regions_are_not_merged():
    s = Scene(200, 100, (255, 255, 255, 255)).rect(0, 0, 100, 100, (60, 120, 200, 255)).rect(100, 0, 200, 100, (95, 150, 235, 255))
    g = vectorize(png_bytes(s.image())).graph
    assert len(g.drawable_shapes()) == 2 and not any(sh.fill for sh in g.drawable_shapes())


def test_label_gradients_improve_fidelity():
    clean = label_scene(noise=0)
    data = png_bytes(label_scene())
    with_g = vectorize(data)
    without = vectorize(data, ProcessingOptions(gradients=False))
    e1, e0 = _err(clean, render_graph(with_g.graph)), _err(clean, render_graph(without.graph))
    assert e1 < e0 * 0.5
    assert with_g.graph.stats["shapes"] < without.graph.stats["shapes"]
    kinds = {s.fill["type"] for s in with_g.graph.drawable_shapes() if s.fill}
    assert kinds == {"linear", "radial"}
    assert with_g.graph.validate() == []


def test_gradient_exports():
    g = vectorize(png_bytes(ramp())).graph
    svg = export(g, ExportOptions(file_format="svg")).decode()
    assert "<linearGradient" in svg and 'fill="url(#g' in svg
    tiny = export(g, ExportOptions(file_format="svg", svg_version="svg_tiny_1_2")).decode()
    assert "gradientTransform" not in tiny
    pdf = export(g, ExportOptions(file_format="pdf"))
    assert b"/ShadingType 2" in pdf and b"/Shading << /Sh0" in pdf
    import zlib

    start = pdf.index(b"stream\n") + 7
    content = zlib.decompress(pdf[start : pdf.index(b"\nendstream")])
    assert b"W* n" in content and b"/Sh0 sh" in content
    eps = export(g, ExportOptions(file_format="eps")).decode()
    assert "shfill" in eps and "/ShadingType 2" in eps
    export(g, ExportOptions(file_format="dxf"))  # solid fallback


@pytest.mark.skipif(not shutil.which("pdftoppm"), reason="poppler not installed")
def test_gradient_pdf_renders_like_raster(tmp_path):
    from PIL import Image

    g = vectorize(png_bytes(label_scene())).graph
    (tmp_path / "a.pdf").write_bytes(export(g, ExportOptions(file_format="pdf")))
    subprocess.run(["pdftoppm", "-png", "-r", "72", "-singlefile", str(tmp_path / "a.pdf"), str(tmp_path / "r")], check=True)
    img = np.asarray(Image.open(tmp_path / "r.png").convert("RGB")).astype(float)
    ref = render_graph(g).astype(float)
    a = ref[..., 3:4] / 255
    assert np.abs(img - (ref[..., :3] * a + 255 * (1 - a))).mean() < 1.5


def test_recolouring_drops_gradient_and_json_roundtrip():
    g = vectorize(png_bytes(ramp())).graph
    sid = g.drawable_shapes()[0].id
    g2 = VectorGraph.from_json(g.to_json())
    assert g2.shapes[sid].fill == g.shapes[sid].fill
    e = EditState.from_json({"shapeColors": {str(sid): 0}})
    assert apply_edits(g, e).shapes[sid].fill is None
    assert apply_edits(g, EditState()).shapes[sid].fill is not None


def test_neural_background_optional():
    from vectorization_engine.background import detect_background, neural_available

    res = vectorize(png_bytes(logo_scene()))
    if not neural_available():
        with pytest.raises(ValueError):
            detect_background(res.graph, res.prepared.rgba, "neural")
        return
    out = detect_background(res.graph, res.prepared.rgba, "neural")
    assert out["method"] == "neural"
    bg = set(out["shapes"])
    assert 0 in bg  # the off-white background shape
    assert not any(s.primitive and s.primitive["type"] == "star" and s.id in bg for s in res.graph.drawable_shapes())
