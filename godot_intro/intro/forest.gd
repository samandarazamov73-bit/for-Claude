extends RefCounted
## Лес вдоль дороги: асфальт, обочины, разметка, остановки с «карманами» и бетонными павильонами,
## деревья (сосны, ели, осенние берёзы), тропинка от конечной остановки через лес к санаторию
## и сам санаторий (заглушка — или модель intro/assets/models/sanatorium.glb).

const C = preload("res://intro/cfg.gd")
const MeshKit = preload("res://intro/meshkit.gd")
const Tex = preload("res://intro/textures.gd")
const Story = preload("res://intro/story.gd")

var route
var root: Node3D
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var light_state: String = "green"          # светофора в лесу нет (поле нужно для совместимости)
var shelters: Dictionary = {}
var path_pts: PackedVector3Array = PackedVector3Array()   # тропинка, точка через ~1 м
var path_cum: PackedFloat32Array = PackedFloat32Array()   # длина тропинки до каждой точки
var path_len: float = 0.0
var exit_xf: Transform3D = Transform3D.IDENTITY           # где герой оказывается после выхода из автобуса
var gate_pos: Vector3 = Vector3.ZERO
var building_xf: Transform3D = Transform3D.IDENTITY       # середина фасада санатория на земле, вход смотрит в −Z
var lit_window: OmniLight3D                               # единственное горящее окно (палата деда)
var gate_lamp: OmniLight3D

var _m_vc: StandardMaterial3D
var _m_asphalt: StandardMaterial3D
var _m_gravel: StandardMaterial3D
var _m_path: StandardMaterial3D
var _m_facade: StandardMaterial3D
var _tree_meshes: Dictionary = {}
var _path_min: Vector2 = Vector2.ZERO
var _path_max: Vector2 = Vector2.ZERO


func build(parent: Node3D, rt) -> void:
	route = rt
	rng.seed = 1975
	root = Node3D.new()
	root.name = "Forest"
	parent.add_child(root)
	_make_materials()
	_build_ground()
	_build_road()
	_build_path()
	_build_sanatorium()
	for ev in route.events:
		_build_stop(ev)
	_build_trees()


# --- Материалы и общие помощники -----------------------------------------------------------

func _std(tex: Texture2D, vcol: bool, rough: float, photo: String = "", mesh_tile: float = 0.0) -> StandardMaterial3D:
	var m: StandardMaterial3D = StandardMaterial3D.new()
	if tex != null:
		m.albedo_texture = tex
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m.vertex_color_use_as_albedo = vcol
	m.vertex_color_is_srgb = vcol
	m.roughness = rough
	if photo == "":
		return m
	var maps: Dictionary = Tex.pbr(photo)
	if maps.has("albedo") and mesh_tile > 0.0:
		var k: float = mesh_tile / float(C.TEX_METERS.get(photo, mesh_tile))
		m.uv1_scale = Vector3(k, k, 1.0)
	if maps.has("normal"):
		m.normal_enabled = true
		m.normal_texture = maps["normal"]
	if maps.has("rough"):
		m.roughness = 1.0
		m.roughness_texture = maps["rough"]
	if maps.has("ao"):
		m.ao_enabled = true
		m.ao_texture = maps["ao"]
	return m


func _make_materials() -> void:
	_m_vc = _std(null, true, 0.9)
	_m_asphalt = _std(Tex.asphalt(), true, 0.95, "road", 6.0)
	_m_gravel = _std(Tex.gravel(), true, 1.0, "gravel", 2.0)
	_m_path = _std(Tex.path_dirt(), true, 1.0, "path", 2.0)
	_m_facade = _std(Tex.facade(0), true, 0.85, "facade", 3.0)


func _node(kit: Object, mat: Material, cast: bool = true, far: float = 0.0) -> MeshInstance3D:
	var uses_normal: bool = mat is BaseMaterial3D and (mat as BaseMaterial3D).normal_enabled
	var mi: MeshInstance3D = kit.build(mat, cast, uses_normal)
	if far > 0.0:
		mi.visibility_range_end = far
	return mi


func _label(text: String, size: int, pix: float, color: Color) -> Label3D:
	var lab: Label3D = Label3D.new()
	lab.text = text
	lab.font_size = size
	lab.pixel_size = pix
	lab.modulate = color
	lab.outline_size = 0
	lab.shaded = true
	return lab


func _at(q: Dictionary, lat: float, y: float) -> Vector3:
	return Vector3(float(q["x"]) + float(q["rx"]) * lat, y, float(q["z"]) + float(q["rz"]) * lat)


