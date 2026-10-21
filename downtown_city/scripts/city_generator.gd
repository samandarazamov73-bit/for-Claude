class_name CityGenerator
extends Node3D
## Builds the whole downtown: street grid, blocks, lots, buildings, street furniture,
## trees and a distant skyline. The layout around the origin reproduces the trailer
## (see CITY_PLAN.md): the main avenue (x = 0) runs north into a T-junction at z = -264,
## the hero intersection is at (0, 0) with The Jade Garden on its north-east corner.
## Units: 1 = 1 m, +X east, -Z north, Y up. Sidewalk level y = 0, asphalt y = -0.15.

signal progress(step: String)

const ROAD_HALF := 6.0
const SIDEWALK := 5.0
const ROW_HALF := ROAD_HALF + SIDEWALK
const CURB_H := 0.15
const AVENUES := [-216.0, -108.0, 0.0, 108.0, 216.0]
const STREETS := [-264.0, -176.0, -88.0, 0.0, 88.0]
const X_LINES := [-290.0, -216.0, -108.0, 0.0, 108.0, 216.0, 290.0]
const Z_LINES := [-330.0, -264.0, -176.0, -88.0, 0.0, 88.0, 150.0]
const MAIN_AVENUE_END := -264.0  # main avenue (x = 0) stops at this street (T-junction, vista)
const ROAD_EXTENT := 420.0       # roads continue this far past the outer blocks

const STYLE_WEIGHTS := {
	"brick_trim": 20, "brick_pairs": 11, "brick_single": 15, "limestone": 14, "limestone_grid": 12,
	"redwhite": 10, "painted": 7, "metal_loft": 6,
}
const FLOORS := {
	"brick_trim": Vector2i(7, 13), "brick_pairs": Vector2i(6, 10), "brick_single": Vector2i(4, 6),
	"limestone": Vector2i(9, 15), "limestone_grid": Vector2i(6, 12), "redwhite": Vector2i(6, 11),
	"painted": Vector2i(5, 9), "metal_loft": Vector2i(6, 10),
}
const SHOP_SIGNS := ["T_Sign_Mays", "T_Sign_Carmines", "T_Sign_Deli", "T_Sign_Books", "T_Sign_Cafe",
	"T_Sign_Pharmacy", "T_Sign_Laundry", "T_Sign_Hardware"]
const AWNING_COLORS := ["green", "red", "navy", "black", "striped", "tan"]

var mats: CityMaterials
var kit: KitLibrary
var props: PropFactory
var bgen: BuildingGenerator
var rng := RandomNumberGenerator.new()
var chunks: Array[CityChunk] = []
var street_chunk: CityChunk
var lamp_lights: Array[Vector3] = []   # world positions of lamp heads (night light pool)
var spawn_points := {}
var block_rects: Array[Rect2] = []
var _deferred: Array = []  # [mesh, xform, cls, shadow] placed into the nearest block chunk


func generate(settings: Dictionary, seed_value := 20251021) -> void:
	rng.seed = seed_value
	mats = CityMaterials.new()
	kit = KitLibrary.new(mats)
	props = PropFactory.new(mats, kit)
	bgen = BuildingGenerator.new(kit, mats, props)
	street_chunk = CityChunk.new("Streets", Vector3.ZERO)
	street_chunk.decal_cls = ""
	chunks.append(street_chunk)
	progress.emit("streets")
	_build_streets()
	progress.emit("blocks")
	_build_blocks()
	for d in _deferred:
		var c := _chunk_at((d[1] as Transform3D).origin)
		c.add_instance(d[0], d[1], Color(), d[2], d[3])
	for x in AVENUES:
		for z in STREETS:
			if _has_avenue(x, z):
				_intersection_props(x, z)
	progress.emit("skyline")
	_build_backdrop()
	progress.emit("meshes")
	for c in chunks:
		c.build(self, settings)


# ============================================================================ streets
func _has_avenue(x: float, z: float) -> bool:
	# the main avenue ends at the T-junction with MAIN_AVENUE_END
	if is_zero_approx(x) and z < MAIN_AVENUE_END - 1.0:
		return false
	return true


