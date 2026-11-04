"""Готовит людей автора для Godot: убирает «табуретки» из моделей, переводит в метры, лицом в −Z,
начало координат — верх сиденья под человеком (сидящие) или пол (стоящие), текстура в JPG.
У мамы голени ниже подола — отдельные узлы LegL / LegR (для шага)."""
import io, json, struct, sys
import numpy as np
from PIL import Image
sys.path.insert(0, sys.argv[1] + "/scripts")
from glbmesh import load
SP, OUT = sys.argv[1], sys.argv[2]

MODELS = [
    # name, src, k (масштаб), origin (в единицах исходника), box (x0,x1,y0,y1,z0,z1) или None, tex size
    ("mom", "mom", 1.70, (-0.003, -0.476, 0.0), None, 2048),
    ("driver", "p1", 1.45, (0.0, -0.177, -0.12), None, 1024),
    ("mother_baby", "p2", 1.45, (0.0, -0.163, -0.15), (-0.13, 0.13, -0.49, -0.18, -0.27, -0.03), 1024),
    ("grandma_scarf", "p3", 1.45, (0.005, -0.163, -0.15), (-0.15, 0.16, -0.49, -0.18, -0.27, -0.03), 1024),
    ("man_newspaper", "p4", 1.45, (-0.02, -0.163, -0.185), (-0.15, 0.11, -0.49, -0.18, -0.32, -0.05), 1024),
]
E = 0.006

def build_glb(name, parts, jpg):
    """parts: [(node_name, translation, P, N, UV, I)] -> bytes"""
    js = {"asset": {"version": "2.0", "generator": "prep_people.py"}, "scene": 0, "scenes": [{"nodes": [0]}],
          "nodes": [{"name": name, "children": []}], "meshes": [], "accessors": [], "bufferViews": [],
          "materials": [{"name": "Person_" + name, "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}, "metallicFactor": 0.0, "roughnessFactor": 0.85}}],
          "textures": [{"source": 0, "sampler": 0}], "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}],
          "images": [], "buffers": []}
    blob = bytearray()
    def view(data, target=None):
        while len(blob) % 4: blob.append(0)
        bv = {"buffer": 0, "byteOffset": len(blob), "byteLength": len(data)}
        if target: bv["target"] = target
        blob.extend(data); js["bufferViews"].append(bv); return len(js["bufferViews"]) - 1
    def accessor(arr, typ, comp, target, minmax=False):
        a = {"bufferView": view(arr.tobytes(), target), "componentType": comp, "count": int(arr.shape[0]), "type": typ}
        if minmax: a["min"] = arr.min(axis=0).tolist(); a["max"] = arr.max(axis=0).tolist()
        js["accessors"].append(a); return len(js["accessors"]) - 1
    for node_name, tr, P, N, UV, I in parts:
        used = np.unique(I); remap = -np.ones(len(P), dtype=np.int64); remap[used] = np.arange(len(used))
        p = P[used].astype(np.float32); n = N[used].astype(np.float32); uv = UV[used].astype(np.float32); idx = remap[I].astype(np.uint32).reshape(-1)
        prim = {"attributes": {"POSITION": accessor(p, "VEC3", 5126, 34962, True), "NORMAL": accessor(n, "VEC3", 5126, 34962),
                               "TEXCOORD_0": accessor(uv, "VEC2", 5126, 34962)},
                "indices": accessor(idx, "SCALAR", 5125, 34963), "material": 0}
        js["meshes"].append({"name": node_name, "primitives": [prim]})
        node = {"name": node_name, "mesh": len(js["meshes"]) - 1}
        if tr is not None: node["translation"] = [float(v) for v in tr]
        js["nodes"].append(node); js["nodes"][0]["children"].append(len(js["nodes"]) - 1)
    js["images"].append({"bufferView": view(jpg), "mimeType": "image/jpeg"})
    while len(blob) % 4: blob.append(0)
    js["buffers"].append({"byteLength": len(blob)})
    jb = json.dumps(js, separators=(",", ":")).encode()
    while len(jb) % 4: jb += b" "
    return struct.pack("<4sII", b"glTF", 2, 12 + 8 + len(jb) + 8 + len(blob)) + struct.pack("<II", len(jb), 0x4E4F534A) + jb + struct.pack("<II", len(blob), 0x004E4942) + bytes(blob)

for name, src, k, o, box, tex in MODELS:
    m = load(f"{SP}/up2/{src}.glb")
    P, N, UV, I = m["P"], m["N"], m["UV"], m["I"]
    c = (P[I[:, 0]] + P[I[:, 1]] + P[I[:, 2]]) / 3
    keep = np.ones(len(I), dtype=bool)
    if box:
        x0, x1, y0, y1, z0, z1 = box
        inside = (c[:, 0] > x0 - E) & (c[:, 0] < x1 + E) & (c[:, 1] > y0 - E) & (c[:, 1] < y1 + E) & (c[:, 2] > z0 - E) & (c[:, 2] < z1 + E)
        keep &= ~inside
        print(f"{name}: removed {inside.sum()} box triangles of {len(I)}")
    # метры, лицом в −Z (поворот на 180°), начало координат в o
    Q = np.empty_like(P); Q[:, 0] = -(P[:, 0] - o[0]) * k; Q[:, 1] = (P[:, 1] - o[1]) * k; Q[:, 2] = -(P[:, 2] - o[2]) * k
    Nn = N.copy(); Nn[:, 0] *= -1; Nn[:, 2] *= -1
    img = Image.open(io.BytesIO(m["img"])).convert("RGB")
    if img.size[0] > tex: img = img.resize((tex, tex), Image.LANCZOS)
    jb = io.BytesIO(); img.save(jb, "JPEG", quality=87, optimize=True)
    parts = []
    if name == "mom":
        cut = -0.215                                  # чуть ниже подола
        ymax = np.maximum.reduce([P[I[:, 0], 1], P[I[:, 1], 1], P[I[:, 2], 1]])
        leg = ymax < cut
        left = leg & (c[:, 0] < -0.02); right = leg & (c[:, 0] >= -0.02)
        parts.append(("Body", None, Q, Nn, UV, I[keep & ~leg]))
        for nm, sel in [("LegR", left), ("LegL", right)]:       # после поворота на 180° левая и правая меняются
            piv_src = np.array([c[sel, 0].mean(), cut, c[sel, 2].mean()])
            piv = np.array([-(piv_src[0] - o[0]) * k, (piv_src[1] - o[1]) * k, -(piv_src[2] - o[2]) * k])
            parts.append((nm, piv, Q - piv, Nn, UV, I[sel]))
            print(f"mom {nm}: {sel.sum()} tris, pivot {np.round(piv, 3)}")
    else:
        parts.append(("Body", None, Q, Nn, UV, I[keep]))
    data = build_glb(name, parts, jb.getvalue())
    open(f"{OUT}/{name}.glb", "wb").write(data)
    hy = Q[np.unique(I[keep])][:, 1]
    print(f"{name}: {len(data)/1e6:.2f} MB, height above origin {hy.max():.2f} m, lowest {hy.min():.2f} m")