## Полоса вдоль маршрута: profile — точки сечения [смещение вправо, высота] слева направо.
func _ribbon(kit: Object, s0: float, s1: float, profile: Array, color: Color, step: float = 2.0,
		u_scale: float = 6.0, v_scale: float = 6.0) -> void:
	var rows: int = maxi(2, int(ceil((s1 - s0) / step)) + 1)
	for i in rows - 1:
		var sa: float = s0 + (s1 - s0) * float(i) / float(rows - 1)
		var sb: float = s0 + (s1 - s0) * float(i + 1) / float(rows - 1)
		var qa: Dictionary = route.sample(sa)
		var qb: Dictionary = route.sample(sb)
		for j in profile.size() - 1:
			var l0: float = float(profile[j][0])
			var y0: float = float(profile[j][1])
			var l1: float = float(profile[j + 1][0])
			var y1: float = float(profile[j + 1][1])
			kit.add_quad(_at(qa, l0, y0), _at(qa, l1, y1), _at(qb, l1, y1), _at(qb, l0, y0), Vector3.UP, color,
				Vector2(l0 / u_scale, sa / v_scale), Vector2(l1 / u_scale, sa / v_scale), Vector2(l1 / u_scale, sb / v_scale), Vector2(l0 / u_scale, sb / v_scale))


## Базис «вдоль дороги»: X — вперёд по маршруту, Z — вправо (от дороги), Y — вверх.
func _road_basis(s: float) -> Basis:
	var q: Dictionary = route.sample(s)
	return Basis(Vector3(float(q["dx"]), 0, float(q["dz"])), Vector3.UP, Vector3(float(q["rx"]), 0, float(q["rz"])))


# --- Земля и дорога --------------------------------------------------------------------------

func _build_ground() -> void:
	var pm: PlaneMesh = PlaneMesh.new()
	pm.size = Vector2(9000, 9000)
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = pm
	var gm: StandardMaterial3D = _std(Tex.forest_floor(), false, 1.0, "forest_floor", 0.0)
	var tile: float = float(C.TEX_METERS["forest_floor"])
	gm.uv1_scale = Vector3(9000.0 / tile, 9000.0 / tile, 1)
	mi.material_override = gm
	mi.position = Vector3(0, -0.03, 0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)


func _build_road() -> void:
	var rd: Object = MeshKit.new()
	var gr: Object = MeshKit.new()
	var mk: Object = MeshKit.new()
	var end_s: float = float(route.length) + 200.0
	var half: float = C.ROAD_HALF
	var white: Color = Color(0.9, 0.9, 0.86)
	_ribbon(rd, -200.0, end_s, [[-half, 0.0], [half, 0.0]], Color.WHITE, 2.0, 6.0, 6.0)
	_ribbon(gr, -200.0, end_s, [[-C.SIDE_OUT, -0.02], [-half, -0.004]], Color.WHITE, 3.0, 2.0, 2.0)
	_ribbon(gr, -200.0, end_s, [[half, -0.004], [C.SIDE_OUT, -0.02]], Color.WHITE, 3.0, 2.0, 2.0)
	# «карманы» у остановок
	for ev in route.events:
		var s: float = float(ev["s"])
		_ribbon(rd, s - 30.0, s + 22.0, [[half - 0.05, 0.003], [C.POCKET_OUT, 0.003]], Color.WHITE, 2.0, 6.0, 6.0)
	# разметка: прерывистая по оси (3 м штрих, 9 м пробел), сплошные по краям
	var s2: float = -150.0
	while s2 < end_s - 10.0:
		_ribbon(mk, s2, s2 + 3.0, [[-0.06, 0.012], [0.06, 0.012]], white, 3.0)
		s2 += 12.0
	_ribbon(mk, -150.0, end_s - 10.0, [[-half + 0.12, 0.012], [-half + 0.24, 0.012]], white, 4.0)
	var edge_from: float = -150.0
	for ev in route.events:
		_ribbon(mk, edge_from, float(ev["s"]) - 32.0, [[half - 0.24, 0.012], [half - 0.12, 0.012]], white, 4.0)
		edge_from = float(ev["s"]) + 24.0
	_ribbon(mk, edge_from, end_s - 10.0, [[half - 0.24, 0.012], [half - 0.12, 0.012]], white, 4.0)
	root.add_child(_node(rd, _m_asphalt, false))
	root.add_child(_node(gr, _m_gravel, false))
	root.add_child(_node(mk, _m_vc, false))


# --- Остановки: бетонный павильон с мозаикой, табличка «А» ------------------------------------

