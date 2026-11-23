"""Новая модель мамы (Meshy, без скелета: стоит, руки опущены) → на скелет и анимации прежней мамы.

Скелет, анимации (walk_loop, idle_loop, run_loop, inject, fall, attack, talk_loop, stand_ref) и имена костей
остаются прежними — игра (story/actor.gd) работает с мамой как раньше. Как:
  1. прежний скелет ставится в позу, похожую на позу новой модели (первый кадр idle_loop — руки опущены);
  2. новая модель подгоняется по росту и ставится в то же место;
  3. веса костей переносятся с прежней модели (в той же позе) на новую — по ближайшей поверхности;
  4. новая модель «распрямляется» обратно в позу покоя скелета (обратное скиннинг-преобразование каждой
     вершины), чтобы в любой анимации она двигалась так же, как прежняя;
  5. прежняя модель удаляется, сохраняется glb со скелетом, новой моделью и всеми анимациями.

Запуск (Blender как модуль python, bpy):
  python -c "import sys; sys.argv=['x','<mom.glb>','<новая модель.glb>','<выход.glb>']; exec(open('rig_new_mom.py').read())"
"""
import math
import sys

import bpy
import numpy as np
from mathutils import Matrix, Vector

src_rig, src_mesh, dst = sys.argv[1], sys.argv[2], sys.argv[3]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.context.scene.render.fps = 30

bpy.ops.import_scene.gltf(filepath=src_rig)
arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
# тело — сетки, привязанные к скелету (в прежнем файле есть ещё лишняя сфера Icosphere — её выбросить)
old = [o for o in bpy.data.objects if o.type == "MESH" and any(m.type == "ARMATURE" for m in o.modifiers)]
for o in [o for o in bpy.data.objects if o.type == "MESH" and o not in old]:
    bpy.data.objects.remove(o, do_unlink=True)
print("armature", arm.name, "old meshes", [o.name for o in old], "actions", [a.name for a in bpy.data.actions])
before = set(bpy.data.objects)
bpy.ops.import_scene.gltf(filepath=src_mesh)
new = [o for o in bpy.data.objects if o not in before and o.type == "MESH"][0]
for o in bpy.data.objects:
    if o not in before and o is not new and o.type != "MESH":
        pass

# ---------------------------------------------------------------- поза: первый кадр idle_loop
act = next((a for a in bpy.data.actions if a.name.startswith("idle_loop")), None)
if arm.animation_data is None:
    arm.animation_data_create()
arm.animation_data.action = act
bpy.context.scene.frame_set(int(act.frame_range[0]) if act else 0)
bpy.context.view_layer.update()


def world_bbox(o, deps):
    ev = o.evaluated_get(deps)
    me = ev.to_mesh()
    pts = np.array([(ev.matrix_world @ v.co)[:] for v in me.vertices])
    ev.to_mesh_clear()
    return pts.min(0), pts.max(0)


deps = bpy.context.evaluated_depsgraph_get()
omin, omax = np.min([world_bbox(o, deps)[0] for o in old], 0), np.max([world_bbox(o, deps)[1] for o in old], 0)
nmin, nmax = world_bbox(new, deps)
print("old posed bbox", omin.round(3), omax.round(3), "new bbox", nmin.round(3), nmax.round(3))
# Blender: Z — вверх. Рост: по Z; ставим ступни на пол прежней, по центру прежней по X/Y
k = (omax[2] - omin[2]) / (nmax[2] - nmin[2])
new.matrix_world = Matrix.Scale(k, 4) @ new.matrix_world
bpy.context.view_layer.update()
nmin, nmax = world_bbox(new, deps := bpy.context.evaluated_depsgraph_get())
oc = (omin + omax) * 0.5
nc = (nmin + nmax) * 0.5
new.matrix_world = Matrix.Translation(Vector((oc[0] - nc[0], oc[1] - nc[1], omin[2] - nmin[2]))) @ new.matrix_world
bpy.context.view_layer.update()
# применить масштаб/сдвиг к вершинам (объект — в начале координат, без трансформа)
bpy.ops.object.select_all(action="DESELECT")
new.select_set(True)
bpy.context.view_layer.objects.active = new
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
nmin, nmax = world_bbox(new, bpy.context.evaluated_depsgraph_get())
print("new fitted bbox", nmin.round(3), nmax.round(3), "scale", round(k, 4))

# ---------------------------------------------------------------- руки скелета — туда, где руки новой модели
# Поза закрепляется (без анимации), плечо поворачивается так, чтобы запястье попало в запястье новой модели:
# тогда и веса прежней модели, и кости рук совпадают с новой.
saved = {pb.name: pb.matrix.copy() for pb in arm.pose.bones}
arm.animation_data.action = None
for pb in arm.pose.bones:                                 # родители раньше детей
    pb.matrix = saved[pb.name]
    bpy.context.view_layer.update()
