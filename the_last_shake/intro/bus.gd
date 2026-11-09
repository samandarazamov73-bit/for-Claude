extends Node3D
## Автобус-заглушка: лаймово-зелёный городской, 12 м, низкопольный.
## Кузов, салон, двери, табло, кнопка остановки. Координаты: пол в центре, перед — −Z, двери — справа (+X).
## Свою модель подставь так: положи intro/assets/models/bus.glb (см. README.md) — игра возьмёт её вместо заглушки.

const C = preload("res://intro/cfg.gd")
const MeshKit = preload("res://intro/meshkit.gd")
const Story = preload("res://intro/story.gd")

const HW: float = 1.275               # половина ширины
const L2: float = 6.0                 # половина длины
const WIN_Y0: float = 1.2
const WIN_Y1: float = 2.5
const DOORS: Dictionary = {"front": [-5.65, -4.35], "middle": [-0.25, 1.25]}

const PAINT: Color = Color(0.62, 0.82, 0.12)        # лайм
const STRIPE: Color = Color(0.16, 0.36, 0.12)       # тёмно-зелёная полоса
const WHITE: Color = Color(0.93, 0.95, 0.93)
const DARK: Color = Color(0.16, 0.17, 0.19)
const INNER: Color = Color(0.84, 0.85, 0.86)
const CEIL: Color = Color(0.93, 0.94, 0.95)
const FLOOR_C: Color = Color(0.32, 0.33, 0.35)
const SEAT: Color = Color(0.14, 0.25, 0.48)
const SHELL_GRAY: Color = Color(0.55, 0.58, 0.61)
const POLE: Color = Color(0.95, 0.76, 0.19)
const BLUE: Color = Color(0.11, 0.37, 0.66)
const TIRE: Color = Color(0.08, 0.08, 0.08)
const RIM: Color = Color(0.65, 0.68, 0.7)

var body: Node3D                      # кузов (качается на подвеске)
var placeholder: Node3D                # заглушка (прячется, когда подставлена настоящая модель)
var placeholder_wheels: Node3D        # колёса заглушки (не качаются вместе с кузовом)
var anchor_wheelchair: Vector3 = Vector3(-0.78, C.FLOOR_Y, 0.72)   # где стоит коляска (лицом назад)
var anchor_mom: Vector3 = Vector3(-0.83, C.FLOOR_Y, 2.32)          # где сидит мама
var has_model: bool = false           # подставлена настоящая модель (bus.glb)
var anchor_xf: Dictionary = {}        # метки из bus.glb (anchor_*, seat_*) → Transform3D в координатах кузова
var door_open: Dictionary = {"front": 0.0, "middle": 0.0}   # 0…1
var indicator: int = 0                # поворотник: 0 нет, 1 правый, -1 левый
var stop_requested: bool = false
var seats: Array = []                 # места пассажиров (Vector3 в координатах кузова)
var stop_button: MeshInstance3D
var wheels: Array = []

var _m_vc: StandardMaterial3D
var _m_glass: StandardMaterial3D
var _m_emit: StandardMaterial3D
var _leaves: Dictionary = {"front": [], "middle": []}
var _indicators: Array = []
var _led_labels: Array = []
var _stop_sign: Label3D
var _button_mat: StandardMaterial3D
var _stop_parts: Array = []
var _door_rigs: Dictionary = {"front": [], "middle": []}   # створки дверей настоящей модели


func build() -> void:
	_m_vc = StandardMaterial3D.new()
	_m_vc.vertex_color_use_as_albedo = true
	_m_vc.vertex_color_is_srgb = true
	_m_vc.roughness = 0.6
	_m_glass = StandardMaterial3D.new()
	_m_glass.albedo_color = Color(0.17, 0.25, 0.31, 0.28)
	_m_glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_m_glass.cull_mode = BaseMaterial3D.CULL_DISABLED
	_m_glass.roughness = 0.05
	_m_emit = StandardMaterial3D.new()
	_m_emit.vertex_color_use_as_albedo = true
	_m_emit.vertex_color_is_srgb = true
	_m_emit.emission_enabled = true
	_m_emit.emission = Color(1.0, 0.96, 0.88)
	_m_emit.emission_energy_multiplier = 1.6

	body = Node3D.new()
	body.name = "Body"
	add_child(body)
	placeholder = Node3D.new()
	placeholder.name = "Placeholder"
	body.add_child(placeholder)
	placeholder_wheels = Node3D.new()
	placeholder_wheels.name = "PlaceholderWheels"
	add_child(placeholder_wheels)
	_build_shell()
	_build_interior()
	_build_doors()
	_build_boards()
	_build_wheels()
	_build_lights()


