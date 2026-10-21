class_name BuildingGenerator
extends RefCounted
## Assembles buildings out of kit modules (instanced per chunk) following facade grammars
## derived from the trailer: red brick with limestone window surrounds, limestone towers,
## metal-framed lofts (The Jade Garden), cream brick with bay-like double windows,
## painted brick and walk-ups with fire escapes. Also emits the merged LOD shell,
## shadow proxy, roof, party walls and collision for every building.

const FLOOR_H := 3.0
const SIDES := ["S", "E", "N", "W"]
const NORMALS := {"S": Vector3(0, 0, 1), "N": Vector3(0, 0, -1), "E": Vector3(1, 0, 0), "W": Vector3(-1, 0, 0)}

## Facade grammars. Patterns are cyclic module sequences; every module is 2 m or 4 m wide.
const STYLES := {
	"brick_trim": {  # Paul & Sons tower: red brick, paired windows with limestone surrounds, stone quoins
		"corner": "stone", "ground": ["Metal_FirstFloor_Window", "Metal_FirstFloor_Window", "Brick_TopTrim"],
		"floor": ["Brick_Window_Trim", "Brick_Window_Trim", "Brick_Plain_3"], "top": ["Brick_Window_Trim_Single", "Brick_Window_Trim_Single", "Brick_Plain_3"],
		"filler": "Brick_Plain_3", "cornice": "trim", "band": true, "far_style": 1,
	},
	"brick_single": {  # walk-up / tenement
		"corner": "none", "ground": ["Metal_FirstFloor_Window", "Metal_FirstFloor_Window", "Metal_FirstFloor_Wall"],
		"floor": ["Brick_Window_Trim_Single", "Brick_Plain_3"], "top": ["Brick_Window_Trim_Single", "Brick_Plain_3"],
		"filler": "Brick_Plain_3", "cornice": "brick", "band": false, "far_style": 0,
	},
	"brick_pairs": {
		"corner": "none", "ground": ["Metal_FirstFloor_Window", "Metal_FirstFloor_Wall"],
		"floor": ["Brick_Window_Trim", "Brick_Window_Trim", "Brick_Plain_3"], "top": ["Brick_Window_Trim", "Brick_Window_Trim", "Brick_Plain_3"],
		"filler": "Brick_Plain_3", "cornice": "metal", "band": true, "far_style": 1,
	},
	"limestone": {  # PA Savings Bank / pale towers: limestone blocks, deep set windows
		"corner": "stone", "ground": ["Brick_Inset_Window_Curved"],
		"floor": ["Brick_Inset_Window"], "top": ["Brick_Inset_Window_Curved_Small"],
		"filler": "Brick_Window_Square_Single", "cornice": "trim", "band": false, "far_style": 1,
	},
	"limestone_grid": {
		"corner": "stone", "ground": ["Metal_FirstFloor_Window", "Metal_FirstFloor_Window", "Brick_TopTrim"],
		"floor": ["Brick_Window_Square_Single"], "top": ["Brick_Window_Square_Single"],
		"filler": "Brick_Window_Square_Single", "cornice": "trim", "band": false, "far_style": 0,
	},
	"redwhite": {  # cream brick with red trim double windows (bay building next to The Jade Garden)
		"corner": "stone", "ground": ["Metal_FirstFloor_Window", "Metal_FirstFloor_Window", "Brick_TopTrim"],
		"floor": ["Brick_RedWhite_DoubleWindow"], "top": ["Brick_Window_CurvedDouble"],
		"filler": "Brick_Window_Square_Single", "cornice": "trim", "band": false, "far_style": 1,
	},
	"painted": {  # slate-blue painted building
		"corner": "none", "ground": ["Metal_FirstFloor_Window", "Metal_FirstFloor_Window", "Metal_FirstFloor_Wall"],
		"floor": ["Brick_Window_Square_Single"], "top": ["Brick_Window_Square_Single"],
		"filler": "Brick_Window_Square_Single", "cornice": "metal", "band": false, "far_style": 0,
	},
	"metal_loft": {  # Jade Garden family: metal frames between brick piers
		"corner": "metal", "ground": ["Metal_FirstFloor_Window", "Metal_FirstFloor_Window", "Metal_FirstFloor_Wall"],
		"floor": ["Metal_Window"], "top": ["Metal_FullWindow"],
		"filler": "Metal_Window_Half", "cornice": "metal", "band": false, "far_style": 2,
	},
}