P = np.array([v.co[:] for v in new.data.vertices])
inv_arm = arm.matrix_world.inverted()
for side, sgn in (("Left", 1.0), ("Right", -1.0)):
    pb_arm = arm.pose.bones["mixamorig:%sArm" % side]
    pb_hand = arm.pose.bones["mixamorig:%sHand" % side]
    shoulder = arm.matrix_world @ pb_arm.head
    wrist = arm.matrix_world @ pb_hand.head
    s_sign = 1.0 if shoulder.x > 0 else -1.0
    side_pts = P[(P[:, 0] * s_sign > 0.2) & (P[:, 2] < shoulder.z - 0.25) & (P[:, 2] > 0.55)]   # кисть, не подол
    if len(side_pts) < 20:
        continue
    zmin = side_pts[:, 2].min()
    band = side_pts[(side_pts[:, 2] > zmin + 0.07) & (side_pts[:, 2] < zmin + 0.13)]
    if len(band) < 5:
        continue
    target = Vector(band.mean(0))
    a = (wrist - shoulder).normalized()
    b = (target - shoulder).normalized()
    q = a.rotation_difference(b)
    h = pb_arm.head.copy()                                # в осях скелета
    q_arm = (inv_arm.to_3x3() @ q.to_matrix() @ arm.matrix_world.to_3x3()).to_4x4()
    pb_arm.matrix = Matrix.Translation(h) @ q_arm @ Matrix.Translation(-h) @ pb_arm.matrix
    bpy.context.view_layer.update()
    print("%s arm: wrist %s -> %s (target %s), turned %.1f deg" % (side, tuple(round(c, 3) for c in wrist),
          tuple(round(c, 3) for c in (arm.matrix_world @ pb_hand.head)), tuple(round(c, 3) for c in target),
          math.degrees(q.angle)))

# ---------------------------------------------------------------- копия прежней модели в этой позе → веса на новую
src = old[0]
if len(old) > 1:
    bpy.ops.object.select_all(action="DESELECT")
    for o in old:
        o.select_set(True)
    bpy.context.view_layer.objects.active = old[0]
    bpy.ops.object.join()
    src = bpy.context.view_layer.objects.active
posed = src.copy()
posed.data = src.data.copy()
bpy.context.collection.objects.link(posed)
bpy.ops.object.select_all(action="DESELECT")
posed.select_set(True)
bpy.context.view_layer.objects.active = posed
for m in posed.modifiers:
    if m.type == "ARMATURE":
        bpy.ops.object.modifier_apply(modifier=m.name)
posed.parent = None
posed.matrix_world = src.matrix_world.copy()
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

for vg in posed.vertex_groups:
    new.vertex_groups.new(name=vg.name)
dt = new.modifiers.new("dt", "DATA_TRANSFER")
dt.object = posed
dt.use_vert_data = True
dt.data_types_verts = {"VGROUP_WEIGHTS"}
dt.vert_mapping = "POLYINTERP_NEAREST"
dt.layers_vgroup_select_src = "ALL"
dt.layers_vgroup_select_dst = "NAME"
bpy.ops.object.select_all(action="DESELECT")
new.select_set(True)
bpy.context.view_layer.objects.active = new
bpy.ops.object.modifier_apply(modifier="dt")

# ---------------------------------------------------------------- юбка: за тазом, а не за голенями
# Длинное платье: веса с прежней модели тянули ткань к обеим ногам — при шаге между ногами вытягивалась
# «перепонка». Юбку (ниже таза, выше подола) ведёт таз; бока — немного и бедро своей стороны, середина — только таз.
def bone_head(name):
    pb = arm.pose.bones[name]
    return arm.matrix_world @ pb.head


me = new.data
gi_ = {vg.index: vg.name for vg in new.vertex_groups}
hip_z = bone_head("mixamorig:Hips").z
l_x = bone_head("mixamorig:LeftUpLeg").x
r_x = bone_head("mixamorig:RightUpLeg").x
zs = np.array([v.co.z for v in me.vertices])
xs = np.array([v.co.x for v in me.vertices])
# подол: снизу вверх первое сечение, где ширина — уже юбка (> 0.3 м), а не две голени (руки не в счёт: |x| < 0.2)
hem_z = hip_z * 0.4
for zz in np.arange(0.15, hip_z, 0.02):
    m = (zs >= zz) & (zs < zz + 0.04) & (np.abs(xs) < 0.2)
    if m.sum() > 10 and xs[m].max() - xs[m].min() > 0.3:
        hem_z = float(zs[m].min())
        break
print("hips %.3f hem %.3f legs x %.3f / %.3f" % (hip_z, hem_z, l_x, r_x))
for nm in ("mixamorig:Hips", "mixamorig:LeftUpLeg", "mixamorig:RightUpLeg"):
    if nm not in new.vertex_groups:
        new.vertex_groups.new(name=nm)
