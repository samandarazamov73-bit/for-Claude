"""Blender (bpy) script: split multi-item files, turn, scale to real size, origin on the floor (lamps: at the top).
glTF axes in comments: X width, Y up, Z front. Blender: X, Z up, -Y front."""
import bpy, sys, os, json, math
from mathutils import Vector, Matrix

SRC, OUT = sys.argv[-2], sys.argv[-1]
# file → list of outputs. rule: ("H", m) overall height; ("top", m) height of the main flat top; ("len", m) longest
# horizontal extent; rot: degrees about the vertical axis (glTF Y) applied first; hang: origin at the top
JOBS = {
 "armchair_beige 1.glb": dict(split=["armchair_beige__1", "armchair_beige__2", "armchair_beige__3"], rule=("H", 0.86)),
 "armchair_beige 2.glb": dict(split=["armchair__1", "armchair_red__1", "armchair_beige__4"], rule=("H", 0.86)),
 "bedside 1.glb": dict(split=["bedside__1", "bedside__2"], rule=("top", 0.62)),
 "bedside 2.glb": dict(split=["bedside__3", "bedside__4", "bedside__5"], rule=("top", 0.62)),
 "table_small 1.glb": dict(split=["table_small__1", "table_small__2", "table_small__3"], rule=("top", 0.55),
                          rules=[("top", 0.5), ("top", 0.55), ("H", 0.85)], square=[True, False, True]),
 "bath.glb": dict(out="bathtub", rule=("len", 1.7), rot=-90),
 "chair.glb": dict(out="chair", rule=("H", 0.9)),
 "cupboard.glb": dict(out="wardrobe", rule=("H", 1.85)),
 "epi_bed.glb": dict(out="epi_bed", rule=("len", 2.05)),
 "epi_bed 2.glb": dict(out="epi_bed_2", rule=("len", 2.05), rot=-90),
 "epi_cabinet.glb": dict(out="epi_cabinet", rule=("H", 1.65)),
 "epi_cabinet 2.glb": dict(out="epi_cabinet_2", rule=("H", 0.85)),
 "epi_iv.glb": dict(out="epi_iv", rule=("H", 1.9)),
 "epi_lamp.glb": dict(out="epi_lamp", rule=("len", 1.2), hang=True),
 "epi_monitor.glb": dict(out="epi_monitor", rule=("W", 0.45)),
 "for badroom (for toilet).glb": dict(out="bath_shelf", rule=("H", 0.9)),
 "for table.glb": dict(out="table_items", rule=("H", 0.30)),
 "heating.glb": dict(out="radiator", rule=("H", 0.5)),
 "prologue_bus_stop.glb": dict(out="prologue_bus_stop", rule=("H", 2.8), rot=-90),
 "sink.glb": dict(out="sink", rule=("W", 0.55)),
 "standard wheelchairs, just to have them sitting in a hallway or something like that.glb": dict(out="wheelchair", rule=("H", 0.92)),
 "story_rat.glb": dict(out="story_rat", rule=("len", 0.38)),
 "story_roach.glb": dict(out="story_roach", rule=("len", 0.055)),
 "story_void_lamp.glb": dict(out="story_void_lamp", rule=("H", 0.7), hang=True),
 "story_washer.glb": dict(out="story_washer", rule=("H", 0.86)),
 "table.glb": dict(out="table_sq", rule=("top", 0.75)),
 "toilet.glb": dict(out="toilet", rule=("H", 0.8)),
}

def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)

def bbox(objs):
    mn = Vector((1e9,) * 3); mx = Vector((-1e9,) * 3)
    for o in objs:
        for v in o.data.vertices:
            w = o.matrix_world @ v.co
            mn = Vector(map(min, mn, w)); mx = Vector(map(max, mx, w))
    return mn, mx

def select_only(objs, active=None):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs: o.select_set(True)
    bpy.context.view_layer.objects.active = active or objs[0]

def islands(o):
    """vertex islands of the mesh → list of (min, max) world bboxes"""
    n = len(o.data.vertices); par = list(range(n))
    def f(i):
        while par[i] != i: par[i] = par[par[i]]; i = par[i]
        return i
    for e in o.data.edges:
        a, b = f(e.vertices[0]), f(e.vertices[1])
        if a != b: par[a] = b
    bb = {}
    mw = o.matrix_world
    for v in o.data.vertices:
        r = f(v.index); w = mw @ v.co
        if r in bb:
            mn, mx = bb[r]; bb[r] = (Vector(map(min, mn, w)), Vector(map(max, mx, w)))
        else:
            bb[r] = (w.copy(), w.copy())
    return list(bb.values())

def top_height(o, mn, mx):
    """height of the top of the biggest piece (cabinet body, table frame) above the lowest point"""
    best = max(islands(o), key=lambda b: (b[1] - b[0]).x * (b[1] - b[0]).y)
    return best[1].z - mn.z

