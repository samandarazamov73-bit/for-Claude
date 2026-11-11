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


def _fit_sse(G: np.ndarray, Rm: np.ndarray, Q: np.ndarray) -> np.ndarray:
    """Batched per-channel least squares. G (P,6,6), Rm (P,3,6), Q (P,3,3)."""
    P = G.shape[0]
    reg = np.eye(6)[None] * (_RIDGE * np.maximum(G[:, 0, 0], 1.0))[:, None, None]
    reg[:, 0, 0] = 0
    try:
        theta = np.linalg.solve(G + reg, np.transpose(Rm, (0, 2, 1)))  # (P,6,3)
    except np.linalg.LinAlgError:
        theta = np.stack([np.linalg.lstsq(G[i] + reg[i], Rm[i].T, rcond=None)[0] for i in range(P)])
    fitted = np.einsum("pjk,pkj->p", theta, Rm)  # Σ_k θ_k·R_k
    return np.maximum(np.trace(Q, axis1=1, axis2=2) - fitted, 0.0)


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


def _pl_fit(t: np.ndarray, cols: np.ndarray, knots: int) -> tuple[np.ndarray, float]:
    """Least-squares piecewise-linear profile c(t), t in [0, 1], with uniform
    knots (hat basis). Returns (knot colours (K, 3), SSE)."""
    K = knots
    pos = np.clip(t, 0.0, 1.0) * (K - 1)
    j = np.minimum(pos.astype(np.int64), K - 2)
    f = pos - j
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


def _stops_from(knots_cols: np.ndarray, t0: float = 0.0) -> list:
    K = knots_cols.shape[0]
    ts = np.linspace(t0, 1.0, K)
    stops = [(float(t), tuple(int(round(min(255.0, max(0.0, v)))) for v in c) + (255,)) for t, c in zip(ts, knots_cols)]
    if t0 > 1e-6:
        stops = [(0.0, stops[0][1])] + stops
    return _thin_stops(stops)


def _fit_linear_px(px, py, cols, direction, knots=10):
    u = direction / max(np.hypot(*direction), 1e-12)
    proj = px * u[0] + py * u[1]
    t0, t1 = float(proj.min()), float(proj.max())
    if t1 - t0 < 2.0:
        return None, np.inf
    t = (proj - t0) / (t1 - t0)
    kc, sse = _pl_fit(t, cols, knots)
    # endpoints in user space along u, through the point (0, 0)·u = t0
    cx, cy = float(px.mean()), float(py.mean())
    base = cx * u[0] + cy * u[1]
    p1 = (cx + u[0] * (t0 - base), cy + u[1] * (t0 - base))
    p2 = (cx + u[0] * (t1 - base), cy + u[1] * (t1 - base))
    return GradientPaint("linear", _stops_from(kc), p1[0], p1[1], p2[0], p2[1]), sse


def _radial_metric(px, py, q, M):
    dx, dy = px - q[0], py - q[1]
    # M = 2x2 inverse-shape matrix (identity for circles)
    return np.sqrt(np.maximum(M[0, 0] * dx * dx + 2 * M[0, 1] * dx * dy + M[1, 1] * dy * dy, 0.0))


def _fit_radial_px(px, py, cols, q, M, knots=10):
    rho = _radial_metric(px, py, q, M)
    rmax = float(rho.max())
    if rmax < 2.0:
        return None, np.inf
    t = rho / rmax
    t0 = float(t.min())
    tt = (t - t0) / max(1.0 - t0, 1e-9) if t0 > 0.08 else t
    kc, sse = _pl_fit(tt, cols, knots)
    # unit circle -> ellipse {rho = rmax}
    lam, vec = np.linalg.eigh(M)
    L = rmax / np.sqrt(np.maximum(lam, 1e-12))
    e1, e2 = vec[:, 0] * L[0], vec[:, 1] * L[1]
    paint = GradientPaint("radial", _stops_from(kc, t0 if t0 > 0.08 else 0.0), m=(float(e1[0]), float(e1[1]), float(e2[0]), float(e2[1]), float(q[0]), float(q[1])))
    return paint, sse


