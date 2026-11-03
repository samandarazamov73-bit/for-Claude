extends RefCounted
## Город вдоль маршрута: дорога, тротуары, разметка, дома, деревья, фонари, остановки, парк, рынок,
## светофор и больница. Всё собирается кодом (заглушки): потом можно заменить моделями.

const C = preload("res://intro/cfg.gd")
const MeshKit = preload("res://intro/meshkit.gd")
const Tex = preload("res://intro/textures.gd")
const Story = preload("res://intro/story.gd")

var route
var root: Node3D
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var cross_s: float = 0.0              # центр перекрёстка со светофором
var light_state: String = "green"
var hospital_xf: Transform3D = Transform3D.IDENTITY
var shelters: Dictionary = {}

var _m_vc: StandardMaterial3D
var _m_asphalt: StandardMaterial3D
var _m_paving: StandardMaterial3D
var _m_grass: StandardMaterial3D
var _m_glass: StandardMaterial3D
var _m_facade: Array = []
var _m_hospital: StandardMaterial3D
var _light_lamps: Dictionary = {}
var _tree_meshes: Dictionary = {}


func build(parent: Node3D, rt) -> void:
	route = rt
	rng.seed = 42
	root = Node3D.new()
	root.name = "City"
	parent.add_child(root)
	var light: Dictionary = route.by_id["light"]
	cross_s = float(light["stop_line"]) + 9.0
	_make_materials()
	_build_ground()
	_build_road()
	_build_cross_street()
	_build_buildings()
	_build_trees_and_lamps()
	_build_stops()
	_build_park()
	_build_market()
	_build_traffic_light()
	_build_hospital()


# --- Материалы ----------------------------------------------------------------

func _std(tex: Texture2D, vcol: bool, rough: float) -> StandardMaterial3D:
	var m: StandardMaterial3D = StandardMaterial3D.new()
	if tex != null:
		m.albedo_texture = tex
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m.vertex_color_use_as_albedo = vcol
	m.vertex_color_is_srgb = vcol
	m.roughness = rough
	return m


func _make_materials() -> void:
	_m_vc = _std(null, true, 0.85)
	_m_asphalt = _std(Tex.asphalt(), true, 0.95)
	_m_paving = _std(Tex.paving(), true, 0.9)
	_m_grass = _std(Tex.grass(), true, 1.0)
	_m_facade = [_std(Tex.facade(0), true, 0.85), _std(Tex.facade(1), true, 0.85)]
	_m_hospital = _std(Tex.facade(9), true, 0.75)
	_m_glass = StandardMaterial3D.new()
	_m_glass.albedo_color = Color(0.62, 0.77, 0.85, 0.35)
	_m_glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_m_glass.cull_mode = BaseMaterial3D.CULL_DISABLED
	_m_glass.roughness = 0.05


func _label(text: String, size: int, pix: float, color: Color) -> Label3D:
	var lab: Label3D = Label3D.new()
	lab.text = text
	lab.font_size = size
	lab.pixel_size = pix
	lab.modulate = color
	lab.outline_size = 0
	lab.shaded = false
	return lab


func _mesh_node(kit: Object, mat: Material, cast: bool = true, far: float = 0.0) -> MeshInstance3D:
	var mi: MeshInstance3D = kit.build(mat, cast)
	if far > 0.0:
		mi.visibility_range_end = far
	return mi


# --- Лента вдоль маршрута -------------------------------------------------------

func _at(q: Dictionary, lat: float, y: float) -> Vector3:
	return Vector3(float(q["x"]) + float(q["rx"]) * lat, y, float(q["z"]) + float(q["rz"]) * lat)


