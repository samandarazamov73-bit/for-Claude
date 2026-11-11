import json
import os

import numpy as np
import pytest

from export_engine import render_graph
from synthetic import hard_edge_scene, jpeg_roundtrip, logo_scene, png_bytes, repeats_scene, touching_scene, transparent_scene
from vectorization_engine import Cancelled, OptionError, ProcessingOptions, StageCache, VectorGraph, parse_public, vectorize
from vectorization_engine.background import coverage, detect_background
from vectorization_engine.edits import EditState, apply_edits


def fidelity(res) -> float:
    ren = render_graph(res.graph).astype(int)
    src = res.prepared.rgba.astype(int)
    return float(np.abs(ren - src)[..., :3].mean())


def test_logo_end_to_end(logo_result):
    g = logo_result.graph
    assert g.stats["validation_problems"] == []
    kinds = sorted(s.primitive["type"] for s in g.drawable_shapes() if s.primitive)
    assert kinds == ["circle", "circle", "rounded_rectangle", "star"]
    star = next(s for s in g.drawable_shapes() if s.primitive and s.primitive["type"] == "star")
    assert star.primitive["points"] == 5
    assert abs(star.primitive["outer_radius"] - 58) < 0.5
    assert fidelity(logo_result) < 1.0


def test_no_gaps_or_overlaps(logo_result):
    g = logo_result.graph
    # every interface is used exactly once by each adjacent shape
    use: dict[tuple[int, int], int] = {}
    for s in g.shapes.values():
        for lp in s.loops:
            for iid, rev in lp:
                use[(iid, s.id)] = use.get((iid, s.id), 0) + 1
    for f in g.interfaces.values():
        for side in (f.left, f.right):
            if side >= 0:
                assert use.get((f.id, side)) == 1
    assert abs(coverage(g) - 1.0) < 0.002


def test_graph_json_roundtrip(logo_result):
    g = logo_result.graph
    d = g.to_json()
    g2 = VectorGraph.from_json(json.loads(json.dumps(d)))
    assert g2.validate() == []
    assert len(g2.shapes) == len(g.shapes) and len(g2.interfaces) == len(g.interfaces)
    a, b = render_graph(g), render_graph(g2)
    assert np.abs(a.astype(int) - b.astype(int)).max() <= 2


@pytest.mark.parametrize("scene", [touching_scene, transparent_scene, repeats_scene, hard_edge_scene])
def test_scenes_are_faithful_and_valid(scene):
    res = vectorize(png_bytes(scene()))
    assert res.graph.stats["validation_problems"] == []
    assert fidelity(res) < 1.5


def test_jpeg_input():
    import cv2

    img = logo_scene()
    ok, buf = cv2.imencode(".jpg", cv2.cvtColor(img[..., :3], cv2.COLOR_RGB2BGR), [cv2.IMWRITE_JPEG_QUALITY, 75])
    res = vectorize(buf.tobytes())
    assert res.graph.stats["colors"] == 4
    assert res.graph.stats["primitives"] == 4


def test_repeats_and_symmetry():
    res = vectorize(png_bytes(repeats_scene()))
    shapes = [s for s in res.graph.drawable_shapes() if s.repeat_group is not None]
    assert len(shapes) == 4
    assert all(s.symmetry for s in shapes)


def test_transparency_is_kept():
    res = vectorize(png_bytes(transparent_scene()))
    ren = render_graph(res.graph)
    assert ren[0, 0, 3] == 0
    assert any(s.transparent for s in res.graph.shapes.values())


def test_options_change_output():
    img = png_bytes(logo_scene())
    no_shapes = vectorize(img, ProcessingOptions(shapes_enabled=False, symmetry_mirror=False, symmetry_rotation=False))
    assert no_shapes.graph.stats["primitives"] == 0
    lines_only = vectorize(img, ProcessingOptions(curves_cubic=False, curves_quadratic=False, curves_arcs=False, shapes_enabled=False))
    kinds = lines_only.graph.stats["segment_kinds"]
    assert set(kinds) == {"L"}
    assert fidelity(lines_only) < 2.0


def test_progress_and_cancellation():
    seen = []
    vectorize(png_bytes(logo_scene()), progress=lambda s, f, m: seen.append((s, f)))
    stages = [s for s, _ in seen]
    for st in ("decode", "preprocess", "segmentation", "topology", "subpixel", "curves", "shapes", "finalize"):
        assert st in stages
    fr = [f for _, f in seen]
    assert fr == sorted(fr) and fr[-1] > 0.95

    def cancel(stage, frac, msg):
        if stage == "curves":
            raise Cancelled()

    with pytest.raises(Cancelled):
        vectorize(png_bytes(logo_scene()), progress=cancel)


def test_stage_cache_reuses_segmentation(tmp_path):
    cache = StageCache(str(tmp_path))
    img = png_bytes(logo_scene())
    vectorize(img, ProcessingOptions(), cache=cache)
    files = os.listdir(tmp_path)
    assert any(f.startswith("seg_") for f in files) and any(f.startswith("prep_") for f in files)
    msgs = []
    vectorize(img, ProcessingOptions(corners_mode="sharp"), cache=cache, progress=lambda s, f, m: msgs.append(m))
    assert "using cached segmentation" in msgs


def test_crop():
    res = vectorize(png_bytes(logo_scene()), crop=(150, 50, 140, 140))
    assert res.graph.width == 140 and res.graph.height == 140


def test_public_option_parsing():
    o = parse_public({"processing.max_colors": "12", "processing.corners.mode": "sharp", "processing.shapes.circle": "false"})
    assert o.max_colors == 12 and o.corners_mode == "sharp" and not o.shapes_circle
    with pytest.raises(OptionError):
        parse_public({"processing.max_colors": "999"})
    with pytest.raises(OptionError):
        parse_public({"processing.corners.mode": "pointy"})
    with pytest.raises(OptionError):
        parse_public({"processing.palette": "#zzz"})


def test_edits_and_background(logo_result):
    g = logo_result.graph
    bg = detect_background(g, logo_result.prepared.rgba, "color")
    assert len(bg["shapes"]) == 1
    e = EditState.from_json({"backgroundShapes": bg["shapes"], "paletteOverrides": {"3": [0, 0, 0, 255]}})
    g2 = apply_edits(g, e)
    ren = render_graph(g2)
    assert ren[2, 2, 3] == 0  # background removed
    star = next(s for s in g2.drawable_shapes() if s.primitive and s.primitive["type"] == "star")
    assert tuple(g2.palette[star.color]) == (0, 0, 0, 255)
    ring = next(s for s in g2.drawable_shapes() if s.primitive and s.primitive["type"] == "circle" and len(s.loops) == 2)
    inner = next(s for s in g2.drawable_shapes() if s.parent == ring.id)
    g3 = apply_edits(g, EditState.from_json({"regionMerges": [[ring.id, inner.id]]}))
    merged = g3.shapes[ring.id]
    assert len(merged.loops) == 1 and inner.id not in g3.shapes
    assert g3.validate() == []