func _build_streets() -> void:
	var g := street_chunk.ground
	g.set_material(mats.road, true)
	# avenues (north-south)
	for x in AVENUES:
		var zs: Array = STREETS.duplicate()
		if is_zero_approx(x):
			zs = zs.filter(func(z): return z >= MAIN_AVENUE_END)
		# south extension and north extension
		_road_segment(Vector3(x, 0, zs[-1] + ROAD_HALF), Vector3(x, 0, zs[-1] + ROAD_EXTENT), 0 if is_zero_approx(x) else 1, true)
		if not is_zero_approx(x):
			_road_segment(Vector3(x, 0, zs[0] - ROAD_HALF), Vector3(x, 0, zs[0] - ROAD_EXTENT), 1, true)
		for i in zs.size() - 1:
			_road_segment(Vector3(x, 0, zs[i] + ROAD_HALF), Vector3(x, 0, zs[i + 1] - ROAD_HALF), 0 if is_zero_approx(x) else 1)
	# streets (east-west)
	for z in STREETS:
		_road_segment(Vector3(AVENUES[0] - ROAD_HALF, 0, z), Vector3(AVENUES[0] - ROAD_EXTENT, 0, z), 3, true)
		_road_segment(Vector3(AVENUES[-1] + ROAD_HALF, 0, z), Vector3(AVENUES[-1] + ROAD_EXTENT, 0, z), 3, true)
		for i in AVENUES.size() - 1:
			_road_segment(Vector3(AVENUES[i] + ROAD_HALF, 0, z), Vector3(AVENUES[i + 1] - ROAD_HALF, 0, z), 0 if is_zero_approx(z) else 3)
	# intersections
	g.uv2 = Vector2(0, 2)
	for x in AVENUES:
		for z in STREETS:
			if not _has_avenue(x, z):
				continue
			var y := -CURB_H
			g.color = Color(0.6, 0, 0, 1)
			g.add_quad_facing(Vector3(x - ROAD_HALF, y, z + ROAD_HALF), Vector3(x + ROAD_HALF, y, z + ROAD_HALF),
				Vector3(x + ROAD_HALF, y, z - ROAD_HALF), Vector3(x - ROAD_HALF, y, z - ROAD_HALF), Vector3.UP,
				Vector2(0, 0), Vector2(12, 0), Vector2(12, 12), Vector2(0, 12))
	# far ground plane (under everything, beyond the backdrop)
	g.set_material(mats.courtyard)
	var e := 1500.0
	g.add_quad_facing(Vector3(-e, -0.2, e), Vector3(e, -0.2, e), Vector3(e, -0.2, -e), Vector3(-e, -0.2, -e), Vector3.UP)
	# road markings text (main avenue as in the trailer: STOP for the lane entering the crossing, ONLY + arrow leaving it)
	for z in STREETS:
		if z < MAIN_AVENUE_END:
			continue
		if z > MAIN_AVENUE_END + 1.0:
			_lane_decals(Vector3(0, 0, z), Vector3(0, 0, -1))
		_lane_decals(Vector3(0, 0, z), Vector3(0, 0, 1))
	for x in [-108.0, 108.0]:
		_lane_decals(Vector3(x, 0, 0), Vector3(0, 0, -1))
		_lane_decals(Vector3(x, 0, 0), Vector3(0, 0, 1))


## Road strip from a to b (axis aligned). kind: 0 dashed white, 1 double yellow, 3 one-way.
func _road_segment(a: Vector3, b: Vector3, kind: int, open_end := false) -> void:
	var g := street_chunk.ground
	var dir := (b - a).normalized()
	var length := a.distance_to(b)
	var left := Vector3.UP.cross(dir)  # +across = left of the travel direction
	var y := Vector3(0, -CURB_H, 0)
	g.set_material(mats.road, true)
	g.uv2 = Vector2(length if not open_end else 1e6, kind)
	g.color = Color(ROAD_HALF / 10.0, 0, 0, 1)
	var hw := ROAD_HALF
	g.add_quad_facing(a - left * hw + y, b - left * hw + y, b + left * hw + y, a + left * hw + y, Vector3.UP,
		Vector2(0, -hw), Vector2(length, -hw), Vector2(length, hw), Vector2(0, hw))
	# manholes along the lane centres, drains along the curb
	var mh := kit.mesh("Prop_ManholeCover")
	var dr := kit.mesh("Prop_Drain")
	var n := int(length / 34.0)
	for i in n:
		var t := (i + 0.5) * length / maxf(n, 1)
		if t > 300.0:
			break
		var p := a + dir * t + left * (2.2 if i % 2 == 0 else -2.6) + y + Vector3(0, 0.005, 0)
		_deferred.append([mh, Transform3D(Basis(Vector3.UP, rng.randf() * TAU), p), "props", false])
	for t in [7.5, length - 7.5]:
		if t > 0.0 and t < 300.0:
			for s in [-1.0, 1.0]:
				var p: Vector3 = a + dir * t + left * (hw - 0.35) * s + y + Vector3(0, 0.005, 0)
				_deferred.append([dr, Transform3D(Basis(), p), "props", false])


func _lane_decals(center: Vector3, dir: Vector3) -> void:
	# `dir` = travel direction leaving the intersection at `center`
	var d := street_chunk.decals
	d.set_material(mats.decal)
	var right := dir.cross(Vector3.UP)
	var y := Vector3(0, -CURB_H + 0.012, 0)
	var lane := 2.25
	# departing lane (right side of dir): ONLY + straight arrow
	var p_only := center + dir * (ROAD_HALF + 9.5) + right * lane + y
	_decal_quad(d, p_only, dir, Vector2(2.9, 1.25), Rect2(0, 0, 0.5, 0.25))
	_decal_quad(d, p_only + dir * 3.2, dir, Vector2(0.75, 2.4), Rect2(0, 0.25, 0.125, 0.75))
	# approaching lane (left side): STOP read by drivers coming towards the crossing
	var p_stop := center + dir * (ROAD_HALF + 8.0) - right * lane + y
	_decal_quad(d, p_stop, -dir, Vector2(2.9, 1.3), Rect2(0.5, 0, 0.5, 0.25))