var kit: KitLibrary
var mats: CityMaterials
var rng := RandomNumberGenerator.new()
var props: PropFactory
var buildings: Array = []  # summary dictionaries (for minimap / stats)


func _init(library: KitLibrary, materials: CityMaterials, prop_factory: PropFactory) -> void:
	kit = library
	mats = materials
	props = prop_factory


static func building_height(spec: Dictionary) -> float:
	return spec.get("ground_h", 4.0) + spec.get("floors", 6) * FLOOR_H


static func custom_for(spec: Dictionary) -> Color:
	return Color(spec.get("wall", 0) / 15.0, spec.get("wall2", 9) / 15.0, spec.get("trim", 0) / 7.0, spec.get("seed", 0.5))


## Facade frame of one side of a rectangular footprint.
static func side_frame(rect: Rect2, side: String) -> Dictionary:
	var x0 := rect.position.x
	var z0 := rect.position.y
	var x1 := rect.end.x
	var z1 := rect.end.y
	var n: Vector3 = NORMALS[side]
	var right := Vector3.UP.cross(n)
	var left: Vector3
	var length: float
	match side:
		"S":
			left = Vector3(x0, 0, z1)
			length = rect.size.x
		"N":
			left = Vector3(x1, 0, z0)
			length = rect.size.x
		"E":
			left = Vector3(x1, 0, z1)
			length = rect.size.y
		"W":
			left = Vector3(x0, 0, z0)
			length = rect.size.y
	return {"n": n, "right": right, "left": left, "len": length, "basis": Basis(right, Vector3.UP, n)}


func _place(chunk: CityChunk, name: String, f: Dictionary, offset: float, y: float, custom: Color, sy := 1.0, mirror := false, depth_off := 0.0) -> void:
	var m := kit.mesh(name)
	if m == null:
		return
	var b: Basis = f.basis
	if sy != 1.0:
		b = Basis(b.x, b.y * sy, b.z)
	if mirror:
		b = Basis(-b.x, b.y, b.z)
	var pos: Vector3 = f.left + f.right * offset + Vector3.UP * y + f.n * depth_off
	chunk.add_instance(m, Transform3D(b, pos), custom, "detail")


## Splits `length` into module names following `pattern`, centred, padded with `filler`.
func _layout(length: float, pattern: Array, filler: String) -> Array:
	var out: Array = []
	var widths := []
	var total := 0.0
	var i := 0
	while true:
		var name: String = pattern[i % pattern.size()]
		var w := _width(name)
		if total + w > length + 0.01:
			break
		out.append(name)
		widths.append(w)
		total += w
		i += 1
		if i > 400:
			break
	# drop a trailing pier so the pattern ends on a window, then pad symmetrically
	if out.size() > 2 and (out[-1] == filler or out[-1] in ["Brick_Plain_3", "Metal_FirstFloor_Wall", "Brick_TopTrim"]) and pattern.size() > 1:
		total -= widths[-1]
		out.pop_back()
	var rest := length - total
	var pad := int(round(rest / 2.0))
	var left_n := pad / 2
	var right_n := pad - left_n
	var res: Array = []
	for k in left_n:
		res.append(filler)
	res.append_array(out)
	for k in right_n:
		res.append(filler)
	return res


static func _width(name: String) -> float:
	if name in ["Brick_Inset", "Brick_Inset_Window", "Brick_Inset_Window_Curved", "Brick_Inset_Window_Curved_Small",
			"Brick_RedWhite_DoubleWindow", "Brick_Window_CurvedDouble", "Metal_Window"]:
		return 4.0
	return 2.0