func _mosaic_texture(seed_v: int) -> ImageTexture:
	var img: Image = Image.create_empty(128, 64, false, Image.FORMAT_RGBA8)
	var r2: RandomNumberGenerator = RandomNumberGenerator.new()
	r2.seed = seed_v
	var sky: Color = Color(0.18, 0.42, 0.62)
	img.fill(sky)
	for y in 64:                                       # горы, солнце, поле — из квадратиков смальты
		for x in 128:
			var col: Color = sky
			var hill: float = 30.0 + sin(float(x) * 0.09 + float(seed_v)) * 9.0 + sin(float(x) * 0.23) * 4.0
			if Vector2(x - 92, y - 18).length() < 10.0:
				col = Color(0.95, 0.72, 0.2)
			elif float(y) > hill:
				col = Color(0.85, 0.85, 0.88) if float(y) < hill + 4.0 else Color(0.25, 0.45, 0.3)
			if y > 50:
				col = Color(0.8, 0.62, 0.22) if (x / 6 + y / 3) % 2 == 0 else Color(0.7, 0.5, 0.18)
			col = col.lerp(Color(r2.randf(), r2.randf(), r2.randf()), 0.08)
			if x % 4 == 0 or y % 4 == 0:
				col = col.darkened(0.35)                 # швы между плитками
			img.set_pixel(x, y, col)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _build_stop(ev: Dictionary) -> void:
	var id: String = str(ev["id"])
	var s: float = float(ev["s"])
	var conc: Color = Color(0.62, 0.61, 0.58)
	# площадка
	var pl: Object = MeshKit.new()
	_ribbon(pl, s - 12.0, s + 9.0, [[C.POCKET_OUT, 0.006], [C.POCKET_OUT + 4.6, 0.006]], Color(0.66, 0.65, 0.62), 3.0, 1.5, 1.5)
	root.add_child(_node(pl, _m_vc, false))
	# павильон: две стенки, задняя стена с мозаикой, плита крыши, скамья
	var g: Node3D = Node3D.new()
	g.transform = Transform3D(_road_basis(s + 4.5), route.point(s + 4.5, C.POCKET_OUT + 3.2, 0.0))
	var kit: Object = MeshKit.new()
	kit.add_box(Vector3(0, 1.25, 1.05), Vector3(4.2, 2.5, 0.18), conc)
	kit.add_box(Vector3(-2.0, 1.25, 0.3), Vector3(0.18, 2.5, 1.6), conc)
	kit.add_box(Vector3(2.0, 1.25, 0.3), Vector3(0.18, 2.5, 1.6), conc)
	kit.add_box(Vector3(0, 2.6, 0.2), Vector3(4.8, 0.2, 2.2), conc.darkened(0.08))
	kit.add_box(Vector3(0, 0.45, 0.75), Vector3(3.4, 0.08, 0.4), Color(0.45, 0.3, 0.18))
	kit.add_box(Vector3(-1.4, 0.22, 0.75), Vector3(0.12, 0.44, 0.35), conc)
	kit.add_box(Vector3(1.4, 0.22, 0.75), Vector3(0.12, 0.44, 0.35), conc)
	g.add_child(_node(kit, _m_vc))
	var mos: MeshInstance3D = MeshInstance3D.new()
	var qm: QuadMesh = QuadMesh.new()
	qm.size = Vector2(3.6, 1.8)
	mos.mesh = qm
	var mm: StandardMaterial3D = StandardMaterial3D.new()
	mm.albedo_texture = _mosaic_texture(int(s))
	mm.roughness = 0.35
	mm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	mos.material_override = mm
	mos.position = Vector3(0, 1.45, 0.95)
	mos.rotation = Vector3(0, PI, 0)                   # лицом к дороге (−Z)
	g.add_child(mos)
	root.add_child(g)
	shelters[id] = g
	# столб с табличкой
	var sign_s: float = s - 9.0
	var post: Node3D = Node3D.new()
	post.transform = Transform3D(_road_basis(sign_s), route.point(sign_s, C.POCKET_OUT + 0.4, 0.0))
	var pk: Object = MeshKit.new()
	pk.add_cyl(Vector3(0, 1.4, 0), 0.04, 0.04, 2.8, Color(0.35, 0.36, 0.38), Vector3.ZERO, 6)
	pk.add_box(Vector3(0, 2.55, 0), Vector3(0.5, 0.5, 0.03), Color(0.95, 0.83, 0.2))
	pk.add_box(Vector3(0, 2.0, 0), Vector3(1.1, 0.4, 0.03), Color(0.92, 0.92, 0.88))
	post.add_child(_node(pk, _m_vc))
	for side in [-1.0, 1.0]:
		var a: Label3D = _label("А", 64, 0.004, Color(0.1, 0.1, 0.1))
		a.position = Vector3(0, 2.55, side * 0.02)
		a.rotation = Vector3(0, 0.0 if side > 0.0 else PI, 0)
		post.add_child(a)
		var n: Label3D = _label(Story.STOPS.get(id, id), 28, 0.0028, Color(0.12, 0.2, 0.45))
		n.position = Vector3(0, 2.0, side * 0.02)
		n.rotation = Vector3(0, 0.0 if side > 0.0 else PI, 0)
		post.add_child(n)
	root.add_child(post)


# --- Тропинка к санаторию ---------------------------------------------------------------------