func _decal_quad(g: GeoBatch, c: Vector3, dir: Vector3, size: Vector2, uv: Rect2) -> void:
	var right := dir.cross(Vector3.UP)
	var hx := right * size.x * 0.5
	var hz := dir * size.y * 0.5
	g.add_quad(c - hx - hz, c + hx - hz, c + hx + hz, c - hx + hz,
		Vector2(uv.position.x, uv.end.y), Vector2(uv.end.x, uv.end.y), Vector2(uv.end.x, uv.position.y), Vector2(uv.position.x, uv.position.y))


func _intersection_props(x: float, z: float) -> void:
	# traffic signals on two diagonal corners, arms reaching over the road
	# (the trailer's hero crossing has none, so it stays clear)
	if is_zero_approx(x) and is_zero_approx(z):
		return
	var sig := props.signal_mesh()
	var corners := [[Vector3(x + ROAD_HALF + 0.7, 0, z + ROAD_HALF + 0.7), PI], [Vector3(x - ROAD_HALF - 0.7, 0, z - ROAD_HALF - 0.7), 0.0]]
	for c in corners:
		var p: Vector3 = c[0]
		var chunk := _chunk_at(p)
		chunk.add_instance(sig, Transform3D(Basis(Vector3.UP, c[1]), p), Color(), "street", true)
		chunk.add_cylinder_collider(p, 0.16, 6.0)


# ============================================================================ blocks
func _chunk_at(p: Vector3) -> CityChunk:
	var best: CityChunk = street_chunk
	var bd := INF
	for c in chunks:
		if c == street_chunk or c.name.begins_with("Skyline"):
			continue
		var d := Vector2(c.center.x - p.x, c.center.z - p.z).length_squared()
		if d < bd:
			bd = d
			best = c
	return best


func _build_blocks() -> void:
	# create chunks first so props can find their nearest block
	var blocks: Array = []
	for i in X_LINES.size() - 1:
		for j in Z_LINES.size() - 1:
			var xa: float = X_LINES[i]
			var xb: float = X_LINES[i + 1]
			var za: float = Z_LINES[j]
			var zb: float = Z_LINES[j + 1]
			if j == 0 and is_equal_approx(xa, 0.0):
				continue  # merged into the vista block
			var vista := j == 0 and is_equal_approx(xb, 0.0)
			if vista:
				xb = X_LINES[i + 2]
			var w_road := xa in AVENUES and (not (is_zero_approx(xa) and j == 0))
			var e_road := xb in AVENUES and (not (is_zero_approx(xb) and j == 0))
			var n_road := za in STREETS
			var s_road := zb in STREETS
			var x0 := xa + (ROW_HALF if w_road else 0.0)
			var x1 := xb - (ROW_HALF if e_road else 0.0)
			var z0 := za + (ROW_HALF if n_road else 0.0)
			var z1 := zb - (ROW_HALF if s_road else 0.0)
			var rect := Rect2(x0, z0, x1 - x0, z1 - z0)
			var streets := []
			if s_road: streets.append("S")
			if e_road: streets.append("E")
			if n_road: streets.append("N")
			if w_road: streets.append("W")
			var chunk := CityChunk.new("Block_%d_%d" % [i, j], Vector3(rect.get_center().x, 0, rect.get_center().y))
			chunks.append(chunk)
			blocks.append({"rect": rect, "streets": streets, "chunk": chunk, "id": Vector2i(i, j), "vista": vista})
			block_rects.append(rect)
	for b in blocks:
		_sidewalks(b)
		var lots: Array = _hero_lots(b)
		if lots.is_empty():
			lots = _generic_lots(b)
		for spec in lots:
			bgen.build(b.chunk, spec)
			_dress_building(b.chunk, spec)
		_street_furniture(b)


func _sidewalks(b: Dictionary) -> void:
	var rect: Rect2 = b.rect
	var streets: Array = b.streets
	var chunk: CityChunk = b.chunk
	var outer := rect
	if "W" in streets: outer = outer.grow_individual(SIDEWALK, 0, 0, 0)
	if "E" in streets: outer = outer.grow_individual(0, 0, SIDEWALK, 0)
	if "N" in streets: outer = outer.grow_individual(0, SIDEWALK, 0, 0)
	if "S" in streets: outer = outer.grow_individual(0, 0, 0, SIDEWALK)
	var radius := 3.0
	var ring := _rounded_rect(outer, radius, 6)
	var inner_ring := _rounded_rect(outer.grow(-0.3), radius - 0.3, 6)
	var y := 0.0
	var g := chunk.ground
	# paving
	g.set_material(mats.sidewalk)
	var c := Vector3(outer.get_center().x, y, outer.get_center().y)
	for i in inner_ring.size():
		var p0: Vector3 = inner_ring[i]
		var p1: Vector3 = inner_ring[(i + 1) % inner_ring.size()]
		g.add_tri_facing(c, p0, p1, Vector3.UP)
	# granite curb band + curb face
	g.set_material(mats.curb)
	for i in ring.size():
		var a: Vector3 = ring[i]
		var bb: Vector3 = ring[(i + 1) % ring.size()]
		var ia: Vector3 = inner_ring[i]
		var ib: Vector3 = inner_ring[(i + 1) % ring.size()]
		g.add_quad_facing(a, bb, ib, ia, Vector3.UP)
		var out := ((a + bb) * 0.5 - c)
		out.y = 0.0
		g.add_quad_facing(a, bb, bb - Vector3(0, CURB_H, 0), a - Vector3(0, CURB_H, 0), out)
	# courtyard (inside the block, between the buildings)
	g.set_material(mats.courtyard)
	var ci := rect.grow(-0.5)
	g.add_quad_facing(Vector3(ci.position.x, 0.02, ci.end.y), Vector3(ci.end.x, 0.02, ci.end.y),
		Vector3(ci.end.x, 0.02, ci.position.y), Vector3(ci.position.x, 0.02, ci.position.y), Vector3.UP)
	chunk.add_box_collider(Transform3D(Basis(), Vector3(outer.get_center().x, -CURB_H * 0.5, outer.get_center().y)), Vector3(outer.size.x, CURB_H, outer.size.y))


