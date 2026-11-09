@tool
class_name LodManager
extends Node3D
## Level-of-detail and culling for every instance: trees, saplings, bushes, rocks, props and the
## ground cover (grass, ferns, forbs, stones, twigs).
##
## Instances are baked offline (tools/world_gen.py) as MultiMesh buffers grouped by variant and by
## 32 m cell. For every variant there are three MultiMeshInstance3D "buckets", one per LOD mesh
## (ground cover has one mesh and uses bucket 0 only). A worker thread rebuilds the buckets around
## the camera every few metres of movement:
##   * cells whose distance range misses a LOD band, or that lie outside a widened view frustum, are
##     skipped (cells that can still throw a shadow into the view — the frustum swept towards the
##     sun — are kept for the shadow pass);
##   * every instance of the remaining cells is tested against its exact band and the frustum, and
##     ground cover is thinned by the preset density (random per-plant value, so thinning is uniform).
## The exact per-instance choice and the dithered cross-fade happen in the vertex/fragment shaders
## (shaders/include/forest_common.gdshaderinc) using the same distance bands, so the CPU only needs
## to run every few metres of camera movement and the result never pops.
## Draw calls stay at (variants x 3 LODs x surfaces) no matter how many instances exist.

const STRIDE := 16

class PlantVariant:
	var name := ""
	var group := ""
	var meshes: Array[Mesh] = []
	var lod := PackedFloat32Array([40.0, 120.0, 420.0])
	var height := 10.0
	var translucency := 1.0
	var cells := {}               # cell id -> PackedFloat32Array (16 floats / instance)
	var count := 0
	var buckets: Array = []       # per LOD: {node, mm, capacity, key, count}
	var cast_shadows := [true, true, false]
	var cover := false            # ground cover: one mesh, own distance scale, density thinning
	var kind := ""


var cell_size := 32.0
var grid := 64
var origin := -1024.0
var variants: Array[PlantVariant] = []
var cell_variants := {}           # cell id -> PackedInt32Array of variant indices
var cell_y := {}                  # cell id -> Vector2(min ground, max ground)
var terrain: TerrainSystem

# settings (GraphicsSettings)
var lod_scale := 1.0
var far_scale := 1.0
var shadow_distance := 130.0
var shadow_lod1 := true
var shadow_coarse := false
var cover_scale := 1.0
var cover_density := 1.0
var cover_shadows := false
var frustum_margin_deg := 18.0
var sun_light: DirectionalLight3D

var _task := -1
var _result: Array = []
var _last_pos := Vector3(INF, INF, INF)
var _last_fwd := Vector3.ZERO
var _dirty := true
var stats := {"updates": 0, "last_update_ms": 0.0, "apply_ms": 0.0, "visible_instances": [0, 0, 0, 0], "buckets": 0}


func add_set(data: Dictionary, catalog: Dictionary, materials: Dictionary, group: String) -> void:
	cell_size = float(data["cell"])
	grid = int(data["grid"])
	origin = float(data["origin"])
	var floats: PackedFloat32Array = data["floats"]
	for vd in data["variants"]:
		var meta: Dictionary = catalog[vd["name"]]
		var v := PlantVariant.new()
		v.name = vd["name"]
		v.group = group
		v.meshes = ForestGenerator.load_lod_meshes(meta, materials)
		v.lod = PackedFloat32Array(meta["lod"])
		v.height = float(meta["height"])
		v.translucency = 0.55 if meta["kind"] in ["pine", "spruce", "fir"] else 1.0
		v.kind = str(meta["kind"])
		v.cover = str(meta["category"]) == "cover"
		if v.cover:
			v.cast_shadows = [false, false, false]
		var off := int(vd["offset"])
		for c in vd["cells"]:
			var cid := int(c[0])
			var start := (off + int(c[1])) * STRIDE
			var n := int(c[2])
			v.cells[cid] = floats.slice(start, start + n * STRIDE)
			v.count += n
			var vi := variants.size()
			if not cell_variants.has(cid):
				cell_variants[cid] = PackedInt32Array()
			cell_variants[cid].append(vi)
		variants.append(v)
		_make_buckets(v)