# --- Кузов -----------------------------------------------------------------

func _panel(kit: Object, side: float, y0: float, y1: float, z0: float, z1: float, outer: Color, inner: Color) -> void:
	var xo: float = side * HW
	var xi: float = side * (HW - 0.05)
	kit.add_quad(Vector3(xo, y0, z0), Vector3(xo, y0, z1), Vector3(xo, y1, z1), Vector3(xo, y1, z0), Vector3(side, 0, 0), outer)
	kit.add_quad(Vector3(xi, y0, z0), Vector3(xi, y0, z1), Vector3(xi, y1, z1), Vector3(xi, y1, z0), Vector3(-side, 0, 0), inner)


func _build_shell() -> void:
	var kit: Object = MeshKit.new()
	var glass: Object = MeshKit.new()
	var emit: Object = MeshKit.new()
	var roof_y: float = C.BUS_HEIGHT
	for side in [-1.0, 1.0]:
		var gaps: Array = []
		if side > 0.0:
			gaps = [DOORS["front"], DOORS["middle"]]
		var spans: Array = []
		var z: float = -L2
		for g in gaps:
			spans.append([z, float(g[0])])
			z = float(g[1])
		spans.append([z, L2])
		for sp in spans:
			var z0: float = float(sp[0])
			var z1: float = float(sp[1])
			if z1 - z0 < 0.01:
				continue
			_panel(kit, side, 0.28, 0.95, z0, z1, PAINT, INNER)
			_panel(kit, side, 0.95, WIN_Y0, z0, z1, STRIPE, INNER)
			_panel(kit, side, WIN_Y1, roof_y - 0.06, z0, z1, PAINT, INNER)
			var n: int = maxi(1, int(round((z1 - z0) / 1.45)))
			for i in n + 1:
				var zz: float = z0 + (z1 - z0) * float(i) / float(n)
				kit.add_box(Vector3(side * (HW - 0.025), (WIN_Y0 + WIN_Y1) / 2.0, zz), Vector3(0.06, WIN_Y1 - WIN_Y0, 0.1), DARK)
			var xg: float = side * (HW - 0.02)
			glass.add_quad(Vector3(xg, WIN_Y0, z0), Vector3(xg, WIN_Y0, z1), Vector3(xg, WIN_Y1, z1), Vector3(xg, WIN_Y1, z0), Vector3(side, 0, 0), Color.WHITE)
		for g in gaps:
			_panel(kit, side, 2.35, roof_y - 0.06, float(g[0]), float(g[1]), PAINT, INNER)

	# Крыша, потолок, пол, днище.
	kit.add_box(Vector3(0, roof_y - 0.04, 0), Vector3(C.BUS_WIDTH, 0.08, C.BUS_LENGTH), WHITE)
	kit.add_box(Vector3(0, roof_y + 0.1, 1.5), Vector3(C.BUS_WIDTH - 0.6, 0.25, 3.2), WHITE)
	var cw: float = (C.BUS_WIDTH - 0.1) / 2.0
	var cl: float = (C.BUS_LENGTH - 0.1) / 2.0
	kit.add_quad(Vector3(-cw, 2.78, -cl), Vector3(cw, 2.78, -cl), Vector3(cw, 2.78, cl), Vector3(-cw, 2.78, cl), Vector3(0, -1, 0), CEIL)
	kit.add_box(Vector3(0, C.FLOOR_Y - 0.06, 0), Vector3(C.BUS_WIDTH - 0.1, 0.12, C.BUS_LENGTH - 0.1), FLOOR_C)
	kit.add_box(Vector3(0, 0.25, 0), Vector3(C.BUS_WIDTH, 0.12, C.BUS_LENGTH), DARK)
	# Перед: нижняя панель, верх, бампер, лобовое стекло, фары.
	kit.add_box(Vector3(0, 0.62, -L2), Vector3(C.BUS_WIDTH, 0.75, 0.08), STRIPE)
	kit.add_box(Vector3(0, 2.9, -L2), Vector3(C.BUS_WIDTH, 0.3, 0.08), DARK)
	kit.add_box(Vector3(0, 0.32, -L2 - 0.02), Vector3(C.BUS_WIDTH + 0.04, 0.12, 0.25), DARK)
	var ww: float = (C.BUS_WIDTH - 0.1) / 2.0
	glass.add_quad(Vector3(-ww, 1.0, -L2 + 0.01), Vector3(ww, 1.0, -L2 + 0.01), Vector3(ww, 2.72, -L2 + 0.01), Vector3(-ww, 2.72, -L2 + 0.01), Vector3(0, 0, -1), Color.WHITE)
	for x in [-0.95, 0.95]:
		emit.add_box(Vector3(x, 0.72, -L2 - 0.05), Vector3(0.34, 0.14, 0.04), Color(1.0, 0.97, 0.88))
	# Зад.
	kit.add_box(Vector3(0, 1.25, L2), Vector3(C.BUS_WIDTH, 1.9, 0.08), PAINT)
	kit.add_box(Vector3(0, 2.85, L2), Vector3(C.BUS_WIDTH, 0.38, 0.08), PAINT)
	glass.add_quad(Vector3(-1.0, 2.2, L2 + 0.01), Vector3(1.0, 2.2, L2 + 0.01), Vector3(1.0, 2.8, L2 + 0.01), Vector3(-1.0, 2.8, L2 + 0.01), Vector3(0, 0, 1), Color.WHITE)
	for x in [-1.05, 1.05]:
		emit.add_box(Vector3(x, 0.85, L2 + 0.04), Vector3(0.22, 0.32, 0.05), Color(0.8, 0.07, 0.07))
	# Арки колёс.
	for zc in [-3.3, 3.2]:
		for side in [-1.0, 1.0]:
			kit.add_box(Vector3(side * (HW + 0.01), 1.0, zc), Vector3(0.06, 0.4, 1.3), DARK)

	placeholder.add_child(kit.build(_m_vc))
	placeholder.add_child(glass.build(_m_glass, false))
	placeholder.add_child(emit.build(_m_emit, false))

	# Поворотники (мигают при подъезде к остановке).
	for side in [-1.0, 1.0]:
		for zz in [-L2 - 0.05, L2 + 0.05]:
			var mi: MeshInstance3D = MeshInstance3D.new()
			var bm: BoxMesh = BoxMesh.new()
			bm.size = Vector3(0.18, 0.1, 0.05)
			mi.mesh = bm
			var mat: StandardMaterial3D = StandardMaterial3D.new()
			mat.albedo_color = Color(0.42, 0.29, 0.06)
			mat.emission_enabled = true
			mat.emission = Color(1.0, 0.63, 0.0)
			mat.emission_energy_multiplier = 0.0
			mi.material_override = mat
			mi.position = Vector3(side * 1.08, 1.0, zz)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			placeholder.add_child(mi)
			_indicators.append({"mat": mat, "side": 1 if side > 0.0 else -1})


