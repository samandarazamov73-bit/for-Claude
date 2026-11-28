"""Fine details: sharpening halos, thin lines, small highlights on shading,
and profile fitting of vignette-like gradients."""
import math

import cv2
import numpy as np
import pytest

from image_processing import SegmentationOptions, preprocess, segment
from image_processing.gradients import _pl_fit, _pl_fit_adaptive
from synthetic import Scene, png_bytes
from vectorization_engine import vectorize
from export_engine import render_graph

LETTER = (5, 55, 25, 255)


def _seg(img, **kw):
    pp = preprocess(img)
    a = pp.analysis
    return segment(pp.rgba, SegmentationOptions(**kw), noise_sigma=a.noise_sigma, edge_width=a.edge_width, compressed=a.compressed)


def _sharpen(img, amount=0.6, sigma=1.0):  # mild unsharp mask, like upscalers apply
    f = img[..., :3].astype(np.float32)
    out = img.copy()
    out[..., :3] = np.clip(f + amount * (f - cv2.GaussianBlur(f, (0, 0), sigma)), 0, 255).astype(np.uint8)
    return out


def _glyph_scene():
    # a "Г" and an "L"-like glyph: straight edges and right-angle corners
    s = Scene(220, 120)
    s.polygon([(20, 20), (90, 20), (90, 36), (38, 36), (38, 100), (20, 100)], LETTER)
    s.polygon([(120, 20), (138, 20), (138, 84), (200, 84), (200, 100), (120, 100)], LETTER)
    # a near-black swatch elsewhere puts the halo colour into the palette,
    # as dark artwork does in real labels
    s.rect(150, 4, 210, 12, (1, 20, 3, 255))
    return s.image()


def test_sharpening_halo_stays_part_of_the_letter():
    seg = _seg(_sharpen(_glyph_scene()))
    # two glyphs, the swatch and the background, nothing else: the dark
    # overshoot rim and anti-aliasing strips must not become regions
    assert seg.region_count == 4
    g = vectorize(png_bytes(_sharpen(_glyph_scene()))).graph
    assert len(g.drawable_shapes()) == 4


def test_thin_diagonal_line_survives():
    s = Scene(200, 200, (40, 120, 30, 255))
    d = np.array([1.0, -1.0]) / np.sqrt(2.0)
    n = np.array([1.0, 1.0]) / np.sqrt(2.0) * 0.45  # line 0.9 px wide
    a, b = np.array([20.0, 180.0]), np.array([180.0, 20.0])
    s.polygon([tuple(a + n), tuple(b + n), tuple(b - n), tuple(a - n)], (235, 250, 215, 255))
    s.circle(20, 180, 4, (235, 250, 215, 255))  # the solid end the line grows from
    seg = _seg(s.image())
    light = [r for r in range(1, seg.region_color.shape[0]) if seg.region_color[r] >= 0 and seg.palette[seg.region_color[r]][0] > 120]
    assert light, "the line disappeared"
    spans = []
    for r in light:
        ys, xs = np.nonzero(seg.regions == r)
        spans.append(xs.max() - xs.min())
    # one connected light region runs (almost) the whole length of the line
    assert max(spans) > 120


def test_small_highlight_is_not_dissolved_into_a_gradient():
    # a droplet-sized highlight on a large smooth ramp: it barely changes the
    # pooled error of the ramp, but must not be merged into its gradient
    w, h = 600, 400
    x = np.linspace(0, 1, w)[None, :, None]
    img = np.zeros((h, w, 4), np.uint8)
    img[..., :3] = np.clip(np.array([40, 120, 30]) * (1 - x) + np.array([150, 210, 90]) * x, 0, 255)
    img[..., 3] = 255
    s = Scene(w, h)
    s.img[:] = 0
    s.circle(300, 200, 2.5, (190, 235, 150, 255))
    spot = s.image()
    a = spot[..., 3:4].astype(np.float32) / 255.0
    img[..., :3] = (img[..., :3] * (1 - a) + spot[..., :3] * a + 0.5).astype(np.uint8)
    res = vectorize(png_bytes(img))
    ren = render_graph(res.graph)
    assert ren[200, 300, :3].astype(int).sum() > 520  # highlight kept (ramp there: ~320)
    assert any(sh.fill for sh in res.graph.drawable_shapes())  # and the ramp is a gradient


