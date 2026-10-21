class_name PropFactory
extends RefCounted
## Procedural meshes for everything the kit does not provide (street furniture, trees,
## fire escapes, awnings, signs). Repeated props are built once and instanced through
## MultiMesh by CityChunk.

var mats: CityMaterials
var kit: KitLibrary
var _cache := {}
var rng := RandomNumberGenerator.new()


func _init(materials: CityMaterials, library: KitLibrary) -> void:
	mats = materials
	kit = library
	rng.seed = 4242


func _cached(key: String, builder: Callable) -> Mesh:
	if not _cache.has(key):
		_cache[key] = builder.call()
	return _cache[key]


# ----------------------------------------------------------------------------- trees
## Birch-like street tree: white trunk with forked branches, canopy of noisy leaf clumps.
func tree_mesh(variant: int) -> Mesh:
	return _cached("tree%d" % variant, func(): return _build_tree(variant))


func _build_tree(variant: int) -> Mesh:
	var r := RandomNumberGenerator.new()
	r.seed = 9001 + variant * 77
	var g := GeoBatch.new()
	g.set_material(mats.bark)
	var height := r.randf_range(6.0, 7.6)
	var lean := Vector3(r.randf_range(-0.25, 0.25), 0, r.randf_range(-0.25, 0.25))
	var fork_y := r.randf_range(2.4, 3.2)
	var trunk_top := Vector3(0, fork_y, 0) + lean * 0.4
	g.add_tube(Vector3.ZERO, trunk_top, 0.13, 0.1, 7)
	var tips: Array[Vector3] = []
	var nb := r.randi_range(3, 4)
	for i in nb:
		var a := TAU * (float(i) / nb) + r.randf_range(-0.4, 0.4)
		var out := Vector3(cos(a), 0, sin(a))
		var mid := trunk_top + out * r.randf_range(0.5, 0.9) + Vector3(0, r.randf_range(1.2, 1.8), 0) + lean * 0.3
		var tip := mid + out * r.randf_range(0.5, 1.0) + Vector3(0, r.randf_range(1.2, 2.0), 0) + lean * 0.3
		g.add_tube(trunk_top, mid, 0.085, 0.06, 6)
		g.add_tube(mid, tip, 0.06, 0.025, 5)
		tips.append(mid)
		tips.append(tip)
		# twigs
		for k in 2:
			var tw := mid + (tip - mid) * r.randf_range(0.2, 0.7)
			var td := (out.rotated(Vector3.UP, r.randf_range(-1.2, 1.2)) + Vector3(0, r.randf_range(0.3, 0.9), 0)).normalized()
			g.add_tube(tw, tw + td * r.randf_range(0.6, 1.1), 0.03, 0.01, 4)
	# leader
	var leader := trunk_top + Vector3(0, height - fork_y, 0) + lean * 0.6
	g.add_tube(trunk_top, leader, 0.08, 0.02, 6)
	tips.append(leader)

	# canopy clumps
	g.set_material(mats.leaves)
	var canopy_c := Vector3(0, (fork_y + height) * 0.5 + 0.6, 0) + lean * 0.5
	var canopy_r := Vector3(r.randf_range(2.0, 2.6), (height - fork_y) * 0.55 + 0.4, r.randf_range(2.0, 2.6))
	var clumps: Array[Vector3] = []
	for t in tips:
		clumps.append(t + Vector3(r.randf_range(-0.3, 0.3), r.randf_range(-0.1, 0.4), r.randf_range(-0.3, 0.3)))
	for i in 14:
		var d := Vector3(r.randf_range(-1, 1), r.randf_range(-0.7, 1), r.randf_range(-1, 1)).normalized()
		clumps.append(canopy_c + d * canopy_r * r.randf_range(0.5, 0.95))
	for c in clumps:
		var rad := r.randf_range(0.55, 0.9)
		_clump(g, c, Vector3(rad, rad * r.randf_range(0.75, 0.95), rad), canopy_c, canopy_r, r)
	return g.commit()


static var _ico_v: Array[Vector3] = []
static var _ico_f: Array = []