# --- Салон -----------------------------------------------------------------

func _seat(kit: Object, x: float, z: float) -> void:
	var fy: float = C.FLOOR_Y
	kit.add_box(Vector3(x, fy + 0.45, z), Vector3(0.44, 0.1, 0.42), SEAT)
	kit.add_box(Vector3(x, fy + 0.76, z + 0.21), Vector3(0.44, 0.55, 0.07), SEAT, Vector3(0.12, 0, 0))
	kit.add_box(Vector3(x, fy + 0.2, z), Vector3(0.3, 0.4, 0.3), SHELL_GRAY)
	seats.append(Vector3(x, fy, z))


func _build_interior() -> void:
	var kit: Object = MeshKit.new()
	var emit: Object = MeshKit.new()
	var fy: float = C.FLOOR_Y
	seats = []
	# Слева: спереди и сзади; по центру слева — место для коляски.
	for z in [-3.9, -3.1, -2.3, -1.5]:
		for x in [-0.98, -0.52]:
			_seat(kit, x, z)
	for z in [2.32, 3.12, 3.92, 4.72]:
		for x in [-0.98, -0.52]:
			_seat(kit, x, z)
	# Справа: за передней дверью и за средней.
	for z in [-3.5, -2.7]:
		for x in [0.52, 0.98]:
			_seat(kit, x, z)
	for z in [2.3, 3.1, 3.9, 4.7]:
		for x in [0.52, 0.98]:
			_seat(kit, x, z)
	for x in [-0.98, -0.5, 0.0, 0.5, 0.98]:
		_seat(kit, x, 5.55)
	# Поручни.
	for p in [[0.32, -4.2], [-0.32, -1.1], [0.32, -1.1], [0.32, 1.8], [-0.32, 1.9], [0.32, 3.5], [-0.32, 3.5], [0.32, -0.45], [0.32, 1.45]]:
		kit.add_cyl(Vector3(float(p[0]), fy + 1.22, float(p[1])), 0.02, 0.02, 2.45, POLE, Vector3.ZERO, 8)
	for x in [-0.45, 0.45]:
		kit.add_cyl(Vector3(x, 2.35, 0.3), 0.018, 0.018, 10.4, POLE, Vector3(PI / 2.0, 0, 0), 8)
	# Светильники под потолком.
	for x in [-0.85, 0.85]:
		emit.add_box(Vector3(x, 2.76, 0.4), Vector3(0.18, 0.03, 9.8), Color(1.0, 0.96, 0.88))
	# Место для коляски: синяя разметка, упор для спины, поручень.
	kit.add_box(Vector3(-0.78, fy + 0.003, 0.95), Vector3(0.9, 0.006, 1.5), BLUE)
	kit.add_box(Vector3(-0.78, fy + 0.95, 0.18), Vector3(0.62, 0.62, 0.1), BLUE)
	kit.add_box(Vector3(-0.78, fy + 0.6, 0.12), Vector3(0.05, 1.2, 0.05), POLE)
	# Кабина водителя: перегородка, приборная панель, руль, сиденье.
	kit.add_box(Vector3(-0.78, fy + 0.5, -4.55), Vector3(1.0, 0.95, 0.06), SHELL_GRAY)
	kit.add_box(Vector3(0, fy + 0.75, -5.65), Vector3(2.3, 0.45, 0.6), DARK)
	kit.add_torus(Vector3(-0.72, fy + 1.05, -5.15), 0.2, 0.25, DARK, Vector3(-1.1, 0, 0))
	kit.add_box(Vector3(-0.72, fy + 0.5, -4.85), Vector3(0.5, 0.12, 0.5), DARK)
	kit.add_box(Vector3(-0.72, fy + 0.85, -4.6), Vector3(0.5, 0.6, 0.1), DARK)
	# Валидатор у средней двери.
	kit.add_box(Vector3(0.32, fy + 1.3, 1.4), Vector3(0.14, 0.22, 0.1), DARK)
	placeholder.add_child(kit.build(_m_vc))
	placeholder.add_child(emit.build(_m_emit, false))

	# Кнопка остановки у места для коляски — до неё дотягивается герой.
	stop_button = MeshInstance3D.new()
	stop_button.name = "StopButton"
	var cm: CylinderMesh = CylinderMesh.new()
	cm.top_radius = 0.06
	cm.bottom_radius = 0.06
	cm.height = 0.04
	cm.radial_segments = 16
	stop_button.mesh = cm
	_button_mat = StandardMaterial3D.new()
	_button_mat.albedo_color = BLUE
	_button_mat.emission_enabled = true
	_button_mat.emission = Color(0.2, 0.5, 1.0)
	_button_mat.emission_energy_multiplier = 0.0
	stop_button.material_override = _button_mat
	stop_button.rotation = Vector3(0, 0, -PI / 2.0)
	stop_button.position = Vector3(-HW + 0.07, fy + 0.98, 1.25)
	body.add_child(stop_button)
	var plate: MeshInstance3D = MeshInstance3D.new()
	var pm: BoxMesh = BoxMesh.new()
	pm.size = Vector3(0.03, 0.22, 0.22)
	plate.mesh = pm
	var plate_mat: StandardMaterial3D = StandardMaterial3D.new()
	plate_mat.albedo_color = DARK
	plate.material_override = plate_mat
	plate.position = Vector3(-HW + 0.04, fy + 0.98, 1.25)
	body.add_child(plate)
	var lab: Label3D = Label3D.new()
	lab.text = "СТОП"
	lab.font_size = 24
	lab.pixel_size = 0.0018
	lab.modulate = Color(1, 1, 1)
	lab.outline_size = 0
	lab.shaded = false
	lab.position = Vector3(-HW + 0.095, fy + 0.98, 1.25)
	lab.rotation = Vector3(0, PI / 2.0, 0)
	body.add_child(lab)
	# В 1975-м кнопок «остановка» в автобусах не было — водителю говорили голосом.
	_stop_parts = [stop_button, plate, lab]
	for part in _stop_parts:
		(part as Node3D).visible = false


