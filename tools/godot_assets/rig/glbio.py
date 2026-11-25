"""Minimal GLB reader helpers (numpy)."""
import json, struct
import numpy as np
COMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}
DT = {5126: "<f4", 5125: "<u4", 5123: "<u2", 5121: "u1", 5120: "i1", 5122: "<i2"}

def load(fn):
    data = open(fn, "rb").read()
    ln, _ = struct.unpack_from("<II", data, 12)
    j = json.loads(data[20:20 + ln])
    off = 20 + ln
    bl, _ = struct.unpack_from("<II", data, off)
    return j, bytes(data[off + 8:off + 8 + bl])

def acc(j, b, ai):
    a = j["accessors"][ai]
    bv = j["bufferViews"][a["bufferView"]]
    nc = COMP[a["type"]]
    dt = np.dtype(DT[a["componentType"]])
    start = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    stride = bv.get("byteStride", 0) or nc * dt.itemsize
    if stride == nc * dt.itemsize:
        arr = np.frombuffer(b, dt, a["count"] * nc, start).reshape(a["count"], nc)
    else:
        arr = np.stack([np.frombuffer(b, dt, nc, start + i * stride) for i in range(a["count"])])
    if a.get("normalized"):
        arr = arr.astype(np.float32) / np.iinfo(dt).max
    return arr.copy()

def quat_mat(q):
    x, y, z, w = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])

def mat_quat(m):
    t = np.trace(m)
    if t > 0:
        s = np.sqrt(t + 1.0) * 2; w = 0.25 * s
        x = (m[2, 1] - m[1, 2]) / s; y = (m[0, 2] - m[2, 0]) / s; z = (m[1, 0] - m[0, 1]) / s
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = np.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        w = (m[2, 1] - m[1, 2]) / s; x = 0.25 * s; y = (m[0, 1] + m[1, 0]) / s; z = (m[0, 2] + m[2, 0]) / s
    elif m[1, 1] > m[2, 2]:
        s = np.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        w = (m[0, 2] - m[2, 0]) / s; x = (m[0, 1] + m[1, 0]) / s; y = 0.25 * s; z = (m[1, 2] + m[2, 1]) / s
    else:
        s = np.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
        w = (m[1, 0] - m[0, 1]) / s; x = (m[0, 2] + m[2, 0]) / s; y = (m[1, 2] + m[2, 1]) / s; z = 0.25 * s
    q = np.array([x, y, z, w]); return q / np.linalg.norm(q)

def trs(n):
    M = np.eye(4)
    M[:3, :3] = quat_mat(n.get("rotation", [0, 0, 0, 1])) @ np.diag(n.get("scale", [1, 1, 1]))
    M[:3, 3] = n.get("translation", [0, 0, 0])
    return M

def skeleton(j):
    """joints (node idx list), names, parent index within joints (-1), local rest mats, global rest mats, IBMs"""
    sk = j["skins"][0]
    joints = sk["joints"]
    parent_node = {}
    for i, n in enumerate(j["nodes"]):
        for c in n.get("children", []):
            parent_node[c] = i
    jidx = {n: k for k, n in enumerate(joints)}
    par = [jidx.get(parent_node.get(n), -1) for n in joints]
    names = [j["nodes"][n].get("name") for n in joints]
    loc = [trs(j["nodes"][n]) for n in joints]
    # global including non-joint ancestors
    def glob(n):
        M = trs(j["nodes"][n]); p = parent_node.get(n)
        while p is not None:
            M = trs(j["nodes"][p]) @ M; p = parent_node.get(p)
        return M
    G = [glob(n) for n in joints]
    return joints, names, par, loc, G