def clusters(parts, n_items):
    bb = [bbox([p]) for p in parts]
    area = [(b[1].x - b[0].x) * (b[1].y - b[0].y) for b in bb]
    order = sorted(range(len(parts)), key=lambda i: -area[i])
    seeds = []
    for i in order:
        if len(seeds) == n_items: break
        a = bb[i]
        inside = any(min(a[1].x, bb[k][1].x) - max(a[0].x, bb[k][0].x) > 0.5 * (a[1].x - a[0].x) and
                     min(a[1].y, bb[k][1].y) - max(a[0].y, bb[k][0].y) > 0.5 * (a[1].y - a[0].y) for k in seeds)
        if not inside: seeds.append(i)
    groups = {k: [parts[k]] for k in seeds}
    gb = {k: (bb[k][0].copy(), bb[k][1].copy()) for k in seeds}
    for i in order:
        if i in groups: continue
        a = bb[i]
        def score(k):
            b = gb[k]
            ox = min(a[1].x, b[1].x) - max(a[0].x, b[0].x); oy = min(a[1].y, b[1].y) - max(a[0].y, b[0].y)
            return max(ox, 0) * max(oy, 0) + 1e-3 * min(ox, 0) + 1e-3 * min(oy, 0)
        k = max(seeds, key=score)
        groups[k].append(parts[i])
        gb[k] = (Vector(map(min, gb[k][0], a[0])), Vector(map(max, gb[k][1], a[1])))
    return list(groups.values())

def square_up(o):
    import numpy as np
    pts = np.array([(o.matrix_world @ v.co).xy[:] for v in o.data.vertices])
    best = None
    for a in np.arange(0, 90, 0.5):
        t = np.radians(a); R = np.array([[np.cos(t), -np.sin(t)], [np.sin(t), np.cos(t)]])
        q = pts @ R.T; area = np.ptp(q[:, 0]) * np.ptp(q[:, 1])
        if best is None or area < best[0]: best = (area, a)
    a = best[1]
    return a if a <= 45 else a - 90

def finish(o, rule, rot, hang, name, report, square=False):
    select_only([o])
    if square:
        rot = (rot or 0) + square_up(o)
        print(f"    yaw fix {rot:+.1f}°")
    if rot:
        o.rotation_mode = "XYZ"; o.rotation_euler = (0, 0, math.radians(rot)); bpy.ops.object.transform_apply(rotation=True)
    mn, mx = bbox([o])
    kind, val = rule
    if kind == "H": cur = mx.z - mn.z
    elif kind == "W": cur = mx.x - mn.x
    elif kind == "len": cur = max(mx.x - mn.x, mx.y - mn.y)
    elif kind == "top": cur = top_height(o, mn, mx)
    s = val / cur
    o.scale = (s, s, s); bpy.ops.object.transform_apply(scale=True)
    mn, mx = bbox([o])
    c = (mn + mx) / 2
    off = Vector((-c.x, -c.y, -(mx.z if hang else mn.z)))
    o.data.transform(Matrix.Translation(off)); o.location = (0, 0, 0)
    mn, mx = bbox([o])
    tris = sum(len(p.vertices) - 2 for p in o.data.polygons)
    select_only([o])
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, name + ".glb"), export_format="GLB", use_selection=True,
                              export_apply=True, export_yup=True)
    # report in glTF axes: W = X, H = Blender Z, D = Blender Y
    report[name] = dict(W=round(mx.x - mn.x, 3), H=round(mx.z - mn.z, 3), D=round(mx.y - mn.y, 3), scale=round(s, 4), tris=tris)
    print(f"  {name:22s} W {mx.x-mn.x:6.3f} H {mx.z-mn.z:6.3f} D {mx.y-mn.y:6.3f}  x{s:.3f}  tris {tris}")

os.makedirs(OUT, exist_ok=True)
report = {}
for f, job in JOBS.items():
    reset()
    bpy.ops.import_scene.gltf(filepath=os.path.join(SRC, f))
    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    select_only(meshes); bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    if len(meshes) > 1:
        bpy.ops.object.join()
    o = bpy.context.view_layer.objects.active
    for p in [x for x in bpy.context.scene.objects if x.type != "MESH"]:
        bpy.data.objects.remove(p)
    print(f)
    if "split" in job:
        select_only([o]); bpy.ops.object.mode_set(mode="EDIT"); bpy.ops.mesh.select_all(action="SELECT")
        bpy.ops.mesh.separate(type="LOOSE"); bpy.ops.object.mode_set(mode="OBJECT")
        parts = [x for x in bpy.context.scene.objects if x.type == "MESH"]
        groups = clusters(parts, len(job["split"]))
        groups.sort(key=lambda g: (bbox(g)[0].x + bbox(g)[1].x) / 2)        # left → right in the front view
        print(f"  {len(parts)} loose parts → {len(groups)} items")
        if len(groups) != len(job["split"]):
            print("  !! expected", len(job["split"])); continue
        objs = []
        for g in groups:
            select_only(g); bpy.ops.object.join(); objs.append(bpy.context.view_layer.objects.active)
        for n_i, (ob, name) in enumerate(zip(objs, job["split"])):
            # each item alone in the scene for export
            for other in objs:
                other.hide_set(other is not ob)
            rule = job.get("rules", [job["rule"]] * 9)[n_i]
            sq = job.get("square", [True] * 9)[n_i]
            finish(ob, rule, job.get("rot", 0), job.get("hang", False), name, report, square=sq)
    else:
        finish(o, job["rule"], job.get("rot", 0), job.get("hang", False), job["out"], report)
json.dump(report, open(os.path.join(OUT, "_report.json"), "w"), indent=1)