func _build_path() -> void:
	var fs: float = float(route.by_id[route.final_id]["s"])
	var exit_s: float = fs - 3.6                       # задняя дверь автобуса
	var start: Vector3 = route.point(exit_s, C.POCKET_OUT + 1.3, 0.0)
	var q: Dictionary = route.sample(exit_s)
	var right: Vector3 = Vector3(float(q["rx"]), 0, float(q["rz"]))
	# герой после выхода: на площадке, лицом к дороге (автобус уедет направо)
	exit_xf = Transform3D(Basis(Vector3.UP, atan2(right.x, right.z)), start)
	# тропинка: сначала прямо от дороги, дальше плавно петляет, но уходит от неё
	var ctrl: Array = [start, start + right * 6.0]
	var heading: float = atan2(right.x, right.z)
	var base: float = heading
	var p: Vector3 = start + right * 6.0
	var steps: int = maxi(3, int(C.PATH_LENGTH / 32.0))
	for i in steps:
		heading = clampf(heading + rng.randf_range(-0.5, 0.5), base - 0.8, base + 0.8)
		p = p + Vector3(sin(heading), 0, cos(heading)) * 32.0
		ctrl.append(p)
	var curve: Curve3D = Curve3D.new()
	for i in ctrl.size():
		var pt: Vector3 = ctrl[i]
		var tin: Vector3 = Vector3.ZERO
		var tout: Vector3 = Vector3.ZERO
		if i > 0 and i < ctrl.size() - 1:
			var t: Vector3 = ((ctrl[i + 1] as Vector3) - (ctrl[i - 1] as Vector3)) * 0.25
			tin = -t
			tout = t
		curve.add_point(pt, tin, tout)
	curve.bake_interval = 1.0
	var baked: PackedVector3Array = curve.get_baked_points()
	path_pts = PackedVector3Array()
	path_cum = PackedFloat32Array()
	var acc: float = 0.0
	for i in baked.size():
		var b: Vector3 = Vector3(baked[i].x, 0.0, baked[i].z)
		if i > 0:
			acc += b.distance_to(path_pts[path_pts.size() - 1])
		path_pts.append(b)
		path_cum.append(acc)
	path_len = acc
	_path_min = Vector2(INF, INF)
	_path_max = Vector2(-INF, -INF)
	for b2 in path_pts:
		_path_min = Vector2(minf(_path_min.x, b2.x), minf(_path_min.y, b2.z))
		_path_max = Vector2(maxf(_path_max.x, b2.x), maxf(_path_max.y, b2.z))
	# лента тропинки с неровными краями
	var kit: Object = MeshKit.new()
	var acc_v: float = 0.0
	for i in path_pts.size() - 1:
		var a: Vector3 = path_pts[i]
		var b3: Vector3 = path_pts[i + 1]
		var d: Vector3 = (b3 - a).normalized()
		var rgt: Vector3 = Vector3(-d.z, 0, d.x)
		var wa: float = 1.05 + sin(float(i) * 0.37) * 0.18
		var wb: float = 1.05 + sin(float(i + 1) * 0.37) * 0.18
		var y: float = 0.006
		var v0: float = acc_v / 2.0
		acc_v += a.distance_to(b3)
		var v1: float = acc_v / 2.0
		kit.add_quad(a - rgt * wa + Vector3(0, y, 0), a + rgt * wa + Vector3(0, y, 0), b3 + rgt * wb + Vector3(0, y, 0), b3 - rgt * wb + Vector3(0, y, 0),
			Vector3.UP, Color.WHITE, Vector2(0, v0), Vector2(1, v0), Vector2(1, v1), Vector2(0, v1))
	root.add_child(_node(kit, _m_path, false))
	# указатель у начала тропинки
	var sign_node: Node3D = Node3D.new()
	var sp: Vector3 = path_at(4.0)
	var sd: Vector3 = path_dir(4.0)
	sign_node.transform = Transform3D(Basis(Vector3.UP, atan2(sd.x, sd.z)), sp + Vector3(-sd.z, 0, sd.x) * -1.8)
	var sk: Object = MeshKit.new()
	sk.add_cyl(Vector3(0, 1.0, 0), 0.06, 0.05, 2.0, Color(0.35, 0.25, 0.16), Vector3.ZERO, 6)
	sk.add_box(Vector3(0, 1.75, 0), Vector3(1.6, 0.36, 0.04), Color(0.2, 0.36, 0.6))
	sign_node.add_child(_node(sk, _m_vc))
	for side in [-1.0, 1.0]:
		var t2: Label3D = _label(Story.PATH_SIGN, 26, 0.0028, Color(0.95, 0.95, 0.92))
		t2.position = Vector3(0, 1.75, side * 0.025)
		t2.rotation = Vector3(0, 0.0 if side > 0.0 else PI, 0)
		sign_node.add_child(t2)
	root.add_child(sign_node)


