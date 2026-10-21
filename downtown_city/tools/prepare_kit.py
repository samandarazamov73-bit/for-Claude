"""Repack Quaternius Downtown City MegaKit glTF modules for this project.

- drops interior-only surfaces (interior walls/floors/roofs) and transparent glass
  (the fake-interior shader already renders reflections), which removes all
  alpha-blended geometry from the buildings;
- strips texture references (materials are replaced at runtime by name, see
  scripts/kit_library.gd), so the import never looks for missing PNGs;
- keeps POSITION / NORMAL / TEXCOORD_0 / COLOR_0 (wear mask) and repacks the
  binary buffer so only the used data ships with the project.

Usage: python3 tools/prepare_kit.py <src_dir> [<src_dir> ...] <dst_dir>
"""
import json
import os
import sys

import numpy as np

DROP_MATERIALS = {"MI_InteriorWall", "MI_InteriorFloor", "MI_InteriorRoof", "MI_Glass"}
KEEP_ATTRS = ("POSITION", "NORMAL", "TEXCOORD_0", "COLOR_0")
COMP = {5126: np.float32, 5123: np.uint16, 5125: np.uint32, 5121: np.uint8, 5122: np.int16, 5120: np.int8}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}


def read_accessor(j, bins, i):
    a = j["accessors"][i]
    bv = j["bufferViews"][a["bufferView"]]
    dt = np.dtype(COMP[a["componentType"]])
    n = NCOMP[a["type"]]
    elem = n * dt.itemsize
    stride = bv.get("byteStride", 0) or elem
    off = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    buf = bins[bv["buffer"]]
    rows = [buf[off + k * stride: off + k * stride + elem] for k in range(a["count"])] if stride != elem else None
    if rows is None:
        raw = buf[off: off + elem * a["count"]]
    else:
        raw = b"".join(rows)
    return np.frombuffer(raw, dtype=dt).reshape(a["count"], n), a


def _components(idx, nverts):
    """Connected components of a triangle list (union-find on vertex indices)."""
    parent = list(range(nverts))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for t in idx.reshape(-1, 3):
        ra, rb, rc = find(int(t[0])), find(int(t[1])), find(int(t[2]))
        parent[rb] = ra
        parent[find(rc)] = ra
    groups = {}
    for v in range(nverts):
        groups.setdefault(find(v), []).append(v)
    return list(groups.values())


def add_interior_primitive(j, bins, p, np_, add):
    """Fake-interior planes: rewrite UVs to a canonical room frame.

    TEXCOORD_0 : u = 0..1 left->right seen from outside, v = 0 (top) .. 1 (bottom)
    TEXCOORD_1 : room plane size in metres (width, height)
    COLOR_0    : r = random seed per plane (rooms differ inside one mesh)
    """
    pos, pa = read_accessor(j, bins, p["attributes"]["POSITION"])
    nrm, na = read_accessor(j, bins, p["attributes"]["NORMAL"])
    if "indices" in p:
        idx, ia = read_accessor(j, bins, p["indices"])
        idx = idx.reshape(-1)
    else:
        idx = np.arange(len(pos))
        ia = None
    pos = pos.astype(np.float64)
    uv = np.zeros((len(pos), 2), np.float32)
    size = np.zeros((len(pos), 2), np.float32)
    col = np.ones((len(pos), 4), np.float32)
    rng = np.random.default_rng(len(pos) * 7 + int(abs(pos.sum()) * 1000) % 100000)
    for g in _components(idx, len(pos)):
        P = pos[g]
        n = nrm[g].astype(np.float64).mean(0)
        n[1] = 0.0
        ln = np.linalg.norm(n)
        n = n / ln if ln > 1e-6 else np.array([0.0, 0.0, 1.0])
        right = np.cross([0.0, 1.0, 0.0], n)
        x = P @ right
        y = P[:, 1]
        w = max(x.max() - x.min(), 0.05)
        h = max(y.max() - y.min(), 0.05)
        uv[g, 0] = (x - x.min()) / w
        uv[g, 1] = 1.0 - (y - y.min()) / h
        size[g] = (w, h)
        col[g, 0] = rng.random()
    np_["attributes"]["POSITION"] = add(pos.astype(np.float32), pa, 34962)
    np_["attributes"]["NORMAL"] = add(nrm, na, 34962)
    meta = {"componentType": 5126, "count": len(pos), "type": "VEC2"}
    np_["attributes"]["TEXCOORD_0"] = add(uv, meta, 34962)
    np_["attributes"]["TEXCOORD_1"] = add(size, meta, 34962)
    np_["attributes"]["COLOR_0"] = add(col, {"componentType": 5126, "count": len(pos), "type": "VEC4"}, 34962)
    if ia is not None:
        np_["indices"] = add(idx.reshape(-1, 1), ia, 34963)


