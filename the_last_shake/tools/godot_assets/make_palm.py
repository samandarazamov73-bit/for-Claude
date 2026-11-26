# Пальма в кадке (кентия): керамическая кадка, земля, 4 стебля, 10 перистых листьев с узкими листочками.
# Запуск: python make_palm.py out.glb  (нужен модуль bpy). Ориентир: высота ~1.6 м, кадка Ø 0.38 м.
import sys, math, random
import bpy, bmesh
from mathutils import Vector, Matrix

out = sys.argv[-1]
random.seed(1975)
bpy.ops.wm.read_factory_settings(use_empty=True)


def mat(name, rgb, rough=0.7, two=False):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*rgb, 1.0)
    b.inputs["Roughness"].default_value = rough
    m.use_backface_culling = not two
    return m


M_POT = mat("pot", (0.42, 0.20, 0.11), 0.55)
M_RIM = mat("pot_rim", (0.36, 0.17, 0.09), 0.5)
M_SOIL = mat("soil", (0.10, 0.07, 0.05), 0.95)
M_STEM = mat("stem", (0.22, 0.26, 0.10), 0.7)
M_LEAF = [mat("leaf_a", (0.10, 0.22, 0.06), 0.55, True), mat("leaf_b", (0.14, 0.27, 0.07), 0.55, True),
          mat("leaf_c", (0.17, 0.25, 0.08), 0.6, True)]
M_DRY = mat("leaf_dry", (0.36, 0.30, 0.14), 0.8, True)


def obj(name, bm, mats):
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new(name, me)
    for m in mats:
        me.materials.append(m)
    bpy.context.collection.objects.link(o)
    return o


# ---------------------------------------------------------------- кадка: усечённый конус с толстым ободом
bm = bmesh.new()
N = 28
prof = [(0.135, 0.0), (0.150, 0.015), (0.185, 0.31), (0.198, 0.315), (0.200, 0.36), (0.186, 0.36), (0.180, 0.33)]
rings = []
for (r, z) in prof:
    rings.append([bm.verts.new((r * math.cos(2 * math.pi * i / N), r * math.sin(2 * math.pi * i / N), z)) for i in range(N)])
for k in range(len(rings) - 1):
    for i in range(N):
        f = bm.faces.new((rings[k][i], rings[k][(i + 1) % N], rings[k + 1][(i + 1) % N], rings[k + 1][i]))
        f.material_index = 1 if k >= 2 else 0
        f.smooth = True
bm.faces.new(list(reversed(rings[0])))
obj("pot", bm, [M_POT, M_RIM])
# земля
bm = bmesh.new()
c = bm.verts.new((0, 0, 0.325))
ring = [bm.verts.new((0.178 * math.cos(2 * math.pi * i / N), 0.178 * math.sin(2 * math.pi * i / N), 0.33)) for i in range(N)]
for i in range(N):
    bm.faces.new((c, ring[i], ring[(i + 1) % N]))
obj("soil", bm, [M_SOIL])


# ---------------------------------------------------------------- стебли и листья
def tube(bm, pts, r0, r1, sides=6):
    prev = None
    for k, p in enumerate(pts):
        t = k / (len(pts) - 1)
        r = r0 + (r1 - r0) * t
        d = (pts[min(k + 1, len(pts) - 1)] - pts[max(k - 1, 0)]).normalized()
        a = d.orthogonal().normalized()
        b = d.cross(a)
        ring = [bm.verts.new(p + (a * math.cos(2 * math.pi * i / sides) + b * math.sin(2 * math.pi * i / sides)) * r) for i in range(sides)]
        if prev:
            for i in range(sides):
                f = bm.faces.new((prev[i], prev[(i + 1) % sides], ring[(i + 1) % sides], ring[i]))
                f.smooth = True
        prev = ring


stems = bmesh.new()
leaves = bmesh.new()
tops = []
for s in range(4):
    ang = s * math.pi / 2 + random.uniform(-0.4, 0.4)
    h = [0.95, 0.72, 0.58, 0.84][s] + random.uniform(-0.05, 0.05)
    lean = random.uniform(0.04, 0.10)
    base = Vector((math.cos(ang) * 0.04, math.sin(ang) * 0.04, 0.33))
    pts = [base + Vector((math.cos(ang) * lean * (t ** 1.6), math.sin(ang) * lean * (t ** 1.6), h * t)) for t in [i / 6 for i in range(7)]]
    tube(stems, pts, 0.016, 0.009)
    tops.append((pts[-1], ang))


def frond(top, yaw, pitch, length, mat_i, dry=False):
    # рахис: дуга — вверх под углом pitch, потом свисает
    n = 26
    pts = []
    p = top.copy()
    dirv = Vector((math.cos(yaw) * math.cos(pitch), math.sin(yaw) * math.cos(pitch), math.sin(pitch)))
    step = length / n
    for k in range(n + 1):
        pts.append(p.copy())
        dirv = (dirv + Vector((0, 0, -0.085 - 0.02 * k / n))).normalized()
        p = p + dirv * step
    tube(stems, pts[:: 2] + [pts[-1]], 0.006, 0.0015, 4)
    side = Vector((-math.sin(yaw), math.cos(yaw), 0))
    first = len(leaves.faces)
    for k in range(3, n):
        t = k / n
        L = (0.11 + 0.22 * math.sin(math.pi * min(1.0, t * 1.15))) * (0.8 if dry else 1.0)
        w = 0.016 + 0.01 * math.sin(math.pi * t)
        base = pts[k]
        fwd = (pts[min(k + 1, n)] - pts[k]).normalized()
        for sg in (-1, 1):
            # листочек: наружу, вперёд по рахису и вниз (свисает), чуть сложен «домиком»
            out_v = (side * sg * 0.85 + fwd * 0.45 + Vector((0, 0, -0.25 - 0.35 * t))).normalized()
            nrm = out_v.cross(fwd).normalized() * sg
            if nrm.z < 0:
                nrm = -nrm
            wv = fwd.cross(out_v).normalized()
            tip = base + out_v * L + Vector((0, 0, -0.05 * L / 0.3))
            mid = base + out_v * (L * 0.45)
            v0 = leaves.verts.new(base)
            v1 = leaves.verts.new(mid + wv * w + nrm * w * 0.35)
            v2 = leaves.verts.new(mid - wv * w + nrm * w * 0.35)
            v3 = leaves.verts.new(mid - nrm * w * 0.1)
            v4 = leaves.verts.new(tip)
            for f in (leaves.faces.new((v0, v1, v3)), leaves.faces.new((v0, v3, v2)),
                      leaves.faces.new((v3, v1, v4)), leaves.faces.new((v3, v4, v2))):
                f.material_index = 3 if dry else mat_i
                f.smooth = True


fi = 0
for (top, ang) in tops:
    for j in range(random.choice([2, 3, 3])):
        yaw = ang + random.uniform(-1.1, 1.1) + j * 2.1
        frond(top, yaw, random.uniform(0.75, 1.25), random.uniform(0.68, 1.0), fi % 3)
        fi += 1
frond(Vector((0.03, -0.02, 0.36)), tops[2][1] + 0.6, 0.35, 0.42, 0, dry=True)  # один подсохший лист снизу
obj("stems", stems, [M_STEM])
obj("leaves", leaves, M_LEAF + [M_DRY])

bpy.ops.object.select_all(action="SELECT")
bpy.ops.export_scene.gltf(filepath=out, export_format="GLB", use_selection=True, export_apply=True)
tris = sum(len(o.data.polygons) for o in bpy.data.objects if o.type == "MESH")
print("PALM faces", tris)
