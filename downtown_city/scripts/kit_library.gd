class_name KitLibrary
extends RefCounted
## Loads the Quaternius Downtown City MegaKit modules (models/kit/*.gltf, repacked by
## tools/prepare_kit.py) and swaps their placeholder materials for the city materials by name.
## Modules face +Z, origin at the bottom centre of the facade plane, 2 m bays, 3 m storeys.

const SHOP_INTERIOR := ["Metal_FirstFloor_Window"]

var mats: CityMaterials
var meshes := {}   # module name -> Mesh
var aabbs := {}    # module name -> AABB


func _init(materials: CityMaterials) -> void:
	mats = materials


func has(name: String) -> bool:
	return meshes.has(name) or ResourceLoader.exists("res://models/kit/%s.gltf" % name)


func mesh(name: String) -> Mesh:
	if meshes.has(name):
		return meshes[name]
	var path := "res://models/kit/%s.gltf" % name
	var scene: PackedScene = load(path)
	if scene == null:
		push_error("Kit module missing: " + path)
		return null
	var root := scene.instantiate()
	var mi: MeshInstance3D = root if root is MeshInstance3D else root.find_children("*", "MeshInstance3D", true, false)[0]
	var m: Mesh = mi.mesh
	for s in m.get_surface_count():
		var placeholder := m.surface_get_material(s)
		var mat_name := placeholder.resource_name if placeholder else ""
		var mat: Material = mats.kit.get(mat_name)
		if mat_name == "MI_FakeInterior" and name in SHOP_INTERIOR:
			mat = mats.interior_shop
		if mat == null:
			push_warning("No city material for %s in %s" % [mat_name, name])
			mat = mats.kit["MI_Trim"]
		m.surface_set_material(s, mat)
	root.free()
	meshes[name] = m
	aabbs[name] = m.get_aabb()
	return m


func aabb(name: String) -> AABB:
	if not aabbs.has(name):
		mesh(name)
	return aabbs.get(name, AABB())