## Поверхность, протянутая вдоль маршрута. profile — точки сечения [смещение вправо, высота], слева направо.
func _ribbon(kit: Object, s0: float, s1: float, profile: Array, color: Color,
		step: float = 2.0, u_scale: float = 6.0, v_scale: float = 6.0, u_from_lateral: bool = true) -> void:
	var rows: int = maxi(2, int(ceil((s1 - s0) / step)) + 1)
	var cum: Array = [0.0]
	for j in range(1, profile.size()):
		var dl0: float = float(profile[j][0]) - float(profile[j - 1][0])
		var dy0: float = float(profile[j][1]) - float(profile[j - 1][1])
		cum.append(float(cum[j - 1]) + Vector2(dl0, dy0).length())
	for i in rows - 1:
		var sa: float = s0 + (s1 - s0) * float(i) / float(rows - 1)
		var sb: float = s0 + (s1 - s0) * float(i + 1) / float(rows - 1)
		var qa: Dictionary = route.sample(sa)
		var qb: Dictionary = route.sample(sb)
		var qm: Dictionary = route.sample((sa + sb) / 2.0)
		for j in profile.size() - 1:
			var l0: float = float(profile[j][0])
			var y0: float = float(profile[j][1])
			var l1: float = float(profile[j + 1][0])
			var y1: float = float(profile[j + 1][1])
			var n_lat: float = -(y1 - y0)
			var n_y: float = l1 - l0
			var nrm: Vector3 = Vector3(float(qm["rx"]) * n_lat, n_y, float(qm["rz"]) * n_lat).normalized()
			var u0: float = (l0 if u_from_lateral else float(cum[j])) / u_scale
			var u1: float = (l1 if u_from_lateral else float(cum[j + 1])) / u_scale
			kit.add_quad(_at(qa, l0, y0), _at(qa, l1, y1), _at(qb, l1, y1), _at(qb, l0, y0), nrm, color,
				Vector2(u0, sa / v_scale), Vector2(u1, sa / v_scale), Vector2(u1, sb / v_scale), Vector2(u0, sb / v_scale))


## Плоский прямоугольник на земле: origin + dir*d + perp*l (для поперечной улицы).
func _flat(kit: Object, origin: Vector3, dir: Vector3, perp: Vector3, d0: float, d1: float, l0: float, l1: float,
		y: float, color: Color, tile: float = 6.0) -> void:
	var up: Vector3 = Vector3(0, y, 0)
	kit.add_quad(origin + dir * d0 + perp * l0 + up, origin + dir * d0 + perp * l1 + up,
		origin + dir * d1 + perp * l1 + up, origin + dir * d1 + perp * l0 + up, Vector3.UP, color,
		Vector2(l0 / tile, d0 / tile), Vector2(l1 / tile, d0 / tile), Vector2(l1 / tile, d1 / tile), Vector2(l0 / tile, d1 / tile))


func _wall_v(kit: Object, origin: Vector3, dir: Vector3, perp: Vector3, d0: float, d1: float, l: float,
		y0: float, y1: float, normal: Vector3, color: Color) -> void:
	kit.add_quad(origin + dir * d0 + perp * l + Vector3(0, y0, 0), origin + dir * d1 + perp * l + Vector3(0, y0, 0),
		origin + dir * d1 + perp * l + Vector3(0, y1, 0), origin + dir * d0 + perp * l + Vector3(0, y1, 0), normal, color)


func _build_ground() -> void:
	var pm: PlaneMesh = PlaneMesh.new()
	pm.size = Vector2(9000, 9000)
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = pm
	var gm: StandardMaterial3D = _std(Tex.grass(), false, 1.0)
	gm.uv1_scale = Vector3(1800, 1800, 1)
	mi.material_override = gm
	mi.position = Vector3(0, -0.05, 0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)


func _sidewalk_spans(from_s: float, to_s: float) -> Array:
	return [[from_s, cross_s - 6.0], [cross_s + 6.0, to_s]]


func _build_road() -> void:
	var rd: Object = MeshKit.new()
	var pv: Object = MeshKit.new()
	var cb: Object = MeshKit.new()
	var mk: Object = MeshKit.new()
	var end_s: float = float(route.length) + 300.0
	var half: float = C.ROAD_HALF
	var out: float = C.SIDE_OUT
	var h: float = C.CURB
	var concrete: Color = Color(0.64, 0.65, 0.66)
	var white: Color = Color(0.95, 0.95, 0.93)
	_ribbon(rd, -200.0, end_s, [[-half, 0.0], [half, 0.0]], Color.WHITE, 2.0, 6.0, 6.0)
	for sp in _sidewalk_spans(-200.0, end_s):
		var a: float = float(sp[0])
		var z: float = float(sp[1])
		_ribbon(pv, a, z, [[half, h], [out, h]], Color.WHITE, 3.0, 1.2, 1.2)
		_ribbon(pv, a, z, [[-out, h], [-half, h]], Color.WHITE, 3.0, 1.2, 1.2)
		_ribbon(cb, a, z, [[half, 0.0], [half, h]], concrete, 3.0, 1.0, 1.0, false)
		_ribbon(cb, a, z, [[-half, h], [-half, 0.0]], concrete, 3.0, 1.0, 1.0, false)
		_ribbon(cb, a, z, [[out, h], [out, -0.05]], concrete, 3.0, 1.0, 1.0, false)
		_ribbon(cb, a, z, [[-out, -0.05], [-out, h]], concrete, 3.0, 1.0, 1.0, false)
		# Разметка: двойная сплошная по оси и прерывистые между полосами.
		var m0: float = a + 4.0
		var m1: float = z - 4.0
		if m1 > m0:
			_ribbon(mk, m0, m1, [[-0.22, 0.02], [-0.1, 0.02]], white, 3.0)
			_ribbon(mk, m0, m1, [[0.1, 0.02], [0.22, 0.02]], white, 3.0)
			var s: float = m0
			while s < m1 - 3.0:
				for lat in [-3.5, 3.5]:
					_ribbon(mk, s, s + 3.0, [[float(lat) - 0.075, 0.02], [float(lat) + 0.075, 0.02]], white, 3.0)
				s += 9.0
	# Стоп-линия и «зебра» перед светофором.
	var sl: float = float(route.by_id["light"]["stop_line"])
	_ribbon(mk, sl - 0.4, sl, [[0.2, 0.02], [half - 0.2, 0.02]], white, 0.4)
	var lat2: float = -6.4
	while lat2 < 6.5:
		_ribbon(mk, sl + 1.0, sl + 4.5, [[lat2, 0.02], [lat2 + 0.6, 0.02]], white, 3.5)
		lat2 += 1.2
	root.add_child(_mesh_node(rd, _m_asphalt, false))
	root.add_child(_mesh_node(pv, _m_paving, false))
	root.add_child(_mesh_node(cb, _m_vc, false))
	root.add_child(_mesh_node(mk, _m_vc, false))


