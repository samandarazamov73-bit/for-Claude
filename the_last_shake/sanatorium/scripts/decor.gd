extends RefCounted
## Свои картинки автора (sanatorium/assets/pics/, подготовлены tools/user_assets/) на предметах здания:
## картины в рамах, доски объявлений, циферблаты часов, радиоточки, экраны и шильдики телевизоров, диски
## телефонов, пульты вызова, таблички «Не влезай!», этикетки огнетушителей, шахматные доски.
## Предмет здания — коробка из атласа; картинка ставится плоскостью на его лицевую сторону (+Z), картины и доски
## (плоские наклейки) заменяются целиком. Тип с собственной 3D-моделью (sanatorium/models/) не трогается.

const PICS := "res://sanatorium/assets/pics/"

static var _mats := {}


static func _tex(pic: String) -> Texture2D:
	for ext in [".png", ".jpg"]:
		if ResourceLoader.exists(PICS + pic + ext):
			return load(PICS + pic + ext)
	return null


## Материал картинки: бумага/краска матовые, вырезанные картинки — с прозрачностью по краю.
static func mat(pic: String, rough := 0.85, metal := 0.0) -> StandardMaterial3D:
	var key := "%s|%.2f|%.2f" % [pic, rough, metal]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	var t := _tex(pic)
	if t == null:
		return null
	m.albedo_texture = t
	m.roughness = rough
	m.metallic = metal
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	if ResourceLoader.exists(PICS + pic + ".png"):
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		m.alpha_scissor_threshold = 0.5
	if ResourceLoader.exists(PICS + pic + "_normal.jpg"):
		m.normal_enabled = true
		m.normal_texture = load(PICS + pic + "_normal.jpg")
		m.normal_scale = 0.6
	_mats[key] = m
	return m


static func _wood() -> StandardMaterial3D:
	if _mats.has("_wood"):
		return _mats["_wood"]
	var m := StandardMaterial3D.new()
	var dir := "res://sanatorium/assets/tex/%s.jpg"
	if ResourceLoader.exists(dir % "door_albedo"):
		m.albedo_texture = load(dir % "door_albedo")
		m.uv1_scale = Vector3(0.25, 0.25, 0.25)
	else:
		m.albedo_color = Color(0.3, 0.17, 0.09)
	m.roughness = 0.45
	_mats["_wood"] = m
	return m


static func _plain(col: Color, rough: float, key: String) -> StandardMaterial3D:
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	_mats[key] = m
	return m


