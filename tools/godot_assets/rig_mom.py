"""Скелет для мамы (Blender, bpy): кости, автоматические веса, анимации hold_loop / idle_loop / walk_loop, выгрузка GLB.
Координаты суставов — в системе игры (glTF): x вправо, y вверх, z назад (лицо смотрит в −z), метры, пол = 0.
Запуск: python rig_mom.py <исходная мама.glb> <выход.glb>"""
import math
import sys
import bpy
from mathutils import Matrix, Vector

src, out = sys.argv[-2], sys.argv[-1]
K = 1.70
O = Vector((-0.003, -0.476, 0.0))          # точка исходника, которая станет началом координат (между ступней, на полу)
GRIP_WRIST = (0.255, 1.73, -0.03)          # куда тянется запястье правой руки (поручень над головой справа)


def B(p):                                  # glTF -> Blender (Z вверх)
    return Vector((p[0], -p[2], p[1]))


J = {
    "hips": (0, 0.92, 0.0), "spine": (0, 1.05, 0.0), "chest": (0, 1.2, 0.0), "neck": (0, 1.37, 0.0),
    "head": (0, 1.45, -0.01), "head_top": (0, 1.62, -0.02),
    "clav_R": (0.03, 1.33, 0.0), "sh_R": (0.15, 1.29, 0.0), "el_R": (0.19, 1.01, -0.04), "wr_R": (0.185, 0.82, -0.10), "hd_R": (0.18, 0.74, -0.13),
    "clav_L": (-0.03, 1.33, 0.0), "sh_L": (-0.16, 1.29, 0.0), "el_L": (-0.2, 1.01, -0.03), "wr_L": (-0.2, 0.86, -0.08), "hd_L": (-0.19, 0.77, -0.11),
    "hip_R": (0.08, 0.87, -0.01), "kn_R": (0.062, 0.46, -0.02), "an_R": (0.06, 0.085, 0.0), "to_R": (0.06, 0.02, -0.13),
    "hip_L": (-0.085, 0.87, -0.01), "kn_L": (-0.025, 0.46, -0.02), "an_L": (-0.03, 0.085, 0.0), "to_L": (-0.03, 0.02, -0.13),
}

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
mesh = [o for o in bpy.context.scene.objects if o.type == "MESH"][0]
for o in bpy.context.scene.objects:
    o.select_set(o == mesh)
bpy.context.view_layer.objects.active = mesh
bpy.ops.object.parent_clear(type="CLEAR_KEEP_TRANSFORM")
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
ob = Vector((O.x, -O.z, O.y))
mesh.data.transform(Matrix.Rotation(math.pi, 4, "Z") @ Matrix.Scale(K, 4) @ Matrix.Translation(-ob))
mesh.name = "Mom"
bpy.ops.object.mode_set(mode="EDIT")                  # сшиваем швы развёртки — без этого веса не считаются
bpy.ops.mesh.select_all(action="SELECT")
bpy.ops.mesh.remove_doubles(threshold=0.0003)
bpy.ops.object.mode_set(mode="OBJECT")
# Ноги у модели сомкнуты: ниже колен разрезаем треугольники, которые соединяют левую и правую ногу (туфли касаются).
import bmesh
bm = bmesh.new()
bm.from_mesh(mesh.data)
MID_X = 0.015
cut = [f for f in bm.faces if max(v.co.z for v in f.verts) < 0.44
       and min(v.co.x for v in f.verts) <= MID_X and max(v.co.x for v in f.verts) > MID_X]
bmesh.ops.delete(bm, geom=cut, context="FACES")
bm.to_mesh(mesh.data)
bm.free()
mesh.data.validate()
print("cut faces between legs:", len(cut))
zs = [v.co.z for v in mesh.data.vertices]
print("mesh height", round(max(zs), 3), "min", round(min(zs), 3), "verts", len(zs))

# --- кости
bpy.ops.object.armature_add(enter_editmode=True, location=(0, 0, 0))
arm = bpy.context.object
arm.name = "MomRig"
eb = arm.data.edit_bones
eb.remove(eb[0])


def bone(name, h, t, parent=None, connect=False):
    b = eb.new(name)
    b.head = B(J[h]) if isinstance(h, str) else B(h)
    b.tail = B(J[t]) if isinstance(t, str) else B(t)
    b.roll = 0.0
    if parent:
        b.parent = eb[parent]
        b.use_connect = connect
    return b