# Поперечная улица на перекрёстке со светофором.
func _build_cross_street() -> void:
	var rd: Object = MeshKit.new()
	var pv: Object = MeshKit.new()
	var cb: Object = MeshKit.new()
	var mk: Object = MeshKit.new()
	var q: Dictionary = route.sample(cross_s)
	var fwd: Vector3 = Vector3(float(q["dx"]), 0, float(q["dz"]))
	var right: Vector3 = Vector3(float(q["rx"]), 0, float(q["rz"]))
	var concrete: Color = Color(0.64, 0.65, 0.66)
	var h: float = C.CURB
	var inner: float = C.SIDE_OUT - C.ROAD_HALF
	var length: float = 120.0
	for side in [1.0, -1.0]:
		var origin: Vector3 = route.point(cross_s, float(side) * C.ROAD_HALF, 0.0)
		var dir: Vector3 = right * float(side)
		_flat(rd, origin, dir, fwd, 0.0, length, -5.5, 5.5, 0.0, Color.WHITE)
		_flat(pv, origin, dir, fwd, inner, length, 5.5, 9.0, h, Color.WHITE, 1.2)
		_flat(pv, origin, dir, fwd, inner, length, -9.0, -5.5, h, Color.WHITE, 1.2)
		_wall_v(cb, origin, dir, fwd, inner, length, 5.5, 0.0, h, -fwd, concrete)
		_wall_v(cb, origin, dir, fwd, inner, length, -5.5, 0.0, h, fwd, concrete)
		_flat(mk, origin, dir, fwd, 1.0, length, -0.08, 0.08, 0.02, Color(0.95, 0.95, 0.93))
	root.add_child(_mesh_node(rd, _m_asphalt, false))
	root.add_child(_mesh_node(pv, _m_paving, false))
	root.add_child(_mesh_node(cb, _m_vc, false))
	root.add_child(_mesh_node(mk, _m_vc, false))


# --- Дома ----------------------------------------------------------------------

## Где нельзя ставить дома/деревья.
func _blocked(s: float, side: float, kind: String = "building") -> bool:
	for t in route.turns:
		if s > float(t["s0"]) - 16.0 and s < float(t["s1"]) + 16.0:
			return true
	if absf(s - cross_s) < 15.0:
		return true
	if side > 0.0:
		var hs: float = float(route.by_id["hospital"]["s"])
		var ps: float = float(route.by_id["park"]["s"])
		var ms: float = float(route.by_id["market"]["s"])
		if s > hs - 70.0 and s < hs + 75.0:
			return true
		if kind == "building" and s > ps - 75.0 and s < ps + 65.0:
			return true
		if kind == "building" and absf(s - ms) < 28.0:
			return true
		if kind != "building" and (absf(s - ps) < 9.0 or absf(s - ms) < 9.0 or absf(s - hs) < 9.0):
			return true
	return false


