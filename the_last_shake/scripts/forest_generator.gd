@tool
class_name ForestGenerator
extends Node3D
## Builds all vegetation, rocks and props from assets/catalog.json and the instance sets baked by
## tools/world_gen.py:
##   trees, understory, bushes, rocks, props -> LodManager (per-instance LOD, 3 levels)
##   cover (grass, ferns, forbs, stones, twigs) -> LodManager too (one mesh, distance fade, density)
## Materials are shared .tres resources in assets/materials (one per kind, not per asset).

const MATERIALS := {
	"foliage": "res://assets/materials/foliage.tres",
	"foliage_cover": "res://assets/materials/foliage_cover.tres",
	"bark": "res://assets/materials/bark.tres",
	"rock": "res://assets/materials/rock.tres",
	"prop": "res://assets/materials/prop.tres",
}
const LOD_SETS := ["trees", "understory", "bushes", "rocks", "props", "cover"]

static var _mesh_cache := {}

var catalog := {}
var materials := {}
var lod_manager: LodManager
var load_ms := {}


func build(meta: Dictionary, terrain: TerrainSystem) -> void:
	var t0 := Time.get_ticks_msec()
	var cat: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/catalog.json"))
	for v in cat["variants"]:
		catalog[v["name"]] = v
	for k in MATERIALS:
		materials[k] = load(MATERIALS[k])
	lod_manager = LodManager.new()
	lod_manager.name = "LodManager"
	lod_manager.terrain = terrain
	add_child(lod_manager)
	for set_name in LOD_SETS:
		var t1 := Time.get_ticks_msec()
		var data := load_instance_set(str(meta["instances"][set_name]))
		lod_manager.add_set(data, catalog, materials, set_name)
		load_ms[set_name] = Time.get_ticks_msec() - t1
	lod_manager.compute_cell_heights()
	load_ms["total"] = Time.get_ticks_msec() - t0


func configure(s: Dictionary) -> void:
	lod_manager.configure(s)


## Reads an inst_<set>.bin.gz file: "FDI1", u32 header length, JSON header, float32 instance data.
static func load_instance_set(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	assert(f != null, "missing " + path)
	var raw := f.get_buffer(f.get_length()).decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	assert(raw.slice(0, 4).get_string_from_ascii() == "FDI1", "bad instance file " + path)
	var hlen := raw.decode_u32(4)
	var header: Dictionary = JSON.parse_string(raw.slice(8, 8 + hlen).get_string_from_utf8())
	header["floats"] = raw.slice(8 + hlen).to_float32_array()
	return header


## LOD meshes of a catalog entry with the shared materials assigned (cached per file).
static func load_lod_meshes(meta: Dictionary, materials: Dictionary) -> Array[Mesh]:
	var file := str(meta["file"])
	if _mesh_cache.has(file):
		return _mesh_cache[file]
	var scene: PackedScene = load(file)
	var root := scene.instantiate()
	var out: Array[Mesh] = []
	for i in 3:
		var node := root.find_child("LOD%d" % i, true, false)
		if node is MeshInstance3D:
			out.append((node as MeshInstance3D).mesh)
	root.free()
	assert(out.size() > 0, "no LOD meshes in " + file)
	for m in out:
		for s in m.get_surface_count():
			var mat := m.surface_get_material(s)
			var sname := mat.resource_name if mat else ""
			if sname == "":
				sname = (m as ArrayMesh).surface_get_name(s) if m is ArrayMesh else ""
			var key := "prop"
			if sname.begins_with("foliage"):
				key = "foliage_cover" if meta["category"] == "cover" else "foliage"
			elif sname.begins_with("bark"):
				key = "bark"
			elif meta["group"] == "rocks":
				key = "rock"
			m.surface_set_material(s, materials[key])
	_mesh_cache[file] = out
	return out