func _build_doors() -> void:
	for door_name in DOORS:
		var d: Array = DOORS[door_name]
		var w: float = (float(d[1]) - float(d[0])) / 2.0
		for kk in 2:
			var leaf: Node3D = Node3D.new()
			var zc: float = float(d[0]) + w / 2.0 + float(kk) * w
			leaf.position = Vector3(HW - 0.03, C.FLOOR_Y + 1.2, zc)
			leaf.set_meta("zc", zc)
			leaf.set_meta("dir", 1.0 if kk == 1 else -1.0)
			leaf.set_meta("w", w)
			var fk: Object = MeshKit.new()
			fk.add_box(Vector3(0, 1.1, 0), Vector3(0.05, 0.1, w - 0.02), DARK)
			fk.add_box(Vector3(0, -0.85, 0), Vector3(0.05, 0.55, w - 0.02), PAINT)
			fk.add_box(Vector3(0, 0, (w - 0.02) / 2.0), Vector3(0.05, 2.3, 0.05), DARK)
			fk.add_box(Vector3(0, 0, -(w - 0.02) / 2.0), Vector3(0.05, 2.3, 0.05), DARK)
			leaf.add_child(fk.build(_m_vc))
			var gk: Object = MeshKit.new()
			var gw: float = (w - 0.16) / 2.0
			gk.add_quad(Vector3(0.03, -0.7, -gw), Vector3(0.03, -0.7, gw), Vector3(0.03, 1.0, gw), Vector3(0.03, 1.0, -gw), Vector3(1, 0, 0), Color.WHITE)
			leaf.add_child(gk.build(_m_glass, false))
			placeholder.add_child(leaf)
			(_leaves[door_name] as Array).append(leaf)


