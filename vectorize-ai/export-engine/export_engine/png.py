"""PNG export: rasterises the vector result (never the source bitmap).

Each shape is filled into a coverage mask restricted to its bounding box
(even-odd rule, 1/16 px precision, optional anti-aliasing) and composited
with Porter-Duff *over* in premultiplied space, so translucent colours and
transparency are exact. Shapes are always drawn stacked (parents first),
which avoids conflation seams between neighbours."""
from __future__ import annotations

import dataclasses
import io
import math

import cv2
import numpy as np
from PIL import Image

from geometry_engine import Affine, path_flatten

from .common import Drawing, ExportOptions, build_drawing

MAX_PIXELS = 52_000_000
SHIFT = 4


class RasterTooLarge(ValueError):
    pass


def _coverage(polys, x0: int, y0: int, bw: int, bh: int, antialias: bool) -> np.ndarray:
    """Even-odd coverage of ``polys`` inside a bbox. Anti-aliasing uses a
    supersampled box filter (exact area coverage up to the sample grid)."""
    ss = 1
    if antialias:
        area = bw * bh
        ss = 4 if area * 16 <= 48_000_000 else (2 if area * 4 <= 64_000_000 else 1)
    mask = np.zeros((bh * ss, bw * ss), dtype=np.uint8)
    pts = [(((p - [x0, y0]) * ss - 0.5) * (1 << SHIFT)).round().astype(np.int32) for p in polys]
    line = cv2.LINE_8 if (ss > 1 or not antialias) else cv2.LINE_AA
    cv2.fillPoly(mask, pts, 255, lineType=line, shift=SHIFT)
    cov = mask.astype(np.float32) / 255.0
    if ss > 1:
        cov = cv2.resize(cov, (bw, bh), interpolation=cv2.INTER_AREA)
    return cov


def _opaque(item) -> bool:
    if item.color[3] < 255:
        return False
    paint = getattr(item, "paint", None)
    return paint is None or all(c[3] >= 255 for _, c in paint.stops)


def rasterize_seamless(d: Drawing, scale: float, antialias: bool = True, tile: int = 256) -> np.ndarray:
    """Conflation-free rasterisation for opaque artwork.

    Every subsample belongs to exactly one shape (the topmost in stacking
    order) via an ID buffer; colours are averaged afterwards. Unlike
    compositing anti-aliased shapes one after another, neighbouring shapes
    cannot leave a faint seam of whatever lies beneath them."""
    w = max(1, int(round(d.width * scale)))
    h = max(1, int(round(d.height * scale)))
    if w * h > MAX_PIXELS:
        raise RasterTooLarge(f"Requested PNG of {w}x{h} exceeds {MAX_PIXELS:,} pixels.")
    ss = 4 if antialias else 1
    tol = 0.04 / max(scale, 1e-6)
    items = list(d.items)
    polys, boxes = [], []
    for it in items:
        pts = [path_flatten(lp, tol) * scale for lp in it.loops]
        pts = [p for p in pts if p.shape[0] >= 3]
        polys.append(pts)
        if pts:
            allp = np.concatenate(pts)
            boxes.append((allp[:, 0].min(), allp[:, 1].min(), allp[:, 0].max(), allp[:, 1].max()))
        else:
            boxes.append((1, 1, 0, 0))
    boxes = np.array(boxes, dtype=np.float64).reshape(-1, 4)
    flat = np.array([[c / 255.0 for c in it.color] for it in items], dtype=np.float64).reshape(-1, 4)
    paints = {i: it.paint.transformed(Affine.scale(scale)) for i, it in enumerate(items) if getattr(it, "paint", None) is not None}
    out = np.zeros((h, w, 4), dtype=np.float64)
    for ty in range(0, h, tile):
        for tx in range(0, w, tile):
            th, tw = min(tile, h - ty), min(tile, w - tx)
            hit = np.nonzero((boxes[:, 2] >= tx - 1) & (boxes[:, 0] <= tx + tw + 1) & (boxes[:, 3] >= ty - 1) & (boxes[:, 1] <= ty + th + 1))[0]
            if hit.size == 0:
                continue
            ids = np.full((th * ss, tw * ss), -1, dtype=np.int32)
            for i in hit:
                pts = [(((p - [tx, ty]) * ss - 0.5) * (1 << SHIFT)).round().astype(np.int32) for p in polys[i]]
                cv2.fillPoly(ids, pts, int(i), lineType=cv2.LINE_8, shift=SHIFT)
            col = np.zeros((th * ss, tw * ss, 4), dtype=np.float64)
            covered = ids >= 0
            col[covered] = flat[ids[covered]]
            present = np.unique(ids[covered])
            grad_ids = [int(i) for i in present if int(i) in paints]
            if grad_ids:
                ys, xs = np.nonzero(np.isin(ids, grad_ids))
                sid = ids[ys, xs]
                order = np.argsort(sid, kind="stable")
                sid_s = sid[order]
                uniq, starts = np.unique(sid_s, return_index=True)
                ends = np.append(starts[1:], sid_s.shape[0])
                for gi, s0, e0 in zip(uniq.tolist(), starts.tolist(), ends.tolist()):
                    sel = order[s0:e0]
                    px = tx + (xs[sel] + 0.5) / ss
                    py = ty + (ys[sel] + 0.5) / ss
                    col[ys[sel], xs[sel]] = paints[gi].colors_at(px, py) / 255.0
            col[..., :3] *= col[..., 3:4]  # premultiply before averaging
            out[ty : ty + th, tx : tx + tw] = col.reshape(th, ss, tw, ss, 4).mean(axis=(1, 3))
    if d.overlay:
        canvas = out.astype(np.float32)
        _composite(canvas, d.overlay, scale, antialias, w, h)
        out = canvas.astype(np.float64)
    alpha = out[..., 3:4]
    rgb = np.where(alpha > 1e-6, out[..., :3] / np.maximum(alpha, 1e-6), 0.0)
    return np.clip(np.concatenate([rgb, alpha], -1) * 255.0 + 0.5, 0, 255).astype(np.uint8)


