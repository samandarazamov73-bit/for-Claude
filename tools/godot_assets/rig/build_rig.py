#!/usr/bin/env python3
"""Скелет и анимации для статичной модели человека в A-позе (Meshy без рига): story_doctor.glb и др.

Скелет — от нашего персонажа-образца (psycho / mom / grandpa: те же 66 костей Mixamo, свои анимации):
  * суставы ставятся по форме самой модели (landmarks.py), длины костей — свои;
  * поза покоя костей (их повороты) — как у образца, поэтому анимации образца (idle_loop, walk_loop,
    talk_loop, run_loop) переносятся как есть, по именам костей; движение таза масштабируется по росту;
  * модель «пристёгнута» к скелету в своей A-позе (inverse bind matrices), веса кожи — автоматические веса
    Blender (bpy_weights.py) на копии, сшитой по швам развёртки; пальцы не гнутся (вся кисть — на кости Hand).
Текстуры — не больше 2048 (JPEG), металличность выключена (ткань и кожа не металл).

Сумка в руке (Left / Right) — на своей кости «Bag» у кисти: в игре висит отвесно, куда бы ни шла рука
(story/bone_look.gd), а не торчит вбок, когда человек сидит, положив руку на колено.

  python3 build_rig.py <модель.glb> <образец.glb> <выход.glb> <рост, м> <python с bpy> [анимации через запятую] [Left|Right]
"""
import io
import json
import os
import struct
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from glbio import acc, load, mat_quat, skeleton  # noqa: E402
from landmarks import landmarks, normalize  # noqa: E402

SRC, REF, OUT, HEIGHT, BPY = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]), sys.argv[5]
ANIMS = (sys.argv[6] if len(sys.argv) > 6 else "idle_loop,walk_loop,talk_loop,run_loop").split(",")
BAG = sys.argv[7] if len(sys.argv) > 7 else ""      # "Left" / "Right": в этой руке сумка — висит отвесно (кость Bag)
PRE = "mixamorig:"

PRIMARY = {"Spine": "Spine1", "Spine1": "Spine2", "Spine2": "Neck", "Neck": "Head", "Head": "HeadTop_End"}
for s in ("Left", "Right"):
    PRIMARY.update({s + "Shoulder": s + "Arm", s + "Arm": s + "ForeArm", s + "ForeArm": s + "Hand",
                    s + "Hand": s + "HandMiddle1", s + "UpLeg": s + "Leg", s + "Leg": s + "Foot",
                    s + "Foot": s + "ToeBase", s + "ToeBase": s + "Toe_End"})
DEFORM = ["Hips", "Spine", "Spine1", "Spine2", "Neck", "Head"]
for s in ("Left", "Right"):
    DEFORM += [s + n for n in ("Shoulder", "Arm", "ForeArm", "Hand", "UpLeg", "Leg", "Foot", "ToeBase")]
TAIL = {"Hips": "Spine", "Head": "HeadTop_End", "LeftHand": "LeftHandTip", "RightHand": "RightHandTip",
        "LeftToeBase": "LeftToe_End", "RightToeBase": "RightToe_End"}


def rot_between(a, b):
    v = np.cross(a, b)
    c = float(np.dot(a, b))
    if c > 0.999999:
        return np.eye(3)
    vx = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + vx + vx @ vx * (1.0 / (1.0 + c))


# ---------------------------------------------------------------- модель
sj, sb = load(SRC)
prim = sj["meshes"][0]["primitives"][0]
pos = acc(sj, sb, prim["attributes"]["POSITION"]).astype(np.float64)
nrm = acc(sj, sb, prim["attributes"]["NORMAL"]).astype(np.float32)
uv = acc(sj, sb, prim["attributes"]["TEXCOORD_0"]).astype(np.float32)
idx = acc(sj, sb, prim["indices"]).reshape(-1, 3).astype(np.int64)
node = [n for n in sj["nodes"] if "mesh" in n][0]
assert np.allclose(np.array(node.get("matrix", np.eye(4).flatten())).reshape(4, 4), np.eye(4)), "mesh node not identity"
P, k, off = normalize(pos, HEIGHT)
L = landmarks(P, HEIGHT, idx)