## Точка тропинки на расстоянии d от остановки.
func path_at(d: float) -> Vector3:
	var dd: float = clampf(d, 0.0, path_len)
	var lo: int = 0
	var hi: int = path_cum.size() - 1
	while hi - lo > 1:
		var mid: int = (lo + hi) / 2
		if path_cum[mid] <= dd:
			lo = mid
		else:
			hi = mid
	var seg: float = maxf(path_cum[hi] - path_cum[lo], 0.0001)
	return path_pts[lo].lerp(path_pts[hi], (dd - path_cum[lo]) / seg)


func path_dir(d: float) -> Vector3:
	return (path_at(d + 1.0) - path_at(d - 1.0)).normalized()


## Ближайшая точка тропинки: {"s": пройдено, "dist": отклонение, "point": Vector3}.
func path_nearest(p: Vector3) -> Dictionary:
	var best_d: float = INF
	var best_s: float = 0.0
	var best_p: Vector3 = path_pts[0]
	var flat: Vector3 = Vector3(p.x, 0, p.z)
	for i in path_pts.size() - 1:
		var a: Vector3 = path_pts[i]
		var ab: Vector3 = path_pts[i + 1] - a
		var l2: float = maxf(ab.length_squared(), 0.0001)
		var t: float = clampf((flat - a).dot(ab) / l2, 0.0, 1.0)
		var c: Vector3 = a + ab * t
		var d: float = flat.distance_squared_to(c)
		if d < best_d:
			best_d = d
			best_p = c
			best_s = path_cum[i] + (path_cum[i + 1] - path_cum[i]) * t
	return {"s": best_s, "dist": sqrt(best_d), "point": best_p}


## Не даёт уехать с тропинки дальше half метров.
func constrain(p: Vector3, half: float) -> Vector3:
	var n: Dictionary = path_nearest(p)
	var c: Vector3 = n["point"]
	if float(n["dist"]) <= half:
		return Vector3(p.x, 0.0, p.z)
	var off: Vector3 = Vector3(p.x, 0, p.z) - c
	return c + off.normalized() * half


func _near_path(x: float, z: float, r: float) -> bool:
	if x < _path_min.x - r or x > _path_max.x + r or z < _path_min.y - r or z > _path_max.y + r:
		return false
	var p: Vector3 = Vector3(x, 0, z)
	for i in range(0, path_pts.size(), 2):
		if p.distance_squared_to(path_pts[i]) < r * r:
			return true
	return false


# --- Санаторий ----------------------------------------------------------------------------------

func _build_sanatorium() -> void:
	var end_p: Vector3 = path_pts[path_pts.size() - 1]
	var d: Vector3 = path_dir(path_len - 2.0)
	gate_pos = end_p
	var front: Vector3 = end_p + d * 26.0
	var zb: Vector3 = d
	var xb: Vector3 = Vector3.UP.cross(zb).normalized()
	building_xf = Transform3D(Basis(xb, Vector3.UP, zb), front)
	var gate_xf: Transform3D = Transform3D(Basis(xb, Vector3.UP, zb), end_p)
	# ворота, забор, фонарь
	var g: Node3D = Node3D.new()
	g.transform = gate_xf
	var kit: Object = MeshKit.new()
	var brick: Color = Color(0.55, 0.3, 0.22)
	for sx in [-2.2, 2.2]:
		kit.add_box(Vector3(sx, 1.6, 0), Vector3(0.6, 3.2, 0.6), brick)
		kit.add_box(Vector3(sx, 3.25, 0), Vector3(0.75, 0.12, 0.75), Color(0.6, 0.58, 0.55))
	kit.add_box(Vector3(0, 3.9, 0), Vector3(4.9, 0.6, 0.12), Color(0.2, 0.32, 0.45))
	var x0: float = 2.6
	while x0 < 34.0:                                   # бетонный забор в обе стороны от ворот
		for sx2 in [-1.0, 1.0]:
			kit.add_box(Vector3(sx2 * x0, 0.9, 0), Vector3(0.18, 1.8, 0.18), Color(0.6, 0.6, 0.57))
			kit.add_box(Vector3(sx2 * (x0 + 1.25), 0.95, 0), Vector3(2.4, 1.3, 0.08), Color(0.56, 0.56, 0.53))
		x0 += 2.6
	for sx3 in [-1.0, 1.0]:                            # открытые створки ворот
		kit.add_box(Vector3(sx3 * 2.6, 1.0, -1.0), Vector3(0.05, 1.8, 2.0), Color(0.16, 0.2, 0.18), Vector3(0, sx3 * 0.3, 0))
	g.add_child(_node(kit, _m_vc))
	for side in [-1.0, 1.0]:
		var lab: Label3D = _label(Story.SANATORIUM_SIGN, 40, 0.0045, Color(0.92, 0.88, 0.7))
		lab.position = Vector3(0, 3.9, side * 0.07)
		lab.rotation = Vector3(0, PI if side < 0.0 else 0.0, 0)
		g.add_child(lab)
	gate_lamp = OmniLight3D.new()
	gate_lamp.position = Vector3(2.2, 3.6, -0.6)
	gate_lamp.light_color = Color(1.0, 0.75, 0.42)
	gate_lamp.light_energy = 0.0
	gate_lamp.omni_range = 11.0
	gate_lamp.shadow_enabled = false
	g.add_child(gate_lamp)
	var bulb: MeshInstance3D = MeshInstance3D.new()
	var sm: SphereMesh = SphereMesh.new()
	sm.radius = 0.12
	sm.height = 0.24
	bulb.mesh = sm
	var bm: StandardMaterial3D = StandardMaterial3D.new()
	bm.albedo_color = Color(1.0, 0.85, 0.55)
	bm.emission_enabled = true
	bm.emission = Color(1.0, 0.75, 0.42)
	bm.emission_energy_multiplier = 2.0
	bulb.material_override = bm
	bulb.position = gate_lamp.position
	g.add_child(bulb)
	root.add_child(g)
	# здание: модель автора или заглушка
	var b: Node3D = Node3D.new()
	b.name = "Sanatorium"
	b.transform = building_xf
	root.add_child(b)
	if ResourceLoader.exists(C.SANATORIUM_MODEL):
		var res: Resource = load(C.SANATORIUM_MODEL)
		if res is PackedScene:
			b.add_child((res as PackedScene).instantiate())
			_add_window_light(b, Vector3(0, 8.0, 1.0))
			return
	_placeholder_building(b)


