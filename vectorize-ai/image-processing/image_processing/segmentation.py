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
    thin_lines: bool = True  # continue thin lines into partially covered pixels


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


def _absorb_edge_bands(labels: np.ndarray, label_feats: np.ndarray, label_rgb: np.ndarray, max_width: float, ratio: float = 0.32, de_max: float = 26.0, aa_width: float = 1.6, de_enclosed: float = 12.0) -> tuple[np.ndarray, int]:
    """Merge edge bands into the shapes they belong to.

    *Anti-aliasing strips*: a strip about one pixel wide between regions A
    and B whose colour is a mixture of A and B is the partially covered
    pixel row of the A–B edge (its colour merely happens to match another
    palette entry). It joins the side that covers most of it; the sub-pixel
    stage then places the edge inside those pixels.

    *Sharpening halos*: sharpened or AI-upscaled artwork carries a thin band along strong edges
    that *overshoots* the colour of one side (a darker rim around dark
    letters, a lighter rim around light ones). Such a band is thin, lies
    between two regions A and B, its lightness is beyond A's on the side away
    from B, and it is close to A compared with the A–B contrast. Kept as its
    own region it splits letter outlines into pieces, so corners get rounded
    and edges wobble. Genuine outlines (black lines around a light fill)
    are far from both sides and are kept."""
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
    wide_halo = 1.4 * max_width  # allowed for faint halos along strong edges
    thin = (width < wide_halo) & (region_color >= 0)
    thin[0] = False
    if not thin.any() or a.size == 0:
        return labels, 0
    lo, hi = np.minimum(a, b), np.maximum(a, b)
    keys, cnt = np.unique(lo * nreg + hi, return_counts=True)
    p, q = keys // nreg, keys % nreg
    src = np.concatenate([p, q])
    dst = np.concatenate([q, p])
    ln = np.concatenate([cnt, cnt]).astype(np.float64)
    sel = thin[src] & (region_color[dst] >= 0)
    src, dst, ln = src[sel], dst[sel], ln[sel]
    if src.size == 0:
        return labels, 0
    lab = label_feats[:, :3]
    alpha = label_feats[:, 3]
    order = np.argsort(src, kind="stable")
    src, dst, ln = src[order], dst[order], ln[order]
    starts = np.flatnonzero(np.r_[True, src[1:] != src[:-1]])
    ends = np.r_[starts[1:], src.shape[0]]
    lut = region_color.astype(np.int64).copy()
    merged = 0
    for s0, e0 in zip(starts.tolist(), ends.tolist()):
        r = int(src[s0])
        cr = int(region_color[r])
        nb, nl = dst[s0:e0], ln[s0:e0]
        cols = region_color[nb]
        tot = float(perim[r])
        # border length per neighbouring colour
        ucol, inv = np.unique(cols, return_inverse=True)
        clen = np.bincount(inv, weights=nl)
        big = clen >= 0.2 * tot
        if big.sum() < 2:
            # *enclosed strips*: a one-pixel line inside a single shape that
            # differs only moderately from it (compression ringing parallel
            # to an edge) belongs to that shape
            ia = int(np.argmax(clen))
            ca = int(ucol[ia])
            if width[r] <= aa_width and clen[ia] >= 0.8 * tot and abs(alpha[ca] - alpha[cr]) <= 1e-6:
                if float(np.sqrt(((lab[cr] - lab[ca]) ** 2).sum())) <= de_enclosed:
                    lut[r] = ca
                    merged += 1
            continue
        best = None
        if width[r] <= aa_width:
            for ia in np.flatnonzero(big):
                for ib in np.flatnonzero(big):
                    if ib <= ia:
                        continue
                    ca, cb = int(ucol[ia]), int(ucol[ib])
                    d = label_rgb[cb] - label_rgb[ca]
                    dd = float((d * d).sum())
                    if dd < 900.0:  # A and B too similar to call R a mixture
                        continue
                    v = label_rgb[cr] - label_rgb[ca]
                    t = float((v * d).sum()) / dd
                    perp = float(np.sqrt(((v - t * d) ** 2).sum()))
                    if -0.05 <= t <= 1.05 and perp <= max(12.0, 0.15 * math.sqrt(dd)):
                        score = perp / math.sqrt(dd) - 1.0  # prefer mixtures over halos
                        if best is None or score < best[0]:
                            best = (score, ca if t < 0.5 else cb)
        for ia in np.flatnonzero(big):
            ca = int(ucol[ia])
            if abs(alpha[ca] - alpha[cr]) > 1e-6:
                continue
            de_ra = float(np.sqrt(((lab[cr] - lab[ca]) ** 2).sum()))
            if de_ra > de_max:
                continue
            for ib in np.flatnonzero(big):
                if ib == ia:
                    continue
                cb = int(ucol[ib])
                de_ab = float(np.sqrt(((lab[ca] - lab[cb]) ** 2).sum()))
                dl_r = float(lab[cr, 0] - lab[ca, 0])
                dl_b = float(lab[cb, 0] - lab[ca, 0])
                if dl_r * dl_b >= 0 or abs(dl_r) < 0.5 * de_ra:
                    continue  # not an overshoot of A away from B
                if de_ra > ratio * de_ab or (width[r] >= max_width and de_ra > 0.15 * de_ab):
                    continue
                score = de_ra / max(de_ab, 1e-6)
                if best is None or score < best[0]:
                    best = (score, ca)
        if best is not None:
            lut[r] = best[1]
            merged += 1
    if not merged:
        return labels, 0
    return lut[regions], merged