static func _rounded_rect(r: Rect2, radius: float, seg: int) -> Array:
	var pts := []
	var cs := [
		[Vector2(r.end.x - radius, r.end.y - radius), 0.0],
		[Vector2(r.end.x - radius, r.position.y + radius), -PI * 0.5],
		[Vector2(r.position.x + radius, r.position.y + radius), -PI],
		[Vector2(r.position.x + radius, r.end.y - radius), -PI * 1.5]]
	for c in cs:
		var cc: Vector2 = c[0]
		for k in seg + 1:
			var a: float = c[1] + PI * 0.5 - PI * 0.5 * k / seg
			pts.append(Vector3(cc.x + cos(a) * radius, 0.0, cc.y + sin(a) * radius))
	return pts


# ---------------------------------------------------------------------------- lots
func _pick_style() -> String:
	var total := 0
	for k in STYLE_WEIGHTS:
		total += STYLE_WEIGHTS[k]
	var r := rng.randi_range(0, total - 1)
	for k in STYLE_WEIGHTS:
		r -= STYLE_WEIGHTS[k]
		if r < 0:
			return k
	return "brick_trim"


func _even(v: float) -> float:
	return floorf(v / 2.0) * 2.0


func _palette_for(style: String) -> Dictionary:
	match style:
		"limestone", "limestone_grid":
			var w: int = [9, 10, 11, 12, 9, 10][rng.randi_range(0, 5)]
			return {"wall": w, "wall2": w, "trim": [1, 0, 2, 3][rng.randi_range(0, 3)]}
		"redwhite":
			return {"wall": [0, 1, 4][rng.randi_range(0, 2)], "wall2": [5, 6, 7, 8][rng.randi_range(0, 3)], "trim": [0, 1][rng.randi_range(0, 1)]}
		"painted":
			var w: int = [13, 14, 15][rng.randi_range(0, 2)]
			return {"wall": w, "wall2": w, "trim": [2, 1, 4][rng.randi_range(0, 2)]}
		"metal_loft":
			return {"wall": [0, 1, 3, 4][rng.randi_range(0, 3)], "wall2": 9, "trim": 4}
		_:
			return {"wall": [0, 1, 2, 3, 4, 0, 1][rng.randi_range(0, 6)], "wall2": [9, 10, 11, 5, 6][rng.randi_range(0, 4)], "trim": [0, 1, 3, 2][rng.randi_range(0, 3)]}


func _make_spec(rect: Rect2, streets: Array, style := "", floors := -1, corner := false) -> Dictionary:
	if style == "":
		style = _pick_style()
	var fr: Vector2i = FLOORS[style]
	if floors < 0:
		floors = rng.randi_range(fr.x, fr.y) + (2 if corner and rng.randf() < 0.5 else 0)
	var spec := {
		"rect": rect, "style": style, "floors": floors, "street_sides": streets,
		"ground_h": [4.0, 4.0, 4.5, 3.6][rng.randi_range(0, 3)], "seed": rng.randf(),
	}
	spec.merge(_palette_for(style))
	var mansard_ok := style in ["brick_trim", "redwhite", "limestone_grid", "brick_pairs"]
	if mansard_ok and rng.randf() < 0.42:
		spec["roof"] = "mansard"
	else:
		spec["roof"] = "flat"
		spec["water_tank"] = rng.randf() < 0.14 and floors < 12
	if style == "brick_single" and rng.randf() < 0.7:
		var f := BuildingGenerator.side_frame(rect, streets[0])
		var w := 6.0 if f.len >= 12.0 else 4.0
		spec["fire_escape"] = {"side": streets[0], "offset": _even(rng.randf_range(1.0, maxf(f.len - w - 1.0, 1.0))), "width": w}
	elif style in ["brick_trim", "brick_pairs"] and rng.randf() < 0.25 and streets.size() > 0:
		var f := BuildingGenerator.side_frame(rect, streets[-1])
		if f.len >= 10.0:
			spec["fire_escape"] = {"side": streets[-1], "offset": 2.0, "width": 6.0}
	# storefront dressing on the main street side
	var sfs := []
	var main := BuildingGenerator.side_frame(rect, streets[0])
	var n_shops := 1 if main.len < 18.0 else 2
	for k in n_shops:
		var off: float = main.len * (k + 1) / (n_shops + 1)
		var sf := {"side": streets[0], "offset": off, "width": minf(6.0, main.len * 0.4)}
		if rng.randf() < 0.45:
			sf["awning"] = AWNING_COLORS[rng.randi_range(0, AWNING_COLORS.size() - 1)]
		if rng.randf() < 0.5:
			sf["sign"] = SHOP_SIGNS[rng.randi_range(0, SHOP_SIGNS.size() - 1)]
			sf["sign_w"] = 4.0
			sf["sign_h"] = 1.0
		elif rng.randf() < 0.3:
			sf["blade"] = SHOP_SIGNS[rng.randi_range(0, SHOP_SIGNS.size() - 1)]
			sf["blade_size"] = Vector2(1.6, 0.4)
		sfs.append(sf)
	spec["storefronts"] = sfs
	spec["planters"] = rng.randf() < 0.3
	# courtyard side gets windows, party walls stay blank
	var back := {}
	for s in streets:
		back[{"S": "N", "N": "S", "E": "W", "W": "E"}[s]] = true
	spec["back_windows"] = back
	return spec