bone("Hips", "hips", "spine")
bone("Spine", "spine", "chest", "Hips", True)
bone("Chest", "chest", "neck", "Spine", True)
bone("Neck", "neck", "head", "Chest", True)
bone("Head", "head", "head_top", "Neck", True)
for s in ("R", "L"):
    bone("Shoulder." + s, "clav_" + s, "sh_" + s, "Chest")
    bone("UpperArm." + s, "sh_" + s, "el_" + s, "Shoulder." + s, True)
    bone("Forearm." + s, "el_" + s, "wr_" + s, "UpperArm." + s, True)
    bone("Hand." + s, "wr_" + s, "hd_" + s, "Forearm." + s, True)
    bone("Thigh." + s, "hip_" + s, "kn_" + s, "Hips")
    bone("Shin." + s, "kn_" + s, "an_" + s, "Thigh." + s, True)
    bone("Foot." + s, "an_" + s, "to_" + s, "Shin." + s, True)
bpy.ops.object.mode_set(mode="OBJECT")

# --- автоматические веса (тепловая диффузия Blender)
bpy.ops.object.select_all(action="DESELECT")
mesh.select_set(True)
arm.select_set(True)
bpy.context.view_layer.objects.active = arm
bpy.ops.object.parent_set(type="ARMATURE_AUTO")
# Ниже колен каждая вершина принадлежит только «своей» ноге (иначе туфли тянутся друг к другу при шаге).
MID_X = 0.015
gi = {g.name: g.index for g in mesh.vertex_groups}
for v in mesh.data.vertices:
    if v.co.z > 0.42:
        continue
    side, other = ("R", "L") if v.co.x > MID_X else ("L", "R")
    moved = {}
    for g in v.groups:
        nm = mesh.vertex_groups[g.group].name
        if nm.endswith("." + other) and nm.split(".")[0] in ("Shin", "Foot", "Thigh"):
            moved[nm.split(".")[0] + "." + side] = moved.get(nm.split(".")[0] + "." + side, 0.0) + g.weight
            mesh.vertex_groups[nm].remove([v.index])
    for nm, w in moved.items():
        mesh.vertex_groups[nm].add([v.index], w, "ADD")
counts = {g.name: 0 for g in mesh.vertex_groups}
for v in mesh.data.vertices:
    for g in v.groups:
        if g.weight > 0.05:
            counts[mesh.vertex_groups[g.group].name] += 1
print("weights:", counts)

# --- позы
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode="POSE")
pb = arm.pose.bones
for p in pb:
    p.rotation_mode = "QUATERNION"


def reset():
    for p in pb:
        p.rotation_quaternion = (1, 0, 0, 0)
        p.location = (0, 0, 0)
    bpy.context.view_layer.update()


def aim(name, target_g):
    """Повернуть кость так, чтобы её хвост смотрел на точку (в координатах игры), без лишнего скручивания."""
    bpy.context.view_layer.update()
    p = pb[name]
    M = p.matrix.copy()
    head = M.translation.copy()
    cur = (M.to_3x3() @ Vector((0, 1, 0))).normalized()
    want = (B(target_g) - head).normalized()
    R = cur.rotation_difference(want).to_matrix().to_4x4()
    p.matrix = Matrix.Translation(head) @ R @ Matrix.Translation(-head) @ M
    bpy.context.view_layer.update()


def tail_g(name):
    bpy.context.view_layer.update()
    t = arm.matrix_world @ pb[name].tail
    return (t.x, t.z, -t.y)


def ik_point(S, T, l1, l2, pole):
    S, T, pole = Vector(S), Vector(T), Vector(pole)
    d = T - S
    L = min(d.length, (l1 + l2) * 0.995)
    dn = d.normalized()
    a = (l1 * l1 - l2 * l2 + L * L) / (2 * L)
    h = math.sqrt(max(0.0, l1 * l1 - a * a))
    p = (pole - dn * pole.dot(dn)).normalized()
    E = S + dn * a + p * h
    return tuple(E), tuple(S + dn * L)


def length(a, b):
    return (Vector(J[a]) - Vector(J[b])).length


ARM_BONES = ["Shoulder.R", "UpperArm.R", "Forearm.R", "Hand.R", "Shoulder.L", "UpperArm.L", "Forearm.L", "Hand.L"]
LEG_BONES = ["Hips", "Thigh.R", "Shin.R", "Foot.R", "Thigh.L", "Shin.L", "Foot.L", "Spine", "Chest"]