def _choose_paint(px, py, cols, G, Rm, Q, n, S, c0, tau_fin, min_range, allow_radial, rng):
    """Pixel-based paint selection: linear and radial candidates with
    piecewise-linear colour profiles; returns (paint or None, rms)."""
    m = px.shape[0]
    if m > 12000:
        sel = rng.choice(m, 12000, replace=False)
        px, py, cols = px[sel], py[sel], cols[sel]
        m = 12000
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
        try:
            th_q = np.linalg.solve(G + np.eye(6) * _RIDGE * max(n, 1.0) * (np.arange(6) > 0), rs)
            A = np.array([[th_q[3], th_q[4] / 2], [th_q[4] / 2, th_q[5]]])
            if np.linalg.det(A) > 0:
                qn = -0.5 * np.linalg.solve(A, th_q[1:3])
                cands.append(qn * S + np.asarray(c0))
        except np.linalg.LinAlgError:
            pass
        sub = slice(None) if m <= 2500 else rng.choice(m, 2500, replace=False)
        spx, spy, scol = px[sub], py[sub], cols[sub]
        sq_total = float((scol ** 2).sum())
        I2 = np.eye(2)
        KB = 10

        def obj(q):
            # residual of a ring-wise constant profile (cheap proxy for the
            # piecewise-linear fit, used only to locate the centre)
            rho = np.sqrt((spx - q[0]) ** 2 + (spy - q[1]) ** 2)
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
    if best is None:
        return None, 0.0
    rms = math.sqrt(best_sse / (3 * m))
    explained = 1.0 - best_sse / max(flat, 1e-9)
    colors = np.array([c for _, c in best.stops], dtype=np.float64)[:, :3]
    rng_vis = float(np.abs(colors.max(0) - colors.min(0)).max())
    if rms > tau_fin or explained < 0.5 or rng_vis < min_range:
        return None, rms
    return best, rms


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
    pairs = np.unique(lo.astype(np.int64) * nreg + hi)
    pa, pb = pairs // nreg, pairs % nreg
    ok = opaque[pa] & opaque[pb]
    pa, pb = pa[ok], pb[ok]

    G, Rm, Q, n = stats.G.copy(), stats.Rm.copy(), stats.Q.copy(), stats.n.copy()

    def cost_batch(ia, ib):
        sm = _fit_sse(G[ia] + G[ib], Rm[ia] + Rm[ib], Q[ia] + Q[ib])
        nm = n[ia] + n[ib]
        rms_m = np.sqrt(sm / (3 * nm))
        pooled = np.sqrt((sse[ia] + sse[ib]) / (3 * nm))
        return rms_m - pooled, rms_m, sm

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

    def flat_rms(r: int) -> float:
        mu = Rm[r][:, 0] / max(n[r], 1.0)
        cov = Q[r] / max(n[r], 1.0) - np.outer(mu, mu)
        return math.sqrt(max(float(np.trace(cov)) / 3.0, 0.0))

    gparent = {r: r for r in members}

    def gfind(r: int) -> int:
        while gparent[r] != r:
            gparent[r] = gparent[gparent[r]]
            r = gparent[r]
        return r

    attempts, changed = 0, True
    while changed and attempts < 300:
        changed = False
        gp = set()
        for a0, b0 in zip(pa.tolist(), pb.tolist()):
            ra, rb = gfind(int(root[a0])), gfind(int(root[b0]))
            if ra != rb and (ra in paints or rb in paints) and ra in pix and rb in pix:
                gp.add((min(ra, rb), max(ra, rb)))
        for A, B in sorted(gp, key=lambda t: -(n[t[0]] + n[t[1]])):
            A, B = gfind(A), gfind(B)
            if A == B or attempts >= 300:
                continue
            attempts += 1
            sel = np.concatenate([pix[A], pix[B]])
            try:
                radial_parts = any(paints.get(x) is not None and paints[x].kind == "radial" for x in (A, B))
                paint, _ = _choose_paint(xs[sel] + 0.5, ys[sel] + 0.5, col[sel], G[A] + G[B], Rm[A] + Rm[B], Q[A] + Q[B], n[A] + n[B], S, c0, tau_fin, min_range, allow_radial=radial_parts, rng=rng)
            except np.linalg.LinAlgError:
                paint = None
            if paint is None:
                continue
            pred = paint.colors_at(xs[sel] + 0.5, ys[sel] + 0.5)[:, :3]
            r_u = math.sqrt(float(((pred - col[sel]) ** 2).mean()))
            limit = max(rms_of.get(A, flat_rms(A)), rms_of.get(B, flat_rms(B))) + 0.5 * tau_inc
            if r_u > limit or r_u > tau_fin:
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

    # ---- verification on real pixels (all pixels of the group) ---------
    rejected = set()
    for r, paint in list(paints.items()):
        sel = pix[r]
        pred = paint.colors_at(xs[sel] + 0.5, ys[sel] + 0.5)[:, :3]
        err = math.sqrt(float(((pred - col[sel]) ** 2).mean()))
        if err > tau_fin * 1.1:
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
    st.extra = {"merges": merges, "tau_abs": round(tau_abs, 2), "tau_inc": round(tau_inc, 2)}
    stats_out = dict(seg.stats)
    stats_out.update({"gradient_regions": len(fills), "gradient_linear": st.linear, "gradient_radial": st.radial, "gradient_merged_groups": st.merged_groups, "gradient_reverted": st.reverted, "regions_before_gradients": st.regions_before, "regions": st.regions_after, "colors": int(palette.shape[0])})
    out = Segmentation(labels=labels, palette=palette, counts=counts, regions=new_regions, region_color=new_rc, stats=stats_out)
    out.fills = fills
    if progress:
        progress(1.0, "gradients done")
    return out, fills, st
