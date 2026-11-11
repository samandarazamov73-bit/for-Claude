"""End-to-end vectorisation pipeline.

    decode → preprocess → segmentation → topology → sub-pixel sampling →
    curve optimisation → shape recognition → symmetry/repeats → finalise

Progress is reported per stage with real work fractions (e.g. interfaces
fitted so far). The progress callback may raise :class:`Cancelled` to abort.
Stages 1–3 are cached on disk so geometry-only option changes re-run in a
fraction of the time."""
from __future__ import annotations

import hashlib
import json
import os
import time
from dataclasses import dataclass, field
from typing import Callable

import numpy as np

from image_processing import (
    DecodedImage,
    ImageAnalysis,
    Segmentation,
    SegmentationOptions,
    decode_image,
    parse_palette,
    preprocess,
    segment,
)

from .curves import finalize_interfaces, fit_all, fit_parameters
from .graph import VectorGraph
from .ml import registry
from .options import ProcessingOptions
from .recognition import apply_repeats, apply_symmetry, recognize_shapes
from .subpixel import assign_samples, crack_samples, refine_junctions, region_pm_colors
from .topology import build_topology


class Cancelled(Exception):
    pass


ProgressFn = Callable[[str, float, str], None]

# (stage, weight) — weights reflect typical relative runtime
STAGES: list[tuple[str, float]] = [
    ("decode", 0.04),
    ("preprocess", 0.08),
    ("segmentation", 0.26),
    ("topology", 0.05),
    ("subpixel", 0.05),
    ("curves", 0.34),
    ("shapes", 0.07),
    ("symmetry", 0.07),
    ("finalize", 0.04),
]
STAGE_PHASE = {
    "decode": "preparing",
    "preprocess": "preparing",
    "segmentation": "processing",
    "topology": "processing",
    "subpixel": "processing",
    "curves": "processing",
    "shapes": "optimizing",
    "symmetry": "optimizing",
    "finalize": "optimizing",
}


class _Reporter:
    def __init__(self, cb: ProgressFn | None):
        self.cb = cb
        self.offsets = {}
        acc = 0.0
        for name, w in STAGES:
            self.offsets[name] = (acc, w)
            acc += w

    def __call__(self, stage: str, frac: float = 0.0, msg: str = ""):
        if self.cb is None:
            return
        off, w = self.offsets[stage]
        self.cb(stage, min(0.999, off + w * max(0.0, min(1.0, frac))), msg or stage)

    def sub(self, stage: str):
        return lambda frac, msg="": self(stage, frac, msg)


@dataclass
class PreparedImage:
    rgba: np.ndarray
    analysis: ImageAnalysis
    scale: float
    original_size: tuple[int, int]
    denoise_applied: str
    source_format: str


@dataclass
class PipelineResult:
    graph: VectorGraph
    prepared: PreparedImage
    timings: dict = field(default_factory=dict)


class StageCache:
    """On-disk cache for the preprocessed image and segmentation."""

    def __init__(self, directory: str):
        self.dir = directory
        os.makedirs(directory, exist_ok=True)

    def _p(self, name: str) -> str:
        return os.path.join(self.dir, name)

    def load_prepared(self, key: str) -> PreparedImage | None:
        path = self._p(f"prep_{key}.npz")
        if not os.path.exists(path):
            return None
        try:
            z = np.load(path, allow_pickle=False)
            meta = json.loads(str(z["meta"]))
            a = ImageAnalysis(**meta["analysis"])
            return PreparedImage(z["rgba"], a, meta["scale"], tuple(meta["original_size"]), meta["denoise"], meta["format"])
        except Exception:  # noqa: BLE001 - corrupt cache entries are ignored
            return None

    def save_prepared(self, key: str, p: PreparedImage) -> None:
        meta = {
            "analysis": p.analysis.__dict__,
            "scale": p.scale,
            "original_size": list(p.original_size),
            "denoise": p.denoise_applied,
            "format": p.source_format,
        }
        tmp = self._p(f"prep_{key}.tmp.npz")
        np.savez_compressed(tmp, rgba=p.rgba, meta=json.dumps(meta))
        os.replace(tmp, self._p(f"prep_{key}.npz"))

    def load_segmentation(self, key: str) -> Segmentation | None:
        path = self._p(f"seg_{key}.npz")
        if not os.path.exists(path):
            return None
        try:
            z = np.load(path, allow_pickle=False)
            return Segmentation(z["labels"], z["palette"], z["counts"], z["regions"], z["region_color"], json.loads(str(z["stats"])))
        except Exception:  # noqa: BLE001
            return None

    def save_segmentation(self, key: str, s: Segmentation) -> None:
        tmp = self._p(f"seg_{key}.tmp.npz")
        np.savez_compressed(tmp, labels=s.labels, palette=s.palette, counts=s.counts, regions=s.regions, region_color=s.region_color, stats=json.dumps(s.stats))
        os.replace(tmp, self._p(f"seg_{key}.npz"))


