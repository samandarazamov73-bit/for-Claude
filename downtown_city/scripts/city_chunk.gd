class_name CityChunk
extends RefCounted
## One city block worth of content. Everything is batched per chunk:
##  - kit modules and props -> one MultiMeshInstance3D per (mesh, visibility class)
##  - procedural geometry   -> one ArrayMesh per layer (one surface per material)
##  - collisions            -> one StaticBody3D with primitive shapes
## Visibility ranges give a cheap HLOD: kit facades within DETAIL_RANGE, merged
## shell boxes with a procedural facade shader beyond it.

const RANGES := {
	"detail": 175.0,     # kit facade modules + near procedural details
	"props": 95.0,       # small street furniture
	"street": 340.0,     # trees, lamps, signals
	"roof": 420.0,       # rooftop clutter
}
const DETAIL_MARGIN := 12.0

var name := ""
var center := Vector3.ZERO
var instances := {}  # key -> {mesh, cls, shadow, xforms: Array, customs: PackedColorArray}
var detail := GeoBatch.new()
var ground := GeoBatch.new()
var always := GeoBatch.new()
var shell := GeoBatch.new()
var shadow := GeoBatch.new()
var decals := GeoBatch.new()
var boxes: Array = []      # [Transform3D, Vector3 size]
var cylinders: Array = []  # [Vector3 base, radius, height]
var stats := {"instances": 0}
var decal_cls := "props"


func _init(n: String, c: Vector3) -> void:
	name = n
	center = c


func add_instance(m: Mesh, xf: Transform3D, custom := Color(0, 0, 0, 0), cls := "detail", cast_shadow := false) -> void:
	if m == null:
		return
	var key := "%d|%s|%s" % [m.get_instance_id(), cls, cast_shadow]
	if not instances.has(key):
		instances[key] = {"mesh": m, "cls": cls, "shadow": cast_shadow, "xforms": [], "customs": PackedColorArray()}
	var e: Dictionary = instances[key]
	e.xforms.append(xf)
	e.customs.append(custom)
	stats.instances += 1


func add_box_collider(xf: Transform3D, size: Vector3) -> void:
	boxes.append([xf, size])


func add_cylinder_collider(base: Vector3, radius: float, height: float) -> void:
	cylinders.append([base, radius, height])


func build(parent: Node3D, settings: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = name
	root.position = center
	parent.add_child(root)
	var to_local := Transform3D(Basis(), -center)

	for key in instances:
		var e: Dictionary = instances[key]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = e.mesh
		mm.instance_count = e.xforms.size()
		for i in e.xforms.size():
			mm.set_instance_transform(i, to_local * e.xforms[i])
			mm.set_instance_custom_data(i, e.customs[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		var cls: String = e.cls
		if cls == "always":
			pass
		else:
			mmi.visibility_range_end = RANGES[cls]
			mmi.visibility_range_end_margin = DETAIL_MARGIN
		if e.shadow:
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		elif cls == "detail":
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if settings.get("detail_shadows", false) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mmi.add_to_group("detail_shadow_casters")
		else:
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		root.add_child(mmi)

	_add_geo(root, detail, to_local, "detail", GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "detail_shadow_casters")
	_add_geo(root, ground, to_local, "", GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	_add_geo(root, always, to_local, "", GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	_add_geo(root, decals, to_local, decal_cls, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	var far := _add_geo(root, shell, to_local, "", GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	if far:
		far.visibility_range_begin = RANGES["detail"] - DETAIL_MARGIN
		far.visibility_range_begin_margin = DETAIL_MARGIN
	var sh := _add_geo(root, shadow, to_local, "", GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY)
	if sh:
		sh.name = "ShadowProxy"

	if not boxes.is_empty() or not cylinders.is_empty():
		var body := StaticBody3D.new()
		body.name = "Collision"
		root.add_child(body)
		for b in boxes:
			var cs := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = b[1]
			cs.shape = shape
			cs.transform = to_local * (b[0] as Transform3D)
			body.add_child(cs)
		for c in cylinders:
			var cs := CollisionShape3D.new()
			var shape := CylinderShape3D.new()
			shape.radius = c[1]
			shape.height = c[2]
			cs.shape = shape
			cs.position = (c[0] as Vector3) - center + Vector3(0, c[2] * 0.5, 0)
			body.add_child(cs)
	return root


func _add_geo(root: Node3D, batch: GeoBatch, to_local: Transform3D, cls: String, shadow_mode: int, group := "") -> MeshInstance3D:
	if batch.is_empty():
		return null
	# geometry was accumulated in world space: bake the chunk offset into the vertices
	for s in batch.surfaces.values():
		var v: PackedVector3Array = s.verts
		for i in v.size():
			v[i] = to_local * v[i]
		s.verts = v
	var mi := MeshInstance3D.new()
	mi.mesh = batch.commit()
	mi.cast_shadow = shadow_mode
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	if cls != "":
		mi.visibility_range_end = RANGES[cls]
		mi.visibility_range_end_margin = DETAIL_MARGIN
	if group != "":
		mi.add_to_group(group)
	root.add_child(mi)
	return mi