def test_adaptive_knots_follow_a_vignette_profile():
    rng = np.random.default_rng(0)
    t = rng.random(20000)
    v = np.where(t < 0.78, 250.0, 250.0 - (t - 0.78) / 0.22 * 110.0)
    cols = np.stack([v, v - 5, v - 20], 1) + rng.normal(0, 1.0, (t.shape[0], 3))
    _, sse_uniform = _pl_fit(t, cols, 8)
    pos, _, sse_adaptive = _pl_fit_adaptive(t, cols, 8)
    assert sse_adaptive < 0.6 * sse_uniform
    assert pos[0] == 0.0 and pos[-1] == 1.0 and np.all(np.diff(pos) > 0)
    assert (pos > 0.7).sum() >= 3  # knots gather where the colour changes


def test_detail_option_is_validated():
    from vectorization_engine import OptionError, ProcessingOptions, parse_public

    assert parse_public({"processing.detail": "max"}).detail_level == 2
    assert parse_public({"processing.detail": "photo"}).detail_level == 3
    assert ProcessingOptions().detail_level == 0
    with pytest.raises(OptionError):
        parse_public({"processing.detail": "ultra"})
    # detail changes the segmentation, so it is part of the cache key
    assert ProcessingOptions(detail="high").segmentation_key() != ProcessingOptions().segmentation_key()


def test_tiny_closed_loops_stay_in_place():
    from geometry_engine.fitting import smooth_points

    tri = np.array([[458.0, 194.5], [458.5, 195.0], [459.0, 194.5]])
    out = smooth_points(tri, 1.5, closed=True)  # kernel radius > loop length
    assert np.abs(out - tri.mean(0)).max() < 1.0
    sq = np.array([[0.0, 0.0], [10.0, 0.0], [10.0, 10.0], [0.0, 10.0]])
    out = smooth_points(sq, 0.9, closed=True)
    assert np.allclose(out.mean(0), [5.0, 5.0]) and np.ptp(out[:, 0]) > 5.0  # not collapsed


def test_higher_detail_is_closer_to_the_source():
    from synthetic import photo_like
    from vectorization_engine import ProcessingOptions

    img = photo_like(360, 260, seed=7)
    errs, shapes = [], []
    for level in ("normal", "max", "photo"):
        res = vectorize(png_bytes(img), ProcessingOptions(detail=level))
        ren = render_graph(res.graph)
        errs.append(np.abs(ren[..., :3].astype(int) - res.prepared.rgba[..., :3].astype(int)).mean())
        shapes.append(len(res.graph.drawable_shapes()))
        # no stray geometry: every shape lies inside the canvas
        for sh in res.graph.drawable_shapes():
            assert sh.bbox[0] > -2 and sh.bbox[1] > -2 and sh.bbox[2] < 362 and sh.bbox[3] < 262
    assert errs[1] < 0.85 * errs[0]
    assert errs[2] < errs[1]  # photo is the closest
    assert shapes[0] < shapes[1] < shapes[2]


def _red_text_logo():
    from PIL import Image as PILImage, ImageDraw, ImageFont

    S = 4
    im = PILImage.new("RGB", (420 * S, 150 * S), "white")
    d = ImageDraw.Draw(im)
    font_path = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
    try:
        small = ImageFont.truetype(font_path, 30 * S)
        big = ImageFont.truetype(font_path, 70 * S)
    except OSError:
        pytest.skip("DejaVu font not available")
    d.text((20 * S, 10 * S), "NTA", font=big, fill=(239, 24, 32))
    d.text((20 * S, 100 * S), "SINCE 2013", font=small, fill=(239, 24, 32))
    clean = im.resize((420, 150), PILImage.BOX)
    return np.asarray(clean)


def _jpeg(rgb, quality=85, subsampling=2):
    import io as _io

    from PIL import Image as PILImage

    buf = _io.BytesIO()
    PILImage.fromarray(rgb).save(buf, "JPEG", quality=quality, subsampling=subsampling)
    return buf.getvalue()


