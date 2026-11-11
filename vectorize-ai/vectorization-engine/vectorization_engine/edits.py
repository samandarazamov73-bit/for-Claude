"""Editor operations applied to a Vector Graph.

The web editor keeps an :class:`EditState` (undoable on the client, stored
on the server). Exports and previews apply it with :func:`apply_edits`:

* palette edits: recolour, add, delete (shapes become transparent), merge;
* region edits: recolour single shapes, delete them, mark background;
* region merges: true geometric union – shared interfaces between the merged
  shapes are removed and the loops are re-assembled;
* optional merging of adjacent shapes that ended up with the same colour.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from .graph import VectorGraph

MAX_LIST = 200_000


@dataclass
class EditState:
    palette_overrides: dict[int, tuple[int, int, int, int]] = field(default_factory=dict)
    added_colors: list[tuple[int, int, int, int]] = field(default_factory=list)
    deleted_colors: set[int] = field(default_factory=set)
    merged_colors: dict[int, int] = field(default_factory=dict)
    shape_colors: dict[int, int] = field(default_factory=dict)
    hidden_shapes: set[int] = field(default_factory=set)
    background_shapes: set[int] = field(default_factory=set)
    region_merges: list[list[int]] = field(default_factory=list)

    def is_empty(self) -> bool:
        return not any(
            (self.palette_overrides, self.added_colors, self.deleted_colors, self.merged_colors, self.shape_colors, self.hidden_shapes, self.background_shapes, self.region_merges)
        )

    @staticmethod
    def _rgba(v) -> tuple[int, int, int, int]:
        if not isinstance(v, (list, tuple)) or len(v) not in (3, 4):
            raise ValueError("colour must be [r, g, b] or [r, g, b, a]")
        vals = [int(x) for x in v] + ([255] if len(v) == 3 else [])
        if any(x < 0 or x > 255 for x in vals):
            raise ValueError("colour components must be 0..255")
        return tuple(vals)  # type: ignore[return-value]

    @classmethod
    def from_json(cls, d: dict | None) -> "EditState":
        d = d or {}
        e = cls()
        for k, v in (d.get("paletteOverrides") or {}).items():
            e.palette_overrides[int(k)] = cls._rgba(v)
        e.added_colors = [cls._rgba(v) for v in (d.get("addedColors") or [])][:1024]
        e.deleted_colors = {int(x) for x in (d.get("deletedColors") or [])}
        e.merged_colors = {int(k): int(v) for k, v in (d.get("mergedColors") or {}).items()}
        e.shape_colors = {int(k): int(v) for k, v in (d.get("shapeColors") or {}).items()}
        e.hidden_shapes = {int(x) for x in (d.get("hiddenShapes") or [])}
        e.background_shapes = {int(x) for x in (d.get("backgroundShapes") or [])}
        e.region_merges = [[int(x) for x in grp] for grp in (d.get("regionMerges") or []) if len(grp) >= 2]
        total = len(e.shape_colors) + len(e.hidden_shapes) + len(e.background_shapes) + sum(len(g) for g in e.region_merges)
        if total > MAX_LIST:
            raise ValueError("edit state is too large")
        return e

    def to_json(self) -> dict:
        return {
            "paletteOverrides": {str(k): list(v) for k, v in self.palette_overrides.items()},
            "addedColors": [list(c) for c in self.added_colors],
            "deletedColors": sorted(self.deleted_colors),
            "mergedColors": {str(k): v for k, v in self.merged_colors.items()},
            "shapeColors": {str(k): v for k, v in self.shape_colors.items()},
            "hiddenShapes": sorted(self.hidden_shapes),
            "backgroundShapes": sorted(self.background_shapes),
            "regionMerges": self.region_merges,
        }


def _resolve(c: int, merged: dict[int, int]) -> int:
    seen = set()
    while c in merged and c not in seen:
        seen.add(c)
        c = merged[c]
    return c


def merge_shapes(g: VectorGraph, groups: list[list[int]]) -> None:
    """Geometric union of shape groups (in place)."""
    rep: dict[int, int] = {}
    for grp in groups:
        members = [s for s in grp if s in g.shapes]
        if len(members) < 2:
            continue
        root = rep.get(members[0], members[0])
        for m in members:
            r = rep.get(m, m)
            for k, v in list(rep.items()):
                if v == r:
                    rep[k] = root
            rep[m] = root
    if not rep:
        return
    affected = set(rep.values())
    for f in list(g.interfaces.values()):
        lf, rt = rep.get(f.left, f.left), rep.get(f.right, f.right)
        if lf == rt:
            del g.interfaces[f.id]
            continue
        f.left, f.right = lf, rt
    for sid, r in rep.items():
        if sid != r and sid in g.shapes:
            g.shapes[r].area += g.shapes[sid].area
            del g.shapes[sid]
    for r in affected:
        s = g.shapes[r]
        s.primitive = None
        s.symmetry = None
    g.rebuild_shape_loops(affected)
    g.remove_unused()


def apply_edits(graph: VectorGraph, edits: EditState | None, *, merge_same_color: bool = False) -> VectorGraph:
    g = VectorGraph.from_json(graph.to_json())  # deep copy
    if edits is None or (edits.is_empty() and not merge_same_color):
        return g
    k0 = len(g.palette)
    palette = list(g.palette) + list(edits.added_colors)
    counts = list(g.palette_counts) + [0] * len(edits.added_colors)
    for idx, col in edits.palette_overrides.items():
        if 0 <= idx < len(palette):
            palette[idx] = col
    g.palette, g.palette_counts = palette, counts
    nk = len(palette)
    for s in g.shapes.values():
        if s.transparent:
            continue
        c = edits.shape_colors.get(s.id, s.color)
        c = _resolve(c, edits.merged_colors)
        if not (0 <= c < nk):
            c = s.color
        s.color = c
        if c in edits.deleted_colors or s.id in edits.hidden_shapes or s.id in edits.background_shapes:
            s.transparent = True
            s.primitive = None
    del k0
    if edits.region_merges:
        groups = []
        for grp in edits.region_merges:
            members = [x for x in grp if x in g.shapes and not g.shapes[x].transparent]
            if len(members) >= 2:
                col = g.shapes[members[0]].color
                for m in members:
                    g.shapes[m].color = col
                groups.append(members)
        merge_shapes(g, groups)
    if merge_same_color:
        merge_same_colored_neighbours(g)
    g.compute_hierarchy()
    g.compute_bboxes()
    return g


def merge_same_colored_neighbours(g: VectorGraph) -> None:
    """Union adjacent shapes with identical colour (also merges adjacent
    transparent areas), producing the simplest equivalent geometry."""
    parent = {sid: sid for sid in g.shapes}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for f in g.interfaces.values():
        if f.left < 0 or f.right < 0:
            continue
        a, b = g.shapes[f.left], g.shapes[f.right]
        same = (a.transparent and b.transparent) or (not a.transparent and not b.transparent and a.color == b.color)
        if same:
            ra, rb = find(a.id), find(b.id)
            if ra != rb:
                parent[rb] = ra
    groups: dict[int, list[int]] = {}
    for sid in g.shapes:
        groups.setdefault(find(sid), []).append(sid)
    merge_shapes(g, [grp for grp in groups.values() if len(grp) > 1])