func _add_window_light(b: Node3D, pos: Vector3) -> void:
	lit_window = OmniLight3D.new()
	lit_window.position = pos
	lit_window.light_color = Color(1.0, 0.8, 0.5)
	lit_window.light_energy = 0.0
	lit_window.omni_range = 7.0
	b.add_child(lit_window)


## Сталинский санаторий: три этажа, портик с колоннами, фронтон. Фасад — в −Z, тянется в +Z.
func _placeholder_building(b: Node3D) -> void:
	var walls: Object = MeshKit.new()
	var misc: Object = MeshKit.new()
	var plaster: Color = Color(0.86, 0.78, 0.58)
	var white: Color = Color(0.9, 0.88, 0.82)
	var w: float = 48.0
	var h: float = 11.4
	var dz: float = 14.0
	var hx: float = w / 2.0
	var bay: float = 3.0
	var faces: Array = [
		[Vector3(0, 0, -1), Vector3(hx, 0, 0), Vector3(-hx, 0, 0), w],
		[Vector3(0, 0, 1), Vector3(-hx, 0, dz), Vector3(hx, 0, dz), w],
		[Vector3(1, 0, 0), Vector3(hx, 0, dz), Vector3(hx, 0, 0), dz],
		[Vector3(-1, 0, 0), Vector3(-hx, 0, 0), Vector3(-hx, 0, dz), dz],
	]
	var up: Vector3 = Vector3(0, h, 0)
	for f in faces:
		var bl: Vector3 = f[1]
		var br: Vector3 = f[2]
		var wu: float = float(f[3]) / bay
		walls.add_quad(bl, br, br + up, bl + up, f[0], plaster, Vector2(0, h / bay), Vector2(wu, h / bay), Vector2(wu, 0), Vector2(0, 0))
	misc.add_box(Vector3(0, h + 0.25, dz / 2.0), Vector3(w + 0.6, 0.5, dz + 0.6), white)          # карниз
	misc.add_box(Vector3(0, 0.35, dz / 2.0), Vector3(w + 0.4, 0.7, dz + 0.4), Color(0.5, 0.48, 0.45))
	# портик: ступени, 6 колонн, фронтон
	for i in 4:
		misc.add_box(Vector3(0, 0.15 + float(i) * 0.15, -4.6 + float(i) * 0.35), Vector3(14.0 - float(i) * 0.4, 0.3, 1.0), Color(0.62, 0.6, 0.56))
	misc.add_box(Vector3(0, 0.7, -2.4), Vector3(13.0, 0.25, 4.8), Color(0.62, 0.6, 0.56))
	for i in 6:
		misc.add_cyl(Vector3(-5.5 + float(i) * 2.2, 4.4, -4.2), 0.42, 0.36, 7.4, white, Vector3.ZERO, 10)
	misc.add_box(Vector3(0, 8.4, -2.3), Vector3(13.4, 0.8, 4.6), white)
	var tri_l: Vector3 = Vector3(-6.7, 8.8, -4.6)
	var tri_r: Vector3 = Vector3(6.7, 8.8, -4.6)
	var tri_t: Vector3 = Vector3(0, 11.0, -4.6)
	misc.add_quad(tri_l, tri_r, tri_t, tri_t, Vector3(0, 0, -1), white)
	misc.add_quad(tri_l + Vector3(0, 0, 4.6), tri_t + Vector3(0, 0, 4.6), tri_t, tri_l, Vector3(-0.6, 0.8, 0).normalized(), Color(0.45, 0.42, 0.4))
	misc.add_quad(tri_r, tri_r + Vector3(0, 0, 4.6), tri_t + Vector3(0, 0, 4.6), tri_t, Vector3(0.6, 0.8, 0).normalized(), Color(0.45, 0.42, 0.4))
	misc.add_box(Vector3(0, 2.0, -0.05), Vector3(2.0, 3.0, 0.1), Color(0.18, 0.12, 0.08))           # дверь
	b.add_child(_node(walls, _m_facade))
	b.add_child(_node(misc, _m_vc))
	var sign_b: Label3D = _label(Story.SANATORIUM_SIGN, 64, 0.008, Color(0.35, 0.25, 0.12))
	sign_b.position = Vector3(0, 9.4, -4.75)
	sign_b.rotation = Vector3(0, PI, 0)
	b.add_child(sign_b)
	# окно палаты деда — единственное, где горит свет (третий этаж, справа)
	var win: MeshInstance3D = MeshInstance3D.new()
	var qm: QuadMesh = QuadMesh.new()
	qm.size = Vector2(1.8, 1.9)
	win.mesh = qm
	var wm: StandardMaterial3D = StandardMaterial3D.new()
	wm.albedo_color = Color(0.3, 0.22, 0.1)
	wm.emission_enabled = true
	wm.emission = Color(1.0, 0.72, 0.38)
	wm.emission_energy_multiplier = 1.4
	win.material_override = wm
	win.position = Vector3(10.5, 8.1, -0.03)
	win.rotation = Vector3(0, PI, 0)
	b.add_child(win)
	_add_window_light(b, Vector3(10.5, 8.0, -1.2))


