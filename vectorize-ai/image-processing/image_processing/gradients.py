"""Stage 3b — gradient regions.

Colour quantisation turns smooth shading into bands of flat colour. This
stage undoes that:

1. For every region, sufficient statistics of a per-channel quadratic colour
   model ``c(x, y) = θ·[1, x, y, x², xy, y²]`` are accumulated over interior
   pixels (moments of the coordinates and colours), so the least-squares fit
   of any union of regions is available in closed form.
2. Adjacent regions are merged greedily (cheapest first) while one model
   explains the union about as well as the separate models explain the parts
   (``Δrms ≤ τ_inc``) and the union still fits (``rms ≤ τ_abs``). Real edges –
   letters, object outlines – produce a large ``Δrms`` and are kept.
3. Each resulting region gets a paint: flat, linear gradient or (elliptical)
   radial gradient, from a rank-1 colour model ``c = μ + v·s(x, y)`` (``v`` =
   principal colour direction). The paint is verified against the real
   pixels; groups whose paint does not fit are restored to their original
   regions, so the stage never makes a result worse.
"""
from __future__ import annotations

import heapq
import math
import time as _time
from dataclasses import dataclass, field

import numpy as np

from geometry_engine.paint import GradientPaint

from .segmentation import Segmentation

# basis exponents (x^i y^j) of the quadratic model
_BASIS = [(0, 0), (1, 0), (0, 1), (2, 0), (1, 1), (0, 2)]
_MOMENTS = sorted({(a[0] + b[0], a[1] + b[1]) for a in _BASIS for b in _BASIS})
_MIDX = {m: i for i, m in enumerate(_MOMENTS)}
_GIDX = np.array([[_MIDX[(a[0] + b[0], a[1] + b[1])] for b in _BASIS] for a in _BASIS])
_RIDGE = 1e-7


@dataclass
class GradientStats:
    merged_groups: int = 0
    regions_before: int = 0
    regions_after: int = 0
    linear: int = 0
    radial: int = 0
    reverted: int = 0
    extra: dict = field(default_factory=dict)


def _fit_theta(G: np.ndarray, Rm: np.ndarray) -> np.ndarray:
    """Batched per-channel least squares θ (P,6,3) for G (P,6,6), Rm (P,3,6)."""
    P = G.shape[0]
    reg = np.eye(6)[None] * (_RIDGE * np.maximum(G[:, 0, 0], 1.0))[:, None, None]
    reg[:, 0, 0] = 0
    try:
        return np.linalg.solve(G + reg, np.transpose(Rm, (0, 2, 1)))
    except np.linalg.LinAlgError:
        return np.stack([np.linalg.lstsq(G[i] + reg[i], Rm[i].T, rcond=None)[0] for i in range(P)])


def _fit_sse(G: np.ndarray, Rm: np.ndarray, Q: np.ndarray) -> np.ndarray:
    """Batched per-channel least squares. G (P,6,6), Rm (P,3,6), Q (P,3,3)."""
    theta = _fit_theta(G, Rm)
    fitted = np.einsum("pjk,pkj->p", theta, Rm)  # Σ_k θ_k·R_k
    return np.maximum(np.trace(Q, axis1=1, axis2=2) - fitted, 0.0)


def _part_sse(theta: np.ndarray, G: np.ndarray, Rm: np.ndarray, Q: np.ndarray) -> np.ndarray:
    """SSE of a part (G, Rm, Q) under a given model θ (closed form)."""
    lin = np.einsum("pjk,pkj->p", theta, Rm)
    quad = np.einsum("pjk,pjl,plk->p", theta, G, theta)
    return np.maximum(np.trace(Q, axis1=1, axis2=2) - 2.0 * lin + quad, 0.0)


class _Stats:
    def __init__(self, ids, x, y, c, nreg):
        mono = {}
        for (i, j) in _MOMENTS:
            mono[(i, j)] = np.bincount(ids, weights=(x ** i) * (y ** j), minlength=nreg)
        M = np.stack([mono[m] for m in _MOMENTS], 1)  # (R, nmom)
        self.G = M[:, _GIDX]  # (R,6,6)
        basis = np.stack([(x ** i) * (y ** j) for i, j in _BASIS], 1)
        self.Rm = np.zeros((nreg, 3, 6))
        for k in range(3):
            for b in range(6):
                self.Rm[:, k, b] = np.bincount(ids, weights=c[:, k] * basis[:, b], minlength=nreg)
        self.Q = np.zeros((nreg, 3, 3))
        for k in range(3):
            for l in range(k, 3):
                v = np.bincount(ids, weights=c[:, k] * c[:, l], minlength=nreg)
                self.Q[:, k, l] = v
                self.Q[:, l, k] = v
        self.n = self.G[:, 0, 0].copy()


