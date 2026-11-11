"""Background detection on a finished Vector Graph.

* ``color``   – the colour owning most of the image border is the
  background; every border-connected shape of that colour (optionally also
  enclosed shapes of the same colour, e.g. letter counters) is selected.
* ``grabcut`` – foreground/background segmentation of the source image
  (OpenCV GrabCut, initialised with the image border as background); a
  shape is background when most of its pixels are classified as such.
* ``neural``  – salient-object segmentation with a neural network
  (rembg / ISNet, MIT licensed, ONNX on CPU). Optional dependency: installed
  with ``pip install -e ".[ai]"``; the model is downloaded on first use.
* ``auto``    – ``color`` when one colour clearly dominates the border,
  otherwise ``grabcut``.
"""
from __future__ import annotations

import os
import threading

import cv2
import numpy as np

from geometry_engine import path_flatten, signed_area
from image_processing.color import srgb_to_lab

from .graph import VectorGraph


def _border_share(g: VectorGraph) -> dict[int, float]:
    per_color: dict[int, float] = {}
    for f in g.interfaces.values():
        if not f.border:
            continue
        sid = f.left if f.left >= 0 else f.right
        s = g.shapes.get(sid)
        if s is None:
            continue
        ln = sum(seg.length() for seg in f.segments)
        key = -1 if s.transparent else s.color
        per_color[key] = per_color.get(key, 0.0) + ln
    total = sum(per_color.values()) or 1.0
    return {k: v / total for k, v in per_color.items()}


def by_color(g: VectorGraph, include_enclosed: bool = False, tolerance: float = 6.0) -> tuple[list[int], float]:
    share = _border_share(g)
    if not share:
        return [], 0.0
    col, frac = max(share.items(), key=lambda kv: kv[1])
    if col < 0:
        return [], frac  # border is already transparent
    pal = np.array([c[:3] for c in g.palette], dtype=np.uint8)
    lab = srgb_to_lab(pal)
    close = {i for i in range(len(g.palette)) if np.linalg.norm(lab[i] - lab[col]) <= tolerance}
    border_shapes = set()
    for f in g.interfaces.values():
        if f.border:
            border_shapes.add(f.left if f.left >= 0 else f.right)
    picked = []
    for s in g.shapes.values():
        if s.transparent or s.color not in close:
            continue
        if s.id in border_shapes or include_enclosed:
            picked.append(s.id)
    return picked, frac


def shape_label_raster(g: VectorGraph) -> np.ndarray:
    """Rasterise shapes (stacked, non anti-aliased) into an id map."""
    lab = np.full((g.height, g.width), -1, dtype=np.int32)
    for s in g.drawable_shapes():
        loops = [path_flatten(g.loop_segments(lp), 0.3) for lp in g.shape_loops(s, True)]
        pts = [((p - 0.5) * 16).round().astype(np.int32) for p in loops if p.shape[0] >= 3]
        if pts:
            cv2.fillPoly(lab, pts, int(s.id), lineType=cv2.LINE_8, shift=4)
    return lab


def by_grabcut(g: VectorGraph, rgba: np.ndarray, iterations: int = 5) -> list[int]:
    h, w = rgba.shape[:2]
    scale = min(1.0, 640.0 / max(h, w))
    small = cv2.resize(rgba[..., :3], (max(8, int(w * scale)), max(8, int(h * scale))), interpolation=cv2.INTER_AREA)
    sh, sw = small.shape[:2]
    mx, my = max(1, int(sw * 0.02)), max(1, int(sh * 0.02))
    mask = np.zeros((sh, sw), np.uint8)
    bgd, fgd = np.zeros((1, 65), np.float64), np.zeros((1, 65), np.float64)
    bgr = cv2.cvtColor(np.ascontiguousarray(small), cv2.COLOR_RGB2BGR)
    try:
        cv2.grabCut(bgr, mask, (mx, my, sw - 2 * mx, sh - 2 * my), bgd, fgd, iterations, cv2.GC_INIT_WITH_RECT)
    except cv2.error:
        return []
    fg_small = ((mask == cv2.GC_FGD) | (mask == cv2.GC_PR_FGD)).astype(np.uint8)
    fg = cv2.resize(fg_small, (w, h), interpolation=cv2.INTER_NEAREST).astype(bool)
    fg &= rgba[..., 3] >= 128
    if g.width != w or g.height != h:
        fg = cv2.resize(fg.astype(np.uint8), (g.width, g.height), interpolation=cv2.INTER_NEAREST).astype(bool)
    return _vote(g, fg)