## Buckets: 0 = LOD0, 1 = LOD1 inside the shadow range (casts), 2 = LOD2, 3 = LOD1 beyond the shadow
## range (same mesh and band as 1, but never rendered into the shadow cascades).
func _make_buckets(v: PlantVariant) -> void:
	for b in 4:
		var lod := 1 if b == 3 else b
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = v.meshes[mini(lod, v.meshes.size() - 1)]
		mm.instance_count = 0
		var node := MultiMeshInstance3D.new()
		node.name = "%s_LOD%d%s" % [v.name, lod, "_far" if b == 3 else ""]
		node.multimesh = mm
		node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if v.cast_shadows[lod] else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.set_instance_shader_parameter("plant_params", Vector4(v.height, v.translucency, 1.0, 3.0 if v.cover else float(lod)))
		add_child(node)
		v.buckets.append({"node": node, "mm": mm, "capacity": 0, "key": -1, "count": 0})
	_apply_ranges(v)


## LOD n draws between band[n].x and band[n].z (metres), with fade widths band[n].y / band[n].w.
## Ground cover has a single mesh: only bucket 0 is used, faded out at the end of its range.
func _bands(v: PlantVariant) -> Array:
	if v.cover:
		var e: float = v.lod[2] * cover_scale
		var off := Vector4(-1.0, 0.0, -1.0, 0.0)
		return [Vector4(0.0, 0.0, e, clampf(e * 0.25, 4.0, 14.0)), off, off]
	var d01: float = v.lod[0] * lod_scale
	var d12: float = v.lod[1] * lod_scale
	var dend: float = v.lod[2] * far_scale
	var w01 := clampf(d01 * 0.18, 3.0, 9.0)
	var w12 := clampf(d12 * 0.12, 6.0, 16.0)
	var wend := clampf(dend * 0.1, 8.0, 40.0)
	return [Vector4(0.0, 0.0, d01, w01), Vector4(d01, w01, d12, w12), Vector4(d12, w12, dend, wend)]


func _apply_ranges(v: PlantVariant) -> void:
	var bands := _bands(v)
	for b in 4:
		var lod := 1 if b == 3 else b
		var node: MultiMeshInstance3D = v.buckets[b]["node"]
		node.set_instance_shader_parameter("lod_range", bands[lod])
		if b == 3:
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			continue
		var cast := bool(v.cast_shadows[lod])
		if lod == 1 and not shadow_lod1 and not shadow_coarse:
			cast = false
		if lod == 0 and shadow_coarse:
			cast = false
		if v.cover:
			cast = lod == 0 and cover_shadows and v.kind in ["fern", "forb"]
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func configure(s: Dictionary) -> void:
	lod_scale = float(s["lod_scale"])
	far_scale = float(s["far_scale"])
	shadow_distance = float(s["shadow_distance"])
	shadow_lod1 = bool(s["shadow_lod1"])
	shadow_coarse = bool(s.get("shadow_coarse", false))
	cover_scale = float(s["cover_distance"])
	cover_density = float(s["cover_density"])
	cover_shadows = bool(s["cover_shadows"])
	for v in variants:
		_apply_ranges(v)
	_dirty = true


func compute_cell_heights() -> void:
	for cid in cell_variants:
		var cx := int(cid) % grid
		var cz := int(cid) / grid
		var lo := INF
		var hi := -INF
		for j in 5:
			for i in 5:
				var h := terrain.height_at(origin + (cx + i * 0.25) * cell_size, origin + (cz + j * 0.25) * cell_size)
				lo = minf(lo, h)
				hi = maxf(hi, h)
		var top := 0.0
		for vi in cell_variants[cid]:
			top = maxf(top, variants[vi].height * 1.3)
		cell_y[cid] = Vector3(lo - 1.0, hi, hi + top)


func update(cam: Camera3D) -> void:
	if _task != -1:
		if WorkerThreadPool.is_task_completed(_task):
			WorkerThreadPool.wait_for_task_completion(_task)
			_task = -1
			_apply_result()
		return
	var xf := cam.global_transform
	var fwd := -xf.basis.z
	if not _dirty and xf.origin.distance_to(_last_pos) < 4.0 and fwd.dot(_last_fwd) > cos(deg_to_rad(7.0)):
		return
	_dirty = false
	_last_pos = xf.origin
	_last_fwd = fwd
	var snap := {
		"xf": xf, "fov": cam.fov, "aspect": cam.get_viewport().get_visible_rect().size.aspect(),
		"light": (-sun_light.global_transform.basis.z) if sun_light else Vector3(0, -1, 0),
	}
	_task = WorkerThreadPool.add_task(_compute.bind(snap), false, "forest LOD update")


## Blocking full update (tests / benchmarks / first frame).
func update_now(cam: Camera3D) -> void:
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_apply_result()
	_dirty = true
	update(cam)
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_apply_result()