def key(names, frame):
    for n in names:
        pb[n].keyframe_insert("rotation_quaternion", frame=frame)
        if n == "Hips":
            pb[n].keyframe_insert("location", frame=frame)


def new_action(name):
    act = bpy.data.actions.new(name)
    arm.animation_data_create()
    arm.animation_data.action = act
    return act


def pose_hold():
    """Правая рука на верхнем поручне: плечо чуть поднято, рука вверх, кисть над головой справа."""
    aim("Shoulder.R", (0.15, 1.335, 0.0))
    S = tail_g("Shoulder.R")
    E, W = ik_point(S, GRIP_WRIST, length("sh_R", "el_R"), length("el_R", "wr_R"), (1.0, -0.15, 0.35))
    aim("UpperArm.R", E)
    aim("Forearm.R", W)
    aim("Hand.R", (W[0] + 0.01, W[1] + 0.09, W[2] - 0.02))
    aim("Forearm.L", (-0.19, 0.88, -0.14))             # левая рука чуть согнута


actions = []
# hold
reset()
act = new_action("hold_loop")
pose_hold()
key(ARM_BONES + LEG_BONES, 1)
key(ARM_BONES + LEG_BONES, 25)
actions.append(act)
print("hold: hand tip at", [round(v, 3) for v in tail_g("Hand.R")], "wrist", [round(v, 3) for v in tail_g("Forearm.R")])
# idle
reset()
act = new_action("idle_loop")
key(ARM_BONES + LEG_BONES, 1)
key(ARM_BONES + LEG_BONES, 25)
actions.append(act)
# walk: шаг 0.5 с, цикл 1 с (25 кадров при 24 к/с)
reset()
act = new_action("walk_loop")
for f in range(1, 26, 2):
    reset()
    ph = (f - 1) / 24.0 * 2 * math.pi
    for s, sh in (("R", 0.0), ("L", math.pi)):
        a = math.radians(24.0) * math.sin(ph + sh)              # + вперёд
        hip, kn, an = Vector(J["hip_" + s]), Vector(J["kn_" + s]), Vector(J["an_" + s])
        l1, l2 = (kn - hip).length, (an - kn).length
        knee = hip + Vector((0, -math.cos(a), -math.sin(a))) * l1
        bend = math.radians(38.0) * max(0.0, math.sin(ph + sh + math.pi * 0.5)) ** 2     # колено сгибается при выносе ноги
        sa = a - bend
        ank = knee + Vector((0, -math.cos(sa), -math.sin(sa))) * l2
        aim("Thigh." + s, tuple(knee))
        aim("Shin." + s, tuple(ank))
        aim("Foot." + s, (ank.x, ank.y - 0.065, ank.z - 0.13))
        b = math.radians(11.0) * math.sin(ph + sh + math.pi)      # руки — против ног
        sh_p, el = Vector(J["sh_" + s]), Vector(J["el_" + s])
        e2 = sh_p + Vector((el.x - sh_p.x, -math.cos(b) * (sh_p.y - el.y), -math.sin(b) * (sh_p.y - el.y)))
        aim("UpperArm." + s, tuple(e2))
    pb["Hips"].location = (0, 0, 0)
    bob = 0.018 * abs(math.cos(ph))
    pb["Hips"].location = (0, bob, 0)                             # Y кости Hips — вверх по позвоночнику
    key(ARM_BONES + LEG_BONES, f)
actions.append(act)

# каждое действие — в свою дорожку NLA (так выгрузчик отдаёт их отдельными анимациями)
arm.animation_data.action = None
for act in actions:
    tr = arm.animation_data.nla_tracks.new()
    tr.name = act.name
    tr.strips.new(act.name, 1, act)
reset()
bpy.ops.object.mode_set(mode="OBJECT")

# текстуру — 2048 JPG
for img in bpy.data.images:
    if img.size[0] > 2048:
        img.scale(2048, 2048)

bpy.ops.export_scene.gltf(filepath=out, export_format="GLB", export_animations=True, export_animation_mode="NLA_TRACKS",
                          export_skins=True, export_yup=True, export_image_format="JPEG", export_jpeg_quality=86,
                          export_force_sampling=True, export_def_bones=False)
print("exported", out)