_SMOOTH: dict[int, np.ndarray] = {}


def _smooth_matrix(K: int) -> np.ndarray:
    m = _SMOOTH.get(K)
    if m is None:
        D = np.diff(np.eye(K), axis=0)
        m = _SMOOTH[K] = D.T @ D
    return m


def _pl_fit(t: np.ndarray, cols: np.ndarray, knots) -> tuple[np.ndarray, float]:
    """Least-squares piecewise-linear profile c(t), t in [0, 1] (hat basis).
    ``knots`` is a count (uniform) or an increasing array of positions from
    0 to 1. Returns (knot colours (K, 3), SSE)."""
    pos = np.linspace(0.0, 1.0, knots) if np.isscalar(knots) else np.asarray(knots, dtype=np.float64)
    K = pos.shape[0]
    tc = np.clip(t, 0.0, 1.0)
    j = np.clip(np.searchsorted(pos, tc, side="right") - 1, 0, K - 2)
    f = (tc - pos[j]) / np.maximum(pos[j + 1] - pos[j], 1e-12)
    w0, w1 = 1.0 - f, f
    ata = np.zeros((K, K))
    d0 = np.bincount(j, weights=w0 * w0, minlength=K) + np.bincount(j + 1, weights=w1 * w1, minlength=K)
    off = np.bincount(j, weights=w0 * w1, minlength=K)[: K - 1]
    ata[np.arange(K), np.arange(K)] = d0 + 1e-6
    ata[np.arange(K - 1), np.arange(1, K)] = off
    ata[np.arange(1, K), np.arange(K - 1)] = off
    # light smoothness prior keeps empty knots well defined
    lam = 1e-3 * max(t.shape[0] / K, 1.0)
    ata += lam * _smooth_matrix(K)
    atb = np.stack([np.bincount(j, weights=w0 * cols[:, k], minlength=K) + np.bincount(j + 1, weights=w1 * cols[:, k], minlength=K) for k in range(3)], 1)
    x = np.linalg.solve(ata, atb)
    pred = x[j] * w0[:, None] + x[j + 1] * w1[:, None]
    return x, float(((pred - cols) ** 2).sum())


def _pl_fit_adaptive(t: np.ndarray, cols: np.ndarray, knots: int = 12) -> tuple[np.ndarray, np.ndarray, float]:
    """Profile fit with knots placed where the colour changes: a uniform fit
    gives the colour curve, then the knots are spread evenly along its
    length (plus a uniform share), and the profile is refitted. Vignettes —
    a long plateau and a short ramp — need this. Returns (positions, knot
    colours, SSE)."""
    pos0 = np.linspace(0.0, 1.0, knots)
    kc0, sse0 = _pl_fit(t, cols, pos0)
    seg = np.sqrt((np.diff(kc0, axis=0) ** 2).sum(1))
    total = float(seg.sum())
    if total < 1e-6:
        return pos0, kc0, sse0
    dens = seg + 0.2 * total / (knots - 1)
    cum = np.concatenate([[0.0], np.cumsum(dens)])
    cum /= cum[-1]
    pos1 = np.interp(np.linspace(0.0, 1.0, knots), cum, pos0)
    pos1[0], pos1[-1] = 0.0, 1.0
    if np.any(np.diff(pos1) < 1e-4):
        return pos0, kc0, sse0
    kc1, sse1 = _pl_fit(t, cols, pos1)
    return (pos1, kc1, sse1) if sse1 < sse0 else (pos0, kc0, sse0)


def _stops_from(knots_cols: np.ndarray, t0: float = 0.0, pos: np.ndarray | None = None) -> list:
    K = knots_cols.shape[0]
    base = np.linspace(0.0, 1.0, K) if pos is None else np.asarray(pos, dtype=np.float64)
    ts = t0 + (1.0 - t0) * base
    stops = [(float(t), tuple(int(round(min(255.0, max(0.0, v)))) for v in c) + (255,)) for t, c in zip(ts, knots_cols)]
    if t0 > 1e-6:
        stops = [(0.0, stops[0][1])] + stops
    return _thin_stops(stops)


def _fit_linear_px(px, py, cols, direction, knots=12):
    u = direction / max(np.hypot(*direction), 1e-12)
    proj = px * u[0] + py * u[1]
    t0, t1 = float(proj.min()), float(proj.max())
    if t1 - t0 < 2.0:
        return None, np.inf
    t = (proj - t0) / (t1 - t0)
    pos, kc, sse = _pl_fit_adaptive(t, cols, knots)
    # endpoints in user space along u, through the point (0, 0)·u = t0
    cx, cy = float(px.mean()), float(py.mean())
    base = cx * u[0] + cy * u[1]
    p1 = (cx + u[0] * (t0 - base), cy + u[1] * (t0 - base))
    p2 = (cx + u[0] * (t1 - base), cy + u[1] * (t1 - base))
    return GradientPaint("linear", _stops_from(kc, 0.0, pos), p1[0], p1[1], p2[0], p2[1]), sse


