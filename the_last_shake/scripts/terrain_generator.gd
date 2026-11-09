@tool
class_name TerrainSystem
extends Node3D
## Chunked terrain driven by the 1 m heightmap baked by tools/world_gen.py.
##
## * The world is split into 64 m chunks (32 x 32). Every chunk is a MeshInstance3D that uses one of
##   five shared flat grid meshes (0.5 m .. 8 m spacing); the vertex shader displaces it from the
##   heightmap texture, so terrain geometry costs almost no memory.
## * Each chunk picks its LOD from its 2D distance to the camera; odd vertices morph onto the next
##   coarser grid before the switch (no popping), and skirts hide T-junction cracks.
## * Chunks outside the frustum are culled by Godot using a per-chunk custom AABB; hills are added
##   as conservative occluders for occlusion culling.
## * Physics uses a HeightMapShape3D built from the same heights.

const CHUNK := 64.0
const SPACING := [0.5, 1.0, 2.0, 4.0, 8.0]
const SKIRT := [0.25, 0.45, 0.9, 1.8, 3.6]

@export var lod_end := PackedFloat32Array([70.0, 190.0, 400.0, 760.0])   # chunk LOD 0..3 end distance
@export var material: ShaderMaterial

var res := 2049
var origin := -1024.0
var heights := PackedFloat32Array()
var height_texture: ImageTexture
var grid_meshes: Array[ArrayMesh] = []
var grid_tris: Array[int] = []
var chunks: Array[Dictionary] = []
var lod_scale := 1.0
## Low/Medium: the finest (0.5 m) chunks around the camera don't render into the shadow cascades;
## trees still shadow the ground, only the floor's own micro self-shadowing is lost.
var near_chunk_shadows := true
var _last_cam := Vector3(INF, 0, INF)
var stats := {"chunk_lods": [0, 0, 0, 0, 0], "allocated_triangles": 0}


func load_world(meta: Dictionary, with_physics := true) -> void:
	res = int(meta["resolution"])
	origin = float(meta["origin"])
	var f := FileAccess.open(str(meta["heightmap"]), FileAccess.READ)
	assert(f != null, "heightmap missing")
	var raw := f.get_buffer(f.get_length()).decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	heights = raw.to_float32_array()
	assert(heights.size() == res * res)
	var img := Image.create_from_data(res, res, false, Image.FORMAT_RF, raw)
	height_texture = ImageTexture.create_from_image(img)
	RenderingServer.global_shader_parameter_set("terrain_height", height_texture)
	RenderingServer.global_shader_parameter_set("world_rect", Vector4(origin, origin, res, res))
	_build_grid_meshes()
	_build_chunks(float(meta["height_min"]), float(meta["height_max"]))
	if with_physics:
		_build_collision()
	_build_occluders()


## Bilinear terrain height (same data the GPU uses; ignores the sub-metre shader relief).
func height_at(x: float, z: float) -> float:
	var fx := clampf(x - origin, 0.0, res - 1.001)
	var fz := clampf(z - origin, 0.0, res - 1.001)
	var ix := int(fx)
	var iz := int(fz)
	var tx := fx - ix
	var tz := fz - iz
	var i := iz * res + ix
	var a := heights[i]
	var b := heights[i + 1]
	var c := heights[i + res]
	var d := heights[i + res + 1]
	return lerpf(lerpf(a, b, tx), lerpf(c, d, tx), tz)


func normal_at(x: float, z: float) -> Vector3:
	var hx := height_at(x + 0.5, z) - height_at(x - 0.5, z)
	var hz := height_at(x, z + 0.5) - height_at(x, z - 0.5)
	return Vector3(-hx, 1.0, -hz).normalized()


func _build_grid_meshes() -> void:
	var total := 0
	for k in SPACING.size():
		var g: float = SPACING[k]
		var n := int(CHUNK / g)
		var verts := PackedVector3Array()
		var uv2 := PackedVector2Array()
		var idx := PackedInt32Array()
		for j in n + 1:
			for i in n + 1:
				verts.append(Vector3(i * g, 0.0, j * g))
				uv2.append(Vector2(0, 0))
		for j in n:
			for i in n:
				var a := j * (n + 1) + i
				var b := a + 1
				var c := a + n + 1
				var d := c + 1
				# alternate the diagonal so morphing collapses odd vertices consistently
				idx.append_array([a, b, c, b, d, c])
		# skirts: duplicate the border ring and pull it down in the shader (UV2.x = 1)
		var border: Array[int] = []
		for i in n + 1: border.append(i)                                  # z = 0
		for j in range(1, n + 1): border.append(j * (n + 1) + n)          # x = max
		for i in range(n - 1, -1, -1): border.append(n * (n + 1) + i)    # z = max
		for j in range(n - 1, 0, -1): border.append(j * (n + 1))          # x = 0
		var base := verts.size()
		for bi in border:
			verts.append(verts[bi])
			uv2.append(Vector2(1, 0))
		var m := border.size()
		for e in m:
			var t0 := border[e]
			var t1 := border[(e + 1) % m]
			var s0 := base + e
			var s1 := base + (e + 1) % m
			idx.append_array([t1, t0, s0, t1, s0, s1])
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		var nrm := PackedVector3Array()
		nrm.resize(verts.size())
		nrm.fill(Vector3.UP)
		arr[Mesh.ARRAY_NORMAL] = nrm
		arr[Mesh.ARRAY_TEX_UV2] = uv2
		arr[Mesh.ARRAY_INDEX] = idx
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		mesh.surface_set_material(0, material)
		mesh.resource_name = "terrain_grid_%sm" % g
		grid_meshes.append(mesh)
		grid_tris.append(idx.size() / 3)
		total += idx.size() / 3
	stats["allocated_triangles"] = total