## Дом: 4 стены с окнами (текстура «пролёт 3×3 м»), крыша, цоколь. center — центр основания.
func _add_building(walls: Object, misc: Object, center: Vector3, yaw: float, wx: float, h: float, wz: float, color: Color) -> void:
	var bs: Basis = Basis(Vector3.UP, yaw)
	var hx: float = wx / 2.0
	var hz: float = wz / 2.0
	var bay: float = 3.0
	var hv: float = h / bay
	# [нормаль, нижний-левый, нижний-правый, ширина]
	var faces: Array = [
		[Vector3(0, 0, 1), Vector3(-hx, 0, hz), Vector3(hx, 0, hz), wx],
		[Vector3(0, 0, -1), Vector3(hx, 0, -hz), Vector3(-hx, 0, -hz), wx],
		[Vector3(1, 0, 0), Vector3(hx, 0, hz), Vector3(hx, 0, -hz), wz],
		[Vector3(-1, 0, 0), Vector3(-hx, 0, -hz), Vector3(-hx, 0, hz), wz],
	]
	var up: Vector3 = Vector3(0, h, 0)
	for f in faces:
		var bl: Vector3 = center + bs * (f[1] as Vector3)
		var br: Vector3 = center + bs * (f[2] as Vector3)
		var wu: float = float(f[3]) / bay
		walls.add_quad(bl, br, br + up, bl + up, bs * (f[0] as Vector3), color,
			Vector2(0, hv), Vector2(wu, hv), Vector2(wu, 0), Vector2(0, 0))
	var roof_c: Color = Color(0.42, 0.43, 0.45)
	misc.add_quad(center + bs * Vector3(-hx, h, hz), center + bs * Vector3(hx, h, hz),
		center + bs * Vector3(hx, h, -hz), center + bs * Vector3(-hx, h, -hz), Vector3.UP, roof_c)
	misc.add_box(center + Vector3(0, 0.3, 0), Vector3(wx + 0.4, 0.6, wz + 0.4), Color(0.6, 0.61, 0.62), Vector3(0, yaw, 0))


func _build_buildings() -> void:
	var palette: Array = [Color("e8d8b8"), Color("e9c9bb"), Color("efe2a6"), Color("d9dcde"), Color("bfd5e2"),
		Color("c9876a"), Color("f4f1ea"), Color("d6c6e0"), Color("c8dcc0")]
	var awnings: Array = [Color("c0392b"), Color("2e86c1"), Color("27ae60"), Color("f39c12"), Color("8e44ad")]
	var plots: Array = []
	for side in [1.0, -1.0]:
		var s: float = -180.0
		while s < float(route.length) + 260.0:
			var w: float = rng.randf_range(14.0, 28.0)
			if not _blocked(s, side) and not _blocked(s + w, side) and not _blocked(s + w / 2.0, side):
				plots.append({"side": side, "s": s, "w": w})
			s += w + rng.randf_range(1.0, 5.0)
	plots.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["s"]) < float(b["s"]))

	var chunk_end: float = -9999.0
	var walls: Array = []
	var misc: Object = null
	for p in plots:
		if float(p["s"]) > chunk_end:
			_flush_buildings(walls, misc)
			walls = [MeshKit.new(), MeshKit.new()]
			misc = MeshKit.new()
			chunk_end = float(p["s"]) + 130.0
		var side: float = float(p["side"])
		var w: float = float(p["w"])
		var depth: float = rng.randf_range(12.0, 18.0)
		var floors: int = rng.randi_range(3, 9)
		var h: float = float(floors) * 3.0 + 0.6
		var setback: float = C.SIDE_OUT + 1.2 + rng.randf_range(0.0, 1.6)
		var mid: float = float(p["s"]) + w / 2.0
		var q: Dictionary = route.sample(mid)
		var lat: float = side * (setback + depth / 2.0)
		var center: Vector3 = Vector3(float(q["x"]) + float(q["rx"]) * lat, 0.0, float(q["z"]) + float(q["rz"]) * lat)
		var yaw: float = route.yaw(mid)
		var color: Color = palette[rng.randi_range(0, palette.size() - 1)]
		_add_building(walls[rng.randi_range(0, 1)], misc, center, yaw, depth, h, w, color)
		if rng.randf() < 0.45:
			var toward: float = -side * (depth / 2.0 + 0.7)
			var ac: Vector3 = Vector3(center.x + float(q["rx"]) * toward, 3.1, center.z + float(q["rz"]) * toward)
			misc.add_box(ac, Vector3(1.4, 0.15, w * 0.8), awnings[rng.randi_range(0, awnings.size() - 1)], Vector3(0, yaw, 0))
	_flush_buildings(walls, misc)


func _flush_buildings(walls: Array, misc: Object) -> void:
	if misc == null:
		return
	for i in walls.size():
		if not (walls[i] as Object).is_empty():
			root.add_child(_mesh_node(walls[i], _m_facade[i], true, 520.0))
	if not misc.is_empty():
		root.add_child(_mesh_node(misc, _m_vc, true, 520.0))


# --- Деревья и фонари -------------------------------------------------------------