def convert(src, dst_dir):
    j = json.load(open(src))
    d = os.path.dirname(src)
    bins = [open(os.path.join(d, b["uri"]), "rb").read() for b in j["buffers"]]
    out = bytearray()
    views, accs = [], []

    def add(arr, a, target):
        nonlocal out
        while len(out) % 4:
            out += b"\0"
        data = np.ascontiguousarray(arr).tobytes()
        views.append({"buffer": 0, "byteOffset": len(out), "byteLength": len(data), "target": target})
        out += data
        na = {"bufferView": len(views) - 1, "componentType": a["componentType"], "count": a["count"], "type": a["type"]}
        for k in ("min", "max", "normalized"):
            if k in a:
                na[k] = a[k]
        accs.append(na)
        return len(accs) - 1

    used_mats = {}
    materials = []
    meshes = []
    for m in j["meshes"]:
        prims = []
        for p in m["primitives"]:
            mname = j["materials"][p["material"]]["name"] if "material" in p else "MI_Default"
            if mname in DROP_MATERIALS:
                continue
            np_ = {"attributes": {}, "mode": p.get("mode", 4)}
            if mname.startswith("MI_FakeInterior"):
                add_interior_primitive(j, bins, p, np_, add)
            else:
                for k in KEEP_ATTRS:
                    if k in p["attributes"]:
                        arr, a = read_accessor(j, bins, p["attributes"][k])
                        np_["attributes"][k] = add(arr, a, 34962)
                if "indices" in p:
                    arr, a = read_accessor(j, bins, p["indices"])
                    np_["indices"] = add(arr, a, 34963)
            if mname not in used_mats:
                used_mats[mname] = len(materials)
                mat = {"name": mname, "pbrMetallicRoughness": {"baseColorFactor": [0.8, 0.8, 0.8, 1.0], "metallicFactor": 0.0, "roughnessFactor": 0.8}}
                materials.append(mat)
            np_["material"] = used_mats[mname]
            prims.append(np_)
        meshes.append({"name": m.get("name", "mesh"), "primitives": prims})

    name = os.path.splitext(os.path.basename(src))[0]
    if not any(m["primitives"] for m in meshes):
        return name, 0  # interior-only module, nothing visible from the street
    nj = {
        "asset": {"version": "2.0", "generator": "downtown_city prepare_kit.py"},
        "scene": 0,
        "scenes": [{"nodes": list(range(len(j["nodes"])))}],
        "nodes": [{k: v for k, v in n.items() if k in ("mesh", "name", "translation", "rotation", "scale", "matrix")} for n in j["nodes"]],
        "meshes": meshes,
        "materials": materials,
        "accessors": accs,
        "bufferViews": views,
        "buffers": [{"uri": name + ".bin", "byteLength": len(out)}],
    }
    for n in nj["nodes"]:
        n["name"] = name
    with open(os.path.join(dst_dir, name + ".gltf"), "w") as f:
        json.dump(nj, f, separators=(",", ":"))
    with open(os.path.join(dst_dir, name + ".bin"), "wb") as f:
        f.write(out)
    return name, len(out)


if __name__ == "__main__":
    *srcs, dst = sys.argv[1:]
    os.makedirs(dst, exist_ok=True)
    done = set()
    total = 0
    for s in srcs:
        for fn in sorted(os.listdir(s)):
            if fn.endswith(".gltf") and fn not in done:
                done.add(fn)
                name, size = convert(os.path.join(s, fn), dst)
                total += size
                if size == 0:
                    print("skipped (interior only):", name)
    print(f"{len(done)} modules, {total/1e6:.1f} MB of geometry")