func _generic_lots(b: Dictionary) -> Array:
	var rect: Rect2 = b.rect
	var streets: Array = b.streets
	var lots := []
	if streets.is_empty():
		return lots
	var depth := {}
	for s in ["S", "N"]:
		depth[s] = _even(rng.randf_range(16.0, minf(26.0, rect.size.y * 0.5 - 4.0)))
	for s in ["E", "W"]:
		depth[s] = _even(rng.randf_range(16.0, minf(26.0, rect.size.x * 0.5 - 4.0)))
	var x0 := rect.position.x
	var x1 := rect.end.x
	var z0 := rect.position.y
	var z1 := rect.end.y
	# corners: [rect, streets]
	var corner_info := {
		"SW": {"sides": ["S", "W"]}, "SE": {"sides": ["S", "E"]}, "NE": {"sides": ["N", "E"]}, "NW": {"sides": ["N", "W"]}}
	var cw := {}
	var cd := {}
	for k in corner_info:
		var sides: Array = corner_info[k].sides
		var ns: String = sides[0]
		var ew: String = sides[1]
		cw[k] = _even(maxf(depth[ew], rng.randf_range(16.0, 24.0)))
		cd[k] = _even(maxf(depth[ns], rng.randf_range(14.0, 22.0)))
	var corner_rects := {
		"SW": Rect2(x0, z1 - cd["SW"], cw["SW"], cd["SW"]),
		"SE": Rect2(x1 - cw["SE"], z1 - cd["SE"], cw["SE"], cd["SE"]),
		"NE": Rect2(x1 - cw["NE"], z0, cw["NE"], cd["NE"]),
		"NW": Rect2(x0, z0, cw["NW"], cd["NW"])}
	for k in corner_rects:
		var sides: Array = corner_info[k].sides.filter(func(s): return s in streets)
		if sides.is_empty():
			continue
		lots.append(_make_spec(corner_rects[k], sides, "", -1, true))
	# mid-block lots along each street side
	for s in streets:
		var a: float
		var e: float
		match s:
			"S":
				a = x0 + cw["SW"]
				e = x1 - cw["SE"]
			"N":
				a = x0 + cw["NW"]
				e = x1 - cw["NE"]
			"W":
				a = z0 + cd["NW"]
				e = z1 - cd["SW"]
			"E":
				a = z0 + cd["NE"]
				e = z1 - cd["SE"]
		var t := a
		while e - t >= 8.0:
			var w := _even(rng.randf_range(10.0, 22.0))
			if e - t - w < 8.0:
				w = _even(e - t)
			var r: Rect2
			var d: float = depth[s]
			match s:
				"S": r = Rect2(t, z1 - d, w, d)
				"N": r = Rect2(t, z0, w, d)
				"W": r = Rect2(x0, t, d, w)
				"E": r = Rect2(x1 - d, t, d, w)
			# occasionally use one of the kit's prebuilt buildings when the lot fits
			if w >= 14.0 and w <= 18.0 and d >= 14.0 and rng.randf() < 0.18:
				lots.append(_prebuilt_spec("Building_Medium_2_001", r, s))
			elif w >= 12.0 and w <= 14.0 and d >= 13.0 and rng.randf() < 0.15:
				lots.append(_prebuilt_spec("Building_Small_1", r, s))
			else:
				lots.append(_make_spec(r, [s]))
			t += w
	return lots


## Kit prebuilt building, rotated to face street side `s` and centred on the lot frontage.
func _prebuilt_spec(name: String, r: Rect2, s: String) -> Dictionary:
	var rot := {"S": 0.0, "E": PI * 0.5, "N": PI, "W": -PI * 0.5}[s] as float
	var f := BuildingGenerator.side_frame(r, s)
	var pos: Vector3 = f.left + f.right * (f.len * 0.5)
	var local_center_x := {"Building_Medium_2_001": 0.0, "Building_Small_1": -1.0, "Building_Large_2": 1.0}[name] as float
	pos -= f.right * local_center_x
	return {"prebuilt": name, "xform": Transform3D(Basis(Vector3.UP, rot), pos), "seed": rng.randf(),
		"wall": [0, 1, 3][rng.randi_range(0, 2)], "wall2": 9, "trim": 0, "street_sides": [s]}