def _unify_thin_lines(labels: np.ndarray, pm: np.ndarray, colors: np.ndarray, noise_sigma: float, compressed: bool = False) -> tuple[np.ndarray, int]:
    """Keep thin lines (leaf veins, hairline highlights, sparkle rays) whole.

    A line one or two pixels wide is a chain of partially covered pixels: each
    gets whichever palette colour its mixture happens to match, and where the
    line runs diagonally the pixels touch only at corners. As 4-connected
    regions they are single pixels, and speckle removal deletes the line.

    Thin ridges and valleys are found with a morphological top-hat. In each
    connected ridge the line colour L is estimated from its strongest pixels;
    ridge pixels whose colour is a mixture of L and the local background with
    at least a third of L are relabelled L, and diagonal steps are closed so
    the line forms one region. The sub-pixel stage later gives it the width
    its coverage indicates."""
    h, w = labels.shape
    if h < 5 or w < 5 or colors.shape[0] == 0:
        return labels, 0
    y = (0.299 * pm[..., 0] + 0.587 * pm[..., 1] + 0.114 * pm[..., 2]).astype(np.float32)
    se = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    # JPEG ringing forms faint ridges along every edge: stricter there
    t = max(24.0 if compressed else 14.0, 4.0 * noise_sigma)
    k = colors.shape[0]
    pal = np.zeros((k, 4))
    pal[:, :3] = colors[:, :3] * (colors[:, 3:4] / 255.0)
    pal[:, 3] = colors[:, 3]
    out = labels.copy()
    total = 0
    for resp in (y - cv2.morphologyEx(y, cv2.MORPH_OPEN, se), cv2.morphologyEx(y, cv2.MORPH_CLOSE, se) - y):
        mask = (resp > t) & (out >= 0)
        if not mask.any():
            continue
        core = mask & (resp > 2.5 * t)
        ncc, cc = cv2.connectedComponents(mask.astype(np.uint8), connectivity=8)
        core_cnt = np.bincount(cc[core], minlength=ncc)
        core_cnt[0] = 0
        keep = core_cnt >= (8 if compressed else 4)
        if not keep.any():
            continue
        # local background: label of the nearest pixel outside the ridge
        _, (iy, ix) = ndimage.distance_transform_edt(mask, return_indices=True)
        bg_lab = out[iy, ix]
        # line colour per component: mean of its strongest core pixels
        cys, cxs = np.nonzero(core & keep[cc])
        comp = cc[cys, cxs]
        r = resp[cys, cxs]
        order = np.lexsort((-r, comp))
        comp_s = comp[order]
        starts = np.flatnonzero(np.r_[True, comp_s[1:] != comp_s[:-1]])
        ends = np.r_[starts[1:], comp_s.shape[0]]
        line_lab = np.full(ncc, -1, dtype=np.int64)
        for s0, e0 in zip(starts.tolist(), ends.tolist()):
            m = max(2, (e0 - s0) // 3)
            sel = order[s0 : s0 + m]
            c = pm[cys[sel], cxs[sel]].astype(np.float64).mean(0)
            line_lab[int(comp_s[s0])] = int(np.argmin(((pal - c) ** 2).sum(1)))
        ys, xs = np.nonzero(mask & keep[cc])
        L = line_lab[cc[ys, xs]]
        B = bg_lab[ys, xs]
        ok = (L >= 0) & (B >= 0) & (B != L)
        cl, cb = pal[np.maximum(L, 0)], pal[np.maximum(B, 0)]
        d = cl - cb
        dd = (d * d).sum(1)
        x = pm[ys, xs].astype(np.float64)
        a = ((x - cb) * d).sum(1) / np.maximum(dd, 1e-9)
        res = np.sqrt(((x - cb - a[:, None] * d) ** 2).sum(1))
        ok &= (dd > 1600.0) & (a >= 0.33) & (a <= 1.4) & (res <= np.maximum(14.0, 0.25 * np.sqrt(dd)))
        ok &= out[ys, xs] != L
        if not ok.any():
            continue
        out[ys[ok], xs[ok]] = L[ok]
        total += int(ok.sum())
        # close diagonal steps: a line pixel touching another of the same
        # colour only at a corner gets the stronger of the two bridging pixels
        line_px = np.zeros((h, w), dtype=bool)
        line_px[ys[ok], xs[ok]] = True
        for _ in range(2):
            fixed = 0
            for dx in (1, -1):
                y0, y1 = 0, h - 1
                x0, x1 = (0, w - 1) if dx == 1 else (1, w)
                p = out[y0:y1, x0:x1]
                q = out[y0 + 1 : y1 + 1, x0 + dx : x1 + dx]
                b1 = out[y0:y1, x0 + dx : x1 + dx]  # same row, next column
                b2 = out[y0 + 1 : y1 + 1, x0:x1]  # next row, same column
                lp = line_px[y0:y1, x0:x1] | line_px[y0 + 1 : y1 + 1, x0 + dx : x1 + dx]
                diag = lp & (p == q) & (p >= 0) & (b1 != p) & (b2 != p)
                if not diag.any():
                    continue
                dy_, dx_ = np.nonzero(diag)
                r1 = resp[dy_, dx_ + x0 + dx]
                r2 = resp[dy_ + 1, dx_ + x0]
                lab_ = p[dy_, dx_]
                use1 = r1 >= r2
                ty = np.where(use1, dy_, dy_ + 1)
                tx = np.where(use1, dx_ + x0 + dx, dx_ + x0)
                good = out[ty, tx] >= 0
                out[ty[good], tx[good]] = lab_[good]
                line_px[ty[good], tx[good]] = True
                fixed += int(good.sum())
            total += fixed
            if not fixed:
                break
    return out, total


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
        auto_thr = max(auto_thr, 9.0)
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
    extended = 0
    if k and opts.thin_lines:
        labels, extended = _unify_thin_lines(labels, pm, colors, noise_sigma, compressed)

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
    thin_absorbed = halos = 0
    if k:
        de_limit = 24.0 if compressed else 9.0
        for _ in range(2):
            labels, n_abs = _absorb_thin_regions(labels, centers, de_limit, 3.0 if compressed else 2.2)
            thin_absorbed += n_abs
            if not n_abs:
                break
        for _ in range(3):  # bands can be nested (AA strip outside a halo)
            labels, n_b = _absorb_edge_bands(labels, centers, colors, 3.0 if compressed else 2.6, de_enclosed=40.0 if compressed else 12.0)
            halos += n_b
            if not n_b:
                break
        if thin_absorbed or halos:
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
        "edge_bands_absorbed": int(halos),
        "thin_line_pixels": int(extended),
        "colors_added_second_pass": int(added),
        "compressed_source": bool(compressed),
    }
    return Segmentation(labels=labels, palette=palette, counts=counts, regions=regions, region_color=region_color, stats=stats)