def _vote(g: VectorGraph, fg: np.ndarray) -> list[int]:
    """Shapes whose pixels are mostly background according to ``fg``."""
    lab = shape_label_raster(g)
    valid = lab >= 0
    n = max(g.shapes) + 1 if g.shapes else 0
    tot = np.bincount(lab[valid], minlength=n)
    fgc = np.bincount(lab[valid & fg], minlength=n)
    picked = []
    for s in g.drawable_shapes():
        if tot[s.id] == 0:
            continue
        if fgc[s.id] / tot[s.id] < 0.5:
            picked.append(s.id)
    return picked


_SESSIONS: dict = {}
_SESSION_LOCK = threading.Lock()


def neural_available() -> bool:
    try:
        import rembg  # noqa: F401
    except Exception:  # noqa: BLE001 - optional dependency
        return False
    return True


def by_neural(g: VectorGraph, rgba: np.ndarray, model: str | None = None) -> list[int]:
    from PIL import Image
    from rembg import new_session, remove

    name = model or os.environ.get("VZ_REMBG_MODEL", "isnet-general-use")
    with _SESSION_LOCK:
        sess = _SESSIONS.get(name)
        if sess is None:
            sess = _SESSIONS[name] = new_session(name)
    mask = np.asarray(remove(Image.fromarray(np.ascontiguousarray(rgba[..., :3])), session=sess, only_mask=True))
    if mask.ndim == 3:
        mask = mask[..., 0]
    fg = (mask >= 128) & (rgba[..., 3] >= 128)
    if fg.shape != (g.height, g.width):
        fg = cv2.resize(fg.astype(np.uint8), (g.width, g.height), interpolation=cv2.INTER_NEAREST).astype(bool)
    return _vote(g, fg)


def detect_background(g: VectorGraph, rgba: np.ndarray | None = None, method: str = "auto", include_enclosed: bool = False) -> dict:
    if method not in ("auto", "color", "grabcut", "neural"):
        raise ValueError("method must be auto, color, grabcut or neural")
    if method == "neural":
        if rgba is None:
            raise ValueError("neural background removal needs the source image")
        if not neural_available():
            raise ValueError("Neural background removal is not installed on this server (pip install -e '.[ai]').")
        return {"method": "neural", "shapes": by_neural(g, rgba), "border_share": None}
    used = method
    if method in ("auto", "color"):
        ids, frac = by_color(g, include_enclosed)
        if method == "color" or frac >= 0.6 or rgba is None:
            return {"method": "color", "shapes": ids, "border_share": round(frac, 3)}
    if rgba is None:
        raise ValueError("grabcut needs the source image")
    ids = by_grabcut(g, rgba)
    used = "grabcut"
    return {"method": used, "shapes": ids, "border_share": None}


def coverage(g: VectorGraph) -> float:
    """Fraction of the image area covered by drawn shapes (diagnostics)."""
    total = 0.0
    for s in g.drawable_shapes():
        a = abs(signed_area(path_flatten(g.loop_segments(s.loops[0]), 0.3)))
        for lp in s.loops[1:]:
            a -= abs(signed_area(path_flatten(g.loop_segments(lp), 0.3)))
        total += a
    return total / max(1.0, g.width * g.height)


__all__ = ["detect_background", "by_color", "by_grabcut", "by_neural", "neural_available", "shape_label_raster", "coverage"]