# ---------------------------------------------------------------- скелет образца → свой
rj, rb = load(REF)
joints, names, par, loc, G = skeleton(rj)
short = [n.replace(PRE, "") for n in names]
ref_mesh_node = [n for n in rj["nodes"] if "mesh" in n][0]
ref_pos = acc(rj, rb, rj["meshes"][ref_mesh_node["mesh"]]["primitives"][0]["attributes"]["POSITION"])
s_glob = HEIGHT / float(ref_pos[:, 1].max() - ref_pos[:, 1].min())
nj = len(joints)
depth = [0] * nj
for i in range(nj):
    p = par[i]
    while p >= 0:
        depth[i] += 1
        p = par[p]
order = sorted(range(nj), key=lambda i: depth[i])
T = [None] * nj                 # своя длина/смещение кости (локально)
Bm = [None] * nj                # поза «привязки» (A-поза модели), глобально
for i in order:
    R_rest = loc[i][:3, :3] / np.linalg.norm(loc[i][:3, :3], axis=0)
    pM = np.eye(4) if par[i] < 0 else Bm[par[i]]
    if T[i] is None:
        if short[i] in L:
            T[i] = pM[:3, :3].T @ (L[short[i]] - pM[:3, 3])
        else:
            T[i] = loc[i][:3, 3] * s_glob
    rot = pM[:3, :3] @ R_rest
    c = PRIMARY.get(short[i])
    if c and c in L and short[i] in L and c in short:
        ci = short.index(c)
        tc = loc[ci][:3, 3]
        v0 = rot @ tc
        v0 /= np.linalg.norm(v0)
        v1 = L[c] - L[short[i]]
        dist = np.linalg.norm(v1)
        rot = rot_between(v0, v1 / dist) @ rot
        T[ci] = tc / np.linalg.norm(tc) * dist
    M = np.eye(4)
    M[:3, :3] = rot
    M[:3, 3] = pM[:3, :3] @ T[i] + pM[:3, 3]
    Bm[i] = M
ibm = np.stack([np.linalg.inv(M) for M in Bm])
hips = short.index("Hips")
for nm in ["Hips", "LeftArm", "LeftHand", "LeftLeg", "LeftFoot", "Head"]:
    if nm in short and nm in L:
        assert np.linalg.norm(Bm[short.index(nm)][:3, 3] - L[nm]) < 1e-4, nm

# ---------------------------------------------------------------- веса (Blender)
U, inv = np.unique(P.round(5), axis=0, return_inverse=True)
inv = inv.reshape(-1)
F = inv[idx]
F = F[(F[:, 0] != F[:, 1]) & (F[:, 1] != F[:, 2]) & (F[:, 0] != F[:, 2])]
dnames, heads, tails, parents = [], [], [], []
for nm in DEFORM:
    if nm not in short:
        continue
    i = short.index(nm)
    h = Bm[i][:3, 3]
    tn = TAIL.get(nm, PRIMARY.get(nm))
    t = L[tn] if tn in L else Bm[short.index(tn)][:3, 3]
    p = par[i]
    while p >= 0 and short[p] not in DEFORM:
        p = par[p]
    dnames.append(PRE + nm)
    heads.append(h)
    tails.append(t)
    parents.append(PRE + short[p] if p >= 0 else "")
with tempfile.TemporaryDirectory() as td:
    np.savez(os.path.join(td, "in.npz"), verts=U, faces=F, names=np.array(dnames), heads=np.array(heads),
             tails=np.array(tails), parents=np.array(parents))
    r = subprocess.run([BPY, "-I", os.path.join(HERE, "bpy_weights.py"), os.path.join(td, "in.npz"),
                        os.path.join(td, "out.npz")], capture_output=True, text=True)
    msg = [ln for ln in (r.stdout + r.stderr).splitlines() if "weights:" in ln or "Heat" in ln or "rror" in ln]
    print("\n".join(msg))
    W = np.load(os.path.join(td, "out.npz"))["W"]
heads, tails = np.array(heads), np.array(tails)
# без весов (bone heat не дотянулся: отдельные куски — трость, сумка) — к ближайшей кости, мягко
miss = W.sum(1) < 1e-4
if miss.any():
    q = U[miss][:, None, :]
    ab = tails - heads
    t = np.clip(((q - heads) * ab).sum(-1) / (ab * ab).sum(-1), 0, 1)
    d = np.linalg.norm(q - (heads + ab * t[..., None]), axis=-1)
    W[miss] = np.exp(-(d - d.min(1, keepdims=True)) / 0.015)
Wv = W[inv]
top = np.argsort(-Wv, 1)[:, :4]
tw = np.take_along_axis(Wv, top, 1)
tw[tw < 0.01] = 0
tw /= tw.sum(1, keepdims=True)
jmap = np.array([short.index(n.replace(PRE, "")) for n in dnames])
J4 = jmap[top].astype(np.uint16)
J4[tw == 0] = 0
print("%s: %d verts (%d welded), %d without heat weights, k=%.3f" % (os.path.basename(SRC), len(P), len(U), int(miss.sum()), k))