func _compute(snap: Dictionary) -> void:
	var t0 := Time.get_ticks_usec()
	var xf: Transform3D = snap["xf"]
	var cam := xf.origin
	var f := -xf.basis.z
	var r := xf.basis.x
	var u := xf.basis.y
	var hy := deg_to_rad(float(snap["fov"]) * 0.5 + frustum_margin_deg)
	var hx := atan(tan(deg_to_rad(float(snap["fov"]) * 0.5)) * float(snap["aspect"])) + deg_to_rad(frustum_margin_deg)
	hx = minf(hx, deg_to_rad(89.0))
	hy = minf(hy, deg_to_rad(89.0))
	var planes := [
		r * cos(hx) - f * sin(hx), -r * cos(hx) - f * sin(hx),
		u * cos(hy) - f * sin(hy), -u * cos(hy) - f * sin(hy), -f,
	]
	var light: Vector3 = snap["light"]
	var lh := Vector3(light.x, 0.0, light.z)
	var elev := asin(clampf(-light.y, 0.05, 1.0))
	var shadow_dir := lh.normalized() / maxf(tan(elev), 0.25) if lh.length() > 0.01 else Vector3.ZERO
	# per variant bands (+ slack for size variation and camera movement between updates)
	var vb := []
	var max_d := 0.0
	for v in variants:
		var bands := _bands(v)
		var arr := []
		for li in 3:
			var b: Vector4 = bands[li]
			if b.z < 0.0:
				arr.append(Vector2(INF, -INF))
				continue
			var lo := maxf((b.x - b.y * 0.5) * 0.84 - 6.0, -1.0) if b.x > 0.0 else -1.0
			if li == 1 and shadow_coarse:
				lo = -1.0
			var hi: float = (b.z + b.w * 0.5) * 1.17 + 6.0
			arr.append(Vector2(lo, hi))
			max_d = maxf(max_d, hi)
		vb.append(arr)
	var lists := []
	for v in variants.size():
		lists.append([PackedInt32Array(), PackedInt32Array(), PackedInt32Array()])
	var c0x := clampi(int(floor((cam.x - max_d - origin) / cell_size)), 0, grid - 1)
	var c1x := clampi(int(floor((cam.x + max_d - origin) / cell_size)), 0, grid - 1)
	var c0z := clampi(int(floor((cam.z - max_d - origin) / cell_size)), 0, grid - 1)
	var c1z := clampi(int(floor((cam.z + max_d - origin) / cell_size)), 0, grid - 1)
	for cz in range(c0z, c1z + 1):
		for cx in range(c0x, c1x + 1):
			var cid := cz * grid + cx
			if not cell_variants.has(cid):
				continue
			var x0 := origin + cx * cell_size
			var z0 := origin + cz * cell_size
			var dx := maxf(maxf(x0 - cam.x, 0.0), cam.x - (x0 + cell_size))
			var dz := maxf(maxf(z0 - cam.z, 0.0), cam.z - (z0 + cell_size))
			var dmin := sqrt(dx * dx + dz * dz)
			if dmin > max_d:
				continue
			var fx := maxf(absf(x0 - cam.x), absf(x0 + cell_size - cam.x))
			var fz := maxf(absf(z0 - cam.z), absf(z0 + cell_size - cam.z))
			var cy: Vector3 = cell_y.get(cid, Vector3(cam.y - 50, cam.y, cam.y + 30))
			var dy := maxf(absf(cam.y - cy.x), absf(cam.y - cy.y))
			var dmax := sqrt(fx * fx + fz * fz + dy * dy)
			var box := AABB(Vector3(x0, cy.x, z0), Vector3(cell_size, cy.z - cy.x, cell_size))
			var seen := dmin < 24.0 or _box_in_frustum(box, cam, planes)
			if not seen and dmin < shadow_distance and shadow_dir != Vector3.ZERO:
				var ext := shadow_dir * (cy.z - cy.y)
				seen = _box_in_frustum(box.merge(AABB(box.position + ext, box.size)), cam, planes)
			if not seen:
				continue
			for vi in cell_variants[cid]:
				var b: Array = vb[vi]
				for lod in 3:
					var band: Vector2 = b[lod]
					if dmax >= band.x and dmin <= band.y:
						lists[vi][lod].append(cid)
	# Every bucket is filtered per instance on this worker thread: exact distance band (with the same
	# size scaling as the shader) and a view test that also keeps sun-side shadow casters, so the GPU
	# only receives instances that can actually be drawn.
	var shadow_cut := shadow_distance * 0.75
	var result := []
	for vi in variants.size():
		var v := variants[vi]
		var per := []
		var far_buf := PackedFloat32Array()
		var far_aabb := AABB()
		var far_first := true
		for lod in 3:
			var lst: PackedInt32Array = lists[vi][lod]
			var buf := PackedFloat32Array()
			var aabb := AABB()
			var first := true
			var band: Vector2 = vb[vi][lod]
			var h := v.height
			var casts := lod < 2 and not v.cover
			var keep_frac := 1.0
			if v.cover:
				keep_frac = cover_density if v.kind in ["grass", "sprouts", "forb", "stone"] else lerpf(1.0, cover_density, 0.6)
			for cid in lst:
				var cellbuf: PackedFloat32Array = v.cells[cid]
				for i in range(0, cellbuf.size(), STRIDE):
					if keep_frac < 1.0 and cellbuf[i + 12] > keep_frac:
						continue      # random per-plant value (INSTANCE_CUSTOM.x) -> uniform thinning
					var p := Vector3(cellbuf[i + 3], cellbuf[i + 7], cellbuf[i + 11])
					var sc := cellbuf[i + 14]
					var d := p.distance_to(cam) / (0.5 + 0.5 * sc)
					if d < band.x * 1.05 - 3.0 or d > band.y:
						continue
					var hh := h * sc + 1.0
					var box := AABB(p - Vector3(hh * 0.45, 0.5, hh * 0.45), Vector3(hh * 0.9, hh + 0.5, hh * 0.9))
					var keep := d < 14.0 or _box_in_frustum(box, cam, planes)
					if not keep and casts and d < shadow_distance and shadow_dir != Vector3.ZERO:
						keep = _box_in_frustum(box.merge(AABB(box.position + shadow_dir * hh, box.size)), cam, planes)
					if not keep:
						continue
					if lod == 1 and p.distance_to(cam) > shadow_cut:
						far_buf.append_array(cellbuf.slice(i, i + STRIDE))
						far_aabb = box if far_first else far_aabb.merge(box)
						far_first = false
						continue
					buf.append_array(cellbuf.slice(i, i + STRIDE))
					aabb = box if first else aabb.merge(box)
					first = false
			per.append({"key": 0, "buf": buf, "aabb": aabb, "cells": lst})
		per.append({"key": 0, "buf": far_buf, "aabb": far_aabb, "cells": lists[vi][1]})
		result.append(per)
	_result = result
	stats["last_update_ms"] = (Time.get_ticks_usec() - t0) / 1000.0


