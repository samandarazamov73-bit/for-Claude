"""Fine details: sharpening halos, thin lines, small highlights on shading,
and profile fitting of vignette-like gradients."""
import cv2
import numpy as np

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