static func _icosphere() -> void:
	if not _ico_v.is_empty():
		return
	var t := (1.0 + sqrt(5.0)) / 2.0
	var v: Array[Vector3] = [Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)]
	for i in v.size():
		v[i] = v[i].normalized()
	var f := [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]]
	# one subdivision -> 42 vertices / 80 faces
	var mid := {}
	var nf := []
	for tri in f:
		var m := []
		for e in 3:
			var a: int = tri[e]
			var b: int = tri[(e + 1) % 3]
			var key := mini(a, b) * 100 + maxi(a, b)
			if not mid.has(key):
				v.append(((v[a] + v[b]) * 0.5).normalized())
				mid[key] = v.size() - 1
			m.append(mid[key])
		nf.append([tri[0], m[0], m[2]])
		nf.append([tri[1], m[1], m[0]])
		nf.append([tri[2], m[2], m[1]])
		nf.append([m[0], m[1], m[2]])
	_ico_v = v
	_ico_f = nf


func _clump(g: GeoBatch, c: Vector3, rad: Vector3, canopy_c: Vector3, canopy_r: Vector3, r: RandomNumberGenerator) -> void:
	_icosphere()
	var pts: Array[Vector3] = []
	var nrm: Array[Vector3] = []
	var occ: Array[float] = []
	var ph := r.randf() * 10.0
	for d in _ico_v:
		var bump := 1.0 + 0.18 * sin(d.x * 5.1 + ph) * sin(d.y * 4.3 + ph * 1.3) * sin(d.z * 4.7 + ph * 0.7)
		var p := c + d * rad * bump
		pts.append(p)
		# blend clump normal with the canopy envelope normal for soft, volumetric shading
		var env := ((p - canopy_c) / canopy_r).normalized()
		nrm.append((d * 0.55 + env * 0.45).normalized())
		var outer := clampf(((p - canopy_c) / canopy_r).length(), 0.0, 1.2)
		occ.append(clampf(0.25 + outer * 0.6 + d.y * 0.15 + (p.y - canopy_c.y) / canopy_r.y * 0.2, 0.0, 1.0))
	var s: GeoBatch.Surface = g._cur
	var base := s.verts.size()
	for i in pts.size():
		s.verts.append(pts[i])
		s.normals.append(nrm[i])
		var t := nrm[i].cross(Vector3.UP if absf(nrm[i].y) < 0.9 else Vector3.RIGHT).normalized()
		s.tangents.append_array([t.x, t.y, t.z, 1.0])
		s.uvs.append(Vector2(pts[i].x, pts[i].y))
		s.colors.append(Color(occ[i], 0, 0, 1))
	for tri in _ico_f:
		s.indices.append_array([base + tri[0], base + tri[2], base + tri[1]])


func tree_guard_mesh() -> Mesh:
	return _cached("guard", func():
		var g := GeoBatch.new()
		g.set_material(mats.iron)
		var s := 0.8
		for side in 4:
			var b := Basis(Vector3.UP, side * PI * 0.5)
			var a := b * Vector3(-s, 0, s)
			var c := b * Vector3(s, 0, s)
			g.add_tube(a + Vector3(0, 0.45, 0), c + Vector3(0, 0.45, 0), 0.018, 0.018, 4)
			g.add_tube(a + Vector3(0, 0.08, 0), c + Vector3(0, 0.08, 0), 0.015, 0.015, 4)
			for i in 9:
				var p := a.lerp(c, i / 8.0)
				g.add_tube(p, p + Vector3(0, 0.5, 0), 0.01, 0.01, 4)
		# soil pit + low ground cover
		g.set_material(mats.soil)
		g.add_quad(Vector3(-s, 0.012, s), Vector3(s, 0.012, s), Vector3(s, 0.012, -s), Vector3(-s, 0.012, -s),
			Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1))
		return g.commit())


# ----------------------------------------------------------------------------- street furniture
func lamp_mesh() -> Mesh:
	return _cached("lamp", func():
		var g := GeoBatch.new()
		g.set_material(mats.metal_dark)
		g.add_cylinder(Vector3.ZERO, 0.17, 0.15, 0.6, 8)
		g.add_cylinder(Vector3(0, 0.6, 0), 0.1, 0.065, 7.6, 8)
		# davit arm toward +Z (the street)
		var top := Vector3(0, 8.2, 0)
		g.add_tube(top, top + Vector3(0, 0.45, 0.6), 0.055, 0.05, 6)
		g.add_tube(top + Vector3(0, 0.45, 0.6), top + Vector3(0, 0.55, 1.9), 0.05, 0.045, 6)
		g.add_box(Transform3D(Basis(), top + Vector3(0, 0.5, 2.25)), Vector3(0.36, 0.2, 0.85), 1)
		g.set_material(mats.lamp_glass)
		g.add_box(Transform3D(Basis(), top + Vector3(0, 0.38, 2.25)), Vector3(0.3, 0.06, 0.7), 1)
		return g.commit())