def _prep_key(opts: ProcessingOptions, crop) -> str:
    raw = json.dumps({"mp": opts.max_pixels, "cp": opts.color_profile, "dn": opts.denoise, "crop": crop}, sort_keys=True)
    return hashlib.sha256(raw.encode()).hexdigest()[:20]


def _seg_key(opts: ProcessingOptions, crop) -> str:
    return hashlib.sha256((opts.segmentation_key() + json.dumps(crop)).encode()).hexdigest()[:20]


def prepare(data: bytes, opts: ProcessingOptions, crop: tuple[int, int, int, int] | None = None, report: _Reporter | None = None) -> PreparedImage:
    report = report or _Reporter(None)
    report("decode", 0.1, "decoding image")
    dec: DecodedImage = decode_image(data, color_profile=opts.color_profile)
    rgba = dec.rgba
    if crop:
        x, y, w, h = crop
        x0, y0 = max(0, int(x)), max(0, int(y))
        x1, y1 = min(rgba.shape[1], int(x + w)), min(rgba.shape[0], int(y + h))
        if x1 - x0 < 2 or y1 - y0 < 2:
            raise ValueError("Crop rectangle is empty.")
        rgba = np.ascontiguousarray(rgba[y0:y1, x0:x1])
    report("decode", 1.0, "decoded")
    report("preprocess", 0.1, "analysing image")
    pp = preprocess(rgba, max_pixels=opts.max_pixels, denoise_mode=opts.denoise, source_format=dec.source_format)
    report("preprocess", 1.0, "preprocessed")
    return PreparedImage(pp.rgba, pp.analysis, pp.scale, (rgba.shape[1], rgba.shape[0]), pp.denoise_applied, dec.source_format)