# сумка: всё, что ниже кончиков пальцев этой руки и снаружи от тела, — на кость Bag (дочерняя кисти)
bag_joint = -1
if BAG:
    side = 1.0 if BAG == "Left" else -1.0
    hand = short.index(BAG + "Hand")
    tip = L[BAG + "HandTip"]
    m = (P[:, 0] * side > 0.16 * HEIGHT) & (P[:, 1] < tip[1] - 0.01 * HEIGHT)
    grip = L[BAG + "Hand"] + (tip - L[BAG + "Hand"]) * 0.55
    Grest = [None] * nj
    for i in order:
        R_rest = loc[i][:3, :3] / np.linalg.norm(loc[i][:3, :3], axis=0)
        M = np.eye(4)
        M[:3, :3] = R_rest
        M[:3, 3] = T[i]
        Grest[i] = M if par[i] < 0 else Grest[par[i]] @ M
    bind_bag = np.eye(4)
    bind_bag[:3, 3] = grip
    T.append(np.linalg.inv(Bm[hand]) @ np.append(grip, 1.0))
    T[-1] = T[-1][:3]
    bag_rest_rot = Grest[hand][:3, :3].T                 # в покое — отвесно (глобально без поворота)
    bag_joint = nj
    ibm = np.concatenate([ibm, np.linalg.inv(bind_bag)[None]], 0)
    J4[m] = 0
    J4[m, 0] = bag_joint
    tw[m] = 0
    tw[m, 0] = 1.0
    print("bag in %s hand: %d verts" % (BAG, int(m.sum())))

# ---------------------------------------------------------------- GLB
out = {"asset": {"version": "2.0", "generator": "build_rig.py"}, "scene": 0, "scenes": [{"nodes": [0]}],
       "nodes": [], "meshes": [], "skins": [], "accessors": [], "bufferViews": [], "buffers": [],
       "materials": [], "textures": [], "images": [], "samplers": [], "animations": []}
blob = bytearray()


def view(data, target=None):
    while len(blob) % 4:
        blob.append(0)
    v = {"buffer": 0, "byteOffset": len(blob), "byteLength": len(data)}
    if target:
        v["target"] = target
    blob.extend(data)
    out["bufferViews"].append(v)
    return len(out["bufferViews"]) - 1


def accessor(arr, ctype, typ, target=None, minmax=False):
    a = np.ascontiguousarray(arr)
    bv = view(a.tobytes(), target)
    acc_ = {"bufferView": bv, "componentType": ctype, "count": int(a.shape[0]), "type": typ}
    if minmax:
        flat = a.reshape(a.shape[0], -1)
        acc_["min"] = [float(x) for x in flat.min(0)]
        acc_["max"] = [float(x) for x in flat.max(0)]
    out["accessors"].append(acc_)
    return len(out["accessors"]) - 1


# узлы: 0 — корень, 1 — сетка, дальше кости в порядке образца
out["nodes"].append({"name": "SmartRigArmature", "children": [1, 2 + hips]})
out["nodes"].append({"name": "geometry_0", "mesh": 0, "skin": 0})
for i in range(nj):
    rn = rj["nodes"][joints[i]]
    q = rn.get("rotation", [0, 0, 0, 1])
    nd = {"name": names[i], "rotation": [float(x) for x in q], "translation": [float(x) for x in T[i]]}
    ch = [2 + c for c in range(nj) if par[c] == i]
    if ch:
        nd["children"] = ch
    out["nodes"].append(nd)
nall = nj
if bag_joint >= 0:
    out["nodes"].append({"name": "Bag", "rotation": [float(x) for x in mat_quat(bag_rest_rot)],
                         "translation": [float(x) for x in T[bag_joint]]})
    out["nodes"][2 + hand].setdefault("children", []).append(2 + bag_joint)
    nall = nj + 1
ibm_acc = accessor(ibm.transpose(0, 2, 1).astype("<f4").reshape(nall, 16), 5126, "MAT4")
out["skins"].append({"joints": [2 + i for i in range(nall)], "inverseBindMatrices": ibm_acc})