func _cells(items: Array, key_pos: String) -> Array:
	var cells: Dictionary = {}
	for it in items:
		var p: Vector3 = it[key_pos] if it is Dictionary else (it as Vector3)
		var key: String = str(int(floor(p.x / 200.0))) + "," + str(int(floor(p.z / 200.0)))
		if not cells.has(key):
			cells[key] = []
		(cells[key] as Array).append(it)
	return cells.values()


func _tree_mesh(part: String) -> ArrayMesh:
	if not _tree_meshes.has(part):
		var kit: Object = MeshKit.new()
		if part == "trunk":
			kit.add_cyl(Vector3(0, 1.5, 0), 0.2, 0.14, 3.0, Color(0.42, 0.29, 0.18), Vector3.ZERO, 7)
		else:
			kit.add_sphere(Vector3(0, 4.1, 0), 1.9, Color.WHITE, Vector3(1, 1, 1), 7)
		_tree_meshes[part] = kit.build_mesh()
	return _tree_meshes[part]


## Деревья — инстансами: тысячи штук почти бесплатно. points: массив Vector3 (основание ствола).
func add_trees(points: Array, parent: Node3D) -> void:
	if points.is_empty():
		return
	var greens: Array = [Color("4f7f35"), Color("5b8f3c"), Color("3f6e2c"), Color("6a9a45"), Color("557d2f")]
	for cell in _cells(points, ""):
		var trunks: MultiMesh = MultiMesh.new()
		trunks.transform_format = MultiMesh.TRANSFORM_3D
		trunks.mesh = _tree_mesh("trunk")
		trunks.instance_count = (cell as Array).size()
		var crowns: MultiMesh = MultiMesh.new()
		crowns.transform_format = MultiMesh.TRANSFORM_3D
		crowns.use_colors = true
		crowns.mesh = _tree_mesh("crown")
		crowns.instance_count = (cell as Array).size()
		for i in (cell as Array).size():
			var p: Vector3 = cell[i]
			var sc: float = rng.randf_range(0.8, 1.25)
			var basis: Basis = Basis(Vector3.UP, rng.randf() * TAU) * Basis.from_scale(Vector3(sc, sc * rng.randf_range(0.9, 1.15), sc))
			var xf: Transform3D = Transform3D(basis, p)
			trunks.set_instance_transform(i, xf)
			crowns.set_instance_transform(i, xf)
			crowns.set_instance_color(i, greens[rng.randi_range(0, greens.size() - 1)])
		for mm in [trunks, crowns]:
			var inst: MultiMeshInstance3D = MultiMeshInstance3D.new()
			inst.multimesh = mm
			inst.material_override = _m_vc
			inst.visibility_range_end = 450.0
			parent.add_child(inst)


func add_lamps(list: Array, parent: Node3D) -> void:
	if list.is_empty():
		return
	var kit: Object = MeshKit.new()
	var metal: Color = Color(0.2, 0.22, 0.24)
	kit.add_cyl(Vector3(0, 3.5, 0), 0.1, 0.07, 7.0, metal, Vector3.ZERO, 8)
	kit.add_box(Vector3(0, 6.9, -0.75), Vector3(0.08, 0.08, 1.6), metal)
	kit.add_box(Vector3(0, 6.85, -1.5), Vector3(0.35, 0.14, 0.6), metal)
	var mesh: ArrayMesh = kit.build_mesh()
	for cell in _cells(list, "pos"):
		var mm: MultiMesh = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = (cell as Array).size()
		for i in (cell as Array).size():
			var l: Dictionary = cell[i]
			mm.set_instance_transform(i, Transform3D(Basis(Vector3.UP, float(l["yaw"])), l["pos"]))
		var inst: MultiMeshInstance3D = MultiMeshInstance3D.new()
		inst.multimesh = mm
		inst.material_override = _m_vc
		inst.visibility_range_end = 400.0
		parent.add_child(inst)


func _build_trees_and_lamps() -> void:
	var trees: Array = []
	for side in [1.0, -1.0]:
		var s: float = -150.0
		while s < float(route.length) + 250.0:
			if not _blocked(s, side, "tree"):
				trees.append(route.point(s, side * (C.SIDE_OUT - 0.9), C.CURB))
			s += rng.randf_range(10.0, 16.0)
	add_trees(trees, root)
	var lamps: Array = []
	var i: int = 0
	var ls: float = -150.0
	while ls < float(route.length) + 250.0:
		var side2: float = 1.0 if i % 2 == 1 else -1.0
		if not _blocked(ls, side2, "lamp"):
			lamps.append({"pos": route.point(ls, side2 * (C.ROAD_HALF + 0.45), 0.0),
				"yaw": route.yaw(ls) + (PI / 2.0 if side2 > 0.0 else -PI / 2.0)})
		ls += 30.0
		i += 1
	add_lamps(lamps, root)