def rasterize_drawing(d: Drawing, scale: float, antialias: bool = True, background=None) -> np.ndarray:
    if background is None and all(_opaque(it) for it in d.items):
        return rasterize_seamless(d, scale, antialias)
    return rasterize_composited(d, scale, antialias, background)


def _composite(canvas: np.ndarray, items, scale: float, antialias: bool, w: int, h: int) -> None:
    tol = 0.04 / max(scale, 1e-6)
    for item in items:
        pts_all = [path_flatten(lp, tol) * scale for lp in item.loops]
        pts_all = [p for p in pts_all if p.shape[0] >= 3]
        if not pts_all:
            continue
        allp = np.concatenate(pts_all)
        x0 = max(0, int(math.floor(allp[:, 0].min())) - 2)
        y0 = max(0, int(math.floor(allp[:, 1].min())) - 2)
        x1 = min(w, int(math.ceil(allp[:, 0].max())) + 2)
        y1 = min(h, int(math.ceil(allp[:, 1].max())) + 2)
        if x1 <= x0 or y1 <= y0:
            continue
        cov = _coverage(pts_all, x0, y0, x1 - x0, y1 - y0, antialias)
        region = canvas[y0:y1, x0:x1]
        paint = getattr(item, "paint", None)
        if paint is not None:
            p = paint.transformed(Affine.scale(scale))
            gy, gx = np.mgrid[y0:y1, x0:x1].astype(np.float64)
            colr = p.colors_at(gx + 0.5, gy + 0.5) / 255.0
            r, g, b, a = colr[..., 0], colr[..., 1], colr[..., 2], colr[..., 3]
        else:
            r, g, b, a = (c / 255.0 for c in item.color)
        src_a = cov * a
        inv = 1.0 - src_a
        region[..., 0] = r * src_a + region[..., 0] * inv
        region[..., 1] = g * src_a + region[..., 1] * inv
        region[..., 2] = b * src_a + region[..., 2] * inv
        region[..., 3] = src_a + region[..., 3] * inv


def rasterize_composited(d: Drawing, scale: float, antialias: bool = True, background=None) -> np.ndarray:
    w = max(1, int(round(d.width * scale)))
    h = max(1, int(round(d.height * scale)))
    if w * h > MAX_PIXELS:
        raise RasterTooLarge(f"Requested PNG of {w}x{h} exceeds {MAX_PIXELS:,} pixels.")
    canvas = np.zeros((h, w, 4), dtype=np.float32)  # premultiplied, 0..1
    if background is not None:
        bg = np.asarray(background, dtype=np.float32) / 255.0
        canvas[..., :3] = bg[:3] * bg[3]
        canvas[..., 3] = bg[3]
    _composite(canvas, list(d.items) + list(d.overlay), scale, antialias, w, h)
    alpha = canvas[..., 3:4]
    rgb = np.where(alpha > 1e-6, canvas[..., :3] / np.maximum(alpha, 1e-6), 0.0)
    out = np.concatenate([rgb, alpha], axis=-1)
    return np.clip(out * 255.0 + 0.5, 0, 255).astype(np.uint8)


def render_graph(graph, opts: ExportOptions | None = None, scale: float | None = None) -> np.ndarray:
    """Rasterise a graph. ``scale`` is relative to the output size."""
    opts = dataclasses.replace(opts or ExportOptions(), shape_stacking="stacked", draw_style="fill_shapes")
    d = build_drawing(graph, opts)
    s = scale if scale is not None else (opts.png_scale if opts.png_scale > 0 else 1.0)
    return rasterize_drawing(d, s, opts.png_antialias)


def write_png(graph, opts: ExportOptions) -> bytes:
    rgba = render_graph(graph, opts)
    buf = io.BytesIO()
    meta = None
    dpi = (opts.size_dpi, opts.size_dpi)
    Image.fromarray(rgba, "RGBA").save(buf, format="PNG", dpi=dpi, pnginfo=meta, compress_level=6)
    return buf.getvalue()