# руки: по расстоянию до костей руки в этой позе (перенос весов путал опущенную кисть с бедром и платьем)
def seg_dist(p, a, b):
    ab = b - a
    t = max(0.0, min(1.0, (p - a).dot(ab) / max(ab.length_squared, 1e-9)))
    return (a + ab * t - p).length


ARM = {}
for side in ("Left", "Right"):
    for bn, rad in (("Arm", 0.075), ("ForeArm", 0.06), ("Hand", 0.065)):
        nm = "mixamorig:%s%s" % (side, bn)
        if nm in arm.pose.bones:
            pb = arm.pose.bones[nm]
            tail = pb.tail
            if bn == "Hand":                              # кисть с пальцами длиннее кости
                tail = pb.head + (pb.tail - pb.head) * 2.2
            ARM[nm] = (arm.matrix_world @ pb.head, arm.matrix_world @ tail, rad)
for nm in ARM:
    if nm not in new.vertex_groups:
        new.vertex_groups.new(name=nm)
arm_verts = set()
for v in me.vertices:
    p = v.co
    ds = {nm: seg_dist(p, a, b) for nm, (a, b, r) in ARM.items()}
    best = min(ds, key=ds.get)
    if ds[best] > ARM[best][2]:
        continue
    near = {nm: d for nm, d in ds.items() if d < ds[best] * 1.35 + 0.005 and ("Left" in nm) == ("Left" in best)}
    tot = sum(1.0 / max(d, 0.004) ** 4 for d in near.values())
    for g in list(v.groups):
        new.vertex_groups[gi_[g.group]].remove([v.index])
    for nm, d in near.items():
        new.vertex_groups[nm].add([v.index], (1.0 / max(d, 0.004) ** 4) / tot, "REPLACE")
    arm_verts.add(v.index)
print("arm vertices", len(arm_verts))
gi_ = {vg.index: vg.name for vg in new.vertex_groups}
vg_h = new.vertex_groups["mixamorig:Hips"]
vg_l = new.vertex_groups["mixamorig:LeftUpLeg"]
vg_r = new.vertex_groups["mixamorig:RightUpLeg"]
half = abs(l_x - r_x) * 0.5 + 1e-4
cx = (l_x + r_x) * 0.5
skirt = 0
for v in me.vertices:
    z = v.co.z
    if z >= hip_z - 0.02 or z < hem_z - 0.01:
        continue
    if v.index in arm_verts:
        continue                                          # руки, опущенные вдоль платья
    t = min(max((hip_z - z) / max(hip_z - hem_z, 0.05), 0.0), 1.0)
    side = min(max((v.co.x - cx) / half, -1.0), 1.0)
    leg = 0.55 * t * abs(side) ** 1.5
    for g in list(v.groups):
        new.vertex_groups[gi_[g.group]].remove([v.index])
    vg_h.add([v.index], 1.0 - leg, "REPLACE")
    if leg > 0.0:
        (vg_l if (side > 0) == (l_x > cx) else vg_r).add([v.index], leg, "REPLACE")
    skirt += 1
print("skirt vertices", skirt)

# ---------------------------------------------------------------- «распрямить» новую модель в позу покоя
bones = arm.pose.bones
skin = {}
for pb in bones:
    skin[pb.name] = arm.matrix_world @ pb.matrix @ pb.bone.matrix_local.inverted() @ arm.matrix_world.inverted()
gi = {vg.index: vg.name for vg in new.vertex_groups}
me = new.data
moved = 0
for v in me.vertices:
    M = np.zeros((4, 4))
    tw = 0.0
    for g in v.groups:
        nm = gi[g.group]
        if nm in skin and g.weight > 0.0:
            M += np.array(skin[nm]) * g.weight
            tw += g.weight
    if tw <= 1e-6:
        continue
    M /= tw
    p = np.linalg.solve(M, np.array([v.co.x, v.co.y, v.co.z, 1.0]))
    v.co = Vector(p[:3] / p[3])
    moved += 1
print("unposed vertices", moved, "of", len(me.vertices))

# ---------------------------------------------------------------- привязать к скелету, убрать прежнюю модель
for o in old + [posed]:
    if o.name in bpy.data.objects:
        bpy.data.objects.remove(o, do_unlink=True)
new.parent = arm
new.matrix_parent_inverse = arm.matrix_world.inverted()
mod = new.modifiers.new("Armature", "ARMATURE")
mod.object = arm
new.name = "mom_body"
arm.animation_data.action = None
bpy.context.scene.frame_set(0)
bpy.ops.export_scene.gltf(filepath=dst, export_format="GLB", export_animations=True, export_animation_mode="ACTIONS",
                          export_force_sampling=True, export_image_format="AUTO", export_skins=True,
                          export_def_bones=False, export_extras=False)
print("saved", dst)