# --- Остановки, парк, рынок ----------------------------------------------------------

func _make_shelter(stop_name: String) -> Node3D:
	var g: Node3D = Node3D.new()
	var kit: Object = MeshKit.new()
	var gl: Object = MeshKit.new()
	var dark: Color = Color(0.2, 0.22, 0.24)
	var wood: Color = Color(0.54, 0.35, 0.21)
	kit.add_box(Vector3(0, 2.55, 0), Vector3(1.7, 0.08, 4.6), dark)
	for z in [-2.2, 2.2]:
		for x in [-0.75, 0.75]:
			kit.add_cyl(Vector3(x, 1.27, z), 0.04, 0.04, 2.5, Color(0.5, 0.53, 0.56), Vector3.ZERO, 6)
	kit.add_box(Vector3(0.35, 0.5, 0), Vector3(0.45, 0.06, 3.2), wood)
	kit.add_box(Vector3(0.58, 0.75, 0), Vector3(0.06, 0.45, 3.2), wood)
	kit.add_cyl(Vector3(-1.05, 1.4, -3.2), 0.04, 0.04, 2.8, Color(0.5, 0.53, 0.56), Vector3.ZERO, 6)
	kit.add_box(Vector3(-1.05, 2.6, -3.2), Vector3(0.05, 0.5, 0.5), Color(0.18, 0.49, 0.2))
	gl.add_quad(Vector3(0.8, 0.2, -2.2), Vector3(0.8, 0.2, 2.2), Vector3(0.8, 2.4, 2.2), Vector3(0.8, 2.4, -2.2), Vector3(-1, 0, 0), Color.WHITE)
	g.add_child(_mesh_node(kit, _m_vc))
	g.add_child(_mesh_node(gl, _m_glass, false))
	var sign_lab: Label3D = _label(stop_name, 36, 0.003, Color(0.12, 0.37, 0.66))
	sign_lab.position = Vector3(-0.88, 2.3, -1.6)
	sign_lab.rotation = Vector3(0, -PI / 2.0, 0)
	g.add_child(sign_lab)
	return g


func _build_stops() -> void:
	for id in ["park", "market", "hospital"]:
		var ev: Dictionary = route.by_id[id]
		var sh: Node3D = _make_shelter(Story.STOPS[id])
		# У больницы павильон сдвинут вперёд: место у средней двери нужно коляске.
		var at: float = float(ev["s"]) + 6.0 if id == "hospital" else float(ev["s"]) - 0.5
		sh.position = route.point(at, C.ROAD_HALF + 2.6, C.CURB)
		sh.rotation.y = route.yaw(at)
		root.add_child(sh)
		shelters[id] = sh


func _build_park() -> void:
	var s0: float = float(route.by_id["park"]["s"])
	var kit: Object = MeshKit.new()
	var trees: Array = []
	var pond_c: Vector3 = route.point(s0 - 10.0, 34.0, 0.0)
	for i in 46:
		var p: Vector3 = route.point(s0 + rng.randf_range(-70.0, 62.0), rng.randf_range(C.SIDE_OUT + 2.0, 60.0), 0.0)
		if p.distance_to(pond_c) > 13.0:
			trees.append(p)
	add_trees(trees, root)
	var pond: MeshInstance3D = MeshInstance3D.new()
	var cm: CylinderMesh = CylinderMesh.new()
	cm.top_radius = 10.0
	cm.bottom_radius = 10.0
	cm.height = 0.02
	cm.radial_segments = 28
	pond.mesh = cm
	var pm: StandardMaterial3D = StandardMaterial3D.new()
	pm.albedo_color = Color(0.31, 0.53, 0.66)
	pm.roughness = 0.1
	pm.metallic = 0.2
	pond.material_override = pm
	pond.position = Vector3(pond_c.x, 0.02, pond_c.z)
	pond.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(pond)
	for i in 5:   # утки :)
		var a: float = rng.randf() * TAU
		var d: float = rng.randf_range(2.0, 7.0)
		kit.add_box(Vector3(pond_c.x + cos(a) * d, 0.12, pond_c.z + sin(a) * d), Vector3(0.35, 0.22, 0.2),
			Color(0.77, 0.42, 0.17) if i == 2 else Color(0.96, 0.96, 0.94), Vector3(0, a, 0))
	# Низкая ограда вдоль тротуара с проходом у остановки и скамейки.
	var s: float = s0 - 72.0
	while s < s0 + 64.0:
		if absf(s - s0) >= 5.0:
			var p2: Vector3 = route.point(s, C.SIDE_OUT + 0.3, 0.0)
			kit.add_box(Vector3(p2.x, 0.55, p2.z), Vector3(0.06, 0.8, 2.5), Color(0.2, 0.22, 0.24), Vector3(0, route.yaw(s), 0))
		s += 2.5
	for ds in [-30.0, -12.0, 20.0, 40.0]:
		var p3: Vector3 = route.point(s0 + float(ds), C.SIDE_OUT + 3.0, 0.0)
		kit.add_box(Vector3(p3.x, 0.45, p3.z), Vector3(0.5, 0.08, 1.8), Color(0.54, 0.35, 0.21), Vector3(0, route.yaw(s0 + float(ds)), 0))
	root.add_child(_mesh_node(kit, _m_vc))


