"""Stages 7–8 — shape recognition, symmetry and repeated shapes applied to
the Vector Graph without breaking shared borders."""
from __future__ import annotations

import math

import numpy as np
from scipy.spatial import cKDTree

from geometry_engine import (
    CornerOptions,
    CurveOptions,
    detect_symmetry,
    fit_closed,
    group_transforms,
    match_congruent,
    move_endpoint,
    recognize,
    resample_closed,
    reverse_path,
    signature,
    signed_area,
    symmetrize,
)
from geometry_engine.primitives import Affine, path_flatten

from .graph import VectorGraph
from .options import ProcessingOptions


def loop_samples(g: VectorGraph, loop) -> np.ndarray | None:
    parts = []
    for iid, rev in loop:
        s = g.interfaces[iid].samples
        if s is None:
            return None
        s = s[::-1] if rev else s
        parts.append(s if not parts else s[1:])
    pts = np.concatenate(parts)
    if pts.shape[0] > 1 and np.allclose(pts[0], pts[-1]):
        pts = pts[:-1]
    return pts


def _incident(g: VectorGraph, nid: int):
    for f in g.interfaces.values():
        if f.start == nid or f.end == nid:
            yield f


def apply_primitive(g: VectorGraph, shape, prim, tol: float) -> bool:
    outer = shape.loops[0]
    if len(outer) == 1 and g.interfaces[outer[0][0]].closed:
        iid, rev = outer[0]
        f = g.interfaces[iid]
        u0, _ = prim.project(f.samples[0] if not rev else f.samples[-1])
        path = prim.subpath(u0, u0)
        f.segments = reverse_path(path) if rev else path
        f.locked = True
        return True
    loop_ifaces = {iid for iid, _ in outer}
    nodes = []
    for iid, rev in outer:
        f = g.interfaces[iid]
        nodes.append(f.end if rev else f.start)
    if len(set(nodes)) != len(nodes):
        return False
    m = len(prim.pieces)
    proj = [prim.project(g.nodes[n].pt) for n in nodes]
    for (u, q), n in zip(proj, nodes):
        if math.dist(q, g.nodes[n].pt) > max(1.0, 1.6 * tol):
            return False
        for f in _incident(g, n):
            if f.id not in loop_ifaces and f.locked:
                return False
    us = [u for u, _ in proj]
    rel = [((u - us[0]) % m) for u in us]
    if any(b <= a + 1e-6 for a, b in zip(rel, rel[1:])):
        return False
    paths = []
    for k, (iid, rev) in enumerate(outer):
        u0, u1 = us[k], us[(k + 1) % len(us)]
        path = prim.subpath(u0, u1)
        if not path:
            return False
        paths.append(reverse_path(path) if rev else path)
    for (iid, _), path in zip(outer, paths):
        g.interfaces[iid].segments = path
        g.interfaces[iid].locked = True
    for (u, q), n in zip(proj, nodes):
        node = g.nodes[n]
        node.x, node.y = float(q[0]), float(q[1])
        for f in _incident(g, n):
            if f.id in loop_ifaces or not f.segments:
                continue
            if f.start == n and f.segments[0].start() != q:
                f.segments = move_endpoint(f.segments[0], q, at_end=False) + f.segments[1:]
            if f.end == n and f.segments[-1].end() != q:
                f.segments = f.segments[:-1] + move_endpoint(f.segments[-1], q, at_end=True)
    # snap path ends exactly onto the nodes (projection rounding)
    for (iid, rev) in outer:
        f = g.interfaces[iid]
        a, b = g.nodes[f.start].pt, g.nodes[f.end].pt
        if f.segments[0].start() != a:
            f.segments = move_endpoint(f.segments[0], a, at_end=False) + f.segments[1:]
        if f.segments[-1].end() != b:
            f.segments = f.segments[:-1] + move_endpoint(f.segments[-1], b, at_end=True)
    return True


def recognize_shapes(g: VectorGraph, opts: ProcessingOptions, tol: float, progress=None) -> int:
    enabled = opts.enabled_shapes()
    if not enabled:
        return 0
    # at higher detail levels the many tiny regions are texture, not geometry:
    # idealising them would cost time and fidelity
    min_area = (10, 40, 150)[opts.detail_level]
    shapes = sorted((s for s in g.shapes.values() if not s.transparent and s.area >= min_area and s.loops), key=lambda s: s.area)
    found = 0
    shape_tol = max(0.7, tol * 1.5)
    for i, s in enumerate(shapes):
        if progress and i % 25 == 0:
            progress(i / max(1, len(shapes)), "recognising shapes")
        outer = s.loops[0]
        if any(g.interfaces[iid].locked or g.interfaces[iid].border for iid, _ in outer):
            continue
        pts = loop_samples(g, outer)
        if pts is None or pts.shape[0] < 8:
            continue
        size = math.sqrt(max(s.area, 1.0))
        prim = recognize(pts, max(shape_tol, 0.004 * size), enabled)
        if prim is None:
            continue
        if apply_primitive(g, s, prim, shape_tol):
            s.primitive = prim.to_json()
            found += 1
    return found


