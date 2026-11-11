"""Stage 4 — boundary topology.

Region boundaries are traced on the *crack grid* (pixel edges), so the
boundary between two regions is a single polyline shared by both of them.

* A crack exists between every pair of 4-adjacent pixels (including the
  virtual "outside" border) with different region ids.
* Each crack is oriented so the higher region id lies on its left; along a
  boundary between two regions every crack therefore points the same way.
* Vertices where three or more cracks meet (and the image corners) are
  junctions. Maximal crack chains between junctions – or closed cycles – are
  the interfaces of the Vector Graph.

Crack extraction and successor linking are vectorised with NumPy; chain
walking is a tight loop over plain Python lists."""
from __future__ import annotations

import numpy as np

from .graph import Interface, Node, Shape, VectorGraph


class CrackField:
    """All cracks of a region map with orientation and adjacency."""

    def __init__(self, regions: np.ndarray):
        h, w = regions.shape
        self.h, self.w = h, w
        w1 = w + 1
        self.w1 = w1
        p = np.zeros((h + 2, w + 2), dtype=np.int32)
        p[1:-1, 1:-1] = regions
        # vertical cracks: between pixel (r, c-1) [west] and (r, c) [east]
        west, east = p[1:-1, 0 : w + 1], p[1:-1, 1 : w + 2]
        vr, vc = np.nonzero(west != east)
        vw, ve = west[vr, vc], east[vr, vc]
        south = ve > vw
        top, bottom = vr * w1 + vc, (vr + 1) * w1 + vc
        # horizontal cracks: between pixel (r-1, c) [north] and (r, c) [south]
        north, southp = p[0 : h + 1, 1 : w + 1], p[1 : h + 2, 1 : w + 1]
        hr, hc = np.nonzero(north != southp)
        hn, hs = north[hr, hc], southp[hr, hc]
        eastd = hn > hs
        lv, rv = hr * w1 + hc, hr * w1 + hc + 1

        self.nv = vr.shape[0]
        self.kind = np.concatenate([np.zeros(self.nv, np.int8), np.ones(hr.shape[0], np.int8)])
        self.r = np.concatenate([vr, hr]).astype(np.int64)
        self.c = np.concatenate([vc, hc]).astype(np.int64)
        self.tail = np.concatenate([np.where(south, top, bottom), np.where(eastd, lv, rv)]).astype(np.int64)
        self.head = np.concatenate([np.where(south, bottom, top), np.where(eastd, rv, lv)]).astype(np.int64)
        # "a" = west/north pixel region, "b" = east/south pixel region
        self.ra = np.concatenate([vw, hn]).astype(np.int64)
        self.rb = np.concatenate([ve, hs]).astype(np.int64)
        self.left = np.maximum(self.ra, self.rb)
        self.right = np.minimum(self.ra, self.rb)
        self.n = self.kind.shape[0]

    def vertex_xy(self, v: np.ndarray) -> np.ndarray:
        return np.stack([v % self.w1, v // self.w1], 1).astype(np.float64)

    def midpoints(self) -> np.ndarray:
        """Crack midpoints in pixel-corner coordinates."""
        x = np.where(self.kind == 0, self.c, self.c + 0.5)
        y = np.where(self.kind == 0, self.r + 0.5, self.r)
        return np.stack([x, y], 1).astype(np.float64)


def trace_chains(cf: CrackField) -> tuple[list[np.ndarray], list[bool], np.ndarray]:
    nverts = (cf.h + 1) * cf.w1
    deg = np.bincount(cf.tail, minlength=nverts) + np.bincount(cf.head, minlength=nverts)
    brk = deg >= 3
    for v in (0, cf.w, cf.h * cf.w1, cf.h * cf.w1 + cf.w):  # image corners
        if deg[v] > 0:
            brk[v] = True
    tail_at = np.full(nverts, -1, dtype=np.int64)
    tail_at[cf.tail] = np.arange(cf.n)
    nxt = tail_at[cf.head]
    nxt[brk[cf.head]] = -1
    nxt_l = nxt.tolist()
    visited = bytearray(cf.n)
    chains: list[np.ndarray] = []
    closed: list[bool] = []
    starts = np.nonzero(brk[cf.tail])[0].tolist()
    for c in starts:
        chain = [c]
        visited[c] = 1
        d = nxt_l[c]
        while d >= 0:
            chain.append(d)
            visited[d] = 1
            d = nxt_l[d]
        chains.append(np.asarray(chain, dtype=np.int64))
        closed.append(False)
    remaining = [i for i in range(cf.n) if not visited[i]] if len(starts) < cf.n else []
    for c in remaining:
        if visited[c]:
            continue
        chain = [c]
        visited[c] = 1
        d = nxt_l[c]
        while d != c and d >= 0:
            chain.append(d)
            visited[d] = 1
            d = nxt_l[d]
        chains.append(np.asarray(chain, dtype=np.int64))
        closed.append(True)
    return chains, closed, brk


def build_topology(regions: np.ndarray, region_color: np.ndarray, palette: np.ndarray, counts: np.ndarray, fills: dict | None = None) -> tuple[VectorGraph, CrackField]:
    h, w = regions.shape
    cf = CrackField(regions)
    chains, closed, _ = trace_chains(cf)
    g = VectorGraph(width=w, height=h, palette=[tuple(int(v) for v in c) for c in palette], palette_counts=[int(v) for v in counts])

    area = np.bincount(regions.ravel(), minlength=region_color.shape[0])
    for rid in range(1, region_color.shape[0]):
        col = int(region_color[rid])
        g.shapes[rid - 1] = Shape(id=rid - 1, color=col if col >= 0 else -1, area=float(area[rid]), transparent=col < 0, fill=(fills or {}).get(rid))

    node_of: dict[int, int] = {}

    def node(v: int) -> int:
        nid = node_of.get(v)
        if nid is None:
            nid = len(node_of)
            node_of[v] = nid
            x, y = v % cf.w1, v // cf.w1
            g.nodes[nid] = Node(nid, float(x), float(y), border=(x == 0 or x == w or y == 0 or y == h))
        return nid

    for iid, (chain, is_closed) in enumerate(zip(chains, closed)):
        verts = np.concatenate([cf.tail[chain[:1]], cf.head[chain]])
        xy = cf.vertex_xy(verts)
        x, y = xy[:, 0], xy[:, 1]
        a2 = float((x[:-1] * y[1:] - x[1:] * y[:-1]).sum())
        lreg, rreg = int(cf.left[chain[0]]), int(cf.right[chain[0]])
        f = Interface(
            id=iid,
            start=-1 if is_closed else node(int(verts[0])),
            end=-1 if is_closed else node(int(verts[-1])),
            left=lreg - 1,
            right=rreg - 1,
            closed=is_closed,
            border=rreg == 0,
        )
        f.raw = xy
        f.cracks = chain
        f.raw_area2 = a2
        g.interfaces[iid] = f

    g.rebuild_shape_loops()
    g.compute_hierarchy()
    return g, cf