func _make_label(text: String, size: int, pix: float, color: Color) -> Label3D:
	var lab: Label3D = Label3D.new()
	lab.text = text
	lab.font_size = size
	lab.pixel_size = pix
	lab.modulate = color
	lab.outline_size = 0
	lab.shaded = false
	return lab


func _build_boards() -> void:
	var amber: Color = Color(1.0, 0.69, 0.13)
	var back_kit: Object = MeshKit.new()
	# Табло в салоне: у передней стенки (читается, если повернуться) и у задней (его видит герой).
	back_kit.add_box(Vector3(0, 2.6, -4.2), Vector3(1.3, 0.17, 0.02), Color(0.07, 0.05, 0.02))
	back_kit.add_box(Vector3(0, 2.6, 4.25), Vector3(1.3, 0.17, 0.02), Color(0.07, 0.05, 0.02))
	back_kit.add_box(Vector3(0, 2.86, -L2 - 0.03), Vector3(2.1, 0.26, 0.02), Color(0.07, 0.05, 0.02))
	back_kit.add_box(Vector3(HW + 0.005, 2.55, -3.6), Vector3(0.02, 0.18, 1.4), Color(0.07, 0.05, 0.02))
	placeholder.add_child(back_kit.build(_m_vc, false))

	var front_in: Label3D = _make_label("", 40, 0.0022, amber)
	front_in.position = Vector3(0, 2.6, -4.19)
	placeholder.add_child(front_in)
	var rear_in: Label3D = _make_label("", 40, 0.0022, amber)
	rear_in.position = Vector3(0, 2.6, 4.24)
	rear_in.rotation = Vector3(0, PI, 0)
	placeholder.add_child(rear_in)
	_led_labels = [front_in, rear_in]

	var route_text: String = Story.ROUTE_NUMBER + "  " + Story.ROUTE_SIGN
	var front_out: Label3D = _make_label(route_text, 48, 0.0024, amber)
	front_out.position = Vector3(0, 2.86, -L2 - 0.045)
	front_out.rotation = Vector3(0, PI, 0)
	placeholder.add_child(front_out)
	var side_out: Label3D = _make_label(route_text, 40, 0.0022, amber)
	side_out.position = Vector3(HW + 0.017, 2.55, -3.6)
	side_out.rotation = Vector3(0, PI / 2.0, 0)
	placeholder.add_child(side_out)

	_stop_sign = _make_label("ОСТАНОВКА", 28, 0.0016, Color(0.35, 0.1, 0.1))
	_stop_sign.position = Vector3(0, 2.42, 4.2)
	_stop_sign.rotation = Vector3(0, PI, 0)
	placeholder.add_child(_stop_sign)