## Плоскость с картинкой: центр c, размер (ш, в), смотрит в +Z (или куда повернёт rot).
static func quad(parent: Node3D, m: Material, c: Vector3, size: Vector2, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = size
	mi.mesh = q
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	mi.position = c
	mi.rotation = rot
	return mi


static func box(parent: Node3D, m: Material, c: Vector3, size: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = m
	parent.add_child(mi)
	mi.position = c
	return mi


## model_type: имя узла → тип мебели; has_model: тип → есть ли своя 3D-модель (из game.gd).
static func apply(root: Node, model_type: Callable, has_model: Callable) -> int:
	var n := 0
	for g in root.find_children("*", "MeshInstance3D", true, false):
		var old: MeshInstance3D = g
		if not old.visible or old.mesh == null:
			continue
		var t: String = model_type.call(String(old.name))
		if t == "" or has_model.call(t):
			continue
		var holder: Node3D = null
		match t:
			"painting_1", "painting_2", "painting_3":
				holder = _painting(old, t)
			"notice_board":
				holder = _notice_board(old)
			"clock":
				holder = _clock(old)
			"radio":
				holder = _front(old, "radio_front", 1.0, 0.0)
			"tv_small":
				holder = _tv(old)
			"telephone":
				holder = _telephone(old)
			"call_panel":
				holder = _front(old, "call_numbers", 0.96, 0.0)
			"fire_ext":
				holder = _fire_label(old)
			"fuse_box", "elec_cabinet", "elec_panel_wall":
				holder = _danger_sign(old, 0.16)
			"game_chess":
				holder = _chess(old)
		if holder:
			n += 1
	# таблички «Не влезай!» — не мебель (нет в MODEL_TYPES), ищем по имени
	for g in root.find_children("electro_warning*", "MeshInstance3D", true, false):
		var old2: MeshInstance3D = g
		if old2.visible and old2.mesh:
			if _danger_sign(old2, 0.2, true):
				n += 1
	return n


## Узел на месте предмета (тот же родитель и поворот), с теми же слоями и дальностью видимости.
static func _holder(old: MeshInstance3D, nm: String) -> Node3D:
	var h := Node3D.new()
	h.name = String(old.name) + "_" + nm
	old.get_parent().add_child(h)
	h.transform = old.transform
	h.set_meta("src", old)
	return h


static func _finish(h: Node3D, old: MeshInstance3D) -> Node3D:
	for c in h.find_children("*", "GeometryInstance3D", true, false):
		var gi: GeometryInstance3D = c
		gi.layers = old.layers
		gi.visibility_range_end = old.visibility_range_end
		gi.visibility_range_end_margin = old.visibility_range_end_margin
		gi.visibility_range_fade_mode = old.visibility_range_fade_mode
	return h


## Картина маслом в ореховой раме вместо плоской наклейки.
static func _painting(old: MeshInstance3D, t: String) -> Node3D:
	var m := mat(t, 0.62)
	if m == null:
		return null
	var b: AABB = old.mesh.get_aabb()
	var h := _holder(old, "pic")
	var w: float = b.size.x
	var hh: float = b.size.y
	var c := Vector3(b.get_center().x, b.get_center().y, 0.0)
	var fw := 0.045                                       # ширина рамы
	var depth := 0.03
	var wood := _wood()
	box(h, wood, c + Vector3(0, hh * 0.5 - fw * 0.5, depth * 0.5), Vector3(w, fw, depth))
	box(h, wood, c + Vector3(0, -hh * 0.5 + fw * 0.5, depth * 0.5), Vector3(w, fw, depth))
	box(h, wood, c + Vector3(-w * 0.5 + fw * 0.5, 0, depth * 0.5), Vector3(fw, hh - fw * 2.0, depth))
	box(h, wood, c + Vector3(w * 0.5 - fw * 0.5, 0, depth * 0.5), Vector3(fw, hh - fw * 2.0, depth))
	box(h, _plain(Color(0.2, 0.17, 0.13), 0.9, "_backing"), c + Vector3(0, 0, 0.006), Vector3(w - fw, hh - fw, 0.012))
	quad(h, m, c + Vector3(0, 0, 0.0135), Vector2(w - fw * 1.6, hh - fw * 1.6))
	old.visible = false
	return _finish(h, old)


## Пробковая доска с четырьмя объявлениями (режим дня, приём врачей, тихий час, санитарный день).
static func _notice_board(old: MeshInstance3D) -> Node3D:
	var m := mat("notices", 0.92)
	if m == null:
		return null
	var b: AABB = old.mesh.get_aabb()
	var h := _holder(old, "pic")
	var c := Vector3(b.get_center().x, b.get_center().y, 0.0)
	box(h, _plain(Color(0.55, 0.4, 0.25), 0.95, "_cork"), c + Vector3(0, 0, 0.01), Vector3(b.size.x, b.size.y, 0.02))
	box(h, _wood(), c + Vector3(0, b.size.y * 0.5, 0.012), Vector3(b.size.x + 0.03, 0.025, 0.024))
	box(h, _wood(), c + Vector3(0, -b.size.y * 0.5, 0.012), Vector3(b.size.x + 0.03, 0.025, 0.024))
	var asp := 1536.0 / 1024.0
	var pw: float = minf(b.size.x - 0.08, (b.size.y - 0.08) * asp)
	quad(h, m, c + Vector3(0, 0, 0.0215), Vector2(pw, pw / asp))
	old.visible = false
	return _finish(h, old)


## Циферблат «Янтарь» и стрелки: часы стоят на 11:14 (в эпилоге — 23:14, время смерти).
static func _clock(old: MeshInstance3D) -> Node3D:
	var m := mat("clock_face", 0.5)
	if m == null:
		return null
	var b: AABB = old.mesh.get_aabb()
	var h := _holder(old, "pic")
	var c := Vector3(b.get_center().x, b.get_center().y, b.end.z + 0.002)
	var d: float = minf(b.size.x, b.size.y) * 0.86
	quad(h, m, c, Vector2(d, d))
	var black := _plain(Color(0.03, 0.03, 0.03), 0.4, "_hands")
	var hands := [[(11.0 + 14.0 / 60.0) / 12.0, d * 0.25, 0.012], [14.0 / 60.0, d * 0.38, 0.008]]
	for hd in hands:
		var a: float = float(hd[0]) * TAU
		var len: float = hd[1]
		var arm := Node3D.new()
		h.add_child(arm)
		arm.position = c + Vector3(0, 0, 0.004)
		arm.rotation.z = -a
		box(arm, black, Vector3(0, len * 0.4, 0), Vector3(float(hd[2]), len, 0.002))
	return _finish(h, old)


## Картинка на лицевой стороне коробки: вписать в её переднюю грань с полями (fill — доля).
static func _front(old: MeshInstance3D, pic: String, fill: float, dy: float) -> Node3D:
	var m := mat(pic, 0.7)
	if m == null:
		return null
	var t: Texture2D = m.albedo_texture
	var asp: float = float(t.get_width()) / float(t.get_height())
	var b: AABB = old.mesh.get_aabb()
	var w: float = minf(b.size.x, b.size.y * asp) * fill
	var h := _holder(old, "pic")
	quad(h, m, Vector3(b.get_center().x, b.get_center().y + dy, b.end.z + 0.002), Vector2(w, w / asp))
	return _finish(h, old)


## Телевизор: выключенный кинескоп и шильдик «Электроника» под ним.
static func _tv(old: MeshInstance3D) -> Node3D:
	var scr := mat("tv_screen", 0.08)
	var badge := mat("tv_badge", 0.35, 0.6)
	if scr == null:
		return null
	var b: AABB = old.mesh.get_aabb()
	var h := _holder(old, "pic")
	var w: float = b.size.x * 0.66
	var cy: float = b.position.y + b.size.y * 0.56
	quad(h, scr, Vector3(b.get_center().x - b.size.x * 0.06, cy, b.end.z + 0.003), Vector2(w, w * 0.75))
	if badge:
		var bw: float = b.size.x * 0.26
		quad(h, badge, Vector3(b.get_center().x - b.size.x * 0.06, b.position.y + b.size.y * 0.11, b.end.z + 0.003),
			Vector2(bw, bw * 496.0 / 1536.0))
	return _finish(h, old)


## Телефон: диск с цифрами сверху на скате корпуса.
static func _telephone(old: MeshInstance3D) -> Node3D:
	var m := mat("phone_dial", 0.4)
	if m == null:
		return null
	var b: AABB = old.mesh.get_aabb()
	var h := _holder(old, "pic")
	var d: float = minf(b.size.x, b.size.z) * 0.5
	quad(h, m, Vector3(b.get_center().x, b.end.y + 0.002, b.get_center().z + b.size.z * 0.12), Vector2(d, d * 1084.0 / 1052.0),
		Vector3(-PI * 0.5 + 0.45, 0, 0))
	return _finish(h, old)


## Этикетка ОХП-10 на баллоне огнетушителя.
static func _fire_label(old: MeshInstance3D) -> Node3D:
	var m := mat("fire_label", 0.55)
	if m == null:
		return null
	var b: AABB = old.mesh.get_aabb()
	var h := _holder(old, "pic")
	var w: float = b.size.x * 0.72
	quad(h, m, Vector3(b.get_center().x, b.position.y + b.size.y * 0.42, b.end.z + 0.002), Vector2(w, w / 1.5))
	return _finish(h, old)


## «Не влезай! Убьёт!» — на дверце щитка или вместо старой наклейки.
static func _danger_sign(old: MeshInstance3D, width: float, replace := false) -> Node3D:
	var m := mat("electro_sign", 0.45)
	if m == null:
		return null
	if old.has_meta("decor_done"):
		return null
	old.set_meta("decor_done", true)
	var b: AABB = old.mesh.get_aabb()
	var h := _holder(old, "pic")
	var asp := 1536.0 / 1012.0
	var w: float = minf(width, b.size.x * 0.8) if not replace else width
	var y: float = b.get_center().y if replace else b.position.y + b.size.y * 0.72
	quad(h, m, Vector3(b.get_center().x, y, b.end.z + 0.003), Vector2(w, w / asp))
	if replace:
		old.visible = false
	return _finish(h, old)


## Шахматная доска на столике.
static func _chess(old: MeshInstance3D) -> Node3D:
	var m := mat("chess_board", 0.5)
	if m == null:
		return null
	var b: AABB = old.mesh.get_aabb()
	var h := _holder(old, "pic")
	var s: float = minf(b.size.x, b.size.z) * 0.95
	quad(h, m, Vector3(b.get_center().x, b.end.y + 0.002, b.get_center().z), Vector2(s, s * 1016.0 / 1088.0), Vector3(-PI * 0.5, 0, 0))
	return _finish(h, old)