# ---------------------------------------------------------------------------- hero area
## Hand-placed lots reproducing what the trailer shows around the hero intersection.
func _hero_lots(b: Dictionary) -> Array:
	var id: Vector2i = b.id
	var lots := []
	if id == Vector2i(3, 3):
		# north-east block of the hero intersection: x 11..97, z -77..-11
		var jg := {"prebuilt": "Building_Large_2", "xform": Transform3D(Basis(), Vector3(20.32, 0, -11.0)), "seed": 0.37,
			"wall": 0, "wall2": 9, "trim": 4, "street_sides": ["S", "W"], "hero": "jade_garden"}
		lots.append(jg)
		lots.append({"rect": Rect2(11, -51.32, 22, 24), "style": "brick_trim", "floors": 12, "ground_h": 4.5, "seed": 0.61,
			"wall": 1, "wall2": 9, "trim": 0, "street_sides": ["W"], "roof": "mansard", "back_windows": {"E": true},
			"storefronts": [{"side": "W", "offset": 13.0, "width": 6.0, "awning": "green", "sign": "T_Sign_Bakery", "sign_w": 6.2, "sign_h": 1.55},
				{"side": "W", "offset": 22.6, "width": 1.0, "blade": "T_Sign_JadeSquare", "blade_y": 3.3, "blade_size": Vector2(1.0, 1.0)}],
			"planters": true, "hero": "bakery"})
		lots.append({"rect": Rect2(11, -77, 20, 24), "style": "limestone_grid", "floors": 9, "ground_h": 4.0, "seed": 0.12,
			"wall": 10, "wall2": 10, "trim": 1, "street_sides": ["W", "N"], "roof": "mansard", "back_windows": {"E": true, "S": false},
			"storefronts": [{"side": "W", "offset": 8.0, "width": 5.0, "awning": "navy"}]})
		lots.append({"rect": Rect2(32, -31, 14, 20), "style": "redwhite", "floors": 10, "ground_h": 4.0, "seed": 0.44,
			"wall": 0, "wall2": 6, "trim": 0, "street_sides": ["S"], "roof": "mansard", "back_windows": {"N": true},
			"storefronts": [{"side": "S", "offset": 7.0, "width": 5.0, "awning": "black"}]})
		lots.append({"rect": Rect2(46, -29, 12, 18), "style": "painted", "floors": 8, "ground_h": 4.0, "seed": 0.73,
			"wall": 13, "wall2": 13, "trim": 2, "street_sides": ["S"], "roof": "flat", "back_windows": {"N": true},
			"storefronts": [{"side": "S", "offset": 6.0, "width": 4.0, "blade": "T_Sign_Deli", "blade_size": Vector2(1.6, 0.4)}]})
		lots.append({"rect": Rect2(58, -35, 26, 24), "style": "limestone", "floors": 14, "ground_h": 4.5, "seed": 0.29,
			"wall": 9, "wall2": 9, "trim": 1, "street_sides": ["S"], "roof": "flat", "back_windows": {"N": true},
			"storefronts": [{"side": "S", "offset": 13.0, "width": 8.0, "awning": "navy"}]})
		lots.append(_make_spec(Rect2(85, -31, 12, 20), ["S", "E"], "brick_pairs", 7, true))
		lots.append(_make_spec(Rect2(79, -55, 18, 24), ["E"], "brick_single", 6))
		lots.append(_make_spec(Rect2(75, -77, 22, 22), ["N", "E"], "limestone_grid", 11, true))
		lots.append(_make_spec(Rect2(31, -77, 14, 20), ["N"], "brick_single", 5))
		lots.append(_make_spec(Rect2(45, -77, 16, 20), ["N"], "redwhite", 8))
		lots.append(_make_spec(Rect2(61, -77, 14, 20), ["N"], "brick_trim", 9))
	elif id == Vector2i(2, 3):
		# north-west block: PA Savings Bank tower on the corner, May's salon walk-up on the avenue
		lots.append({"rect": Rect2(-41, -37, 30, 26), "style": "limestone", "floors": 14, "ground_h": 5.0, "seed": 0.83,
			"wall": 10, "wall2": 10, "trim": 1, "street_sides": ["E", "S"], "roof": "flat", "back_windows": {"W": true, "N": true},
			"ground_pattern": ["Brick_Inset_Window_Curved"], "no_door": false, "door_frame": "DoorFrame_Wooden",
			"storefronts": [
				{"side": "E", "offset": 5.0, "width": 3.4, "awning": "green"}, {"side": "E", "offset": 9.0, "width": 3.4, "awning": "green"},
				{"side": "E", "offset": 17.0, "width": 3.4, "awning": "green"}, {"side": "E", "offset": 21.0, "width": 3.4, "awning": "green"},
				{"side": "E", "offset": 13.0, "width": 16.0, "sign": "T_Sign_Bank", "sign_w": 16.0, "sign_h": 1.25, "sign_y": 5.75, "sign_depth": 0.0},
				{"side": "S", "offset": 7.0, "width": 3.4, "awning": "green"}, {"side": "S", "offset": 23.0, "width": 3.4, "awning": "green"}],
			"planters": true, "hero": "bank"})
		lots.append({"prebuilt": "Building_Small_1", "xform": Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(-11.0, 0, -45.0)), "seed": 0.55,
			"wall": 0, "wall2": 8, "trim": 0, "street_sides": ["E"], "hero": "mays"})
		lots.append(_make_spec(Rect2(-33, -61, 22, 10), ["E"], "brick_single", 5))
		lots.append(_make_spec(Rect2(-35, -77, 24, 16), ["E", "N"], "brick_trim", 10, true))
		lots.append_array(_filter_lots(_generic_lots(b), [Rect2(-41.5, -77.5, 31, 67)]))
	elif b.vista:
		# block that closes the main avenue's vista (seen down the street in the trailer)
		lots.append({"rect": Rect2(-16, -299, 32, 24), "style": "limestone_grid", "floors": 10, "ground_h": 4.5, "seed": 0.91,
			"wall": 10, "wall2": 10, "trim": 3, "street_sides": ["S"], "roof": "mansard", "back_windows": {"N": true},
			"storefronts": [{"side": "S", "offset": 16.0, "width": 8.0, "awning": "tan"}]})
		lots.append_array(_filter_lots(_generic_lots(b), [Rect2(-17, -300, 34, 26)]))
	if not lots.is_empty():
		for spec in lots:
			if spec.has("hero") and spec.hero == "jade_garden":
				_dress_jade_garden(b.chunk)
	return lots


