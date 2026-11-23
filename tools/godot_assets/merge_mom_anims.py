#!/usr/bin/env python3
"""Новая мама автора (Meshy: платье, скелет Mixamo, своя ходьба) + остальные анимации прежней мамы.

Скелеты у обеих одинаковые (те же 66 костей, та же поза покоя), поэтому дорожки анимаций переносятся как есть —
по именам костей. Ходьба — своя, из файла автора (переименована в walk_loop); idle_loop, talk_loop, run_loop,
inject, fall, attack, stand_ref — из прежней characters/mom.glb. Заодно печатает скорость шага новой ходьбы
(м/с, при которой ноги не скользят) — её нужно вписать в story/actor.gd (natural["walk_loop"]).

  python3 merge_mom_anims.py <новая мама с ходьбой.glb> <прежняя characters/mom.glb> <выход.glb>
"""
import json
import struct
import sys

import numpy as np

NEW, OLD, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
COMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def load(fn):
    data = open(fn, "rb").read()
    ln, _ = struct.unpack_from("<II", data, 12)
    j = json.loads(data[20:20 + ln])
    off = 20 + ln
    bl, _ = struct.unpack_from("<II", data, off)
    return j, bytearray(data[off + 8:off + 8 + bl])


def acc_bytes(j, b, ai):
    a = j["accessors"][ai]
    bv = j["bufferViews"][a["bufferView"]]
    n = a["count"] * COMP[a["type"]] * 4
    start = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    assert a["componentType"] == 5126 and bv.get("byteStride", 0) in (0, COMP[a["type"]] * 4)
    return bytes(b[start:start + n])


def acc_array(j, b, ai):
    a = j["accessors"][ai]
    return np.frombuffer(acc_bytes(j, b, ai), "<f4").reshape(a["count"], COMP[a["type"]])


nj, nb = load(NEW)
oj, ob = load(OLD)
by_name = {n.get("name"): i for i, n in enumerate(nj["nodes"])}
for a in nj["animations"]:
    if a["name"].startswith("walking"):
        a["name"] = "walk_loop"


def add_accessor(raw, src_acc):
    while len(nb) % 4:
        nb.append(0)
    nj["bufferViews"].append({"buffer": 0, "byteOffset": len(nb), "byteLength": len(raw)})
    nb.extend(raw)
    acc = {k: v for k, v in src_acc.items() if k in ("componentType", "count", "type", "min", "max")}
    acc["bufferView"] = len(nj["bufferViews"]) - 1
    nj["accessors"].append(acc)
    return len(nj["accessors"]) - 1


for a in oj["animations"]:
    if a["name"] == "walk_loop":
        continue                                       # ходьба — своя, у новой модели
    samplers, channels, cache = [], [], {}
    for ch in a["channels"]:
        nm = oj["nodes"][ch["target"]["node"]].get("name")
        path = ch["target"]["path"]
        if nm not in by_name or path == "scale":
            continue
        if path == "translation" and nm != "mixamorig:Hips":
            continue                                   # длины костей — свои, у новой модели
        s = a["samplers"][ch["sampler"]]
        key_in = s["input"]
        if key_in not in cache:
            cache[key_in] = add_accessor(acc_bytes(oj, ob, key_in), oj["accessors"][key_in])
        out = add_accessor(acc_bytes(oj, ob, s["output"]), oj["accessors"][s["output"]])
        samplers.append({"input": cache[key_in], "output": out, "interpolation": s.get("interpolation", "LINEAR")})
        channels.append({"sampler": len(samplers) - 1, "target": {"node": by_name[nm], "path": path}})
    nj["animations"].append({"name": a["name"], "samplers": samplers, "channels": channels})
    print("added", a["name"], len(channels), "tracks")

nj["buffers"][0]["byteLength"] = len(nb)
js = json.dumps(nj, separators=(",", ":")).encode()
while len(js) % 4:
    js += b" "
while len(nb) % 4:
    nb.append(0)
glb = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(nb))
glb += struct.pack("<II", len(js), 0x4E4F534A) + js + struct.pack("<II", len(nb), 0x004E4942) + bytes(nb)
open(OUT, "wb").write(glb)
print("saved", OUT, len(glb) // 1024, "KB")


# ---------------------------------------------------------------- скорость шага новой ходьбы (прямая кинематика)
def quat_mat(q):
    x, y, z, w = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


walk = next(a for a in nj["animations"] if a["name"] == "walk_loop")
tracks = {}
for ch in walk["channels"]:
    s = walk["samplers"][ch["sampler"]]
    tracks[(ch["target"]["node"], ch["target"]["path"])] = (acc_array(nj, nb, s["input"])[:, 0], acc_array(nj, nb, s["output"]))
times = next(iter(tracks.values()))[0]
chain = ["mixamorig:Hips", "mixamorig:LeftUpLeg", "mixamorig:LeftLeg", "mixamorig:LeftFoot"]
parent = {}
for i, n in enumerate(nj["nodes"]):
    for c in n.get("children", []):
        parent[c] = i
zs = []
for k in range(len(times)):
    M = np.eye(4)
    for nm in chain:
        i = by_name[nm]
        n = nj["nodes"][i]
        t = tracks.get((i, "translation"), (None, np.array([n.get("translation", [0, 0, 0])] * len(times))))[1][k]
        r = tracks.get((i, "rotation"), (None, np.array([n.get("rotation", [0, 0, 0, 1])] * len(times))))[1][k]
        L = np.eye(4); L[:3, :3] = quat_mat(r); L[:3, 3] = t
        M = M @ L
    zs.append(M[2, 3])
zs = np.array(zs)
T = float(times[-1] - times[0])
# ступня на земле ~60 % цикла уезжает назад с постоянной скоростью = скорость шага
v = (zs.max() - zs.min()) / (0.6 * T)
print("walk cycle %.3f s, left foot travels %.3f m — natural speed ≈ %.2f m/s" % (T, zs.max() - zs.min(), v))