# --- Деревья ------------------------------------------------------------------------------------

func _tree_mesh(kind: String) -> ArrayMesh:
	if _tree_meshes.has(kind):
		return _tree_meshes[kind]
	var kit: Object = MeshKit.new()
	var bark: Color = Color(0.5, 0.32, 0.2)
	var needles: Color = Color(0.17, 0.26, 0.14)
	match kind:
		"pine":
			kit.add_cyl(Vector3(0, 5.0, 0), 0.22, 0.12, 10.0, bark, Vector3.ZERO, 6)
			kit.add_cyl(Vector3(0, 9.4, 0), 2.1, 0.0, 3.2, needles, Vector3.ZERO, 7)
			kit.add_cyl(Vector3(0, 11.0, 0), 1.7, 0.0, 2.8, needles.lightened(0.05), Vector3.ZERO, 7)
			kit.add_cyl(Vector3(0, 12.5, 0), 1.1, 0.0, 2.4, needles, Vector3.ZERO, 6)
		"spruce":
			kit.add_cyl(Vector3(0, 1.0, 0), 0.2, 0.14, 2.0, bark.darkened(0.3), Vector3.ZERO, 6)
			var dark: Color = Color(0.09, 0.17, 0.1)
			kit.add_cyl(Vector3(0, 3.0, 0), 2.7, 0.0, 4.4, dark, Vector3.ZERO, 8)
			kit.add_cyl(Vector3(0, 5.4, 0), 2.1, 0.0, 3.8, dark.lightened(0.04), Vector3.ZERO, 8)
			kit.add_cyl(Vector3(0, 7.6, 0), 1.5, 0.0, 3.2, dark, Vector3.ZERO, 7)
			kit.add_cyl(Vector3(0, 9.5, 0), 0.9, 0.0, 2.6, dark.lightened(0.03), Vector3.ZERO, 6)
		"birch":
			kit.add_cyl(Vector3(0, 4.0, 0), 0.14, 0.07, 8.0, Color(0.86, 0.85, 0.8), Vector3.ZERO, 6)
			for y in [1.2, 2.3, 3.1, 4.4, 5.6]:
				kit.add_cyl(Vector3(0, y, 0), 0.15, 0.15, 0.06, Color(0.12, 0.12, 0.12), Vector3.ZERO, 6)
			var leaf: Color = Color(0.78, 0.63, 0.2)
			kit.add_sphere(Vector3(0, 6.4, 0), 1.6, leaf, Vector3(1, 1.3, 1), 7)
			kit.add_sphere(Vector3(0.6, 7.6, 0.2), 1.1, leaf.lightened(0.08), Vector3(1, 1.2, 1), 6)
			kit.add_sphere(Vector3(-0.5, 5.6, -0.3), 1.0, leaf.darkened(0.1), Vector3(1, 1.1, 1), 6)
		_:
			var b: Color = Color(0.14, 0.22, 0.11)
			kit.add_sphere(Vector3(0, 0.5, 0), 0.8, b, Vector3(1.2, 0.8, 1.0), 6)
			kit.add_sphere(Vector3(0.5, 0.4, 0.3), 0.55, b.lightened(0.05), Vector3(1, 0.8, 1), 5)
	var m: ArrayMesh = kit.build_mesh()
	_tree_meshes[kind] = m
	return m