func _build_market() -> void:
	var s0: float = float(route.by_id["market"]["s"])
	var kit: Object = MeshKit.new()
	var awn: Array = [Color("c0392b"), Color("e67e22"), Color("27ae60"), Color("2980b9"), Color("f1c40f")]
	var goods: Array = [Color("d62d20"), Color("ffa700"), Color("7bb661"), Color("ffd700"), Color("7d3c98")]
	for i in 7:
		for row in 2:
			var s: float = s0 - 24.0 + float(i) * 7.0 + float(row) * 3.5
			var p: Vector3 = route.point(s, C.SIDE_OUT + 4.0 + float(row) * 7.0, 0.0)
			var yaw: float = route.yaw(s)
			kit.add_box(Vector3(p.x, 0.45, p.z), Vector3(3.2, 0.9, 2.2), Color(0.54, 0.35, 0.21), Vector3(0, yaw, 0))
			kit.add_box(Vector3(p.x, 2.4, p.z), Vector3(3.6, 0.1, 2.8), awn[rng.randi_range(0, awn.size() - 1)], Vector3(0.12, yaw, 0))
			var bs: Basis = Basis(Vector3.UP, yaw)
			for dx in [-1.6, 1.6]:
				var cp: Vector3 = Vector3(p.x, 0.0, p.z) + bs * Vector3(float(dx), 0.0, 0.0)
				kit.add_cyl(Vector3(cp.x, 1.2, cp.z), 0.04, 0.04, 2.4, Color(0.5, 0.53, 0.56), Vector3.ZERO, 5)
			for k in 6:
				var gp: Vector3 = Vector3(p.x, 1.0, p.z) + bs * Vector3(rng.randf_range(-1.2, 1.2), 0.0, rng.randf_range(-0.6, 0.6))
				kit.add_sphere(gp, 0.16, goods[rng.randi_range(0, goods.size() - 1)], Vector3.ONE, 6)
	root.add_child(_mesh_node(kit, _m_vc))


# --- Светофор ---------------------------------------------------------------------------

func _build_traffic_light() -> void:
	var sl: float = float(route.by_id["light"]["stop_line"])
	_make_light_head(route.point(sl - 1.0, C.ROAD_HALF + 0.6, C.CURB), route.yaw(sl), "main")
	_make_light_head(route.point(cross_s + 9.0, -(C.ROAD_HALF + 0.6), C.CURB), route.yaw(sl) + PI, "far")
	set_light("green")


## Столб с коробкой. Лампы на задней (+Z) грани: к ним подъезжает автобус (едет в сторону −Z).
func _make_light_head(pos: Vector3, yaw: float, tag: String) -> void:
	var g: Node3D = Node3D.new()
	g.position = pos
	g.rotation.y = yaw
	var kit: Object = MeshKit.new()
	var dark: Color = Color(0.2, 0.22, 0.24)
	kit.add_cyl(Vector3(0, 1.7, 0), 0.1, 0.08, 3.4, dark, Vector3.ZERO, 8)
	kit.add_box(Vector3(0, 3.6, 0), Vector3(0.4, 1.1, 0.32), dark)
	g.add_child(_mesh_node(kit, _m_vc))
	var colors: Dictionary = {"red": Color(1.0, 0.16, 0.1), "yellow": Color(1.0, 0.76, 0.1), "green": Color(0.16, 1.0, 0.42)}
	var names: Array = ["red", "yellow", "green"]
	for i in 3:
		var lamp: MeshInstance3D = MeshInstance3D.new()
		var lm: CylinderMesh = CylinderMesh.new()
		lm.top_radius = 0.12
		lm.bottom_radius = 0.12
		lm.height = 0.03
		lm.radial_segments = 14
		lamp.mesh = lm
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		mat.albedo_color = Color(0.1, 0.1, 0.1)
		mat.emission_enabled = true
		mat.emission = colors[names[i]]
		mat.emission_energy_multiplier = 0.0
		lamp.material_override = mat
		lamp.rotation = Vector3(PI / 2.0, 0, 0)
		lamp.position = Vector3(0, 3.95 - float(i) * 0.34, 0.165)
		lamp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		g.add_child(lamp)
		if not _light_lamps.has(names[i]):
			_light_lamps[names[i]] = []
		(_light_lamps[names[i]] as Array).append(mat)
	root.add_child(g)