func signal_mesh() -> Mesh:
	return _cached("signal", func():
		var g := GeoBatch.new()
		g.set_material(mats.metal_dark)
		g.add_cylinder(Vector3.ZERO, 0.16, 0.12, 6.4, 8)
		g.add_tube(Vector3(0, 6.1, 0), Vector3(0, 6.1, 4.5), 0.07, 0.05, 6)
		for p in [Vector3(0, 5.6, 4.3), Vector3(0, 2.6, 0.22)]:
			g.set_material(mats.metal_dark)
			g.add_box(Transform3D(Basis(), p), Vector3(0.34, 0.95, 0.24), 1)
			for k in 3:
				var lp: Vector3 = p + Vector3(0, 0.3 - k * 0.3, 0.125)
				g.set_material(mats.signal_red if k == 0 else mats.signal_off)
				g.add_quad(lp + Vector3(-0.1, -0.1, 0), lp + Vector3(0.1, -0.1, 0), lp + Vector3(0.1, 0.1, 0), lp + Vector3(-0.1, 0.1, 0),
					Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0))
		# street-name blades and a ONE WAY sign
		var sm := mats.sign_material("T_StreetSigns", 0.0)
		g.set_material(sm)
		for b in [[Vector3(0, 3.4, 0), Basis()], [Vector3(0, 3.6, 0), Basis(Vector3.UP, PI * 0.5)]]:
			var bb: Basis = b[1]
			var c: Vector3 = b[0]
			var dx: Vector3 = bb * Vector3(0.6, 0, 0)
			var dy := Vector3(0, 0.11, 0)
			var dz: Vector3 = bb * Vector3(0, 0, 0.02)
			var v0 := 0.0 if b[0].y < 3.5 else 0.5
			g.add_quad(c - dx - dy + dz, c + dx - dy + dz, c + dx + dy + dz, c - dx + dy + dz, Vector2(0, v0 + 0.5), Vector2(0.5, v0 + 0.5), Vector2(0.5, v0), Vector2(0, v0))
			g.add_quad(c + dx - dy - dz, c - dx - dy - dz, c - dx + dy - dz, c + dx + dy - dz, Vector2(0, v0 + 0.5), Vector2(0.5, v0 + 0.5), Vector2(0.5, v0), Vector2(0, v0))
		var oc := Vector3(0, 2.0, 0.14)
		g.add_quad(oc + Vector3(-0.45, -0.15, 0), oc + Vector3(0.45, -0.15, 0), oc + Vector3(0.45, 0.15, 0), oc + Vector3(-0.45, 0.15, 0),
			Vector2(0.5, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0.5, 0))
		return g.commit())


func hydrant_mesh() -> Mesh:
	return _cached("hydrant", func():
		var g := GeoBatch.new()
		g.set_material(mats.hydrant_red)
		g.add_cylinder(Vector3.ZERO, 0.16, 0.16, 0.08, 8)
		g.add_cylinder(Vector3(0, 0.08, 0), 0.12, 0.11, 0.5, 8)
		g.add_cylinder(Vector3(0, 0.58, 0), 0.14, 0.05, 0.16, 8)
		g.add_tube(Vector3(-0.2, 0.42, 0), Vector3(0.2, 0.42, 0), 0.05, 0.05, 6)
		g.add_tube(Vector3(0, 0.38, 0), Vector3(0, 0.38, 0.19), 0.06, 0.06, 6)
		return g.commit())


