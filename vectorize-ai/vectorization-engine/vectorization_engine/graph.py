"""The Vector Graph – a planar subdivision of the image.

* **Node**      – a junction where three or more regions (or the image
                  border) meet.
* **Interface** – the boundary between exactly two regions, stored **once**
                  as a chain of curve segments from node to node (or as a
                  closed curve). The region on the *left* of the travel
                  direction is ``left``; ``-1`` means outside the image.
* **Shape**     – one connected colour region. Its boundary is a list of
                  loops (outer first, then holes); each loop is a cyclic list
                  of ``(interface id, reversed)`` half-edges walked with the
                  shape on the left.

Because neighbouring shapes reference the very same interface, the output
can never contain gaps or overlaps between them. Transparent regions are
kept as shapes with ``transparent=True`` (never drawn) so the containment
hierarchy is complete."""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Iterable

import numpy as np

from geometry_engine import Segment, path_flatten, reverse_path, segment_from_json, signed_area

HalfEdge = tuple[int, bool]  # (interface id, reversed)


@dataclass
class Node:
    id: int
    x: float
    y: float
    border: bool = False

    @property
    def pt(self) -> tuple[float, float]:
        return (self.x, self.y)


@dataclass
class Interface:
    id: int
    start: int  # node id (-1 for closed interfaces)
    end: int
    left: int  # shape id or -1 (outside)
    right: int
    segments: list[Segment] = field(default_factory=list)
    closed: bool = False
    border: bool = False
    locked: bool = False
    # transient data used while building (not serialised)
    raw: np.ndarray | None = None  # crack vertex polyline (integer coords)
    cracks: np.ndarray | None = None
    samples: np.ndarray | None = None
    weights: np.ndarray | None = None
    contrast: float = 255.0
    raw_area2: float = 0.0  # 2x shoelace partial sum of ``raw``

    def other(self, shape_id: int) -> int:
        return self.right if self.left == shape_id else self.left

    def path(self, reversed_: bool = False) -> list[Segment]:
        return reverse_path(self.segments) if reversed_ else list(self.segments)

    def start_point(self) -> tuple[float, float]:
        if self.segments:
            return self.segments[0].start()
        return (float(self.raw[0][0]), float(self.raw[0][1]))


@dataclass
class Shape:
    id: int
    color: int  # palette index (-1 = transparent)
    loops: list[list[HalfEdge]] = field(default_factory=list)
    area: float = 0.0  # pixel area at working resolution
    bbox: tuple[float, float, float, float] = (0.0, 0.0, 0.0, 0.0)
    parent: int = -1
    parent_hole: int = -1
    depth: int = 0
    transparent: bool = False
    primitive: dict | None = None
    symmetry: dict | None = None
    repeat_group: int | None = None
    stack_holes: list[int] = field(default_factory=list)