func set_led(text: String) -> void:
	for lab in _led_labels:
		if (lab as Label3D).text != text:
			(lab as Label3D).text = text


func set_stop_requested(on: bool) -> void:
	stop_requested = on
	_stop_sign.modulate = Color(1.0, 0.23, 0.19) if on else Color(0.35, 0.1, 0.1)
	_button_mat.emission_energy_multiplier = 2.0 if on else 0.0


func _build_wheels() -> void:
	for zc in [-3.3, 3.2]:
		for side in [-1.0, 1.0]:
			var w: Node3D = Node3D.new()
			w.position = Vector3(side * (HW - 0.22), 0.5, zc)
			var kit: Object = MeshKit.new()
			kit.add_cyl(Vector3.ZERO, 0.5, 0.5, 0.32, TIRE, Vector3(0, 0, PI / 2.0), 20)
			kit.add_cyl(Vector3.ZERO, 0.3, 0.3, 0.34, RIM, Vector3(0, 0, PI / 2.0), 12)
			w.add_child(kit.build(_m_vc))
			placeholder_wheels.add_child(w)   # колёса не качаются вместе с кузовом
			wheels.append(w)


func _build_lights() -> void:
	for zc in [-2.2, 2.6]:
		var l: OmniLight3D = OmniLight3D.new()
		l.position = Vector3(0, 2.55, zc)
		l.omni_range = 8.0
		l.light_energy = 1.5
		l.light_color = Color(1.0, 0.94, 0.86)
		l.shadow_enabled = false
		body.add_child(l)


# --- Каждый кадр -------------------------------------------------------------