func set_light(state: String) -> void:
	light_state = state
	for key in _light_lamps:
		for mat in _light_lamps[key]:
			(mat as StandardMaterial3D).emission_energy_multiplier = 2.4 if key == state else 0.0


# --- Больница ---------------------------------------------------------------------------------

## Локальные координаты больницы: x — вправо от оси дороги (бордюр на 7), z — вдоль маршрута (−Z вперёд).
func _build_hospital() -> void:
	var hs: float = float(route.by_id["hospital"]["s"])
	var g: Node3D = Node3D.new()
	g.name = "Hospital"
	g.position = route.point(hs, 0.0, 0.0)
	g.rotation.y = route.yaw(hs)
	hospital_xf = Transform3D(Basis(Vector3.UP, route.yaw(hs)), route.point(hs, 0.0, 0.0))
	root.add_child(g)
	var walls: Object = MeshKit.new()
	var unused: Object = MeshKit.new()
	var misc: Object = MeshKit.new()
	var cy: float = C.CURB
	# Площадь перед больницей.
	var x0: float = C.SIDE_OUT
	var x1: float = 47.2
	misc.add_quad(Vector3(x0, cy + 0.003, -48), Vector3(x1, cy + 0.003, -48), Vector3(x1, cy + 0.003, 48), Vector3(x0, cy + 0.003, 48),
		Vector3.UP, Color(0.72, 0.7, 0.66))
	# Главный корпус и входная группа.
	_add_building(walls, misc, Vector3(57, 0, 0), 0.0, 20.0, 15.6, 80.0, Color(0.95, 0.96, 0.94))
	_add_building(unused, misc, Vector3(45.5, 0, 0), 0.0, 3.0, 5.0, 12.0, Color(0.87, 0.91, 0.95))
	# Площадка у входа, козырёк на колоннах.
	misc.add_box(Vector3(43.5, 0.3, 0), Vector3(7.0, 0.6, 16.0), Color(0.6, 0.61, 0.62))
	misc.add_box(Vector3(43.2, 4.1, 0), Vector3(7.5, 0.3, 14.4), Color(0.95, 0.95, 0.95))
	for z in [-6.9, 6.9]:
		misc.add_cyl(Vector3(40.4, 2.4, z), 0.18, 0.18, 3.6, Color(0.95, 0.95, 0.95), Vector3.ZERO, 10)
	# Красный крест над входом.
	misc.add_box(Vector3(46.85, 12.2, 0), Vector3(0.1, 2.6, 0.7), Color(0.9, 0.22, 0.21))
	misc.add_box(Vector3(46.85, 12.2, 0), Vector3(0.1, 0.7, 2.6), Color(0.9, 0.22, 0.21))
	g.add_child(_mesh_node(walls, _m_hospital))
	g.add_child(_mesh_node(unused, _m_hospital))
	g.add_child(_mesh_node(misc, _m_vc))
	var sign_lab: Label3D = _label(Story.STOPS["hospital"].to_upper(), 90, 0.012, Color(0.12, 0.37, 0.66))
	sign_lab.position = Vector3(46.9, 9.0, 0)
	sign_lab.rotation = Vector3(0, -PI / 2.0, 0)
	g.add_child(sign_lab)
	var info: Label3D = _label("Поликлиника · Приёмный покой", 40, 0.006, Color(0.2, 0.2, 0.2))
	info.position = Vector3(46.9, 6.4, 0)
	info.rotation = Vector3(0, -PI / 2.0, 0)
	g.add_child(info)
	# Деревья, фонари и клумбы на площади.
	var trees: Array = []
	for t in [[14, -30], [14, -42], [14, 30], [34, -32], [36, -42], [16, 8], [16, -4]]:
		trees.append(hospital_xf * Vector3(float(t[0]), cy, float(t[1])))
	add_trees(trees, root)
	var lamps: Array = []
	for l in [[18, -24], [18, 26], [34, -10], [34, 14]]:
		lamps.append({"pos": hospital_xf * Vector3(float(l[0]), 0.0, float(l[1])), "yaw": route.yaw(hs)})
	add_lamps(lamps, root)