func _filter_lots(specs: Array, keep_out: Array) -> Array:
	var out := []
	for spec in specs:
		var r: Rect2
		if spec.has("prebuilt"):
			var o: Vector3 = (spec.xform as Transform3D).origin
			r = Rect2(o.x - 8, o.z - 8, 16, 16)
		else:
			r = spec.rect
		var ok := true
		for k in keep_out:
			if r.grow(-0.2).intersects(k):
				ok = false
		if ok:
			out.append(spec)
	return out


func _dress_jade_garden(chunk: CityChunk) -> void:
	# The Jade Garden: red sign over the entrance (south), vertical banner and fire escape (west face)
	var south := BuildingGenerator.side_frame(Rect2(11.0, -27.32, 20.64, 16.64), "S")
	props.wall_sign(chunk, south, 12.6, 3.55, 4.4, 1.1, "T_Sign_JadeGarden", 0.1)
	var west := BuildingGenerator.side_frame(Rect2(11.0, -27.32, 20.64, 16.64), "W")
	props.wall_sign(chunk, west, 11.4, 12.5, 1.15, 4.6, "T_Sign_JadeBanner", 0.12)
	props.fire_escape(chunk, west, 1.0, 5.0, 4.0, 7)


# ---------------------------------------------------------------------------- dressing
func _dress_building(chunk: CityChunk, spec: Dictionary) -> void:
	if not spec.get("planters", false) or spec.has("prebuilt"):
		return
	var rect: Rect2 = spec.rect
	for s in spec.street_sides:
		var f := BuildingGenerator.side_frame(rect, s)
		var n := int(f.len / 9.0)
		for i in n:
			var off: float = (i + 0.5) * f.len / n
			# keep entrances free
			if absf(off - f.len * 0.5) < 2.5:
				continue
			var pos: Vector3 = f.left + f.right * off + f.n * 0.55
			var m := props.planter_mesh(2.6)
			chunk.add_instance(m, Transform3D(f.basis, pos), Color(0.5, 0.6, 0.0, 0), "props")