def _radial_metric(px, py, q, M):
    dx, dy = px - q[0], py - q[1]
    # M = 2x2 inverse-shape matrix (identity for circles)
    return np.sqrt(np.maximum(M[0, 0] * dx * dx + 2 * M[0, 1] * dx * dy + M[1, 1] * dy * dy, 0.0))


def _fit_radial_px(px, py, cols, q, M, knots=12):
    rho = _radial_metric(px, py, q, M)
    rmax = float(rho.max())
    if rmax < 2.0:
        return None, np.inf
    t = rho / rmax
    t0 = float(t.min())
    tt = (t - t0) / max(1.0 - t0, 1e-9) if t0 > 0.08 else t
    pos, kc, sse = _pl_fit_adaptive(tt, cols, knots)
    # unit circle -> ellipse {rho = rmax}
    lam, vec = np.linalg.eigh(M)
    L = rmax / np.sqrt(np.maximum(lam, 1e-12))
    e1, e2 = vec[:, 0] * L[0], vec[:, 1] * L[1]
    paint = GradientPaint("radial", _stops_from(kc, t0 if t0 > 0.08 else 0.0, pos), m=(float(e1[0]), float(e1[1]), float(e2[0]), float(e2[1]), float(q[0]), float(q[1])))
    return paint, sse