func _build_chunks(hmin: float, hmax: float) -> void:
	var count := int(round((res - 1) / CHUNK))
	for cz in count:
		for cx in count:
			var x0 := origin + cx * CHUNK
			var z0 := origin + cz * CHUNK
			# height range of this chunk for culling
			var lo := INF
			var hi := -INF
			var step := 4
			var ix0 := int(cx * CHUNK)
			var iz0 := int(cz * CHUNK)
			for j in range(0, int(CHUNK) + 1, step):
				for i in range(0, int(CHUNK) + 1, step):
					var h := heights[mini(iz0 + j, res - 1) * res + mini(ix0 + i, res - 1)]
					lo = minf(lo, h)
					hi = maxf(hi, h)
			var mi := MeshInstance3D.new()
			mi.name = "Chunk_%d_%d" % [cx, cz]
			mi.mesh = grid_meshes[4]
			mi.position = Vector3(x0, 0.0, z0)
			mi.custom_aabb = AABB(Vector3(0, lo - 5.0, 0), Vector3(CHUNK, hi - lo + 7.0, CHUNK))
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
			add_child(mi)
			chunks.append({"node": mi, "rect": Rect2(x0, z0, CHUNK, CHUNK), "lod": -1, "center_y": (lo + hi) * 0.5})


func update_lods(cam: Vector3, force := false) -> void:
	if not force and Vector2(cam.x - _last_cam.x, cam.z - _last_cam.z).length() < 3.0:
		return
	_last_cam = cam
	var counts := [0, 0, 0, 0, 0]
	for c in chunks:
		var r: Rect2 = c["rect"]
		var dx := maxf(maxf(r.position.x - cam.x, 0.0), cam.x - r.end.x)
		var dz := maxf(maxf(r.position.y - cam.z, 0.0), cam.z - r.end.y)
		var d := sqrt(dx * dx + dz * dz)
		var lod := 4
		for k in 4:
			if d < lod_end[k] * lod_scale:
				lod = k
				break
		counts[lod] += 1
		if lod != c["lod"]:
			c["lod"] = lod
			var mi: MeshInstance3D = c["node"]
			mi.mesh = grid_meshes[lod]
			var end := lod_end[lod] * lod_scale if lod < 4 else 1e6
			var start := end * (0.84 if lod == 1 else 0.78)
			mi.set_instance_shader_parameter("chunk_info", Vector4(SPACING[lod], start, end - 2.0, SKIRT[lod]))
			# shadows from distant terrain chunks are not needed
			var cast := lod <= 2 and (lod > 0 or near_chunk_shadows)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	stats["chunk_lods"] = counts


func visible_triangle_estimate() -> int:
	var t := 0
	for k in 5:
		t += int(stats["chunk_lods"][k]) * grid_tris[k]
	return t


func _build_collision() -> void:
	var body := StaticBody3D.new()
	body.name = "TerrainCollision"
	var shape := HeightMapShape3D.new()
	shape.map_width = res
	shape.map_depth = res
	shape.map_data = heights
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	add_child(body)


## Conservative hill occluders: a coarse grid of the terrain lowered by a safety margin.
func _build_occluders() -> void:
	var step := 32
	var n := (res - 1) / step + 1
	var verts := PackedVector3Array()
	for j in n:
		for i in n:
			var lo := INF
			for dj in range(-step, step + 1, 8):
				for di in range(-step, step + 1, 8):
					var x := clampi(i * step + di, 0, res - 1)
					var z := clampi(j * step + dj, 0, res - 1)
					lo = minf(lo, heights[z * res + x])
			verts.append(Vector3(origin + i * step, lo - 2.5, origin + j * step))
	var idx := PackedInt32Array()
	for j in n - 1:
		for i in n - 1:
			var a := j * n + i
			idx.append_array([a, a + 1, a + n, a + 1, a + n + 1, a + n])
	var occ := ArrayOccluder3D.new()
	occ.set_arrays(verts, idx)
	var oi := OccluderInstance3D.new()
	oi.name = "HillOccluder"
	oi.occluder = occ
	add_child(oi)