func _street_furniture(b: Dictionary) -> void:
	var rect: Rect2 = b.rect
	var chunk: CityChunk = b.chunk
	for s in b.streets:
		var f := BuildingGenerator.side_frame(rect, s)
		var curb_off := SIDEWALK - 1.25  # tree pits close to the curb
		var main_street := false
		match s:
			"W": main_street = is_equal_approx(rect.position.x, ROW_HALF)
			"E": main_street = is_equal_approx(rect.end.x, -ROW_HALF)
			"S": main_street = is_equal_approx(rect.end.y, -ROW_HALF)
			"N": main_street = is_equal_approx(rect.position.y, ROW_HALF)
		var tree_p := 1.0 if main_street else 0.6
		# the trailer shows trees along the main avenue only, none on the hero cross street
		if main_street and (s == "S" or s == "N"):
			tree_p = 0.0
		var spacing := 9.0 if main_street else rng.randf_range(9.0, 12.0)
		var n := int((f.len - 14.0) / spacing)
		for i in n + 1:
			var off := 7.0 + i * spacing
			if off > f.len - 7.0:
				break
			var p: Vector3 = f.left + f.right * off + f.n * curb_off
			if rng.randf() < tree_p:
				var t := props.tree_mesh(rng.randi_range(0, 3))
				var yaw := rng.randf() * TAU
				var sc := rng.randf_range(0.9, 1.15)
				chunk.add_instance(t, Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(sc, sc, sc)), p),
					Color(rng.randf(), rng.randf(), rng.randf(), 0), "street", true)
				chunk.add_instance(props.tree_guard_mesh(), Transform3D(Basis(Vector3.UP, rng.randi_range(0, 3) * PI * 0.5), p), Color(), "props")
				chunk.add_cylinder_collider(p, 0.18, 3.0)
			elif rng.randf() < 0.18:
				chunk.add_instance(props.bench_mesh(), Transform3D(f.basis.rotated(Vector3.UP, PI), p), Color(), "props")
		# lamps near both ends of the side and mid-block
		var lamp := props.lamp_mesh()
		for off in [4.0, f.len * 0.5 + 4.5, f.len - 4.0]:
			if off > f.len * 0.5 and off < f.len * 0.5 + 5.0 and f.len < 40.0:
				continue
			var p: Vector3 = f.left + f.right * off + f.n * (SIDEWALK - 0.45)
			chunk.add_instance(lamp, Transform3D(f.basis, p), Color(), "street", true)
			chunk.add_cylinder_collider(p, 0.15, 8.0)
			lamp_lights.append(p + f.n * 2.25 + Vector3(0, 8.6, 0))
		# hydrant, trash can, mailbox / newspaper boxes near the corners
		var hyd: Vector3 = f.left + f.right * rng.randf_range(10.0, maxf(f.len - 10.0, 10.5)) + f.n * (SIDEWALK - 0.7)
		chunk.add_instance(props.hydrant_mesh(), Transform3D(f.basis, hyd), Color(), "props")
		var tc: Vector3 = f.left + f.right * 6.0 + f.n * (SIDEWALK - 0.8)
		chunk.add_instance(props.trash_can_mesh(), Transform3D(Basis(), tc), Color(), "props")
		if rng.randf() < 0.4:
			var mb: Vector3 = f.left + f.right * (f.len - 6.5) + f.n * (SIDEWALK - 0.8)
			chunk.add_instance(props.mailbox_mesh() if rng.randf() < 0.5 else props.newsbox_mesh(), Transform3D(f.basis, mb), Color(), "props")
	if b.id == Vector2i(3, 3):
		spawn_points["hero"] = Vector3(-3.0, 0.0, 9.0)


# ============================================================================ skyline
## Distant city all around the playable area: shells only (far facade shader).
func _build_backdrop() -> void:
	var chunk := CityChunk.new("Skyline", Vector3.ZERO)
	chunks.append(chunk)
	var r := RandomNumberGenerator.new()
	r.seed = 99
	var inner := Rect2(-300, -340, 600, 500)
	for i in 900:
		var p := Vector2(r.randf_range(-900, 900), r.randf_range(-950, 760))
		if inner.grow(25).has_point(p):
			continue
		# keep the road corridors (extensions of the avenues/streets) clear
		var on_road := false
		for x in AVENUES:
			if absf(p.x - x) < 22.0 and not (is_zero_approx(x) and p.y < MAIN_AVENUE_END):
				on_road = true
		for z in STREETS:
			if absf(p.y - z) < 22.0:
				on_road = true
		if on_road:
			continue
		var w := r.randf_range(16, 34)
		var d := r.randf_range(16, 30)
		var dist := p.length()
		var h := r.randf_range(14, 48) + (r.randf_range(0, 70) if r.randf() < 0.18 else 0.0) + clampf((dist - 400.0) * 0.03, 0.0, 20.0)
		var rect := Rect2(p.x - w * 0.5, p.y - d * 0.5, w, d)
		var spec := {"rect": rect, "style": ["brick_trim", "limestone", "limestone_grid", "redwhite"][r.randi_range(0, 3)],
			"wall": [0, 1, 3, 9, 10, 11, 12, 5][r.randi_range(0, 7)], "trim": r.randi_range(0, 3), "seed": r.randf(),
			"street_sides": ["S", "E", "N", "W"], "ground_h": 4.0}
		var b := chunk.always
		b.set_material(mats.far_facade, false, true)
		b.custom = Color(2.0, 3.0, 4.0, spec.seed)
		for side in ["S", "E", "N", "W"]:
			var f := BuildingGenerator.side_frame(rect, side)
			b.color = Color(spec.wall / 15.0, spec.trim / 7.0, 1.0 / 3.0, 0.0)
			var l: Vector3 = f.left
			var rr: Vector3 = l + f.right * f.len
			b.add_quad(l, rr, rr + Vector3.UP * h, l + Vector3.UP * h, Vector2(0, 0), Vector2(f.len, 0), Vector2(f.len, h), Vector2(0, h))
		b.color = Color(spec.wall / 15.0, 0, 0, 1)
		b.add_quad_facing(Vector3(rect.position.x, h, rect.end.y), Vector3(rect.end.x, h, rect.end.y),
			Vector3(rect.end.x, h, rect.position.y), Vector3(rect.position.x, h, rect.position.y), Vector3.UP)
		if dist < 650.0:
			chunk.shadow.set_material(mats.shadow_only)
			chunk.shadow.add_box(Transform3D(Basis(), Vector3(p.x, h * 0.5, p.y)), Vector3(w, h, d))