def test_jpeg_subsampling_is_detected():
    from image_processing import decode_image

    rgb = _red_text_logo()
    assert decode_image(_jpeg(rgb, subsampling=2)).chroma_subsampling == (2, 2)
    assert decode_image(_jpeg(rgb, subsampling=0)).chroma_subsampling is None
    assert decode_image(png_bytes(np.dstack([rgb, np.full(rgb.shape[:2], 255, np.uint8)]))).chroma_subsampling is None


def test_chroma_restoration_sharpens_thin_red_strokes():
    from image_processing import decode_image
    from image_processing.chroma import restore_subsampled_chroma

    rgb = _red_text_logo()
    dec = decode_image(_jpeg(rgb))
    fixed = restore_subsampled_chroma(dec.rgba, dec.chroma_subsampling)
    text = (slice(95, 140), slice(15, 260))  # the small text
    before = np.abs(dec.rgba[text][..., :3].astype(int) - rgb[text]).mean()
    after = np.abs(fixed[text][..., :3].astype(int) - rgb[text]).mean()
    assert after < 0.8 * before


def test_small_red_text_in_jpeg_keeps_one_red():
    rgb = _red_text_logo()
    res = vectorize(_jpeg(rgb))
    pal = res.graph.palette
    # white and the one red of the design: no darker or pinkish copies
    assert len(pal) == 2
    red = min(pal, key=lambda c: int(c[1]))
    assert abs(int(red[0]) - 239) <= 8 and int(red[1]) <= 40 and int(red[2]) <= 45
    ren = render_graph(res.graph)[..., :3].astype(int)
    assert np.abs(ren - rgb.astype(int)).mean() < 2.0
    # flat artwork keeps flat fills (no gradients made of JPEG noise), and
    # every detail level gives the same clean result
    assert res.graph.stats["flat_artwork"] and res.graph.stats["gradient_shapes"] == 0
    from vectorization_engine import ProcessingOptions

    hi = vectorize(_jpeg(rgb), ProcessingOptions(detail="high")).graph
    assert len(hi.palette) == 2 and hi.stats["gradient_shapes"] == 0


def test_straight_polyline_knee_and_arc():
    from geometry_engine.fitting import _straight_polyline

    rng = np.random.default_rng(3)
    # a diagonal meeting a vertical stem at a shallow knee, with JPEG-like noise
    a = np.stack([np.linspace(0, 60, 121), np.linspace(0, 100, 121)], 1)
    b = np.stack([np.full(80, 60.0), np.linspace(100.5, 140, 80)], 1)
    pts = np.concatenate([a, b]) + rng.normal(0, 0.15, (201, 2))  # after fairing
    pts[0], pts[-1] = (0.0, 0.0), (60.0, 140.0)
    v = _straight_polyline(pts, 0.65)
    assert v is not None and len(v) == 3
    assert np.hypot(*(np.asarray(v[1]) - [60.0, 100.0])) < 1.5
    # a circular arc must stay a curve
    t = np.linspace(0, math.pi / 2, 160)
    arc = np.stack([80 * np.cos(t), 80 * np.sin(t)], 1)
    assert _straight_polyline(arc, 0.65) is None


def test_glyph_edges_are_straight_and_axis_aligned():
    rgb = _red_text_logo()
    g = vectorize(_jpeg(rgb)).graph
    long_lines = []
    for f in g.interfaces.values():
        for s in f.segments:
            if s.kind == "L":
                (x0, y0), (x1, y1) = s.start(), s.end()
                if math.hypot(x1 - x0, y1 - y0) >= 20:
                    ang = math.degrees(math.atan2(y1 - y0, x1 - x0)) % 90
                    long_lines.append(min(ang, 90 - ang))
    # stems and bars of "NTA" come out as long straight lines, most of them
    # exactly horizontal or vertical
    assert len(long_lines) >= 8
    assert sum(1 for a in long_lines if a < 1e-6) >= 0.5 * len(long_lines)