@dataclass
class VectorGraph:
    width: int
    height: int
    palette: list[tuple[int, int, int, int]]
    palette_counts: list[int]
    nodes: dict[int, Node] = field(default_factory=dict)
    interfaces: dict[int, Interface] = field(default_factory=dict)
    shapes: dict[int, Shape] = field(default_factory=dict)
    stats: dict = field(default_factory=dict)
    scale: float = 1.0  # working / original
    original_size: tuple[int, int] = (0, 0)
    order: list[int] = field(default_factory=list)

    # ------------------------------------------------------------------
    # geometry access
    # ------------------------------------------------------------------
    def loop_segments(self, loop: Iterable[HalfEdge]) -> list[Segment]:
        out: list[Segment] = []
        for iid, rev in loop:
            out.extend(self.interfaces[iid].path(rev))
        return out

    def loop_polygon(self, loop: Iterable[HalfEdge], tol: float = 0.25) -> np.ndarray:
        return path_flatten(self.loop_segments(loop), tol)

    def drawable_shapes(self) -> list[Shape]:
        return [self.shapes[i] for i in self.order if i in self.shapes and not self.shapes[i].transparent]

    def shape_loops(self, shape: Shape, stacked: bool) -> list[list[HalfEdge]]:
        if not stacked:
            return shape.loops
        return [shape.loops[0]] + [shape.loops[i] for i in shape.stack_holes if i < len(shape.loops)]

    def color_of(self, shape: Shape) -> tuple[int, int, int, int]:
        return tuple(self.palette[shape.color]) if shape.color >= 0 else (0, 0, 0, 0)

    # ------------------------------------------------------------------
    # topology maintenance
    # ------------------------------------------------------------------
    def half_edges_of(self, shape_id: int) -> list[HalfEdge]:
        out = []
        for iface in self.interfaces.values():
            if iface.left == shape_id:
                out.append((iface.id, False))
            if iface.right == shape_id:
                out.append((iface.id, True))
        return out

    def _endpoints(self, he: HalfEdge) -> tuple[int, int]:
        f = self.interfaces[he[0]]
        return (f.end, f.start) if he[1] else (f.start, f.end)

    def _dir(self, he: HalfEdge, at_start: bool) -> np.ndarray:
        f = self.interfaces[he[0]]
        rev = he[1]
        if f.segments:
            if at_start:
                t = f.segments[-1].end_tangent() if rev else f.segments[0].start_tangent()
                v = np.array(t) * (-1 if rev else 1)
            else:
                t = f.segments[0].start_tangent() if rev else f.segments[-1].end_tangent()
                v = np.array(t) * (-1 if rev else 1)
            return v
        raw = f.raw[::-1] if rev else f.raw
        v = (raw[1] - raw[0]) if at_start else (raw[-1] - raw[-2])
        n = float(np.hypot(*v)) or 1.0
        return np.asarray(v, dtype=np.float64) / n

    def assemble_loops(self, half_edges: list[HalfEdge]) -> list[list[HalfEdge]]:
        """Chain half-edges into closed loops. At a node with several
        candidate continuations the sharpest left turn is taken, which keeps
        the walk hugging the region (4-connectivity semantics)."""
        loops: list[list[HalfEdge]] = []
        by_start: dict[int, list[HalfEdge]] = {}
        for he in half_edges:
            f = self.interfaces[he[0]]
            if f.closed:
                loops.append([he])
                continue
            s, _ = self._endpoints(he)
            by_start.setdefault(s, []).append(he)
        used: set[HalfEdge] = set()
        for he0 in [h for h in half_edges if not self.interfaces[h[0]].closed]:
            if he0 in used:
                continue
            loop = [he0]
            used.add(he0)
            cur = he0
            guard = 0
            while True:
                guard += 1
                if guard > len(half_edges) + 5:
                    break
                _, end_node = self._endpoints(cur)
                cands = [h for h in by_start.get(end_node, []) if h not in used or h == he0]
                if not cands:
                    break
                if len(cands) > 1:
                    din = self._dir(cur, at_start=False)
                    best, best_score = None, -1e9
                    for h in cands:
                        dout = self._dir(h, at_start=True)
                        cross = din[0] * dout[1] - din[1] * dout[0]
                        dot = din[0] * dout[0] + din[1] * dout[1]
                        score = -math.atan2(cross, dot)
                        if abs(abs(score) - math.pi) < 1e-6:
                            score = -math.pi
                        if score > best_score:
                            best, best_score = h, score
                    nxt = best
                else:
                    nxt = cands[0]
                if nxt == he0:
                    break
                loop.append(nxt)
                used.add(nxt)
                cur = nxt
            loops.append(loop)
        return loops

    def loop_area2(self, loop: list[HalfEdge]) -> float:
        """Twice the signed area of a loop (raw crack geometry if present)."""
        total = 0.0
        if all(self.interfaces[i].raw is not None for i, _ in loop):
            for iid, rev in loop:
                a = self.interfaces[iid].raw_area2
                total += -a if rev else a
            return total
        return 2.0 * signed_area(self.loop_polygon(loop))

    def order_loops(self, loops: list[list[HalfEdge]]) -> list[list[HalfEdge]]:
        if len(loops) <= 1:
            return loops
        areas = [abs(self.loop_area2(lp)) for lp in loops]
        k = int(np.argmax(areas))
        return [loops[k]] + loops[:k] + loops[k + 1 :]

    def rebuild_shape_loops(self, shape_ids: Iterable[int] | None = None) -> None:
        ids = list(self.shapes) if shape_ids is None else list(shape_ids)
        per: dict[int, list[HalfEdge]] = {i: [] for i in ids}
        for f in self.interfaces.values():
            if f.left in per:
                per[f.left].append((f.id, False))
            if f.right in per:
                per[f.right].append((f.id, True))
        for sid in ids:
            self.shapes[sid].loops = self.order_loops(self.assemble_loops(per[sid]))

    def compute_hierarchy(self) -> None:
        """Parent = the shape whose hole contains this shape. Shapes adjacent
        across their outer loops are siblings and share the parent."""
        side_loop: dict[tuple[int, int], int] = {}
        for s in self.shapes.values():
            for li, loop in enumerate(s.loops):
                for iid, _ in loop:
                    side_loop[(iid, s.id)] = li
        uf = {sid: sid for sid in self.shapes}

        def find(x):
            while uf[x] != x:
                uf[x] = uf[uf[x]]
                x = uf[x]
            return x

        hole_parent: dict[int, tuple[int, int]] = {}
        root_groups: set[int] = set()
        pending: list[tuple[int, int, int]] = []
        for f in self.interfaces.values():
            a, b = f.left, f.right
            la = side_loop.get((f.id, a), 0) if a >= 0 else None
            lb = side_loop.get((f.id, b), 0) if b >= 0 else None
            if a >= 0 and b >= 0 and la == 0 and lb == 0:
                ra, rb = find(a), find(b)
                if ra != rb:
                    uf[ra] = rb
            elif a >= 0 and b >= 0:
                if la and lb == 0:
                    pending.append((b, a, la))
                elif lb and la == 0:
                    pending.append((a, b, lb))
            elif a >= 0 and la == 0:
                pending.append((a, -1, -1))
            elif b >= 0 and lb == 0:
                pending.append((b, -1, -1))
        for child, par, hole in pending:
            g = find(child)
            if par < 0:
                root_groups.add(g)
            else:
                hole_parent[g] = (par, hole)
        for s in self.shapes.values():
            g = find(s.id)
            if g in hole_parent and g not in root_groups:
                s.parent, s.parent_hole = hole_parent[g]
            else:
                s.parent, s.parent_hole = -1, -1
        self._finish_hierarchy()

    def _finish_hierarchy(self) -> None:
        children: dict[int, list[int]] = {}
        for s in self.shapes.values():
            children.setdefault(s.parent, []).append(s.id)
        order: list[int] = []
        sub_transp: dict[int, bool] = {}

        def visit(sid: int, depth: int):
            # iterative DFS (deep nesting must not hit the recursion limit)
            stack = [(sid, depth, False)]
            while stack:
                cur, d, done = stack.pop()
                s = self.shapes[cur]
                if done:
                    t = s.transparent or any(sub_transp[c] for c in children.get(cur, []))
                    sub_transp[cur] = t
                    continue
                s.depth = d
                order.append(cur)
                stack.append((cur, d, True))
                kids = sorted(children.get(cur, []), key=lambda k: -self.shapes[k].area)
                for k in reversed(kids):
                    stack.append((k, d + 1, False))

        for root in sorted(children.get(-1, []), key=lambda k: -self.shapes[k].area):
            visit(root, 0)
        # shapes not reached (inconsistent topology) are appended as roots
        for sid in self.shapes:
            if sid not in sub_transp:
                visit(sid, 0)
        self.order = order
        for s in self.shapes.values():
            holes = []
            for li in range(1, len(s.loops)):
                kids = [c for c in children.get(s.id, []) if self.shapes[c].parent_hole == li]
                if not kids or any(sub_transp.get(c, False) for c in kids):
                    holes.append(li)
            s.stack_holes = holes

    def compute_bboxes(self) -> None:
        for s in self.shapes.values():
            if not s.loops:
                continue
            poly = self.loop_polygon(s.loops[0], 0.5)
            if poly.shape[0]:
                s.bbox = (float(poly[:, 0].min()), float(poly[:, 1].min()), float(poly[:, 0].max()), float(poly[:, 1].max()))

    def remove_unused(self) -> None:
        """Drop interfaces separating two non-drawn regions and orphan nodes."""
        used_nodes: set[int] = set()
        for f in self.interfaces.values():
            used_nodes.update(n for n in (f.start, f.end) if n >= 0)
        self.nodes = {k: v for k, v in self.nodes.items() if k in used_nodes}

    # ------------------------------------------------------------------
    # serialisation
    # ------------------------------------------------------------------
    def to_json(self, include_stats: bool = True) -> dict:
        ifaces = []
        for f in self.interfaces.values():
            p0 = f.start_point()
            ifaces.append(
                {
                    "id": f.id,
                    "start": f.start,
                    "end": f.end,
                    "left": f.left,
                    "right": f.right,
                    "closed": f.closed,
                    "border": f.border,
                    "p0": [round(p0[0], 3), round(p0[1], 3)],
                    "segs": [s.to_json() for s in f.segments],
                }
            )
        shapes = []
        for sid in self.order:
            s = self.shapes[sid]
            d = {
                "id": s.id,
                "color": s.color,
                "transparent": s.transparent,
                "loops": [[[i, 1 if r else 0] for i, r in lp] for lp in s.loops],
                "area": round(s.area, 2),
                "bbox": [round(v, 2) for v in s.bbox],
                "parent": s.parent,
                "parentHole": s.parent_hole,
                "depth": s.depth,
                "stackHoles": s.stack_holes,
            }
            if s.primitive:
                d["primitive"] = s.primitive
            if s.symmetry:
                d["symmetry"] = s.symmetry
            if s.repeat_group is not None:
                d["repeat"] = s.repeat_group
            shapes.append(d)
        out = {
            "version": 1,
            "width": self.width,
            "height": self.height,
            "scale": self.scale,
            "original": list(self.original_size),
            "palette": [
                {"rgba": list(map(int, c)), "hex": "#%02x%02x%02x" % tuple(int(v) for v in c[:3]), "count": int(n)}
                for c, n in zip(self.palette, self.palette_counts)
            ],
            "nodes": [[n.id, round(n.x, 3), round(n.y, 3)] for n in self.nodes.values()],
            "interfaces": ifaces,
            "shapes": shapes,
            "order": self.order,
        }
        if include_stats:
            out["stats"] = self.stats
        return out

    @classmethod
    def from_json(cls, d: dict) -> "VectorGraph":
        g = cls(
            width=int(d["width"]),
            height=int(d["height"]),
            palette=[tuple(p["rgba"]) for p in d["palette"]],
            palette_counts=[int(p.get("count", 0)) for p in d["palette"]],
            stats=d.get("stats", {}),
            scale=float(d.get("scale", 1.0)),
            original_size=tuple(d.get("original", (d["width"], d["height"]))),
        )
        for nid, x, y in d["nodes"]:
            g.nodes[int(nid)] = Node(int(nid), float(x), float(y))
        for fd in d["interfaces"]:
            segs: list[Segment] = []
            cur = (float(fd["p0"][0]), float(fd["p0"][1]))
            for item in fd["segs"]:
                s = segment_from_json(item, cur)
                segs.append(s)
                cur = s.end()
            g.interfaces[int(fd["id"])] = Interface(
                id=int(fd["id"]),
                start=int(fd["start"]),
                end=int(fd["end"]),
                left=int(fd["left"]),
                right=int(fd["right"]),
                segments=segs,
                closed=bool(fd["closed"]),
                border=bool(fd.get("border", False)),
            )
        for sd in d["shapes"]:
            s = Shape(
                id=int(sd["id"]),
                color=int(sd["color"]),
                loops=[[(int(i), bool(r)) for i, r in lp] for lp in sd["loops"]],
                area=float(sd.get("area", 0)),
                bbox=tuple(sd.get("bbox", (0, 0, 0, 0))),
                parent=int(sd.get("parent", -1)),
                parent_hole=int(sd.get("parentHole", -1)),
                depth=int(sd.get("depth", 0)),
                transparent=bool(sd.get("transparent", False)),
                primitive=sd.get("primitive"),
                symmetry=sd.get("symmetry"),
                repeat_group=sd.get("repeat"),
                stack_holes=list(sd.get("stackHoles", [])),
            )
            g.shapes[s.id] = s
        g.order = [int(i) for i in d.get("order", list(g.shapes))]
        return g

    # ------------------------------------------------------------------
    # validation
    # ------------------------------------------------------------------
    def validate(self, eps: float = 1e-3) -> list[str]:
        problems: list[str] = []
        for f in self.interfaces.values():
            if not f.segments:
                problems.append(f"interface {f.id} has no geometry")
                continue
            for a, b in zip(f.segments[:-1], f.segments[1:]):
                if math.dist(a.end(), b.start()) > eps:
                    problems.append(f"interface {f.id} is discontinuous")
                    break
            if f.closed:
                if math.dist(f.segments[0].start(), f.segments[-1].end()) > eps:
                    problems.append(f"closed interface {f.id} does not close")
            else:
                for nid, p in ((f.start, f.segments[0].start()), (f.end, f.segments[-1].end())):
                    n = self.nodes.get(nid)
                    if n is None or math.dist(n.pt, p) > eps:
                        problems.append(f"interface {f.id} is detached from node {nid}")
        for s in self.shapes.values():
            for li, loop in enumerate(s.loops):
                segs = self.loop_segments(loop)
                if not segs:
                    problems.append(f"shape {s.id} loop {li} is empty")
                    continue
                if math.dist(segs[0].start(), segs[-1].end()) > eps:
                    problems.append(f"shape {s.id} loop {li} is open")
                for a, b in zip(segs[:-1], segs[1:]):
                    if math.dist(a.end(), b.start()) > eps:
                        problems.append(f"shape {s.id} loop {li} has a gap")
                        break
        return problems