func update(dt: float, speed: float, accel: float, curvature: float, time: float) -> void:
	# Подвеска: крен в поворотах, клевок при торможении, мелкая вибрация.
	var lat: float = speed * speed * curvature
	var k: float = minf(1.0, dt * 3.0)
	body.rotation.z = lerpf(body.rotation.z, lat * 0.012, k)
	body.rotation.x = lerpf(body.rotation.x, accel * 0.012, k)
	body.position.y = sin(time * 13.0) * 0.004 * minf(1.0, speed / 6.0) + sin(time * 2.3) * 0.002
	for w in wheels:
		(w as Node3D).rotation.x -= speed * dt / 0.5

	# Двери: створки выходят наружу и разъезжаются.
	for door_name in _leaves:
		var t: float = float(door_open[door_name])
		var out: float = minf(1.0, t * 2.0)
		var slide: float = maxf(0.0, t * 2.0 - 1.0) * 0.92
		for lf in _leaves[door_name]:
			var leaf: Node3D = lf as Node3D
			var zc: float = float(leaf.get_meta("zc"))
			var dir: float = float(leaf.get_meta("dir"))
			var half: float = float(leaf.get_meta("w"))
			leaf.position.x = HW - 0.03 + out * 0.12
			leaf.position.z = zc + dir * slide * half

	# Двери настоящей модели: створки поворачиваются на петле и складываются пополам (до 80°).
	for door_name in _door_rigs:
		var th: float = deg_to_rad(80.0) * _ease(float(door_open[door_name]))
		for rig in _door_rigs[door_name]:
			var d: float = float(rig["dir"])
			(rig["hinge"] as Node3D).rotation = Vector3(0.0, th if d > 0.0 else PI - th, 0.0)
			(rig["fold"] as Node3D).rotation = Vector3(0.0, -2.0 * th * d, 0.0)

	# Поворотник: 1.5 Гц.
	var blink: bool = indicator != 0 and sin(time * PI * 3.0) > 0.0
	for ind in _indicators:
		var on: bool = blink and int(ind["side"]) == indicator
		(ind["mat"] as StandardMaterial3D).emission_energy_multiplier = 2.5 if on else 0.0


## Подставляет настоящую модель (intro/assets/models/bus.glb) вместо заглушки.
## Модель — в метрах, нос автобуса смотрит в −Z, двери справа (+X).
## Пустышки-метки внутри модели: anchor_wheelchair, anchor_mom, anchor_driver, seat_NN_* (места пассажиров).
## Створки дверей ЛиАЗа (Door_Front_4Leaf_*, Door_Rear_4Leaf_*) открываются, как в исходной модели.
func use_model(scene: PackedScene) -> void:
	var model: Node3D = scene.instantiate() as Node3D
	if model == null:
		return
	body.add_child(model)
	has_model = true
	placeholder.visible = false
	placeholder_wheels.visible = false
	var inv: Transform3D = body.global_transform.affine_inverse()
	for n in model.find_children("*", "Node3D", true, false):
		var nm: String = str(n.name)
		if nm.begins_with("anchor_") or nm.begins_with("seat_"):
			anchor_xf[nm] = inv * (n as Node3D).global_transform
	if anchor_xf.has("anchor_wheelchair"):
		anchor_wheelchair = (anchor_xf["anchor_wheelchair"] as Transform3D).origin
	if anchor_xf.has("anchor_mom"):
		anchor_mom = (anchor_xf["anchor_mom"] as Transform3D).origin
	for pair in [["front", "Door_Front_4Leaf"], ["middle", "Door_Rear_4Leaf"]]:
		for k in [1, 2]:
			var hinge: Node3D = model.find_child("%s_LeafPair%d_Hinge" % [pair[1], k], true, false) as Node3D
			var fold: Node3D = model.find_child("%s_LeafPair%d_Fold" % [pair[1], k], true, false) as Node3D
			if hinge != null and fold != null:
				var dir: float = 1.0 if hinge.transform.basis.z.z > 0.0 else -1.0
				(_door_rigs[pair[0]] as Array).append({"hinge": hinge, "fold": fold, "dir": dir})
	# Плафоны салона — пониже: у ЛиАЗа потолок ниже, пол выше.
	for l in body.get_children():
		if l is OmniLight3D:
			(l as OmniLight3D).position.y = 2.35
	var rear_light: OmniLight3D = OmniLight3D.new()
	rear_light.position = Vector3(0, 2.35, 4.0)
	rear_light.omni_range = 7.0
	rear_light.light_energy = 1.3
	rear_light.light_color = Color(1.0, 0.92, 0.8)
	body.add_child(rear_light)


static func _ease(t: float) -> float:
	return 4.0 * t * t * t if t < 0.5 else 1.0 - pow(-2.0 * t + 2.0, 3.0) / 2.0