## Main entry: emits a building into `chunk`.
func build(chunk: CityChunk, spec: Dictionary) -> void:
	rng.seed = int(spec.get("seed", 0.5) * 1000003.0) + 17
	if spec.has("prebuilt"):
		_build_prebuilt(chunk, spec)
	else:
		_build_modular(chunk, spec)
	buildings.append({"rect": spec.rect, "h": spec.get("height", building_height(spec)), "style": spec.get("style", spec.get("prebuilt", ""))})


func _build_prebuilt(chunk: CityChunk, spec: Dictionary) -> void:
	var m := kit.mesh(spec.prebuilt)
	var xf: Transform3D = spec.xform
	chunk.add_instance(m, xf, custom_for(spec), "detail")
	var aabb := xf * m.get_aabb()
	var rect := Rect2(aabb.position.x, aabb.position.z, aabb.size.x, aabb.size.z)
	var h := aabb.size.y
	spec["rect"] = rect
	spec["height"] = h
	_emit_volume(chunk, spec, rect.grow(-0.35), h, h)
	chunk.add_box_collider(Transform3D(Basis(), aabb.get_center()), aabb.size)


func _build_modular(chunk: CityChunk, spec: Dictionary) -> void:
	var st: Dictionary = STYLES[spec.style]
	var rect: Rect2 = spec.rect
	var floors: int = spec.floors
	var gh: float = spec.get("ground_h", 4.0)
	var H := gh + floors * FLOOR_H
	var custom := custom_for(spec)
	var street: Array = spec.get("street_sides", ["S"])
	var corner_kind: String = st.corner
	var roof: String = spec.get("roof", "flat")
	var cornice_kind: String = spec.get("cornice", st.cornice)
	var sy_ground := gh / FLOOR_H

	# ---- street facades from kit modules
	for side in street:
		var f := side_frame(rect, side)
		var L: float = f.len
		var inset := 1.0 if corner_kind == "stone" else 0.0
		var span := L - inset * 2.0
		# ground floor (with an entrance roughly in the middle of the main facade)
		var ground: Array = _layout(span, spec.get("ground_pattern", st.ground), "Metal_FirstFloor_Wall")
		var door_i := -1
		if side == street[0] and ground.size() >= 3 and not spec.get("no_door", false):
			door_i = ground.size() / 2
		var off := inset
		for i in ground.size():
			var name: String = ground[i]
			var w := _width(name)
			if i == door_i and w == 2.0:
				_place(chunk, spec.get("door_frame", "DoorFrame_Metal_Single"), f, off + 1.0, 0.0, custom)
				var leaf: String = spec.get("door", "Door_3")
				_place(chunk, leaf, f, off + 1.0, 0.0, custom, 1.0, false, -0.08)
				_place(chunk, leaf, f, off + 1.0, 0.0, custom, 1.0, true, -0.08)
				if gh > 3.05:
					var band := Basis(f.basis.x, f.basis.y * ((gh - 3.0) / 1.0), f.basis.z)
					chunk.add_instance(kit.mesh("Metal_FirstFloor_Wall_1"), Transform3D(band, f.left + f.right * (off + 1.0) + Vector3.UP * 3.0), custom)
			else:
				_place(chunk, name, f, off + w * 0.5, 0.0, custom, sy_ground)
			off += w
		# upper floors
		var floor_mods: Array = _layout(span, spec.get("floor_pattern", st.floor), st.filler)
		var top_mods: Array = _layout(span, spec.get("top_pattern", st.top), st.filler)
		for k in floors:
			var y := gh + k * FLOOR_H
			var mods: Array = top_mods if (k == floors - 1 and floors > 3) else floor_mods
			off = inset
			for name in mods:
				var w := _width(name)
				_place(chunk, name, f, off + w * 0.5, y, custom)
				off += w
		# band courses over the ground floor (brick styles)
		if st.band:
			var nb := int(span / 2.0)
			for i in nb:
				_place(chunk, "Brick_Ornament_Horizontal", f, inset + 1.0 + i * 2.0, gh + 0.17, custom)
		# corner quoins / columns at the facade's right end (the next side's left end)
		_corners(chunk, f, side, street, corner_kind, floors, gh, custom)
		# cornice
		if roof != "mansard":
			_cornice(chunk, f, side, street, cornice_kind, H, custom)
		# storefront dressing
		_storefront(chunk, f, side, spec, gh)

	# ---- roof
	if roof == "mansard":
		_mansard(chunk, rect, street, H, custom, spec.get("dormers", true))
	else:
		_flat_roof(chunk, rect, H, spec, street)

	# ---- fire escape
	if spec.has("fire_escape"):
		var fe: Dictionary = spec.fire_escape
		props.fire_escape(chunk, side_frame(rect, fe.side), fe.get("offset", 2.0), fe.get("width", 6.0), gh, floors)

	_emit_volume(chunk, spec, rect, H, H + (3.2 if roof == "mansard" else 1.0))
	chunk.add_box_collider(Transform3D(Basis(), Vector3(rect.get_center().x, H * 0.5, rect.get_center().y)), Vector3(rect.size.x, H, rect.size.y))