func trash_can_mesh() -> Mesh:
	return _cached("trash", func():
		var g := GeoBatch.new()
		g.set_material(mats.trash_green)
		g.add_cylinder(Vector3.ZERO, 0.24, 0.29, 0.92, 10, false)
		g.add_cylinder(Vector3(0, 0.02, 0), 0.22, 0.22, 0.01, 10, true)
		g.set_material(mats.iron)
		g.add_cylinder(Vector3(0, 0.9, 0), 0.3, 0.3, 0.04, 10, false)
		return g.commit())


func bench_mesh() -> Mesh:
	return _cached("bench", func():
		var g := GeoBatch.new()
		g.set_material(mats.wood_bench)
		for i in 3:
			g.add_box(Transform3D(Basis(), Vector3(0, 0.45, -0.18 + i * 0.13)), Vector3(1.8, 0.04, 0.1), 0)
		for i in 2:
			g.add_box(Transform3D(Basis(Vector3.RIGHT, -0.25), Vector3(0, 0.72 + i * 0.13, -0.3)), Vector3(1.8, 0.1, 0.035), 0)
		g.set_material(mats.iron)
		for x in [-0.8, 0.8]:
			g.add_box(Transform3D(Basis(), Vector3(x, 0.22, -0.05)), Vector3(0.05, 0.44, 0.5), 0)
			g.add_box(Transform3D(Basis(Vector3.RIGHT, -0.25), Vector3(x, 0.7, -0.33)), Vector3(0.05, 0.55, 0.04), 0)
		return g.commit())


func mailbox_mesh() -> Mesh:
	return _cached("mailbox", func():
		var g := GeoBatch.new()
		g.set_material(mats.mailbox_blue)
		g.add_box(Transform3D(Basis(), Vector3(0, 0.75, 0)), Vector3(0.52, 0.8, 0.5), 0)
		g.add_cylinder(Vector3(0, 1.15, 0), 0.26, 0.26, 0.05, 10)
		for x in [-0.22, 0.22]:
			for z in [-0.2, 0.2]:
				g.add_box(Transform3D(Basis(), Vector3(x, 0.17, z)), Vector3(0.05, 0.35, 0.05), 0)
		return g.commit())


func newsbox_mesh() -> Mesh:
	return _cached("newsbox", func():
		var g := GeoBatch.new()
		g.set_material(mats.awning["red"])
		g.add_box(Transform3D(Basis(), Vector3(0, 0.6, 0)), Vector3(0.45, 0.6, 0.4), 0)
		g.set_material(mats.iron)
		g.add_box(Transform3D(Basis(), Vector3(0, 0.15, 0)), Vector3(0.4, 0.3, 0.35), 0)
		return g.commit())


func planter_mesh(length: float) -> Mesh:
	return _cached("planter%d" % int(length * 10), func():
		var g := GeoBatch.new()
		g.set_material(mats.curb)
		g.add_box(Transform3D(Basis(), Vector3(0, 0.25, 0)), Vector3(length, 0.5, 0.7), 0)
		g.set_material(mats.hedge)
		var r := RandomNumberGenerator.new()
		r.seed = int(length * 100)
		var n := maxi(int(length / 0.7), 1)
		for i in n:
			var c := Vector3(-length * 0.5 + (i + 0.5) * length / n, 0.72, 0)
			_clump(g, c, Vector3(0.48, 0.4, 0.38), Vector3(0, 0.6, 0), Vector3(length * 0.5, 0.5, 0.4), r)
		return g.commit())


# ----------------------------------------------------------------------------- building dressing
## Fire escape: one instanced unit per storey (platform, railings, stair down) plus a drop ladder.
func fire_escape(chunk: CityChunk, f: Dictionary, offset: float, width: float, gh: float, floors: int) -> void:
	var unit := _cached("fe%d" % int(width), func(): return _fire_escape_unit(width, false))
	var bottom := _cached("feb%d" % int(width), func(): return _fire_escape_unit(width, true))
	var b: Basis = f.basis
	for k in floors:
		var y := gh + k * BuildingGenerator.FLOOR_H + 0.05
		var p: Vector3 = f.left + f.right * (offset + width * 0.5) + Vector3.UP * y
		chunk.add_instance(bottom if k == 0 else unit, Transform3D(b, p), Color(), "detail", true)