def _choose_paint(px, py, cols, G, Rm, Q, n, S, c0, tau_fin, min_range, allow_radial, rng, min_explained=0.5, max_px=12000, nm_px=2500):
    """Pixel-based paint selection: linear and radial candidates with
    piecewise-linear colour profiles; returns (paint or None, rms)."""
    m = px.shape[0]
    if m > max_px:
        sel = rng.choice(m, max_px, replace=False)
        px, py, cols = px[sel], py[sel], cols[sel]
        m = max_px
    mu = cols.mean(0)
    flat = float(((cols - mu) ** 2).sum())
    if flat / (3 * m) < 1.5:  # practically flat
        return None, 0.0
    best, best_sse = None, np.inf
    # linear direction from the closed-form linear fit (rank-1 colour axis)
    cov = Q / n - np.outer(Rm[:, 0] / n, Rm[:, 0] / n)
    v = np.linalg.eigh(cov)[1][:, -1]
    rs = v @ Rm - float(v @ (Rm[:, 0] / n)) * G[0, :]
    ridge = np.eye(3) * _RIDGE * max(n, 1.0)
    ridge[0, 0] = 0
    try:
        th = np.linalg.solve(G[:3, :3] + ridge, rs[:3])
        if np.hypot(th[1], th[2]) > 1e-9:
            paint, sse = _fit_linear_px(px, py, cols, np.array([th[1], th[2]]))
            if paint is not None:
                best, best_sse = paint, sse
    except np.linalg.LinAlgError:
        pass
    if allow_radial:
        from scipy.optimize import minimize

        s_proj = (cols - mu) @ v
        cands = [np.array([px.mean(), py.mean()])]
        k = max(5, m // 50)
        hi_i = np.argpartition(-s_proj, k)[:k]
        lo_i = np.argpartition(s_proj, k)[:k]
        cands += [np.array([px[hi_i].mean(), py[hi_i].mean()]), np.array([px[lo_i].mean(), py[lo_i].mean()])]
        M_ell = None
        q_ell = None
        try:
            th_q = np.linalg.solve(G + np.eye(6) * _RIDGE * max(n, 1.0) * (np.arange(6) > 0), rs)
            A = np.array([[th_q[3], th_q[4] / 2], [th_q[4] / 2, th_q[5]]])
            det = float(np.linalg.det(A))
            if det > 0:
                qn = -0.5 * np.linalg.solve(A, th_q[1:3])
                q_ell = qn * S + np.asarray(c0)
                cands.append(q_ell)
                # iso-colour lines of the quadratic model are ellipses: their
                # shape seeds an elliptical radial gradient
                Mn = A * np.sign(A[0, 0]) / math.sqrt(det)
                lam = np.linalg.eigvalsh(Mn)
                if lam[0] > 0 and lam[1] / lam[0] > 1.25 and lam[1] / lam[0] < 400:
                    M_ell = Mn
        except np.linalg.LinAlgError:
            pass
        sub = slice(None) if m <= nm_px else rng.choice(m, nm_px, replace=False)
        spx, spy, scol = px[sub], py[sub], cols[sub]
        sq_total = float((scol ** 2).sum())
        I2 = np.eye(2)
        KB = 10

        Mcur = [I2]

        def obj(q):
            # residual of a ring-wise constant profile (cheap proxy for the
            # piecewise-linear fit, used only to locate the centre)
            rho = _radial_metric(spx, spy, q, Mcur[0])
            rmax = rho.max()
            if rmax < 1e-6:
                return 1e18
            b = np.minimum((rho * (KB / rmax)).astype(np.int64), KB - 1)
            cnt = np.bincount(b, minlength=KB)
            acc = 0.0
            for k in range(3):
                sums = np.bincount(b, weights=scol[:, k], minlength=KB)
                acc += float((sums[cnt > 0] ** 2 / cnt[cnt > 0]).sum())
            return sq_total - acc

        start = min(cands, key=obj)
        span = max(np.ptp(px), np.ptp(py), 1.0)
        res = minimize(obj, start, method="Nelder-Mead", options={"xatol": 0.75, "fatol": 1e-3 * max(obj(start), 1.0), "maxiter": 45, "initial_simplex": [start, start + [span * 0.1, 0], start + [0, span * 0.1]]})
        paint, sse = _fit_radial_px(px, py, cols, res.x, I2)
        if paint is not None and sse < best_sse * 0.9:
            best, best_sse = paint, sse
        if M_ell is not None:
            Mcur[0] = M_ell
            start = min([res.x, q_ell], key=obj)
            res = minimize(obj, start, method="Nelder-Mead", options={"xatol": 0.75, "fatol": 1e-3 * max(obj(start), 1.0), "maxiter": 45, "initial_simplex": [start, start + [span * 0.1, 0], start + [0, span * 0.1]]})
            paint, sse = _fit_radial_px(px, py, cols, res.x, M_ell)
            if paint is not None and sse < best_sse * 0.9:
                best, best_sse = paint, sse
    if best is None:
        return None, 0.0
    rms = math.sqrt(best_sse / (3 * m))
    explained = 1.0 - best_sse / max(flat, 1e-9)
    colors = np.array([c for _, c in best.stops], dtype=np.float64)[:, :3]
    rng_vis = float(np.abs(colors.max(0) - colors.min(0)).max())
    if rms > tau_fin or explained < min_explained or rng_vis < min_range:
        return None, rms
    return best, rms


def _gradient_magnitude(rgba: np.ndarray) -> np.ndarray:
    import cv2

    f = cv2.GaussianBlur(rgba[..., :3].astype(np.float32), (0, 0), 1.0)
    gx = cv2.Sobel(f, cv2.CV_32F, 1, 0, ksize=3) / 8.0
    gy = cv2.Sobel(f, cv2.CV_32F, 0, 1, ksize=3) / 8.0
    return np.sqrt((gx * gx + gy * gy).sum(-1))


def _thin_stops(stops, tol: float = 1.5):
    keep = [stops[0]]
    for i in range(1, len(stops) - 1):
        a, b, c = keep[-1], stops[i], stops[i + 1]
        w = (b[0] - a[0]) / max(c[0] - a[0], 1e-9)
        if max(abs(a[1][k] * (1 - w) + c[1][k] * w - b[1][k]) for k in range(3)) > tol:
            keep.append(b)
    keep.append(stops[-1])
    return keep


def merge_gradients(rgba: np.ndarray, seg: Segmentation, *, noise_sigma: float = 0.0, compressed: bool = False, max_regions: int = 120_000, progress=None) -> tuple[Segmentation, dict[int, dict], GradientStats]:
    regions = seg.regions
    region_color = seg.region_color
    h, w = regions.shape
    nreg = region_color.shape[0]
    st = GradientStats(regions_before=nreg - 1)
    if nreg - 1 > max_regions or nreg <= 2:
        st.regions_after = nreg - 1
        return seg, {}, st
    alpha_ok = rgba[..., 3] >= 250
    interior = np.ones((h, w), dtype=bool)
    interior[1:, :] &= regions[1:, :] == regions[:-1, :]
    interior[:-1, :] &= regions[:-1, :] == regions[1:, :]
    interior[:, 1:] &= regions[:, 1:] == regions[:, :-1]
    interior[:, :-1] &= regions[:, :-1] == regions[:, 1:]
    use = interior & alpha_ok
    cnt_int = np.bincount(regions[use], minlength=nreg)
    thin = cnt_int[regions] < 8
    use |= thin & alpha_ok
    ys, xs = np.nonzero(use)
    ids = regions[ys, xs]
    S = max(h, w) / 2.0
    c0 = (w / 2.0, h / 2.0)
    xn = (xs + 0.5 - c0[0]) / S
    yn = (ys + 0.5 - c0[1]) / S
    col = rgba[ys, xs, :3].astype(np.float64)
    stats = _Stats(ids, xn, yn, col, nreg)
    if progress:
        progress(0.25, "gradient statistics")

    opaque = (region_color >= 0) & (stats.n > 0)
    opaque[0] = False
    tau_abs = min(12.0, 3.2 + 1.3 * noise_sigma + (2.0 if compressed else 0.0))
    tau_inc = min(5.0, 1.1 + 0.45 * noise_sigma + (0.8 if compressed else 0.0))
    tau_fin = tau_abs * 1.35
    sse = np.zeros(nreg)
    good = np.nonzero(opaque)[0]
    if good.size:
        sse[good] = _fit_sse(stats.G[good], stats.Rm[good], stats.Q[good])

    # adjacency
    a = np.concatenate([regions[:, :-1].ravel(), regions[:-1, :].ravel()])
    b = np.concatenate([regions[:, 1:].ravel(), regions[1:, :].ravel()])
    m = a != b
    lo, hi = np.minimum(a[m], b[m]), np.maximum(a[m], b[m])
    # edge strength of every boundary: mean image gradient across it. Bands
    # of a quantised smooth ramp have soft boundaries, real edges do not.
    gmag = _gradient_magnitude(rgba)
    gpair = np.concatenate([np.maximum(gmag[:, :-1], gmag[:, 1:]).ravel(), np.maximum(gmag[:-1, :], gmag[1:, :]).ravel()])[m]
    pairs, pinv = np.unique(lo.astype(np.int64) * nreg + hi, return_inverse=True)
    p_cnt = np.bincount(pinv).astype(np.float64)
    p_g = np.bincount(pinv, weights=gpair) / np.maximum(p_cnt, 1.0)
    pa, pb = pairs // nreg, pairs % nreg
    ok = opaque[pa] & opaque[pb]
    pa, pb, p_g, p_cnt = pa[ok], pb[ok], p_g[ok], p_cnt[ok]
    # A boundary is soft when the image changes slowly across it: either in
    # absolute terms or relative to the colour step between the two regions
    # (a real edge concentrates the whole step in one or two pixels).
    pal_rgb = seg.palette[:, :3].astype(np.float64)
    if pa.size:
        step = np.sqrt(((pal_rgb[region_color[pa]] - pal_rgb[region_color[pb]]) ** 2).sum(1))
    else:
        step = np.zeros(0)
    g_soft = 4.0 + 2.0 * noise_sigma + (2.0 if compressed else 0.0)
    p_soft_len = np.where((p_g <= g_soft) | (p_g <= 0.2 * step), p_cnt, 0.0)

    G, Rm, Q, n = stats.G.copy(), stats.Rm.copy(), stats.Q.copy(), stats.n.copy()

    tau_part = 1.6 * tau_abs

    def cost_batch(ia, ib):
        Gu, Ru, Qu = G[ia] + G[ib], Rm[ia] + Rm[ib], Q[ia] + Q[ib]
        th = _fit_theta(Gu, Ru)
        sm = np.maximum(np.trace(Qu, axis1=1, axis2=2) - np.einsum("pjk,pkj->p", th, Ru), 0.0)
        nm = n[ia] + n[ib]
        rms_m = np.sqrt(sm / (3 * nm))
        pooled = np.sqrt((sse[ia] + sse[ib]) / (3 * nm))
        # Every part must stay explained by the joint model: a small, distinct
        # detail (a highlight, a thin ray) barely moves the pooled error of a
        # large neighbour, but must not be dissolved into its gradient.
        ra = np.sqrt(_part_sse(th, G[ia], Rm[ia], Q[ia]) / (3 * np.maximum(n[ia], 1.0)))
        rb = np.sqrt(_part_sse(th, G[ib], Rm[ib], Q[ib]) / (3 * np.maximum(n[ib], 1.0)))
        d = rms_m - pooled
        d = np.where(np.maximum(ra, rb) > tau_part, np.inf, d)
        return d, rms_m, sm

    heap: list = []
    if pa.size:
        d, rms_m, _ = cost_batch(pa, pb)
        okc = (rms_m <= tau_abs) & (d <= tau_inc)
        for dd, x, y in zip(d[okc].tolist(), pa[okc].tolist(), pb[okc].tolist()):
            heap.append((dd, x, y, 0, 0))
        heapq.heapify(heap)
    nbrs: dict[int, set[int]] = {}
    for x, y in zip(pa.tolist(), pb.tolist()):
        nbrs.setdefault(x, set()).add(y)
        nbrs.setdefault(y, set()).add(x)
    version = np.zeros(nreg, dtype=np.int64)
    parent = np.arange(nreg)
    alive = np.ones(nreg, dtype=bool)
    merges = 0
    while heap:
        dd, x, y, vx, vy = heapq.heappop(heap)
        if not (alive[x] and alive[y]) or version[x] != vx or version[y] != vy:
            continue
        # merge y into x
        G[x] += G[y]
        Rm[x] += Rm[y]
        Q[x] += Q[y]
        n[x] += n[y]
        sse[x] = _fit_sse(G[x : x + 1], Rm[x : x + 1], Q[x : x + 1])[0]
        alive[y] = False
        parent[y] = x
        version[x] += 1
        merges += 1
        ny_ = nbrs.pop(y, set())
        nx_ = nbrs.setdefault(x, set())
        for c in ny_:
            if c == x:
                continue
            nbrs[c].discard(y)
            nbrs[c].add(x)
            nx_.add(c)
        nx_.discard(y)
        nx_.discard(x)
        cand = [c for c in nx_ if alive[c]]
        if cand:
            ia = np.full(len(cand), x)
            ib = np.array(cand)
            d, rms_m, _ = cost_batch(ia, ib)
            for c, d1, r1 in zip(cand, d.tolist(), rms_m.tolist()):
                if r1 <= tau_abs and d1 <= tau_inc:
                    lo_, hi_ = (x, c) if x < c else (c, x)
                    heapq.heappush(heap, (d1, lo_, hi_, int(version[lo_]), int(version[hi_])))
    if progress:
        progress(0.7, "fitting gradients")

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    root = np.array([find(i) for i in range(nreg)])
    members: dict[int, list[int]] = {}
    for i in range(1, nreg):
        if opaque[i]:
            members.setdefault(int(root[i]), []).append(i)

    min_range = max(5.0, 2.5 * noise_sigma)
    order = np.argsort(root[ids], kind="stable")
    gid_sorted = root[ids][order]
    uniq, starts = np.unique(gid_sorted, return_index=True)
    ends = np.append(starts[1:], gid_sorted.shape[0])
    span = {int(u): (int(s0), int(e0)) for u, s0, e0 in zip(uniq, starts, ends)}
    rng = np.random.default_rng(1234)
    paints: dict[int, GradientPaint] = {}
    cand = [r for r, mem in members.items() if n[r] >= 40]
    # radial search is the expensive part: largest groups first, bounded count
    cand.sort(key=lambda r: -n[r])
    for i, r in enumerate(cand):
        s0, e0 = span.get(r, (0, 0))
        if e0 - s0 < 40:
            continue
        sel = order[s0:e0]
        try:
            paint, _ = _choose_paint(xs[sel] + 0.5, ys[sel] + 0.5, col[sel], G[r], Rm[r], Q[r], n[r], S, c0, tau_fin, min_range, allow_radial=i < 250 and n[r] >= 150, rng=rng)
        except np.linalg.LinAlgError:
            paint = None
        if paint is not None:
            paints[r] = paint
        if progress and i % 50 == 0:
            progress(0.7 + 0.25 * i / max(1, len(cand)), "fitting gradients")

    # ---- second pass: join adjacent groups that one paint explains -------
    # (removes seams where a smooth area was split into two gradients)
    pix = {r: order[span[r][0] : span[r][1]] for r in members if r in span}
    rms_of: dict[int, float] = {}
    for r, paint in paints.items():
        sel = pix[r]
        pred = paint.colors_at(xs[sel] + 0.5, ys[sel] + 0.5)[:, :3]
        rms_of[r] = math.sqrt(float(((pred - col[sel]) ** 2).mean()))

    n0, Q0, R0 = stats.n, stats.Q, stats.Rm

    def flat_rms(r: int) -> float:
        """RMS error of the group as it would be drawn without a paint:
        every member region filled with its own mean colour."""
        mem = np.asarray(members[r])
        tot = float(n0[mem].sum())
        if tot <= 0:
            return 0.0
        sse_m = np.trace(Q0[mem], axis1=1, axis2=2) - (R0[mem, :, 0] ** 2).sum(1) / np.maximum(n0[mem], 1.0)
        return math.sqrt(max(float(sse_m.sum()), 0.0) / (3.0 * tot))

    gparent = {r: r for r in members}

    def gfind(r: int) -> int:
        while gparent[r] != r:
            gparent[r] = gparent[gparent[r]]
            r = gparent[r]
        return r

    t_start = _time.perf_counter()
    max_attempts, time_budget = 500, 15.0
    attempts, changed = 0, True
    failed: set = set()
    while changed and attempts < max_attempts and _time.perf_counter() - t_start < time_budget:
        changed = False
        gsum: dict = {}
        for a0, b0, gs_, gc_ in zip(pa.tolist(), pb.tolist(), p_soft_len.tolist(), p_cnt.tolist()):
            ra, rb = gfind(int(root[a0])), gfind(int(root[b0]))
            if ra == rb or ra not in pix or rb not in pix:
                continue
            key = (min(ra, rb), max(ra, rb))
            acc = gsum.get(key)
            if acc is None:
                gsum[key] = [gs_, gc_]
            else:
                acc[0] += gs_
                acc[1] += gc_
        cands = []
        for (A, B), (gs_, gc_) in gsum.items():
            soft = gs_ >= 0.6 * gc_
            if not (A in paints or B in paints or (soft and n[A] + n[B] >= 400)):
                continue
            cands.append((not soft, -(n[A] + n[B]), A, B, soft))
        cands.sort()
        for _, _, A, B, soft in cands:
            A, B = gfind(A), gfind(B)
            if A == B or attempts >= max_attempts or _time.perf_counter() - t_start > time_budget:
                continue
            fkey = (A, B, int(n[A]), int(n[B]))
            if fkey in failed:
                continue
            # cheap screen: a union the quadratic model misses by far is not
            # rescued by the (more flexible) profile paints either
            rms_q = math.sqrt(float(_fit_sse(G[A : A + 1] + G[B : B + 1], Rm[A : A + 1] + Rm[B : B + 1], Q[A : A + 1] + Q[B : B + 1])[0]) / (3.0 * max(n[A] + n[B], 1.0)))
            if rms_q > 2.4 * tau_fin:
                failed.add(fkey)
                continue
            attempts += 1
            sel = np.concatenate([pix[A], pix[B]])
            try:
                radial_parts = any(paints.get(x) is not None and paints[x].kind == "radial" for x in (A, B))
                allow_radial = radial_parts or (soft and n[A] + n[B] >= 300)
                paint, _ = _choose_paint(xs[sel] + 0.5, ys[sel] + 0.5, col[sel], G[A] + G[B], Rm[A] + Rm[B], Q[A] + Q[B], n[A] + n[B], S, c0, tau_fin, min_range, allow_radial=allow_radial, rng=rng, max_px=6000, nm_px=1500)
            except np.linalg.LinAlgError:
                paint = None
            if paint is None:
                failed.add(fkey)
                continue
            # error of each part on (a sample of) its own pixels: a small part
            # is always checked in full, it must not vanish in a sample
            part_e = []
            for part in (pix[A], pix[B]):
                pp_ = part if part.shape[0] <= 10000 else part[rng.choice(part.shape[0], 10000, replace=False)]
                pred = paint.colors_at(xs[pp_] + 0.5, ys[pp_] + 0.5)[:, :3]
                part_e.append(float(((pred - col[pp_]) ** 2).mean()))
            na_, nb_ = float(pix[A].shape[0]), float(pix[B].shape[0])
            r_u = math.sqrt((part_e[0] * na_ + part_e[1] * nb_) / max(na_ + nb_, 1.0))
            r_pa, r_pb = math.sqrt(part_e[0]), math.sqrt(part_e[1])
            if max(r_pa, r_pb) > 1.2 * tau_fin:
                failed.add(fkey)
                continue
            ra_ = rms_of[A] if A in paints else flat_rms(A)
            rb_ = rms_of[B] if B in paints else flat_rms(B)
            # across a soft boundary one smooth paint is preferred to two
            # pieces with a visible seam, so the tolerance is wider there
            limit = max(ra_, rb_) + (tau_inc if soft else 0.5 * tau_inc)
            if r_u > limit or r_u > tau_fin:
                failed.add(fkey)
                continue
            G[A] += G[B]
            Rm[A] += Rm[B]
            Q[A] += Q[B]
            n[A] += n[B]
            members[A] = members[A] + members.pop(B)
            pix[A] = sel
            pix.pop(B, None)
            paints[A] = paint
            paints.pop(B, None)
            rms_of[A] = r_u
            rms_of.pop(B, None)
            gparent[B] = A
            changed = True

    # ---- third pass: shading inside the remaining bands of smooth areas ----
    # Where no single paint spans several bands (a vignette that follows an
    # egg-shaped border, blurred bokeh), each band of a soft area still gets
    # its own gradient: the colour then runs on across band boundaries
    # instead of stepping, which is what makes posterised shading visible.
    soft_len: dict[int, float] = {}
    all_len: dict[int, float] = {}
    for a0, b0, sl, tl in zip(pa.tolist(), pb.tolist(), p_soft_len.tolist(), p_cnt.tolist()):
        ra, rb = gfind(int(root[a0])), gfind(int(root[b0]))
        if ra == rb:
            continue
        for r_ in (ra, rb):
            soft_len[r_] = soft_len.get(r_, 0.0) + sl
            all_len[r_] = all_len.get(r_, 0.0) + tl
    band_cands = [r for r in pix if r not in paints and n[r] >= 80 and all_len.get(r, 0.0) > 0 and soft_len.get(r, 0.0) >= 0.5 * all_len[r]]
    band_cands.sort(key=lambda r: -n[r])
    t_band = _time.perf_counter()
    band_added = 0
    for i, r in enumerate(band_cands[:600]):
        if _time.perf_counter() - t_band > 10.0:  # safety net only
            break
        sel = pix[r]
        fr = flat_rms(r)
        try:
            # a band paint replaces flat colours, so any clear gain is taken
            paint, rms_b = _choose_paint(xs[sel] + 0.5, ys[sel] + 0.5, col[sel], G[r], Rm[r], Q[r], n[r], S, c0, max(tau_fin, 0.85 * fr), 3.0, allow_radial=n[r] >= 300 and i < 400, rng=rng, min_explained=0.3)
        except np.linalg.LinAlgError:
            paint = None
        if paint is None:
            continue
        if rms_b > 0.85 * fr:  # must clearly beat the flat colours it replaces
            continue
        paints[r] = paint
        rms_of[r] = rms_b
        band_added += 1

    # ---- verification on real pixels (all pixels of the group) ---------
    rejected = set()
    for r, paint in list(paints.items()):
        sel = pix[r]
        pred = paint.colors_at(xs[sel] + 0.5, ys[sel] + 0.5)[:, :3]
        err = math.sqrt(float(((pred - col[sel]) ** 2).mean()))
        if err > max(tau_fin * 1.1, 0.9 * flat_rms(r)):
            rejected.add(r)
    for r in rejected:
        paints.pop(r, None)
    # groups without an accepted paint are restored to their original regions
    final_root = np.arange(nreg)
    reverted = 0
    for r, mem in members.items():
        if r in paints:
            for i in mem:
                final_root[i] = r
        elif len(mem) > 1:
            reverted += 1
    st.reverted = reverted

    # ---- relabel -----------------------------------------------------------
    keep_ids = np.unique(final_root[1:])
    lut = np.zeros(nreg, dtype=np.int64)
    lut[keep_ids] = np.arange(1, keep_ids.shape[0] + 1)
    new_index = lut[final_root]
    new_regions = new_index[regions].astype(np.int32)
    new_rc = np.full(keep_ids.shape[0] + 1, -2, dtype=np.int64)
    pal = seg.palette.astype(np.float64)
    labels = seg.labels.copy()
    fills: dict[int, dict] = {}
    for k, r in enumerate(keep_ids, start=1):
        if r in paints:
            mc = np.array(paints[r].mean_color()[:3], dtype=np.float64)
            ci = int(np.argmin(((pal[:, :3] - mc) ** 2).sum(1))) if pal.shape[0] else -1
            new_rc[k] = ci
            fills[k] = paints[r].to_json()
            st.linear += paints[r].kind == "linear"
            st.radial += paints[r].kind == "radial"
        else:
            new_rc[k] = region_color[r]
    if fills:
        changed = np.isin(new_regions, np.array(list(fills.keys())))
        labels[changed] = new_rc[new_regions[changed]]
    # compact palette
    used = np.unique(labels[labels >= 0])
    lut_c = np.full(max(pal.shape[0], 1) + 1, -1, dtype=np.int64)
    lut_c[used] = np.arange(used.shape[0])
    labels = np.where(labels >= 0, lut_c[np.maximum(labels, 0)], -1).astype(np.int32)
    new_rc = np.where(new_rc >= 0, lut_c[np.maximum(new_rc, 0)], new_rc).astype(np.int32)
    new_rc[0] = -2
    palette = seg.palette[used]
    counts = np.bincount(labels[labels >= 0].ravel(), minlength=palette.shape[0]).astype(np.int64)
    st.merged_groups = sum(1 for r, mem in members.items() if r in paints and len(mem) > 1)
    st.regions_after = keep_ids.shape[0]
    st.extra = {"merges": merges, "joins_attempted": attempts, "band_paints": band_added, "tau_abs": round(tau_abs, 2), "tau_inc": round(tau_inc, 2)}
    stats_out = dict(seg.stats)
    stats_out.update({"gradient_regions": len(fills), "gradient_linear": st.linear, "gradient_radial": st.radial, "gradient_merged_groups": st.merged_groups, "gradient_reverted": st.reverted, "regions_before_gradients": st.regions_before, "regions": st.regions_after, "colors": int(palette.shape[0])})
    out = Segmentation(labels=labels, palette=palette, counts=counts, regions=new_regions, region_color=new_rc, stats=stats_out)
    out.fills = fills
    if progress:
        progress(1.0, "gradients done")
    return out, fills, st