func _corners(chunk: CityChunk, f: Dictionary, side: String, street: Array, kind: String, floors: int, gh: float, custom: Color) -> void:
	if kind == "none":
		return
	var next_side: String = SIDES[(SIDES.find(side) + 1) % 4]
	var prev_side: String = SIDES[(SIDES.find(side) + 3) % 4]
	# right end corner (shared with next side going clockwise seen from above)
	var at := [[f.len, true]]
	if not (prev_side in street):
		at.append([0.0, false])
	for a in at:
		var pos: Vector3 = f.left + f.right * a[0]
		var right_end: bool = a[1]
		var b: Basis = f.basis
		if not right_end:
			# left end: rotate so the column wraps the corner towards the left side
			b = Basis(Vector3.UP, -PI * 0.5) * b
		if kind == "stone":
			var bg := Basis(b.x, b.y * (gh / FLOOR_H), b.z)
			chunk.add_instance(kit.mesh("Brick_CornerColumn_Bottom"), Transform3D(bg, pos), custom)
			for k in floors:
				var nm := "Brick_CornerColumn_Top" if k == floors - 1 else "Brick_CornerColumn_Center"
				chunk.add_instance(kit.mesh(nm), Transform3D(b, pos + Vector3.UP * (gh + k * FLOOR_H)), custom)
		elif kind == "metal":
			var bg := Basis(b.x, b.y * (gh / FLOOR_H), b.z)
			var inward: Vector3 = -f.n * 0.0
			chunk.add_instance(kit.mesh("Metal_Column_Bottom"), Transform3D(bg, pos + inward), custom)
			for k in floors:
				var nm := "Metal_Column_Top" if k == floors - 1 else "Metal_Column_Center"
				chunk.add_instance(kit.mesh(nm), Transform3D(b, pos + inward + Vector3.UP * (gh + k * FLOOR_H)), custom)


func _cornice(chunk: CityChunk, f: Dictionary, side: String, street: Array, kind: String, H: float, custom: Color) -> void:
	var center: String = {"trim": "Cornice_Trim_Center", "metal": "Cornice_Metal_Center", "brick": "Cornice_Brick_Center"}[kind]
	var n := int(round(f.len / 2.0))
	for i in n:
		_place(chunk, center, f, 1.0 + i * 2.0, H, custom)
	# close the outer corner with a small block so cornice runs meet cleanly
	var depth: float = {"trim": 0.53, "metal": 0.1, "brick": 0.0}[kind]
	if depth > 0.0:
		var next_side: String = SIDES[(SIDES.find(side) + 1) % 4]
		if next_side in street:
			var corner: Vector3 = f.left + f.right * f.len
			var c: Vector3 = corner + (f.n + f.right) * depth * 0.5 + Vector3.UP * 0.5
			chunk.detail.set_material(mats.kit["MI_Trim"] if kind == "trim" else mats.kit["MI_Trim_MetalConcrete"])
			chunk.detail.add_box(Transform3D(Basis(), c), Vector3(depth, 0.9, depth) + Vector3(0.02, 0, 0.02), 1)