def vectorize(
    data: bytes,
    opts: ProcessingOptions | None = None,
    *,
    progress: ProgressFn | None = None,
    cache: StageCache | None = None,
    crop: tuple[int, int, int, int] | None = None,
) -> PipelineResult:
    opts = opts or ProcessingOptions()
    rep = _Reporter(progress)
    timings: dict[str, float] = {}
    t0 = time.perf_counter()
    crop_l = list(crop) if crop else None

    # ---- stages 1-2 ---------------------------------------------------
    pkey = _prep_key(opts, crop_l)
    prepared = cache.load_prepared(pkey) if cache else None
    if prepared is None:
        prepared = prepare(data, opts, crop, rep)
        if cache:
            cache.save_prepared(pkey, prepared)
    else:
        rep("preprocess", 1.0, "using cached preprocessing")
    timings["prepare"] = time.perf_counter() - t0
    a = prepared.analysis

    # ---- stage 3 --------------------------------------------------------
    t = time.perf_counter()
    skey = _seg_key(opts, crop_l)
    seg = cache.load_segmentation(skey) if cache else None
    if seg is None:
        sopts = SegmentationOptions(
            max_colors=opts.max_colors,
            palette=parse_palette(opts.palette) if opts.palette else None,
            min_region_px=opts.min_area_px,
            color_threshold=opts.color_threshold,
        )
        model = registry.segmentation()
        seg = model.segment(
            prepared.rgba,
            sopts,
            noise_sigma=a.noise_sigma,
            edge_width=a.edge_width,
            compressed=a.compressed,
            progress=rep.sub("segmentation"),
        )
        if cache:
            cache.save_segmentation(skey, seg)
    else:
        rep("segmentation", 1.0, "using cached segmentation")
    timings["segmentation"] = time.perf_counter() - t

    # ---- stage 4 --------------------------------------------------------
    t = time.perf_counter()
    rep("topology", 0.1, "building vector graph")
    graph, cf = build_topology(seg.regions, seg.region_color, seg.palette, seg.counts)
    graph.scale = prepared.scale
    graph.original_size = prepared.original_size
    rep("topology", 1.0, f"{len(graph.interfaces)} interfaces")
    timings["topology"] = time.perf_counter() - t

    # ---- stage 5 --------------------------------------------------------
    t = time.perf_counter()
    reg_pm = region_pm_colors(seg.region_color, seg.palette)
    samples, soft, contrast = crack_samples(cf, prepared.rgba, seg.regions, reg_pm, enabled=opts.subpixel)
    refiner = registry.edge_refiner()
    if refiner is not None:
        samples = refiner.refine(prepared.rgba, cf, samples)
    assign_samples(graph, cf, samples, soft, contrast)
    refine_junctions(graph)
    rep("subpixel", 1.0, "sub-pixel boundaries")
    timings["subpixel"] = time.perf_counter() - t

    # ---- stage 6 --------------------------------------------------------
    t = time.perf_counter()
    params = fit_parameters(opts, a.soft_edge_ratio, a.compressed, a.edge_width)
    fit_all(graph, params, rep.sub("curves"))
    timings["curves"] = time.perf_counter() - t

    # ---- stages 7-8 -----------------------------------------------------
    t = time.perf_counter()
    n_prims = recognize_shapes(graph, opts, params.tolerance, rep.sub("shapes"))
    timings["shapes"] = time.perf_counter() - t
    t = time.perf_counter()
    n_sym = apply_symmetry(graph, opts, params.curve, params.corner, rep.sub("symmetry"))
    n_rep = apply_repeats(graph, opts, params.curve, params.corner)
    timings["symmetry"] = time.perf_counter() - t

    # ---- stage 9 --------------------------------------------------------
    t = time.perf_counter()
    rep("finalize", 0.2, "final optimisation")
    finalize_interfaces(graph, params.tolerance)
    graph.compute_bboxes()
    problems = graph.validate()
    kinds: dict[str, int] = {}
    for f in graph.interfaces.values():
        for s in f.segments:
            kinds[s.kind] = kinds.get(s.kind, 0) + 1
        f.raw = f.cracks = f.samples = f.weights = None
    timings["finalize"] = time.perf_counter() - t
    timings["total"] = time.perf_counter() - t0
    drawn = [s for s in graph.shapes.values() if not s.transparent]
    graph.stats = {
        "width": graph.width,
        "height": graph.height,
        "original_width": prepared.original_size[0],
        "original_height": prepared.original_size[1],
        "scale": round(prepared.scale, 6),
        "colors": len(graph.palette),
        "shapes": len(drawn),
        "interfaces": len(graph.interfaces),
        "nodes": len(graph.nodes),
        "segments": sum(kinds.values()),
        "segment_kinds": kinds,
        "primitives": n_prims,
        "symmetric_shapes": n_sym,
        "repeated_shapes": n_rep,
        "fit_tolerance": round(params.tolerance, 3),
        "hard_edges": params.hard_edges,
        "analysis": a.to_dict(),
        "denoise": prepared.denoise_applied,
        "segmentation": seg.stats,
        "validation_problems": problems[:20],
        "timings": {k: round(v, 3) for k, v in timings.items()},
    }
    rep("finalize", 1.0, "done")
    return PipelineResult(graph=graph, prepared=prepared, timings=timings)
