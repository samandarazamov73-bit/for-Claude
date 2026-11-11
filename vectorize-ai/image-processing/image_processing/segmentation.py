"""Stage 3 — colour segmentation.

Algorithm (classical, anti-aliasing aware):

1. *Flat pixels* (low local gradient) are the only reliable samples of the
   colours the artist actually used. They are histogrammed and clustered in
   CIELAB+alpha with a noise adaptive threshold (leader clustering, weighted
   k-means refinement, close-pair merging, Ward reduction to ``max_colors``).
2. *Edge pixels* are modelled as a linear mixture of two nearby palette
   colours (anti-aliasing / blur): ``c = a*ci + (1-a)*cj`` in premultiplied
   sRGBA. The pixel joins ``ci`` when ``a >= 0.5`` — i.e. the boundary is the
   50 % coverage iso-line, which keeps edges in place and prevents slivers of
   intermediate colours.
3. Pixels that no palette pair can explain (thin lines, tiny details with no
   flat interior) are clustered in a second pass and added to the palette.
4. Speckles smaller than ``min_region_px`` are absorbed by their neighbours
   and the result is split into 4-connected regions.

The ``SegmentationModel`` protocol in ``vectorization_engine.ml`` allows a
neural model to replace this module without touching later stages.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

import cv2
import numpy as np
from scipy import ndimage, sparse
from scipy.sparse import csgraph

from .color import ALPHA_WEIGHT, MAX_ARGB_DISTANCE, PaletteEntry, rgba_features

TRANSPARENT = -1
_ALPHA_MIN = 8  # alpha below this is treated as fully transparent


@dataclass
class SegmentationOptions:
    max_colors: int = 0  # 0 = automatic
    palette: list[PaletteEntry] | None = None
    min_region_px: float = 0.0  # 0 = automatic
    color_threshold: float = 0.0  # dE76; 0 = automatic


@dataclass
class Segmentation:
    labels: np.ndarray  # (H, W) int32 palette index, -1 = transparent
    palette: np.ndarray  # (K, 4) uint8 straight RGBA
    counts: np.ndarray  # (K,) pixel count per palette entry
    regions: np.ndarray  # (H, W) int32 region id, 1..R
    region_color: np.ndarray  # (R + 1,) palette index per region (-1 transparent)
    stats: dict = field(default_factory=dict)
    fills: dict = field(default_factory=dict)  # region id -> gradient paint JSON

    @property
    def region_count(self) -> int:
        return int(self.region_color.shape[0] - 1)


class _Progress:
    def __init__(self, cb):
        self.cb = cb

    def __call__(self, frac: float, msg: str = ""):
        if self.cb:
            self.cb(float(frac), msg)


# --------------------------------------------------------------------------
# palette estimation
# --------------------------------------------------------------------------

def _bin_colors(rgba: np.ndarray, feats: np.ndarray):
    """Histogram colours into 5-bit RGB + 3-bit alpha bins."""
    r = rgba[:, 0].astype(np.int64) >> 3
    g = rgba[:, 1].astype(np.int64) >> 3
    b = rgba[:, 2].astype(np.int64) >> 3
    a = rgba[:, 3].astype(np.int64) >> 5
    key = (((r << 5) | g) << 5 | b) << 3 | a
    uniq, inv, counts = np.unique(key, return_inverse=True, return_counts=True)
    nb = uniq.shape[0]
    fsum = np.stack([np.bincount(inv, weights=feats[:, c], minlength=nb) for c in range(feats.shape[1])], 1)
    csum = np.stack([np.bincount(inv, weights=rgba[:, c].astype(np.float64), minlength=nb) for c in range(4)], 1)
    w = counts.astype(np.float64)
    return fsum / w[:, None], csum / w[:, None], w


def _leader_cluster(feats: np.ndarray, weights: np.ndarray, thr: float, max_centers: int = 1024) -> np.ndarray:
    order = np.argsort(-weights, kind="stable")
    centers = np.zeros((max_centers, feats.shape[1]), dtype=np.float64)
    n = 0
    thr2 = thr * thr
    for i in order:
        f = feats[i]
        if n:
            d = ((centers[:n] - f) ** 2).sum(1)
            if d.min() < thr2:
                continue
        if n >= max_centers:
            break
        centers[n] = f
        n += 1
    return centers[:n].copy()


def _assign(feats: np.ndarray, centers: np.ndarray, chunk: int = 200_000) -> tuple[np.ndarray, np.ndarray]:
    out = np.empty(feats.shape[0], dtype=np.int64)
    dist = np.empty(feats.shape[0], dtype=np.float64)
    c2 = (centers ** 2).sum(1)
    for s in range(0, feats.shape[0], chunk):
        f = feats[s : s + chunk]
        d = (f ** 2).sum(1)[:, None] - 2.0 * f @ centers.T + c2[None, :]
        j = d.argmin(1)
        out[s : s + chunk] = j
        dist[s : s + chunk] = np.sqrt(np.maximum(d[np.arange(d.shape[0]), j], 0.0))
    return out, dist


def _weighted_kmeans(feats, colors, weights, centers, iters: int = 6):
    for _ in range(iters):
        a, _ = _assign(feats, centers)
        k = centers.shape[0]
        w = np.bincount(a, weights=weights, minlength=k)
        keep = w > 0
        new = np.stack([np.bincount(a, weights=weights * feats[:, c], minlength=k) for c in range(feats.shape[1])], 1)
        new[keep] /= w[keep, None]
        centers = new[keep]
        if centers.shape[0] == 0:
            break
    a, _ = _assign(feats, centers)
    k = centers.shape[0]
    w = np.bincount(a, weights=weights, minlength=k)
    cols = np.stack([np.bincount(a, weights=weights * colors[:, c], minlength=k) for c in range(4)], 1)
    cols /= np.maximum(w, 1e-9)[:, None]
    return centers, cols, w


def _merge_close(centers, colors, weights, thr):
    centers, colors, weights = centers.copy(), colors.copy(), weights.copy()
    while centers.shape[0] > 1:
        d = np.sqrt(((centers[:, None, :] - centers[None, :, :]) ** 2).sum(-1))
        np.fill_diagonal(d, np.inf)
        i, j = np.unravel_index(np.argmin(d), d.shape)
        if d[i, j] >= thr:
            break
        wi, wj = weights[i], weights[j]
        tot = wi + wj
        centers[i] = (centers[i] * wi + centers[j] * wj) / tot
        colors[i] = (colors[i] * wi + colors[j] * wj) / tot
        weights[i] = tot
        centers = np.delete(centers, j, 0)
        colors = np.delete(colors, j, 0)
        weights = np.delete(weights, j, 0)
    return centers, colors, weights


def _ward_reduce(centers, colors, weights, k_max):
    centers, colors, weights = centers.copy(), colors.copy(), weights.copy()
    while centers.shape[0] > k_max:
        d2 = ((centers[:, None, :] - centers[None, :, :]) ** 2).sum(-1)
        w = weights[:, None] * weights[None, :] / (weights[:, None] + weights[None, :])
        cost = w * d2
        np.fill_diagonal(cost, np.inf)
        i, j = np.unravel_index(np.argmin(cost), cost.shape)
        tot = weights[i] + weights[j]
        centers[i] = (centers[i] * weights[i] + centers[j] * weights[j]) / tot
        colors[i] = (colors[i] * weights[i] + colors[j] * weights[j]) / tot
        weights[i] = tot
        centers = np.delete(centers, j, 0)
        colors = np.delete(colors, j, 0)
        weights = np.delete(weights, j, 0)
    return centers, colors, weights


def _cluster(pix_rgba: np.ndarray, pix_feats: np.ndarray, thr: float, min_support: float):
    bf, bc, bw = _bin_colors(pix_rgba, pix_feats)
    centers = _leader_cluster(bf, bw, thr)
    if centers.shape[0] == 0:
        return np.zeros((0, 4)), np.zeros((0, 4)), np.zeros(0)
    centers, colors, weights = _weighted_kmeans(bf, bc, bw, centers)
    centers, colors, weights = _merge_close(centers, colors, weights, thr * 0.85)
    keep = weights >= min_support
    if not keep.any():
        keep[np.argmax(weights)] = True
    return centers[keep], colors[keep], weights[keep]


# --------------------------------------------------------------------------
# pixel assignment
# --------------------------------------------------------------------------

def _gradient(pm: np.ndarray) -> np.ndarray:
    mag = np.zeros(pm.shape[:2], dtype=np.float32)
    for c in range(pm.shape[2]):
        ch = np.ascontiguousarray(pm[..., c])
        gx = cv2.Sobel(ch, cv2.CV_32F, 1, 0, ksize=3) / 8.0
        gy = cv2.Sobel(ch, cv2.CV_32F, 0, 1, ksize=3) / 8.0
        np.maximum(mag, np.sqrt(gx * gx + gy * gy), out=mag)
    return mag


def _mixture_assign(
    pm_pix: np.ndarray,  # (M, 4) premultiplied colours of the pixels to label
    cand: np.ndarray,  # (M, C) candidate palette indices (may repeat)
    pal_pm: np.ndarray,  # (K, 4) premultiplied palette (incl. transparent entry)
    pair_penalty: float,
    chunk: int = 60_000,
) -> tuple[np.ndarray, np.ndarray]:
    m, c = cand.shape
    labels = np.empty(m, dtype=np.int64)
    resid = np.empty(m, dtype=np.float64)
    pairs = [(i, j) for i in range(c) for j in range(i + 1, c)]
    for s in range(0, m, chunk):
        x = pm_pix[s : s + chunk].astype(np.float64)
        cc = cand[s : s + chunk]
        n = x.shape[0]
        best_r = np.full(n, np.inf)
        best_l = cc[:, 0].copy()
        cols = pal_pm[cc]  # (n, C, 4)
        for k in range(c):  # single colour hypotheses
            r = np.sqrt(((x - cols[:, k]) ** 2).sum(1))
            better = r < best_r
            best_r[better] = r[better]
            best_l[better] = cc[better, k]
        for i, j in pairs:  # two-colour mixtures
            ci, cj = cols[:, i], cols[:, j]
            d = ci - cj
            dd = (d * d).sum(1)
            valid = dd > 1.0
            a = np.where(valid, ((x - cj) * d).sum(1) / np.maximum(dd, 1e-9), 1.0)
            a = np.clip(a, 0.0, 1.0)
            r = np.sqrt(((x - cj - a[:, None] * d) ** 2).sum(1)) + pair_penalty
            better = valid & (r < best_r)
            best_r[better] = r[better]
            best_l[better] = np.where(a[better] >= 0.5, cc[better, i], cc[better, j])
        labels[s : s + n] = best_l
        resid[s : s + n] = best_r
    return labels, resid


def label_regions(labels: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """4-connected components over a multi-label map (single sparse pass)."""
    h, w = labels.shape
    n = h * w
    idx = np.arange(n, dtype=np.int64).reshape(h, w)
    same_h = labels[:, :-1] == labels[:, 1:]
    same_v = labels[:-1, :] == labels[1:, :]
    rows = np.concatenate([idx[:, :-1][same_h], idx[:-1, :][same_v]])
    cols = np.concatenate([idx[:, 1:][same_h], idx[1:, :][same_v]])
    graph = sparse.coo_matrix((np.ones(rows.shape[0], dtype=np.int8), (rows, cols)), shape=(n, n)).tocsr()
    count, comp = csgraph.connected_components(graph, directed=False)
    regions = (comp.reshape(h, w) + 1).astype(np.int32)
    region_color = np.full(count + 1, -2, dtype=np.int32)
    region_color[regions.ravel()] = labels.ravel()
    return regions, region_color


def _remove_speckles(labels: np.ndarray, min_area: float) -> tuple[np.ndarray, int]:
    if min_area <= 1:
        return labels, 0
    regions, region_color = label_regions(labels)
    area = np.bincount(regions.ravel())
    small = area < min_area
    small[0] = False
    if not small.any():
        return labels, 0
    mask = small[regions]
    if mask.all():
        return labels, 0
    _, (iy, ix) = ndimage.distance_transform_edt(mask, return_indices=True)
    out = labels.copy()
    out[mask] = labels[iy[mask], ix[mask]]
    return out, int(small.sum())


def _absorb_thin_regions(labels: np.ndarray, label_feats: np.ndarray, de_limit: float, max_width: float) -> tuple[np.ndarray, int]:
    """Merge thin regions (mean width < ``max_width``) into the neighbour with
    the longest shared border whose colour is within ``de_limit``. Removes
    chroma bleeding / halo bands that compression and resampling leave along
    edges, while genuine thin details (which contrast with their neighbours)
    are kept."""
    regions, region_color = label_regions(labels)
    nreg = region_color.shape[0]
    area = np.bincount(regions.ravel(), minlength=nreg).astype(np.float64)
    a = np.concatenate([regions[:, :-1].ravel(), regions[:-1, :].ravel()])
    b = np.concatenate([regions[:, 1:].ravel(), regions[1:, :].ravel()])
    m = a != b
    a, b = a[m].astype(np.int64), b[m].astype(np.int64)
    border = np.concatenate([regions[0], regions[-1], regions[:, 0], regions[:, -1]])
    perim = np.bincount(a, minlength=nreg) + np.bincount(b, minlength=nreg) + np.bincount(border, minlength=nreg)
    width = 2.0 * area / np.maximum(perim, 1)
    thin = (width < max_width) & (region_color >= 0)
    thin[0] = False
    if not thin.any() or a.size == 0:
        return labels, 0
    lo, hi = np.minimum(a, b), np.maximum(a, b)
    keys, cnt = np.unique(lo * nreg + hi, return_counts=True)
    p, q = keys // nreg, keys % nreg
    src = np.concatenate([p, q])
    dst = np.concatenate([q, p])
    ln = np.concatenate([cnt, cnt])
    sel = thin[src] & (region_color[dst] >= 0) & (area[dst] > area[src])
    src, dst, ln = src[sel], dst[sel], ln[sel]
    if src.size == 0:
        return labels, 0
    de = np.sqrt(((label_feats[region_color[src]] - label_feats[region_color[dst]]) ** 2).sum(1))
    ok = de < de_limit
    src, dst, ln = src[ok], dst[ok], ln[ok]
    if src.size == 0:
        return labels, 0
    order = np.lexsort((-ln, src))
    s_sorted, d_sorted = src[order], dst[order]
    first = np.ones(order.shape[0], dtype=bool)
    first[1:] = s_sorted[1:] != s_sorted[:-1]
    lut = region_color.astype(np.int64).copy()
    lut[s_sorted[first]] = region_color[d_sorted[first]]
    return lut[regions], int(first.sum())


def _candidates(filled: np.ndarray, ys: np.ndarray, xs: np.ndarray, near: np.ndarray, offset: int) -> np.ndarray:
    """Up to four distinct nearby palette labels per pixel plus the globally
    nearest colour. Nearby labels come from the nearest-flat-pixel map sampled
    on a small star pattern, so both sides of an edge are represented."""
    h, w = filled.shape
    offs = [(0, 0)]
    for o in (offset, 2 * offset):
        offs += [(0, o), (0, -o), (o, 0), (-o, 0)]
    offs += [(offset, offset), (offset, -offset), (-offset, offset), (-offset, -offset)]
    cand = np.stack([filled[np.clip(ys + dy, 0, h - 1), np.clip(xs + dx, 0, w - 1)] for dy, dx in offs], 1)
    big = np.iinfo(np.int64).max
    c = np.sort(cand, axis=1)
    dup = np.zeros(c.shape, dtype=bool)
    dup[:, 1:] = c[:, 1:] == c[:, :-1]
    c = np.sort(np.where(dup, big, c), axis=1)[:, :4]
    c = np.where(c == big, c[:, :1], c)
    return np.concatenate([c, near[:, None]], axis=1)


def segment(rgba: np.ndarray, opts: SegmentationOptions, *, noise_sigma: float = 0.0, edge_width: float = 1.0, compressed: bool = False, progress=None) -> Segmentation:
    prog = _Progress(progress)
    h, w = rgba.shape[:2]
    npx = h * w
    alpha = rgba[..., 3]
    transparent = alpha < _ALPHA_MIN

    f = rgba.astype(np.float32)
    pm = f.copy()
    pm[..., :3] *= f[..., 3:4] / 255.0
    feats = rgba_features(rgba)
    prog(0.05, "analysing colours")

    # ---- flat pixels ----------------------------------------------------
    grad = _gradient(pm)
    t_flat = max(8.0 if compressed else 5.0, 2.5 * noise_sigma)
    flat = (grad < t_flat) & ~transparent
    if flat.sum() < max(16, npx * 0.002):  # almost no flat area: fall back
        flat = (grad <= np.percentile(grad[~transparent], 30) if (~transparent).any() else flat) & ~transparent

    lab_noise = noise_sigma * 0.4
    auto_thr = float(np.clip(5.5 + 2.5 * lab_noise, 5.5, 16.0))
    if compressed:
        auto_thr = max(auto_thr, 12.0)
    thr = opts.color_threshold if opts.color_threshold > 0 else auto_thr
    min_support = max(3.0, npx * 4e-6)

    flat_rgba = rgba[flat]
    flat_feats = feats[flat]
    if flat_rgba.shape[0]:
        centers, colors, weights = _cluster(flat_rgba, flat_feats, thr, min_support)
    else:
        centers, colors, weights = np.zeros((0, 4)), np.zeros((0, 4)), np.zeros(0)
    prog(0.35, "clustering palette")

    # Flat pixels are labelled from features smoothed by normalised
    # convolution restricted to flat areas: noise no longer makes the iso-
    # lines between neighbouring gradient bands ragged, and edges are not
    # blurred because edge pixels carry zero weight.
    fm = flat.astype(np.float32)
    sig = (3.2 if compressed else 1.2) + 0.25 * min(noise_sigma, 8.0)
    den = cv2.GaussianBlur(fm, (0, 0), sig)
    sm = np.empty_like(feats)
    for ch in range(feats.shape[2]):
        sm[..., ch] = cv2.GaussianBlur(np.ascontiguousarray(feats[..., ch]) * fm, (0, 0), sig)
    sm /= np.maximum(den, 1e-6)[..., None]
    flat_feats_smooth = sm[flat].astype(np.float64)
    del sm, den

    min_region = opts.min_region_px if opts.min_region_px > 0 else float(np.clip(2.0 + 0.8 * noise_sigma, 2.0, 12.0))
    if compressed and opts.min_region_px <= 0:
        min_region = max(min_region, 5.0)
    opaque = ~transparent
    added = 0
    labels = np.full((h, w), TRANSPARENT, dtype=np.int64)
    offset = int(np.clip(round(edge_width / 2.0 + 1.0), 2, 4))

    for pass_no in range(2):
        if opts.max_colors and centers.shape[0] > opts.max_colors:
            centers, colors, weights = _ward_reduce(centers, colors, weights, opts.max_colors)
        k = centers.shape[0]
        if k == 0:
            if opaque.any():
                centers = feats[opaque].mean(0, keepdims=True).astype(np.float64)
                colors = rgba[opaque].mean(0, keepdims=True).astype(np.float64)
                weights = np.array([float(opaque.sum())])
                k = 1
            else:
                break
        tidx = k  # index of the transparent pseudo colour
        pal_pm = np.zeros((k + 1, 4), dtype=np.float64)
        pal_pm[:k, :3] = colors[:, :3] * (colors[:, 3:4] / 255.0)
        pal_pm[:k, 3] = colors[:, 3]

        labels = np.full((h, w), tidx, dtype=np.int64)
        flat_lab, _ = _assign(flat_feats_smooth, centers)
        labels[flat] = flat_lab
        seeds = flat | transparent
        nonseed = ~seeds
        if nonseed.any():
            if seeds.any():
                _, (iy, ix) = ndimage.distance_transform_edt(nonseed, return_indices=True)
                filled = labels[iy, ix]
            else:
                filled = labels
            ys, xs = np.nonzero(nonseed)
            near, _ = _assign(feats[ys, xs].astype(np.float64), centers)
            cand = _candidates(filled, ys, xs, near, offset)
            lab, resid = _mixture_assign(pm[ys, xs], cand, pal_pm, pair_penalty=2.0 + 0.5 * noise_sigma)
            labels[ys, xs] = lab
        else:
            ys = xs = np.zeros(0, dtype=np.int64)
            resid = np.zeros(0)
        prog(0.55 + 0.2 * pass_no, "assigning edge pixels")

        if pass_no == 1 or ys.shape[0] == 0:
            break
        # ---- second pass: colours no palette mixture can explain --------
        t_res = max(40.0 + 4.0 * noise_sigma, 6.0 * float(np.median(resid)))
        if compressed:
            t_res = max(t_res, 70.0)
        bad = resid > t_res
        if bad.sum() < max(3.0, min_region):
            break
        # Keep only spatially coherent unexplained pixels (details, thin
        # lines) - scattered compression/ringing artefacts are ignored.
        bad_mask = np.zeros((h, w), dtype=np.uint8)
        bad_mask[ys[bad], xs[bad]] = 1
        ncc, cc, cstats, _ = cv2.connectedComponentsWithStats(bad_mask, connectivity=8)
        big_cc = cstats[:, cv2.CC_STAT_AREA] >= max(4.0, 1.5 * min_region)
        big_cc[0] = False
        coherent = big_cc[cc[ys[bad], xs[bad]]]
        if coherent.sum() < max(3.0, min_region):
            break
        bys, bxs = ys[bad][coherent], xs[bad][coherent]
        b_rgba = rgba[bys, bxs]
        b_feats = feats[bys, bxs]
        nc, ncol, nw = _cluster(b_rgba, b_feats, thr, max(3.0, min_region))
        if nc.shape[0] == 0:
            break
        dmin = np.sqrt(((nc[:, None, :] - centers[None, :, :]) ** 2).sum(-1)).min(1)
        novel = dmin > thr
        if not novel.any():
            break
        added = int(novel.sum())
        centers = np.concatenate([centers, nc[novel]])
        colors = np.concatenate([colors, ncol[novel]])
        weights = np.concatenate([weights, nw[novel]])

    k = centers.shape[0]
    labels[labels == k] = TRANSPARENT

    # ---- custom palette snapping ----------------------------------------
    out_colors = np.clip(colors + 0.5, 0, 255).astype(np.int64) if k else np.zeros((0, 4), np.int64)
    if opts.palette and k:
        entries = opts.palette
        match = np.array([e.match for e in entries], dtype=np.float64)
        d = np.sqrt(((colors[:, None, :] - match[None, :, :]) ** 2).sum(-1))
        nearest = d.argmin(1)
        remap = np.arange(k)
        target_for_entry: dict[int, int] = {}
        for ci in range(k):
            e = int(nearest[ci])
            tol = entries[e].tolerance
            if tol is not None and d[ci, e] > tol * MAX_ARGB_DISTANCE:
                continue
            out_colors[ci] = entries[e].output
            if e in target_for_entry:
                remap[ci] = target_for_entry[e]
            else:
                target_for_entry[e] = ci
        lut = np.append(remap, TRANSPARENT)
        labels = np.where(labels >= 0, lut[np.maximum(labels, 0)], TRANSPARENT)

    labels, speckles = _remove_speckles(labels, min_region)
    thin_absorbed = 0
    if k:
        de_limit = 24.0 if compressed else 9.0
        for _ in range(2):
            labels, n_abs = _absorb_thin_regions(labels, centers, de_limit, 3.0 if compressed else 2.2)
            thin_absorbed += n_abs
            if not n_abs:
                break
        if thin_absorbed:
            labels, sp2 = _remove_speckles(labels, min_region)
            speckles += sp2
    prog(0.85, "removing speckles")

    # ---- compact palette ------------------------------------------------
    used = np.unique(labels[labels >= 0])
    lut = np.full(max(k, 1) + 1, TRANSPARENT, dtype=np.int64)
    lut[used] = np.arange(used.shape[0])
    labels = np.where(labels >= 0, lut[np.maximum(labels, 0)], TRANSPARENT).astype(np.int32)
    palette = out_colors[used].astype(np.uint8) if used.shape[0] else np.zeros((0, 4), np.uint8)
    counts = np.bincount(labels[labels >= 0].ravel(), minlength=palette.shape[0]).astype(np.int64)

    # Merge palette entries that became identical (e.g. palette remapping).
    if palette.shape[0] > 1:
        keys = [tuple(int(v) for v in c) for c in palette]
        first: dict[tuple, int] = {}
        remap = np.arange(palette.shape[0])
        for i, key in enumerate(keys):
            remap[i] = first.setdefault(key, i)
        if (remap != np.arange(palette.shape[0])).any():
            labels = np.where(labels >= 0, remap[np.maximum(labels, 0)], TRANSPARENT).astype(np.int32)
            used = np.unique(labels[labels >= 0])
            lut = np.full(palette.shape[0] + 1, TRANSPARENT, dtype=np.int64)
            lut[used] = np.arange(used.shape[0])
            labels = np.where(labels >= 0, lut[np.maximum(labels, 0)], TRANSPARENT).astype(np.int32)
            palette = palette[used]
            counts = np.bincount(labels[labels >= 0].ravel(), minlength=palette.shape[0]).astype(np.int64)

    regions, region_color = label_regions(labels)
    prog(1.0, "segmentation complete")
    stats = {
        "colors": int(palette.shape[0]),
        "regions": int(region_color.shape[0] - 1),
        "flat_ratio": round(float(flat.mean()), 4),
        "color_threshold": round(float(thr), 3),
        "min_region_px": round(float(min_region), 3),
        "speckles_removed": int(speckles),
        "thin_regions_absorbed": int(thin_absorbed),
        "colors_added_second_pass": int(added),
        "compressed_source": bool(compressed),
    }
    return Segmentation(labels=labels, palette=palette, counts=counts, regions=regions, region_color=region_color, stats=stats)