func _box_in_frustum(box: AABB, cam: Vector3, planes: Array) -> bool:
	var p0 := box.position
	var p1 := box.end
	for n: Vector3 in planes:
		# the corner furthest inside (most negative along the outward normal)
		var c := Vector3(p0.x if n.x > 0.0 else p1.x, p0.y if n.y > 0.0 else p1.y, p0.z if n.z > 0.0 else p1.z)
		if (c - cam).dot(n) > 0.0:
			return false
	return true


func _apply_result() -> void:
	var t0 := Time.get_ticks_usec()
	var vis := [0, 0, 0, 0]
	var nb := 0
	for vi in _result.size():
		var v := variants[vi]
		for bi in 4:
			var lod := 1 if bi == 3 else bi
			var r = _result[vi][bi]
			var b: Dictionary = v.buckets[bi]
			if r != null:
				var buf: PackedFloat32Array = r["buf"]
				var count := buf.size() / STRIDE
				var mm: MultiMesh = b["mm"]
				if count > int(b["capacity"]) or count < int(b["capacity"]) / 4:
					var cap := maxi(int(count * 1.35) + 16, 32)
					mm.instance_count = cap
					b["capacity"] = cap
				buf.resize(int(b["capacity"]) * STRIDE)
				mm.buffer = buf
				mm.visible_instance_count = count
				mm.custom_aabb = r["aabb"] if count > 0 else AABB(Vector3.ZERO, Vector3.ONE)
				b["key"] = r["key"]
				b["count"] = count
				b["cells"] = r["cells"]
				(b["node"] as Node3D).visible = count > 0
			vis[3 if v.cover else lod] += int(b["count"])
			if int(b["count"]) > 0:
				nb += 1
	_result = []
	stats["updates"] += 1
	stats["apply_ms"] = (Time.get_ticks_usec() - t0) / 1000.0
	stats["visible_instances"] = vis
	stats["buckets"] = nb


func total_instances() -> int:
	var n := 0
	for v in variants:
		n += v.count
	return n


func _exit_tree() -> void:
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