func _storefront(chunk: CityChunk, f: Dictionary, side: String, spec: Dictionary, gh: float) -> void:
	var sf: Array = spec.get("storefronts", [])
	for s in sf:
		if s.get("side", "S") != side:
			continue
		var off: float = s.get("offset", f.len * 0.5)
		var w: float = s.get("width", 6.0)
		if s.has("awning"):
			props.awning(chunk, f, off, w, gh - 1.25 if gh > 3.5 else 2.3, s.awning)
		if s.has("sign"):
			var sw: float = s.get("sign_w", minf(w, 6.0))
			var sh: float = s.get("sign_h", sw / 4.0)
			var sy: float = s.get("sign_y", gh + sh * 0.5 + 0.1)
			props.wall_sign(chunk, f, off, sy, sw, sh, s.sign, s.get("sign_depth", 0.12))
		if s.has("blade"):
			props.blade_sign(chunk, f, off, s.get("blade_y", gh + 0.4), s.blade, s.get("blade_size", Vector2(0.9, 0.9)))


func _mansard(chunk: CityChunk, rect: Rect2, street: Array, H: float, custom: Color, dormers: bool) -> void:
	for side in SIDES:
		var f := side_frame(rect, side)
		var n := int(round(f.len / 2.0))
		for i in n:
			var name := "Roof_SlateCornice_Center"
			if i == 0:
				name = "Roof_SlateCornice_Corner"
			elif dormers and side in street and i % 2 == 1 and i < n - 1:
				name = "Roof_SlateCornice_Window_1"
			elif not (side in street):
				name = "Roof_Slate_Center"
			_place(chunk, name, f, 1.0 + i * 2.0, H, custom)
	# flat top of the mansard
	var top := rect.grow(-1.95)
	chunk.always.set_material(mats.roof_tar)
	var y := H + 3.05
	chunk.always.add_quad(Vector3(top.position.x, y, top.end.y), Vector3(top.end.x, y, top.end.y),
		Vector3(top.end.x, y, top.position.y), Vector3(top.position.x, y, top.position.y),
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1))


func _flat_roof(chunk: CityChunk, rect: Rect2, H: float, spec: Dictionary, street: Array) -> void:
	var y := H + 0.05
	chunk.always.set_material(mats.roof_tar)
	chunk.always.add_quad(Vector3(rect.position.x, y, rect.end.y), Vector3(rect.end.x, y, rect.end.y),
		Vector3(rect.end.x, y, rect.position.y), Vector3(rect.position.x, y, rect.position.y),
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1))
	# parapet on the non-street sides (street sides have the cornice)
	for side in SIDES:
		if side in street:
			continue
		var f := side_frame(rect, side)
		var c: Vector3 = f.left + f.right * (f.len * 0.5) - f.n * 0.15 + Vector3.UP * (H + 0.5)
		chunk.always.set_material(mats.kit["MI_Trim"] if spec.get("style", "") in ["limestone", "limestone_grid"] else mats.curb)
		chunk.always.add_box(Transform3D(f.basis, c), Vector3(f.len, 1.0, 0.3))
	# rooftop clutter: bulkhead, AC units, sometimes a water tank
	var cx := rect.get_center()
	var bw := clampf(rect.size.x * 0.25, 3.0, 6.0)
	var bd := clampf(rect.size.y * 0.25, 3.0, 5.0)
	var bpos := Vector3(cx.x + rng.randf_range(-1.0, 1.0) * (rect.size.x * 0.5 - bw), H + 1.5, cx.y + rng.randf_range(-1.0, 1.0) * (rect.size.y * 0.5 - bd))
	chunk.always.set_material(mats.curb)
	chunk.always.add_box(Transform3D(Basis(), bpos), Vector3(bw, 3.0, bd))
	chunk.shadow.set_material(mats.shadow_only)
	chunk.shadow.add_box(Transform3D(Basis(), bpos), Vector3(bw, 3.0, bd))
	var ac := kit.mesh("Prop_ACUnit")
	for i in rng.randi_range(1, 4):
		var p := Vector3(rect.position.x + rng.randf_range(2.0, rect.size.x - 2.0), H + 0.05, rect.position.y + rng.randf_range(2.0, rect.size.y - 2.0))
		chunk.add_instance(ac, Transform3D(Basis(Vector3.UP, rng.randi_range(0, 3) * PI * 0.5) * Basis().scaled(Vector3.ONE * 1.6), p), Color(0, 0, 0, rng.randf()), "roof")
	if spec.get("water_tank", false):
		props.water_tank(chunk, Vector3(cx.x - bpos.x * 0.0 + rng.randf_range(-2, 2), H + 0.05, cx.y + rng.randf_range(-2, 2)))