def _island_interface(g: VectorGraph, s):
    if not s.loops or len(s.loops[0]) != 1:
        return None, False
    iid, rev = s.loops[0][0]
    f = g.interfaces[iid]
    if not f.closed or f.border:
        return None, False
    return f, rev


def _orient_like(segs, ref_pts: np.ndarray):
    poly = path_flatten(segs, 0.5)
    if np.sign(signed_area(poly)) != np.sign(signed_area(ref_pts)):
        return reverse_path(segs)
    return segs


def apply_symmetry(g: VectorGraph, opts: ProcessingOptions, copts: CurveOptions, kopts: CornerOptions, progress=None) -> int:
    if not (opts.symmetry_mirror or opts.symmetry_rotation):
        return 0
    count = 0
    cands = [s for s in g.shapes.values() if not s.transparent and s.area >= 40 and s.primitive is None]
    cands = sorted(cands, key=lambda s: -s.area)[:400]
    max_radius = 4.0 * max(g.width, g.height)
    for i, s in enumerate(cands):
        if progress and i % 20 == 0:
            progress(i / max(1, len(cands)), "detecting symmetry")
        f, _ = _island_interface(g, s)
        if f is None or f.locked or f.samples is None or f.samples.shape[0] < 12:
            continue
        sym = detect_symmetry(f.samples, opts.symmetry_tolerance, mirror=opts.symmetry_mirror, rotation=opts.symmetry_rotation)
        if not sym.found:
            continue
        pts = resample_closed(f.samples, 0.5)
        sp = symmetrize(pts, group_transforms(sym))
        bf = fit_closed(sp, np.ones(sp.shape[0]), copts, kopts, 0.6, max_radius)
        f.segments = _orient_like(bf.segments, f.samples)
        f.samples = sp
        f.weights = np.ones(sp.shape[0])
        f.locked = True
        s.symmetry = sym.to_json()
        count += 1
    return count


def apply_repeats(g: VectorGraph, opts: ProcessingOptions, copts: CurveOptions, kopts: CornerOptions, progress=None) -> int:
    if not opts.symmetry_repeats:
        return 0
    islands = []
    for s in g.shapes.values():
        if s.transparent or s.area < 30 or s.primitive is not None:
            continue
        f, _ = _island_interface(g, s)
        if f is None or f.samples is None or f.samples.shape[0] < 12:
            continue
        islands.append((s, f))
    islands = sorted(islands, key=lambda t: -t[0].area)[:400]
    if len(islands) < 2:
        return 0
    sigs = [signature(f.samples) for _, f in islands]
    n = len(islands)
    parent = list(range(n))
    xform: dict[int, Affine] = {}  # member -> transform from its root
    tol = opts.symmetry_tolerance
    order = sorted(range(n), key=lambda i: sigs[i].area)
    assigned = [False] * n
    for a_pos, i in enumerate(order):
        if assigned[i]:
            continue
        for j in order[a_pos + 1 :]:
            if sigs[j].area > sigs[i].area * 1.06 + 10:
                break
            if assigned[j]:
                continue
            t = match_congruent(sigs[i], sigs[j], tol)
            if t is not None:
                parent[j] = i
                xform[j] = t
                assigned[j] = True
    groups: dict[int, list[int]] = {}
    for i in range(n):
        groups.setdefault(parent[i], []).append(i)
    max_radius = 4.0 * max(g.width, g.height)
    gid = 0
    made = 0
    for root, members in groups.items():
        if len(members) < 2:
            continue
        xform[root] = Affine()
        base = sigs[root].points
        acc = base.copy()
        for mbr in members:
            if mbr == root:
                continue
            inv = xform[mbr].inverse()
            mp = inv.apply_array(sigs[mbr].points)
            tree = cKDTree(mp)
            _, idx = tree.query(base)
            acc += mp[idx]
        canon = acc / len(members)
        bf = fit_closed(canon, np.ones(canon.shape[0]), copts, kopts, 0.6, max_radius)
        for mbr in members:
            s, f = islands[mbr]
            segs = [seg2 for seg in bf.segments for seg2 in seg.transformed(xform[mbr])]
            f.segments = _orient_like(segs, f.samples)
            f.locked = True
            s.repeat_group = gid
            made += 1
        gid += 1
    return made
