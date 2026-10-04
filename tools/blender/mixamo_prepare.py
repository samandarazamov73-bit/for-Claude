# Blender 3.x / 4.x / 5.x — подготовка персонажа из glTF/GLB к загрузке на Mixamo.
# Выделите кликом любую часть персонажа -> Run Script: объединится вся его иерархия
# (все вложенные меши, включая скрытые). Ничего не выделено — объединятся все меши сцены.
import bpy
import bmesh
import os

DECIMATE_RATIO = 0.1      # ваш GLB: 286 199 треугольников -> ~28 600. Для ~80 000 поставьте 0.28
MERGE_DISTANCE = 0.0001   # сварка совпадающих вершин перед Decimate (0 = не сваривать)
RESULT_NAME = "Character"
EXPORT_FBX = True         # Mixamo не принимает GLB — сохранить FBX, WebP-текстуры встроить как PNG
FBX_PATH = ""             # пусто = mixamo_ready.fbx рядом с .blend (или в домашней папке)

ctx = bpy.context
scene = ctx.scene
view_layer = ctx.view_layer
root = scene.collection

# 0. Object Mode
try:
    if ctx.object and ctx.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
except RuntimeError:
    pass

# 1. Извлечь все меши из иерархий, сохранив мировое положение
view_layer.update()
scene_ptrs = {ob.as_pointer() for ob in scene.objects}
meshes = [ob for ob in scene.objects if ob.type == 'MESH']
if not meshes:
    raise RuntimeError("В сцене нет ни одного Mesh-объекта")


def descendants(ob, found):
    for child in ob.children:
        if child.as_pointer() in scene_ptrs and child.as_pointer() not in found:
            found[child.as_pointer()] = child
            descendants(child, found)
    return found


selected = list(ctx.selected_objects)
if selected:
    family = {}
    for ob in selected:
        while ob.parent:
            ob = ob.parent
        family[ob.as_pointer()] = ob
        descendants(ob, family)
    meshes_ptrs = {ob.as_pointer() for ob in family.values() if ob.type == 'MESH'}
    targets = [ob for ob in meshes if ob.as_pointer() in meshes_ptrs]
    if not targets:
        raise RuntimeError("В иерархии выделенного объекта нет мешей")
else:
    targets = meshes

world = [(ob, ob.matrix_world.copy()) for ob in meshes]
for ob, mw in world:
    ob.parent = None
    ob.matrix_world = mw
for ob in targets:
    ob.animation_data_clear()
    ob.constraints.clear()
    for mod in [m for m in ob.modifiers if m.type == 'ARMATURE']:
        ob.modifiers.remove(mod)

# Запечь модификаторы и shape keys, разорвать общие (multi-user) меши — иначе
# join / transform_apply / Decimate отказываются работать
depsgraph = ctx.evaluated_depsgraph_get()
for ob in targets:
    if len(ob.modifiers) or ob.data.shape_keys:
        new_me = bpy.data.meshes.new_from_object(ob.evaluated_get(depsgraph))
        ob.modifiers.clear()
        ob.data = new_me
        if ob.data.shape_keys:
            ob.shape_key_clear()
    elif ob.data.users > 1:
        ob.data = ob.data.copy()

keep = [ob for ob in targets if len(ob.data.polygons) > 0]
if not keep:
    raise RuntimeError("Меши найдены, но в них нет ни одного полигона")
keep_ptrs = {ob.as_pointer() for ob in keep}
others = [ob for ob in meshes if ob not in targets]  # не входят в модель (например, куб по умолчанию)
others_ptrs = {ob.as_pointer() for ob in others}

# 2. Перенести меши в корневую коллекцию, удалить пустышки, камеры, свет, арматуры
#    и меши модели без полигонов, затем все коллекции
for ob in keep + others:
    if root not in ob.users_collection:
        root.objects.link(ob)
    for coll in list(ob.users_collection):
        if coll != root:
            coll.objects.unlink(ob)

for ob in list(scene.objects):
    if ob.as_pointer() not in keep_ptrs and ob.as_pointer() not in others_ptrs:
        bpy.data.objects.remove(ob, do_unlink=True)


def child_collections(coll, found):
    for child in coll.children:
        if child.as_pointer() not in found:
            found[child.as_pointer()] = child
            child_collections(child, found)
    return found


for coll in child_collections(root, {}).values():
    bpy.data.collections.remove(coll)

for ob in keep:
    ob.hide_viewport = False
    ob.hide_select = False
    ob.hide_render = False
    try:
        ob.hide_set(False)
    except RuntimeError:
        pass

# 3. Объединить всё в один объект
for ob in view_layer.objects:
    ob.select_set(False)
for ob in keep:
    ob.select_set(True)
view_layer.objects.active = max(keep, key=lambda o: len(o.data.polygons))
if len(keep) > 1:
    bpy.ops.object.join()

obj = view_layer.objects.active
obj.name = RESULT_NAME
obj.data.name = RESULT_NAME
obj.select_set(True)

# 4. Применить трансформации
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

# Сварить разорванные вершины, сбросить кастомные нормали из glTF (после
# Decimate они дают артефакты), гладкое затенение
me = obj.data
if MERGE_DISTANCE > 0:
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=MERGE_DISTANCE)
    bm.to_mesh(me)
    bm.free()
try:
    bpy.ops.mesh.customdata_custom_splitnormals_clear()
except RuntimeError:
    pass
me.polygons.foreach_set("use_smooth", [True] * len(me.polygons))
me.update()

# 5. Decimate
tris_before = sum(len(p.vertices) - 2 for p in me.polygons)
mod = obj.modifiers.new(name="Decimate", type='DECIMATE')
mod.decimate_type = 'COLLAPSE'
mod.ratio = DECIMATE_RATIO
mod.use_collapse_triangulate = True
bpy.ops.object.modifier_apply(modifier=mod.name)
tris_after = sum(len(p.vertices) - 2 for p in obj.data.polygons)

try:
    bpy.data.orphans_purge(do_recursive=True)
except (AttributeError, TypeError, RuntimeError):
    pass

# Экспорт FBX для Mixamo
fbx_path = ""
if EXPORT_FBX:
    # Mixamo не читает WebP: перепаковать текстуры в PNG
    for img in bpy.data.images:
        if img.source != 'FILE' or img.size[0] == 0 or img.file_format in {'PNG', 'JPEG'}:
            continue
        img.pixels[0] = img.pixels[0]  # пометить изменённой, чтобы pack() перекодировал в PNG
        img.file_format = 'PNG'
        img.filepath_raw = "//textures/" + bpy.path.clean_name(img.name) + ".png"
        img.pack()

    fbx_path = FBX_PATH or os.path.join(
        os.path.dirname(bpy.data.filepath) if bpy.data.filepath else os.path.expanduser("~"),
        "mixamo_ready.fbx")
    bpy.ops.export_scene.fbx(
        filepath=fbx_path,
        use_selection=True,
        object_types={'MESH'},
        use_mesh_modifiers=True,
        mesh_smooth_type='FACE',
        add_leaf_bones=False,
        bake_anim=False,
        path_mode='COPY',
        embed_textures=True,
    )

msg = "Готово: {} -> {} треугольников".format(tris_before, tris_after)
if fbx_path:
    msg += " | FBX: " + fbx_path
print(msg)
if not bpy.app.background and ctx.window_manager.windows:
    ctx.window_manager.popup_menu(lambda self, _ctx: self.layout.label(text=msg),
                                  title="Mixamo", icon='INFO')