func _build_trees() -> void:
	var fs: float = float(route.by_id[route.final_id]["s"])
	var cells: Dictionary = {}
	var add := func(p: Vector3, near_path: bool) -> void:
		var r: float = rng.randf()
		var kind: String = "spruce" if r < 0.42 else ("pine" if r < 0.8 else "birch")
		var key: String = kind + ":" + str(int(floor(p.x / 160.0))) + "," + str(int(floor(p.z / 160.0))) + (":p" if near_path else "")
		if not cells.has(key):
			cells[key] = []
		(cells[key] as Array).append(p)
	var b_center: Vector3 = building_xf * Vector3(0, 0, 7.0)
	var gap: float = C.TREE_SPACING
	# полоса леса вдоль всей дороги
	var s: float = float(route.start_s) - 220.0             # лес только там, где его видно из автобуса
	while s < fs + 420.0:
		for side in [-1.0, 1.0]:
			var lat: float = C.FOREST_FROM
			while lat < C.FOREST_TO:
				var ss: float = s + rng.randf_range(-0.45, 0.45) * gap
				var ll: float = lat + rng.randf_range(-0.4, 0.4) * gap
				var skip: bool = false
				if side > 0.0:
					for ev in route.events:
						if absf(ss - float(ev["s"])) < 18.0 and ll < 15.0:
							skip = true
				if not skip:
					var p: Vector3 = route.point(ss, side * ll, 0.0)
					if not _near_path(p.x, p.z, 4.0) and p.distance_to(b_center) > 42.0:
						add.call(p, false)
				lat += gap * rng.randf_range(0.8, 1.25)
		s += gap
	# лес вокруг тропинки (дальше от дороги)
	var road_pts: PackedVector3Array = PackedVector3Array()
	var rs: float = fs - 600.0
	while rs < fs + 600.0:
		road_pts.append(route.point(rs, 0.0, 0.0))
		rs += 6.0
	var gx: float = _path_min.x - 45.0
	while gx < _path_max.x + 45.0:
		var gz: float = _path_min.y - 45.0
		while gz < _path_max.y + 45.0:
			var p2: Vector3 = Vector3(gx + rng.randf_range(-0.45, 0.45) * gap, 0, gz + rng.randf_range(-0.45, 0.45) * gap)
			if _near_path(p2.x, p2.z, 48.0) and not _near_path(p2.x, p2.z, 3.4) and p2.distance_to(b_center) > 40.0:
				var far_road: bool = true
				for rp in road_pts:
					if p2.distance_squared_to(rp) < C.FOREST_TO * C.FOREST_TO:
						far_road = false
						break
				if far_road:
					add.call(p2, true)
			gz += gap
		gx += gap
	# кусты у края тропинки
	for i in range(6, int(path_len) - 6, 5):
		var pp: Vector3 = path_at(float(i))
		var pd: Vector3 = path_dir(float(i))
		var side2: float = 1.0 if rng.randf() < 0.5 else -1.0
		var bp: Vector3 = pp + Vector3(-pd.z, 0, pd.x) * side2 * rng.randf_range(2.4, 4.0)
		var key2: String = "bush:" + str(int(floor(bp.x / 160.0))) + "," + str(int(floor(bp.z / 160.0))) + ":p"
		if not cells.has(key2):
			cells[key2] = []
		(cells[key2] as Array).append(bp)
	var tints: Array = [Color(1, 1, 1), Color(0.9, 0.95, 0.88), Color(1.05, 1.0, 0.92), Color(0.85, 0.88, 0.85)]
	for key3 in cells:
		var pts: Array = cells[key3]
		var kind2: String = str(key3).get_slice(":", 0)
		var near: bool = str(key3).ends_with(":p")
		var mm: MultiMesh = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = _tree_mesh(kind2)
		mm.instance_count = pts.size()
		for i in pts.size():
			var sc: float = rng.randf_range(0.75, 1.3)
			var bs: Basis = Basis(Vector3.UP, rng.randf() * TAU) * Basis.from_scale(Vector3(sc, sc * rng.randf_range(0.9, 1.2), sc))
			bs = Basis(Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized(), rng.randf_range(0.0, 0.04)) * bs
			mm.set_instance_transform(i, Transform3D(bs, pts[i]))
			mm.set_instance_color(i, tints[rng.randi_range(0, tints.size() - 1)])
		var inst: MultiMeshInstance3D = MultiMeshInstance3D.new()
		inst.multimesh = mm
		inst.material_override = _m_vc
		inst.visibility_range_end = 190.0
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if near else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(inst)


## Совместимость со старым кодом (светофора нет).
func set_light(state: String) -> void:
	light_state = state
