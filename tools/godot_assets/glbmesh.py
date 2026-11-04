import json, struct
import numpy as np
def load(path):
    b = open(path, "rb").read(); off = 12; js = None; binc = None
    while off < len(b):
        ln, typ = struct.unpack_from("<II", b, off); off += 8
        if typ == 0x4E4F534A: js = json.loads(b[off:off+ln])
        else: binc = b[off:off+ln]
        off += ln
    def acc(i):
        a = js["accessors"][i]; bv = js["bufferViews"][a["bufferView"]]
        n = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[a["type"]]
        dt = {5126: np.float32, 5125: np.uint32, 5123: np.uint16, 5121: np.uint8}[a["componentType"]]
        o = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
        arr = np.frombuffer(binc, dtype=dt, count=a["count"] * n, offset=o)
        return arr.reshape(-1, n) if n > 1 else arr
    p = js["meshes"][0]["primitives"][0]
    out = {"js": js, "bin": binc, "P": acc(p["attributes"]["POSITION"]).astype(np.float64),
           "UV": acc(p["attributes"]["TEXCOORD_0"]).astype(np.float64) if "TEXCOORD_0" in p["attributes"] else None,
           "N": acc(p["attributes"]["NORMAL"]).astype(np.float64) if "NORMAL" in p["attributes"] else None,
           "I": acc(p["indices"]).astype(np.int64).reshape(-1, 3)}
    im = js["images"][0]; bv = js["bufferViews"][im["bufferView"]]; o = bv.get("byteOffset", 0)
    out["img"] = binc[o:o + bv["byteLength"]]
    return out