## LOD shell (far facade shader), shadow proxy and blank walls on back/party sides.
func _emit_volume(chunk: CityChunk, spec: Dictionary, rect: Rect2, H: float, shadow_h: float) -> void:
	var st: Dictionary = STYLES.get(spec.get("style", ""), {})
	var far_style: int = st.get("far_style", 1)
	var wall_idx: int = spec.get("wall", 0)
	var street: Array = spec.get("street_sides", ["S"])
	var gh: float = spec.get("ground_h", 4.0)
	var bay := 4.0 if far_style == 2 else 2.0
	var seed: float = spec.get("seed", 0.5)
	var b := chunk.shell
	b.set_material(mats.far_facade, false, true)
	b.custom = Color(bay, FLOOR_H, gh, seed)
	for side in SIDES:
		var f := side_frame(rect, side)
		var style := far_style if side in street or spec.has("prebuilt") else 3
		b.color = Color(wall_idx / 15.0, spec.get("trim", 0) / 7.0, style / 3.0, 0.0)
		_facade_quad(b, f, 0.0, H)
	b.color = Color(wall_idx / 15.0, 0, 0, 1.0)
	b.add_quad(Vector3(rect.position.x, H, rect.end.y), Vector3(rect.end.x, H, rect.end.y),
		Vector3(rect.end.x, H, rect.position.y), Vector3(rect.position.x, H, rect.position.y),
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1))
	# back and party walls are always rendered with the cheap facade shader
	if not spec.has("prebuilt"):
		var a := chunk.always
		a.set_material(mats.far_facade, false, true)
		a.custom = Color(2.0, FLOOR_H, gh, seed)
		for side in SIDES:
			if side in street:
				continue
			var f := side_frame(rect, side)
			var back: bool = spec.get("back_windows", {}).get(side, false)
			a.color = Color(wall_idx / 15.0, spec.get("trim", 0) / 7.0, (0 if back else 3) / 3.0, 0.0)
			_facade_quad(a, f, 0.0, H, -0.05)
	# shadow proxy
	chunk.shadow.set_material(mats.shadow_only)
	var c := Vector3(rect.get_center().x, shadow_h * 0.5, rect.get_center().y)
	chunk.shadow.add_box(Transform3D(Basis(), c), Vector3(maxf(rect.size.x - 0.5, 1.0), shadow_h, maxf(rect.size.y - 0.5, 1.0)))


func _facade_quad(b: GeoBatch, f: Dictionary, y0: float, y1: float, push := 0.0) -> void:
	var l: Vector3 = f.left + f.n * push
	var r: Vector3 = l + f.right * f.len
	b.add_quad(l + Vector3.UP * y0, r + Vector3.UP * y0, r + Vector3.UP * y1, l + Vector3.UP * y1,
		Vector2(0, y0), Vector2(f.len, y0), Vector2(f.len, y1), Vector2(0, y1))