attrs = {"POSITION": accessor(P.astype("<f4"), 5126, "VEC3", 34962, True),
         "NORMAL": accessor(nrm, 5126, "VEC3", 34962),
         "TEXCOORD_0": accessor(uv, 5126, "VEC2", 34962),
         "JOINTS_0": accessor(J4.astype("<u2"), 5123, "VEC4", 34962),
         "WEIGHTS_0": accessor(tw.astype("<f4"), 5126, "VEC4", 34962)}
ind = accessor(idx.astype("<u4").reshape(-1), 5125, "SCALAR", 34963)
out["meshes"].append({"name": "body", "primitives": [{"attributes": attrs, "indices": ind, "material": 0}]})

# материал и текстуры
smat = sj["materials"][prim.get("material", 0)]
pbr = smat.get("pbrMetallicRoughness", {})
tex_map = {}


def image_of(tex_index, size, quality):
    if tex_index in tex_map:
        return tex_map[tex_index]
    im_i = sj["textures"][tex_index]["source"]
    im = sj["images"][im_i]
    bvw = sj["bufferViews"][im["bufferView"]]
    raw = sb[bvw.get("byteOffset", 0):bvw.get("byteOffset", 0) + bvw["byteLength"]]
    img = Image.open(io.BytesIO(raw)).convert("RGB")
    if max(img.size) > size:
        img = img.resize((size, size), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=quality, optimize=True)
    out["images"].append({"mimeType": "image/jpeg", "bufferView": view(buf.getvalue())})
    out["textures"].append({"source": len(out["images"]) - 1, "sampler": 0})
    tex_map[tex_index] = len(out["textures"]) - 1
    return tex_map[tex_index]


out["samplers"].append({"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497})
mat = {"name": "Body", "doubleSided": True, "pbrMetallicRoughness": {"metallicFactor": 0.0, "roughnessFactor": 1.0}}
if "baseColorTexture" in pbr:
    mat["pbrMetallicRoughness"]["baseColorTexture"] = {"index": image_of(pbr["baseColorTexture"]["index"], 2048, 90)}
if "metallicRoughnessTexture" in pbr:
    mat["pbrMetallicRoughness"]["metallicRoughnessTexture"] = {"index": image_of(pbr["metallicRoughnessTexture"]["index"], 1024, 85)}
else:
    mat["pbrMetallicRoughness"]["roughnessFactor"] = 0.85
if "normalTexture" in smat:
    mat["normalTexture"] = {"index": image_of(smat["normalTexture"]["index"], 2048, 92)}
out["materials"].append(mat)

# анимации образца: повороты — как есть; таз — свой рост
ref_hips_t = np.array(rj["nodes"][joints[hips]].get("translation", [0, 0, 0]))
kh = L["Hips"][1] / ref_hips_t[1]
node_of = {joints[i]: 2 + i for i in range(nj)}
for a in rj["animations"]:
    if a["name"] not in ANIMS:
        continue
    samplers, channels, cache = [], [], {}
    for ch in a["channels"]:
        tn = ch["target"]["node"]
        path = ch["target"]["path"]
        if tn not in node_of or path == "scale" or (path == "translation" and tn != joints[hips]):
            continue
        s = a["samplers"][ch["sampler"]]
        if s["input"] not in cache:
            tt = acc(rj, rb, s["input"]).astype("<f4")
            cache[s["input"]] = accessor(tt, 5126, "SCALAR", minmax=True)
        v = acc(rj, rb, s["output"]).astype(np.float64)
        if path == "translation":
            v = L["Hips"] + (v - ref_hips_t) * kh
        typ = "VEC4" if path == "rotation" else "VEC3"
        o = accessor(v.astype("<f4"), 5126, typ)
        samplers.append({"input": cache[s["input"]], "output": o, "interpolation": s.get("interpolation", "LINEAR")})
        channels.append({"sampler": len(samplers) - 1, "target": {"node": node_of[tn], "path": path}})
    out["animations"].append({"name": a["name"], "samplers": samplers, "channels": channels})
for key in ["animations", "textures", "images", "samplers"]:
    if not out[key]:
        del out[key]

while len(blob) % 4:
    blob.append(0)
out["buffers"].append({"byteLength": len(blob)})
js = json.dumps(out, separators=(",", ":")).encode()
while len(js) % 4:
    js += b" "
glb = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(blob))
glb += struct.pack("<II", len(js), 0x4E4F534A) + js + struct.pack("<II", len(blob), 0x004E4942) + bytes(blob)
open(OUT, "wb").write(glb)
print("saved %s (%d KB): %d joints, anims %s, hips %.3f m" % (OUT, len(glb) // 1024, nj,
      [a["name"] for a in out.get("animations", [])], L["Hips"][1]))
