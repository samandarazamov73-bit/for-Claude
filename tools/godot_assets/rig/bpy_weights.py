"""Blender (bpy): веса кожи по костям — «автоматические веса» (bone heat) Blender.
Вход: npz с вершинами (уже сшитыми по швам развёртки), треугольниками, костями (голова, хвост, родитель).
Выход: npz с матрицей весов (вершины × кости). Координаты — как в glTF (y вверх), переводятся в Blender тут.
  python bpy_weights.py <in.npz> <out.npz>
"""
import sys
import bpy
import numpy as np

src, out = sys.argv[-2], sys.argv[-1]
d = np.load(src, allow_pickle=True)
V, F = d["verts"], d["faces"]
names = list(d["names"]); heads, tails, parents = d["heads"], d["tails"], list(d["parents"])


def B(p):
    return (float(p[0]), float(-p[2]), float(p[1]))


bpy.ops.wm.read_factory_settings(use_empty=True)
me = bpy.data.meshes.new("body")
me.from_pydata([B(v) for v in V], [], [tuple(int(i) for i in f) for f in F])
me.update()
ob = bpy.data.objects.new("body", me)
bpy.context.scene.collection.objects.link(ob)

arm_d = bpy.data.armatures.new("rig")
arm = bpy.data.objects.new("rig", arm_d)
bpy.context.scene.collection.objects.link(arm)
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode="EDIT")
eb = {}
for n, h, t in zip(names, heads, tails):
    b = arm_d.edit_bones.new(n)
    b.head, b.tail = B(h), B(t)
    eb[n] = b
for n, p in zip(names, parents):
    if p:
        eb[n].parent = eb[p]
bpy.ops.object.mode_set(mode="OBJECT")

for o in bpy.context.scene.objects:
    o.select_set(False)
ob.select_set(True)
arm.select_set(True)
bpy.context.view_layer.objects.active = arm
bpy.ops.object.parent_set(type="ARMATURE_AUTO")

W = np.zeros((len(V), len(names)), np.float32)
gi = {g.index: names.index(g.name) for g in ob.vertex_groups if g.name in names}
for v in me.vertices:
    for g in v.groups:
        if g.group in gi:
            W[v.index, gi[g.group]] = g.weight
np.savez(out, W=W)
print("weights: %d verts, %d without weights" % (len(V), int((W.sum(1) < 1e-6).sum())))