def test_small_jpeg_text_stays_close_to_the_clean_original():
    rgb = _red_text_logo()
    res = vectorize(_jpeg(rgb))
    ren = render_graph(res.graph)[..., :3].astype(int)
    text = (slice(95, 140), slice(15, 260))
    # letters whole, bars of E / 2 / 3 solid, no darker or pink pieces
    assert np.abs(ren[text] - rgb[text].astype(int)).mean() < 6.0


def _small_glyph_scene():
    # a 24 px tall "E" with 4.5 px strokes and 3 px slots, a small "C" made
    # of a ring with a cut, and a 5 px dot – rendered with anti-aliasing
    s = Scene(140, 60)
    red = (230, 30, 40, 255)
    e = [(10, 10), (28, 10), (28, 14.5), (14.5, 14.5), (14.5, 19.8), (26, 19.8), (26, 24.2), (14.5, 24.2),
         (14.5, 29.5), (28, 29.5), (28, 34), (10, 34)]
    s.polygon(e, red)
    s.circle(60, 22, 12, red)
    s.circle(60, 22, 7.5, (255, 255, 255, 255))
    s.rect(60, 18, 75, 26, (255, 255, 255, 255))  # the opening of the "C"
    s.circle(100, 22, 5, red)
    return s.image()


def test_small_letters_keep_square_corners():
    img = _small_glyph_scene()
    g = vectorize(_jpeg(img[..., :3].copy(), quality=85)).graph
    e_shape = None
    for sh in g.drawable_shapes():
        x0, y0, x1, y1 = (v / g.scale for v in sh.bbox)
        if x0 < 12 and x1 < 30 and y1 < 36 and (x1 - x0) > 15:
            e_shape = sh
    assert e_shape is not None
    segs = [s for iid, _ in e_shape.loops[0] for s in g.interfaces[iid].segments]
    # the E is a polygon: straight sides with corners, no rounded caps
    assert all(s.kind == "L" for s in segs)
    assert 10 <= len(segs) <= 16


def test_small_round_shapes_stay_round():
    img = _small_glyph_scene()
    g = vectorize(_jpeg(img[..., :3].copy(), quality=85)).graph
    dot = [sh for sh in g.drawable_shapes() if sh.bbox[0] / g.scale > 90 and sh.bbox[2] / g.scale < 110]
    assert dot
    for sh in dot:
        kinds = {s.kind for iid, _ in sh.loops[0] for s in g.interfaces[iid].segments}
        prim = sh.primitive.get("kind") if isinstance(sh.primitive, dict) else None
        assert prim in ("circle", "ellipse") or kinds - {"L"}, kinds  # not a polygon


def test_small_logo_text_is_traced_at_double_resolution():
    import re

    from export_engine import ExportOptions, export

    rgb = _red_text_logo()
    res = vectorize(_jpeg(rgb))
    g = res.graph
    assert g.stats["segmentation"].get("upscaled") == 2 and g.scale == 2.0
    assert tuple(g.original_size) == (420, 150)
    # exports keep the size of the uploaded image
    svg = export(g, ExportOptions(file_format="svg")).decode()
    assert re.search(r'width="420(\.0+)?(px)?"', svg) and re.search(r'height="150(\.0+)?(px)?"', svg)
    ren = render_graph(g)[..., :3].astype(int)
    assert ren.shape[:2] == (150, 420)
    text = (slice(95, 140), slice(15, 260))
    # "SINCE 2013" (strokes ~4 px) follows the clean letters closely
    assert np.abs(ren[text] - rgb[text].astype(int)).mean() < 2.7


def test_photos_are_not_upscaled():
    yy, xx = np.mgrid[0:120, 0:160]
    img = np.zeros((120, 160, 4), np.uint8)
    img[..., 0] = (40 + xx * 1.2).astype(np.uint8)
    img[..., 1] = (60 + yy * 1.1).astype(np.uint8)
    img[..., 2] = (200 - xx * 0.5 - yy * 0.4).astype(np.uint8)
    img[..., 3] = 255
    g = vectorize(png_bytes(img)).graph
    assert "upscaled" not in g.stats["segmentation"] and g.scale == 1.0
