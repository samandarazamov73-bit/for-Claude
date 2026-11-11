import numpy as np

from image_processing import SegmentationOptions, parse_palette, preprocess, segment
from synthetic import Scene, jpeg_roundtrip, logo_scene, transparent_scene


def _seg(img, **kw):
    pp = preprocess(img)
    a = pp.analysis
    return segment(pp.rgba, SegmentationOptions(**kw), noise_sigma=a.noise_sigma, edge_width=a.edge_width, compressed=a.compressed)


def test_clean_logo_exact_palette_and_regions():
    seg = _seg(logo_scene())
    assert seg.palette.shape[0] == 4
    assert seg.region_count == 5
    expected = {(28, 63, 140), (250, 250, 248), (255, 196, 0), (230, 57, 70)}
    got = {tuple(int(v) for v in c[:3]) for c in seg.palette}
    for e in expected:
        assert min(np.abs(np.array(e) - np.array(g)).max() for g in got) <= 3


def test_anti_aliased_edges_create_no_slivers():
    seg = _seg(logo_scene())
    # every region is large: no thin intermediate-colour bands along edges
    area = np.bincount(seg.regions.ravel())[1:]
    assert area.min() > 1000


def test_jpeg_artefacts_are_absorbed():
    seg = _seg(jpeg_roundtrip(logo_scene(), 70))
    assert seg.palette.shape[0] == 4
    assert seg.region_count == 5


def test_max_colors_limit():
    s = Scene(120, 40)
    for i in range(6):
        s.rect(i * 20, 0, i * 20 + 20, 40, (40 * i, 255 - 40 * i, 100, 255))
    seg = _seg(s.image(), max_colors=3)
    assert seg.palette.shape[0] <= 3


def test_custom_palette_remap():
    seg = _seg(logo_scene(), palette=parse_palette("#1c3f8c -> #000000; #ffc400 -> #ff0000 ~ 0.1"))
    cols = {tuple(int(v) for v in c[:3]) for c in seg.palette}
    assert (0, 0, 0) in cols and (255, 0, 0) in cols


def test_palette_parser():
    entries = parse_palette("#fff; #00ff0080 -> #000 ~ 0.25")
    assert entries[0].match == (255, 255, 255, 255)
    assert entries[1].match == (0, 255, 0, 128) and entries[1].output == (0, 0, 0, 255)
    assert entries[1].tolerance == 0.25


def test_transparency_is_its_own_class():
    seg = _seg(transparent_scene())
    assert (seg.labels == -1).any()
    assert seg.palette.shape[0] == 2
    assert (seg.palette[:, 3] == 255).all()