func _fire_escape_unit(w: float, bottom: bool) -> Mesh:
	var g := GeoBatch.new()
	g.set_material(mats.iron)
	var d := 1.3
	var hw := w * 0.5
	# grating platform
	g.add_box(Transform3D(Basis(), Vector3(0, 0, d * 0.5)), Vector3(w, 0.04, d), 0)
	for x in range(0, int(w / 0.12)):
		g.add_box(Transform3D(Basis(), Vector3(-hw + 0.06 + x * 0.12, -0.03, d * 0.5)), Vector3(0.012, 0.03, d), 0)
	# rails
	for y in [0.5, 1.0]:
		g.add_tube(Vector3(-hw, y, d), Vector3(hw, y, d), 0.016, 0.016, 4)
		g.add_tube(Vector3(-hw, y, 0.05), Vector3(-hw, y, d), 0.016, 0.016, 4)
		g.add_tube(Vector3(hw, y, 0.05), Vector3(hw, y, d), 0.016, 0.016, 4)
	var nb := int(w / 0.3)
	for i in nb + 1:
		var x := -hw + i * w / nb
		g.add_tube(Vector3(x, 0, d), Vector3(x, 1.0, d), 0.009, 0.009, 4)
	for i in 4:
		var z := 0.1 + i * (d - 0.1) / 3.0
		g.add_tube(Vector3(-hw, 0, z), Vector3(-hw, 1.0, z), 0.009, 0.009, 4)
		g.add_tube(Vector3(hw, 0, z), Vector3(hw, 1.0, z), 0.009, 0.009, 4)
	# brackets into the wall
	for x in [-hw + 0.3, hw - 0.3]:
		g.add_tube(Vector3(x, -0.7, 0.02), Vector3(x, -0.02, d - 0.1), 0.02, 0.02, 4)
	if bottom:
		# counter-balanced drop ladder
		var lx := hw - 0.5
		for sx in [-0.22, 0.22]:
			g.add_tube(Vector3(lx + sx, 1.0, d - 0.35), Vector3(lx + sx, -2.2, d - 0.35), 0.015, 0.015, 4)
		for i in 10:
			var y := 0.8 - i * 0.3
			g.add_tube(Vector3(lx - 0.22, y, d - 0.35), Vector3(lx + 0.22, y, d - 0.35), 0.01, 0.01, 4)
	else:
		# stair to the platform below
		var z := d - 0.42
		var a := Vector3(-hw + 0.35, 0.0, z)
		var bpt := Vector3(hw - 1.1, -BuildingGenerator.FLOOR_H, z)
		for sz in [-0.3, 0.3]:
			g.add_box(_beam(a + Vector3(0, 0, sz), bpt + Vector3(0, 0, sz)), Vector3(0.03, 0.18, (bpt - a).length()), 0)
			g.add_tube(a + Vector3(0, 0.9, sz), bpt + Vector3(0, 0.9, sz), 0.012, 0.012, 4)
		var steps := 12
		for i in steps:
			var p := a.lerp(bpt, (i + 0.5) / steps)
			g.add_box(Transform3D(Basis(), p), Vector3(0.18, 0.02, 0.62), 0)
	return g.commit()


static func _beam(a: Vector3, b: Vector3) -> Transform3D:
	var z := (b - a).normalized()
	var x := Vector3.UP.cross(z).normalized()
	if x == Vector3.ZERO:
		x = Vector3.RIGHT
	var y := z.cross(x)
	return Transform3D(Basis(x, y, z), (a + b) * 0.5)


## Fabric shop awning (sloped, with valance) spanning `width` metres centred at `offset`.
func awning(chunk: CityChunk, f: Dictionary, offset: float, width: float, y: float, color: String) -> void:
	var g := chunk.detail
	var mat: Material = mats.awning.get(color, mats.awning["green"])
	g.set_material(mat)
	var c: Vector3 = f.left + f.right * offset + Vector3.UP * y
	var r: Vector3 = f.right * (width * 0.5)
	var n: Vector3 = f.n
	var proj := 1.3
	var drop := 0.65
	var top_l := c - r + Vector3.UP * 0.75
	var top_r := c + r + Vector3.UP * 0.75
	var front_l := c - r + n * proj + Vector3.UP * (0.75 - drop)
	var front_r := c + r + n * proj + Vector3.UP * (0.75 - drop)
	g.add_quad(front_l, front_r, top_r, top_l, Vector2(0, 1), Vector2(width, 1), Vector2(width, 0), Vector2(0, 0))
	var val := Vector3.UP * 0.28
	g.add_quad(front_l - val, front_r - val, front_r, front_l, Vector2(0, 1), Vector2(width, 1), Vector2(width, 0), Vector2(0, 0))
	g.add_tri(c - r + Vector3.UP * 0.75, c - r + n * proj + Vector3.UP * (0.75 - drop), c - r + Vector3.UP * (0.75 - drop) + n * 0.02,
		Vector2(0, 0), Vector2(1, 1), Vector2(0, 1))
	g.add_tri(c + r + Vector3.UP * 0.75, c + r + Vector3.UP * (0.75 - drop) + n * 0.02, c + r + n * proj + Vector3.UP * (0.75 - drop),
		Vector2(0, 0), Vector2(0, 1), Vector2(1, 1))
	g.set_material(mats.iron)
	g.add_tube(front_l, front_r, 0.015, 0.015, 4)


func wall_sign(chunk: CityChunk, f: Dictionary, offset: float, y: float, w: float, h: float, file: String, depth := 0.12) -> void:
	var g := chunk.detail
	var c: Vector3 = f.left + f.right * offset + Vector3.UP * y + f.n * (0.06 + depth * 0.5)
	if depth > 0.0:
		g.set_material(mats.metal_dark)
		g.add_box(Transform3D(f.basis, c), Vector3(w + 0.08, h + 0.08, depth), 0)
	var fc: Vector3 = c + f.n * (depth * 0.5 + 0.005)
	var r: Vector3 = f.right * (w * 0.5)
	var u := Vector3.UP * (h * 0.5)
	g.set_material(mats.sign_material(file, 0.5 if depth > 0.0 else 0.0, depth <= 0.0))
	g.add_quad(fc - r - u, fc + r - u, fc + r + u, fc - r + u, Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0))


## Sign perpendicular to the facade (blade / banner), double sided.
func blade_sign(chunk: CityChunk, f: Dictionary, offset: float, y: float, file: String, size: Vector2) -> void:
	var g := chunk.detail
	var base: Vector3 = f.left + f.right * offset + Vector3.UP * y
	var out: Vector3 = f.n
	var c := base + out * (0.25 + size.x * 0.5) + Vector3.UP * (size.y * 0.5)
	g.set_material(mats.metal_dark)
	g.add_tube(base + Vector3.UP * (size.y + 0.05), base + out * (size.x + 0.35) + Vector3.UP * (size.y + 0.05), 0.02, 0.02, 4)
	g.add_box(Transform3D(f.basis, c), Vector3(0.05, size.y + 0.04, size.x + 0.04), 0)
	var mat := mats.sign_material(file, 0.7)
	g.set_material(mat)
	var hx := out * (size.x * 0.5)
	var hy := Vector3.UP * (size.y * 0.5)
	var side: Vector3 = f.right * 0.03
	g.add_quad(c - hx - hy - side, c + hx - hy - side, c + hx + hy - side, c - hx + hy - side, Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0))
	g.add_quad(c + hx - hy + side, c - hx - hy + side, c - hx + hy + side, c + hx + hy + side, Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0))


func water_tank(chunk: CityChunk, p: Vector3) -> void:
	var g := chunk.always
	g.set_material(mats.steel)
	for a in 4:
		var d := Vector3(cos(a * PI * 0.5 + 0.78), 0, sin(a * PI * 0.5 + 0.78)) * 1.4
		g.add_tube(p + d, p + d * 0.95 + Vector3(0, 2.6, 0), 0.08, 0.08, 5)
	g.add_cylinder(p + Vector3(0, 2.5, 0), 1.9, 1.9, 0.12, 12)
	g.set_material(mats.water_tank)
	g.add_cylinder(p + Vector3(0, 2.6, 0), 1.7, 1.75, 3.8, 12, false)
	g.set_material(mats.metal_dark)
	g.add_cylinder(p + Vector3(0, 6.4, 0), 1.85, 0.05, 1.2, 12, false)
	chunk.shadow.set_material(mats.shadow_only)
	chunk.shadow.add_cylinder(p + Vector3(0, 2.6, 0), 1.7, 1.7, 4.8, 8)
