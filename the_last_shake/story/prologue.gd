extends Node3D
## Пролог «The Last Shake» (акт 1, начало): старый ЛиАЗ едет по лесной дороге в густом сером тумане предгорий.
## Коляска Самана стоит на задней площадке (в автобусе её не двигать), свет в салоне выключен; мышью смотришь
## по сторонам, навести взгляд на маму (Барно) и нажать E — разговор. Остановка «Санаторий «Оромгох»» → темнота → остановка снаружи, автобус уезжает →
## по лесной тропинке за мамой в сумерках (F — фонарик) → вверх по пандусу (коляска едет по маршруту
## resources/world/entrance_route.json, W/S) → E — открыть входную дверь → заехать в тамбур → дверь закрывается
## за мамой → санаторий (main.tscn) продолжается с того же места в тамбуре.
## Лес, земля и дорога — из forest_drive (scripts/, scenes/, resources/world/); место санатория и тропинку
## подготовил tools/godot_assets/prepare_world.py (resources/world/story_site.json).

const Bus = preload("res://intro/bus.gd")
const Audio = preload("res://intro/audio.gd")
const StoryUI = preload("res://story/story_ui.gd")
const Actor = preload("res://story/actor.gd")
const Props = preload("res://story/props.gd")
const ChairModel = preload("res://story/chair_model.gd")
const EntranceDoor = preload("res://story/entrance_door.gd")

const RIDE_DISTANCE := 1900.0       # метров до остановки (~2,5 минуты)
const CRUISE := 12.5                # м/с
const ACCEL := 0.8
const DECEL := 0.95
const LAT_ACC := 1.4                # боковое ускорение в поворотах
const LANE := 1.85                  # правая полоса (в forest_drive «плюс» — вправо по ходу)
const STOP_LANE := 2.85             # у остановки прижимается к обочине
const FAST := 6.0                   # Tab — перемотка поездки
const WALK_SPEED := 1.6             # по тропинке (Shift — 2.4)
const PATH_HALF := 1.6
const EYE := Vector3(0.0, 1.19, 0.20)
const MOUSE_SENS := 0.0022
const MOM_IN_BUS := Vector3(-0.5, 0.8, 4.6)     # Барно спокойно стоит слева от Самана (руки опущены)
const HERO_IN_BUS := Vector3(-0.6, 0.8, 3.85)   # задняя площадка, лицом к левому окну
# вход в санаторий (координаты здания, как в sanatorium/assets/level.json)
const RAMP_SPEED := 1.05                        # м/с по пандусу (W — вверх, S — назад)
const DOOR_STOP_X := 26.75                      # пока дверь закрыта, центр коляски — не дальше
const DOOR_POINT := Vector3(27.55, 1.2, 4.27)   # середина входной двери «А»
const MOM_DOOR := Vector3(26.55, 1.2, 2.95)     # мама ждёт сбоку от двери
const MOM_INSIDE := [Vector3(26.95, 1.2, 3.95), Vector3(27.75, 1.2, 4.0), Vector3(28.2, 1.2, 3.25)]
const KEEP_ROOMS := ["Room_EB_VEST_Entrancevestibule", "Room_EB_HALL_Receptionhallandwaitingarea"]
# плафоны тамбура и вестибюля (как в игре здания: plafond 70 → 70/44 × 0.5)
const VEST_LAMPS := [Vector3(28.775, 4.0, 10.26), Vector3(28.775, 4.0, 7.62), Vector3(28.775, 4.0, 4.98),
	Vector3(28.775, 4.0, 2.34), Vector3(31.33, 4.0, 8.125), Vector3(31.33, 4.0, 4.875), Vector3(31.33, 4.0, 1.625),
	Vector3(28.735, 4.0, 0.45)]

@onready var terrain: TerrainSystem = $Terrain
@onready var road: RoadBuilder = $Road
@onready var forest: ForestGenerator = $Forest

var site: Dictionary
var path: Array = []              # Vector3, через ~1 м
var path_cum: Array = []
var env: Environment
var sun: DirectionalLight3D
var sky_mat: ProceduralSkyMaterial
var bus
var audio
var ui                            # story/story_ui.gd
var mom                           # story/actor.gd
var hero: Node3D                  # коляска с героем (в салоне — ребёнок кузова, снаружи — мира)
var head: Node3D
var cam: Camera3D
var torch: SpotLight3D
var building: Node3D
var phase := "load"
var s := 0.0
var v := 0.0
var s_stop := 0.0
var s_start := 0.0
var time := 0.0
var day := 0.0                    # 0 — пасмурный день, 1 — ночь
var look_yaw := 0.0
var look_pitch := -0.05
var walk_s := 0.0                 # где герой на тропинке (м от остановки)
var mom_s := 0.0
var talked := false
var talking := false
var mom_speaking := false         # пока мама говорит — анимация разговора, иначе спокойная стойка
var _skip := false
var _bus_away := false
var _bus_v := 0.0
var _events := {}
var _event_busy := false
var chair_model
var _drone: AudioStreamPlayer
var _mom_hold := false
var site_xf: Transform3D          # координаты здания → мир
var forest_count := 0             # сколько точек в лесной тропинке (дальше — маршрут к двери)
var forest_end_s := 0.0
var door_stop_s := 0.0
var mom_stop_s := 0.0             # тут мама сходит с маршрута к своему месту у двери
var guided := false               # на пандусе коляска едет по маршруту сама (W / S), руль не нужен
var _g_off := Vector3.ZERO        # плавный переход с тропинки на маршрут
var entrance                      # story/entrance_door.gd
var door_open := false
var _door_busy := false
var _preload := false
var _mom_aside := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF    # всё здесь движется в _process
	GameState.set_fade(1.0)
	ui = StoryUI.new()
	add_child(ui)
	ui.line_skipped.connect(_on_skip)
	GameState.set_loading(true, "Загрузка леса…")
	await get_tree().process_frame
	await get_tree().process_frame
	_build_world()
	_build_bus()
	_build_hero()
	_build_mom()
	_build_stop()
	_build_building()
	audio = Audio.new()
	add_child(audio)
	_drone = AudioStreamPlayer.new()
	var ds: AudioStreamWAV = (load("res://story/sfx/drone_low.wav") as AudioStreamWAV).duplicate()
	ds.loop_mode = AudioStreamWAV.LOOP_FORWARD
	ds.loop_end = int(ds.get_length() * ds.mix_rate)
	_drone.stream = ds
	_drone.volume_db = -60.0
	add_child(_drone)
	_drone.play()
	_apply_graphics(GraphicsSettings.settings)
	GraphicsSettings.changed.connect(_apply_graphics)
	_update_globals()
	terrain.update_lods(cam.global_position, true)
	forest.lod_manager.update_now(cam)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	phase = "ride"
	_ride_story()


func _on_skip() -> void:
	_skip = true


# ================================================================================ мир
func _build_world() -> void:
	var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://resources/world/world.json"))
	terrain.load_world(meta)
	road.build(JSON.parse_string(FileAccess.get_file_as_string(str(meta["road"]))))
	forest.build(meta, terrain)
	site = JSON.parse_string(FileAccess.get_file_as_string("res://resources/world/story_site.json"))
	for p in site["path"]:
		path.append(Vector3(float(p[0]), float(p[1]), float(p[2])))
	forest_count = path.size()
	var b: Dictionary = site["building"]
	site_xf = Transform3D(Basis(Vector3.UP, float(b["yaw"])), Vector3(float(b["origin"][0]), float(b["origin"][1]), float(b["origin"][2])))
	# дальше тропинка продолжается маршрутом коляски: вдоль пандуса, вверх с разворотом, к двери и в тамбур
	var route: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://resources/world/entrance_route.json"))
	if route is Dictionary:
		for q in route["points"]:
			var w: Vector3 = site_xf * Vector3(float(q[0]), float(q[1]), float(q[2]))
			if int(q[3]) == 1:
				w.y = terrain.height_at(w.x, w.z)
			if w.distance_to(path[-1]) > 0.05:
				path.append(w)
	var acc := 0.0
	path_cum.append(0.0)
	for i in range(1, path.size()):
		acc += (path[i] - path[i - 1]).length()
		path_cum.append(acc)
	forest_end_s = path_cum[forest_count - 1]
	door_stop_s = path_cum[-1]
	mom_stop_s = path_cum[-1]
	var inv: Transform3D = site_xf.affine_inverse()
	for i in range(path.size() - 1, forest_count - 1, -1):
		var lp: Vector3 = inv * (path[i] as Vector3)
		if lp.y > 1.0 and lp.x >= DOOR_STOP_X:
			door_stop_s = path_cum[i]
		if lp.y > 1.0 and lp.x >= 24.6:
			mom_stop_s = path_cum[i]
	s_stop = float(site["stop"]["s"]) - 1.5
	s_start = fposmod(s_stop - RIDE_DISTANCE, road.length)
	s = s_start
	# небо, туман, солнце: основа — настройки леса forest_drive (main.tscn), но пасмурно, сырой туман
	# предгорий, вечер переходит в ночь. Туман «по глубине» начинается в 10 м — в салоне воздух чистый.
	sky_mat = ProceduralSkyMaterial.new()
	sky_mat.sky_curve = 0.11
	sky_mat.ground_curve = 0.05
	sky_mat.sun_curve = 0.06
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.0
	env.ssao_enabled = true
	env.ssao_radius = 1.4
	env.ssao_intensity = 1.8
	env.ssao_power = 1.4
	env.ssao_detail = 0.6
	env.ssao_horizon = 0.06
	env.ssao_light_affect = 0.0
	env.ssao_ao_channel_affect = 0.35
	env.ssil_enabled = true
	env.ssil_radius = 4.0
	env.ssil_intensity = 0.5
	env.glow_enabled = true
	env.glow_intensity = 0.28
	env.glow_strength = 0.9
	env.glow_bloom = 0.03
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	env.glow_hdr_threshold = 1.1
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_depth_curve = 1.5
	env.fog_sky_affect = 1.0
	env.fog_sun_scatter = 0.0                  # без светлого пятна вокруг солнца в тумане
	env.fog_aerial_perspective = 0.4
	env.fog_height = -3.0
	env.fog_height_density = 0.04
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.008
	env.volumetric_fog_albedo = Color(0.9, 0.92, 0.93)
	env.volumetric_fog_anisotropy = 0.15
	env.volumetric_fog_length = 90.0
	env.volumetric_fog_detail_spread = 1.6
	env.volumetric_fog_ambient_inject = 0.12
	env.volumetric_fog_sky_affect = 0.0
	env.volumetric_fog_temporal_reprojection_enabled = true
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.08
	# цвет: тени — в холодный зелёно-серый, света — в старую бумагу (как плёнка 70-х)
	var grade := Gradient.new()
	grade.set_color(0, Color(0.0, 0.015, 0.02))
	grade.set_color(1, Color(1.0, 0.97, 0.9))
	grade.add_point(0.45, Color(0.42, 0.45, 0.44))
	var lut := GradientTexture1D.new()
	lut.gradient = grade
	lut.width = 256
	env.adjustment_color_correction = lut
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	sun.shadow_blur = 2.0
	sun.directional_shadow_max_distance = 90.0
	sun.directional_shadow_blend_splits = true
	sun.light_angular_distance = 2.5          # пасмурно: мягкие расплывчатые тени
	# пасмурно: самого диска солнца (и луны) на небе нет — иначе сквозь туман в окне автобуса висит белый круг
	sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	sun.light_specular = 0.35                 # без яркой полосы-блика на рамах окон
	sun.light_volumetric_fog_energy = 0.35
	add_child(sun)
	forest.lod_manager.sun_light = sun
	set_day(0.0)


# время: [t, высота солнца/луны °, цвет света, сила, верх неба, горизонт, туман, конец тумана м, рассеянный, насыщенность]
const DAY_KEYS := [
	[0.0, 17.0, Color(1.0, 0.95, 0.88), 1.15, Color(0.46, 0.51, 0.56), Color(0.70, 0.72, 0.72), Color(0.62, 0.65, 0.66), 175.0, 1.0, 0.72],
	[0.38, 7.0, Color(1.0, 0.74, 0.5), 1.0, Color(0.42, 0.45, 0.53), Color(0.78, 0.64, 0.54), Color(0.62, 0.56, 0.52), 150.0, 1.05, 0.72],
	[0.6, 3.0, Color(1.0, 0.58, 0.4), 0.65, Color(0.40, 0.44, 0.56), Color(0.74, 0.6, 0.55), Color(0.56, 0.51, 0.5), 125.0, 0.9, 0.68],
	# дальше не ночь, а поздние синие сумерки: небо светлее земли, лес и здание видно без фонаря.
	# Небо почти целиком закрыто туманом (fog_sky_affect), поэтому его цвет задаёт в основном цвет тумана.
	[0.8, 25.0, Color(0.66, 0.74, 0.9), 0.3, Color(0.30, 0.35, 0.5), Color(0.56, 0.56, 0.64), Color(0.42, 0.45, 0.54), 110.0, 0.75, 0.7],
	[1.0, 32.0, Color(0.66, 0.74, 0.92), 0.32, Color(0.24, 0.28, 0.42), Color(0.46, 0.47, 0.56), Color(0.34, 0.36, 0.45), 95.0, 0.62, 0.66],
]


## 0 — пасмурный серый день в тумане, 0.38 — вечер у остановки, 1 — глубокие сумерки у санатория (свет — луна).
func set_day(t: float) -> void:
	day = clampf(t, 0.0, 1.0)
	var i: int = 1
	while i < DAY_KEYS.size() - 1 and day > float(DAY_KEYS[i][0]):
		i += 1
	var a: Array = DAY_KEYS[i - 1]
	var b: Array = DAY_KEYS[i]
	var k: float = clampf((day - float(a[0])) / maxf(float(b[0]) - float(a[0]), 0.0001), 0.0, 1.0)
	var moon: bool = day > 0.7
	var az: float = 150.0 if moon else -40.0
	sun.rotation_degrees = Vector3(-lerpf(float(a[1]), float(b[1]), k), az, 0.0)
	sun.light_color = (a[2] as Color).lerp(b[2], k)
	# солнце сменяется луной в сумерках, когда свет почти пропал (без скачка теней)
	sun.light_energy = lerpf(float(a[3]), float(b[3]), k) * clampf(absf(day - 0.7) / 0.05, 0.0, 1.0)
	sun.visible = sun.light_energy > 0.01
	var top: Color = (a[4] as Color).lerp(b[4], k)
	var hor: Color = (a[5] as Color).lerp(b[5], k)
	sky_mat.sky_top_color = top
	sky_mat.sky_horizon_color = hor
	sky_mat.ground_horizon_color = hor.darkened(0.15)
	sky_mat.ground_bottom_color = hor.darkened(0.6)
	sky_mat.sun_angle_max = 35.0 if not moon else 3.0
	env.fog_light_color = (a[6] as Color).lerp(b[6], k)
	env.fog_depth_begin = 10.0
	env.fog_depth_end = lerpf(float(a[7]), float(b[7]), k)
	env.fog_density = 0.94
	env.ambient_light_energy = lerpf(float(a[8]), float(b[8]), k)
	env.adjustment_saturation = lerpf(float(a[9]), float(b[9]), k)
	env.volumetric_fog_albedo = Color(0.9, 0.92, 0.93).lerp(Color(0.3, 0.32, 0.38), smoothstep(0.5, 1.0, day))
	# сумерки: небо и дымка ещё светятся (иначе туман и цветокоррекция делают небо почти чёрным)
	var dusk: float = smoothstep(0.5, 0.9, day)
	sky_mat.energy_multiplier = 1.0 + 0.9 * dusk
	env.fog_light_energy = 1.0 + 1.15 * dusk
	env.volumetric_fog_ambient_inject = lerpf(0.12, 0.8, dusk)
	env.volumetric_fog_emission = Color(0.36, 0.4, 0.48)               # дымка светится, как в лунном тумане
	env.volumetric_fog_emission_energy = 0.55 * dusk


func _apply_graphics(st: Dictionary) -> void:
	env.ssao_enabled = st["ssao"]
	env.ssil_enabled = st["ssil"]
	env.glow_enabled = st["glow"]
	env.volumetric_fog_enabled = st["volumetric_fog"]
	sun.directional_shadow_max_distance = minf(float(st["shadow_distance"]), 90.0)
	RenderingServer.global_shader_parameter_set("far_shadow", Vector2(float(st["shadow_distance"]) * 0.75, float(st["shadow_distance"]) * 0.98))
	RenderingServer.global_shader_parameter_set("shadow_coarse", bool(st["shadow_coarse"]))
	if cam:
		cam.far = minf(float(st["far_plane"]), 700.0)
	terrain.lod_scale = st["terrain_lod_scale"]
	terrain.near_chunk_shadows = int(st["preset"]) >= GraphicsSettings.Preset.HIGH
	for c in terrain.chunks:
		c["lod"] = -1
	if cam:
		terrain.update_lods(cam.global_position, true)
	(terrain.material as ShaderMaterial).set_shader_parameter("anti_tiling", st["terrain_anti_tiling"])
	forest.configure(st)


func _update_globals() -> void:
	RenderingServer.global_shader_parameter_set("main_camera_pos", cam.global_position)
	RenderingServer.global_shader_parameter_set("wind", Vector4(0.8, 0.6, 0.45, 1.0))
	RenderingServer.global_shader_parameter_set("wetness", 0.35)


# ================================================================================ автобус, люди
func _build_bus() -> void:
	bus = Bus.new()
	add_child(bus)
	bus.build()
	var res: Resource = load("res://intro/assets/models/bus.glb")
	if res is PackedScene:
		bus.use_model(res)
	bus.set_led("107  Санаторий «Оромгох»")
	if bus.stop_button:
		bus.stop_button.visible = false
	# в салоне нет тумана (объёмный туман вычитается коробкой по размеру кузова)
	var clear := FogVolume.new()
	clear.size = Vector3(2.5, 2.6, 10.6)
	clear.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
	var fm := FogMaterial.new()
	fm.density = -1.0
	clear.material = fm
	bus.body.add_child(clear)
	clear.position = Vector3(0, 1.9, 0)
	# свет в салоне свой: рассеянный — тусклый, холодный (не как на улице), без отражений неба
	var probe := ReflectionProbe.new()
	probe.size = Vector3(2.5, 2.7, 10.6)
	probe.interior = true
	probe.box_projection = true
	probe.ambient_mode = ReflectionProbe.AMBIENT_COLOR
	probe.ambient_color = Color(0.6, 0.64, 0.68)
	probe.ambient_color_energy = 0.42             # свет только из окон: салон чуть темнее улицы
	probe.intensity = 0.0                         # без отражений из пробы (в стекле не было бы белого круга)
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	bus.body.add_child(probe)
	probe.position = Vector3(0, 1.9, 0)
	# плафоны выключены: днём в салоне светло только от окон, туман за окном виден лучше
	for l in bus.body.get_children():
		if l is OmniLight3D:
			(l as OmniLight3D).visible = false
	# стёкла без зеркального пятна: иначе в форточке висит белый круг (отражение светлого неба)
	for mi in bus.body.find_children("Glass_*", "MeshInstance3D", true, false):
		var gm: MeshInstance3D = mi
		for si in gm.mesh.get_surface_count():
			var gmat: Material = gm.get_active_material(si)
			if gmat is BaseMaterial3D:
				var g2: BaseMaterial3D = (gmat as BaseMaterial3D).duplicate()
				g2.metallic_texture = null
				g2.roughness_texture = null
				g2.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED   # просто лёгкий оттенок, без бликов
				g2.albedo_color = Color(0.5, 0.58, 0.56, 0.12)
				gm.set_surface_override_material(si, g2)
	# …и сами плафоны не светятся (иначе их белый круг отражается в стекле окна)
	for mi in bus.body.find_children("*Plafond*", "MeshInstance3D", true, false):
		var m3: MeshInstance3D = mi
		for si in m3.mesh.get_surface_count():
			var mat: Material = m3.get_active_material(si)
			if mat is BaseMaterial3D:
				var off: BaseMaterial3D = (mat as BaseMaterial3D).duplicate()
				off.emission_enabled = false
				off.albedo_color = off.albedo_color.darkened(0.25)
				m3.set_surface_override_material(si, off)
	_place_bus(0.0)
	for pair in [["driver", "anchor_driver"], ["grandma_scarf", "seat_13_w_r"], ["man_newspaper", "seat_11_a"],
			["mother_baby", "seat_19_s"]]:
		var p: String = "res://intro/assets/models/people/%s.glb" % pair[0]
		if not bus.anchor_xf.has(pair[1]) or not ResourceLoader.exists(p):
			continue
		var m: Node3D = (load(p) as PackedScene).instantiate()
		bus.body.add_child(m)
		m.transform = bus.anchor_xf[pair[1]]


func _road_xf(dist: float, lateral: float) -> Transform3D:
	var xf: Transform3D = road.sample(dist, 0.0)
	xf.origin += xf.basis.x.normalized() * lateral
	xf.origin.y = road.sample(dist, lateral).origin.y
	return xf


func _lane_at(dist: float) -> float:
	var d: float = s_stop - dist
	if d < -400.0:
		d += road.length
	return lerpf(LANE, STOP_LANE, clampf(1.0 - absf(d) / 60.0, 0.0, 1.0)) if phase != "away" else LANE


func _place_bus(dt: float) -> void:
	var xf: Transform3D = _road_xf(s, _lane_at(s))
	bus.global_transform = xf
	var ahead: Transform3D = road.sample(s + 6.0, 0.0)
	var behind: Transform3D = road.sample(s - 6.0, 0.0)
	var turn: float = (-behind.basis.z).signed_angle_to(-ahead.basis.z, Vector3.UP) / 12.0
	bus.update(dt, v, 0.0, -turn, time)


func _curvature(dist: float) -> float:
	var a: Vector3 = -road.sample(dist - 8.0, 0.0).basis.z
	var b: Vector3 = -road.sample(dist + 8.0, 0.0).basis.z
	return absf(a.signed_angle_to(b, Vector3.UP)) / 16.0


func _build_hero() -> void:
	hero = Node3D.new()
	hero.name = "Hero"
	bus.body.add_child(hero)
	hero.position = HERO_IN_BUS
	hero.rotation.y = PI * 0.5                       # лицом к окну (за окном туман), мама — слева
	# своя коляска (джойстик наклоняется при езде); тени не отбрасывает — иначе рука закрывает луч фонаря
	chair_model = ChairModel.new()
	chair_model.build(hero)
	head = Node3D.new()
	head.position = EYE
	hero.add_child(head)
	cam = Camera3D.new()
	cam.fov = 72.0
	cam.near = 0.05
	cam.far = 700.0
	head.add_child(cam)
	cam.make_current()
	torch = SpotLight3D.new()
	torch.light_color = Color(1.0, 0.9, 0.74)
	torch.light_energy = 28.0
	torch.spot_range = 32.0
	torch.spot_angle = 24.0
	torch.spot_angle_attenuation = 0.8
	torch.light_volumetric_fog_energy = 1.2
	torch.light_specular = 0.4
	torch.shadow_enabled = true
	torch.shadow_bias = 0.05
	torch.rotation.x = -0.14                     # чуть вниз — на тропинку
	torch.visible = false
	torch.position = Vector3(0.18, -0.25, -0.1)
	cam.add_child(torch)


func _build_mom() -> void:
	mom = Actor.new()
	mom.name = "Barno"
	bus.body.add_child(mom)
	mom.setup("res://characters/mom.glb")
	mom.position = MOM_IN_BUS
	mom.set_yaw(PI * 0.5)                             # тоже смотрит в окно
	mom.play("idle_loop")


# ================================================================================ остановка и санаторий
func _build_stop() -> void:
	var xf: Transform3D = _road_xf(float(site["stop"]["s"]) + 7.0, 6.2)
	var root := Node3D.new()
	root.name = "BusStop"
	add_child(root)
	root.global_transform = Transform3D(Basis(Vector3.UP, atan2(xf.basis.x.x, xf.basis.x.z) - PI * 0.5), xf.origin)
	var conc := Props.mat(Color(0.55, 0.54, 0.5), 0.95)
	var mosaic := Props.mat(Color(0.25, 0.45, 0.58), 0.6)
	var red := Props.mat(Color(0.6, 0.18, 0.14), 0.7)
	Props.box(root, Vector3(0, 0.05, 0), Vector3(2.6, 0.18, 6.0), conc)
	Props.box(root, Vector3(1.05, 1.35, 0), Vector3(0.18, 2.6, 5.2), conc)
	Props.box(root, Vector3(0.95, 1.6, 0), Vector3(0.02, 1.4, 4.4), mosaic)
	for i in 6:
		Props.box(root, Vector3(0.93, 1.1 + 0.18 * (i % 3), -1.8 + i * 0.72), Vector3(0.02, 0.12, 0.5), red if i % 2 == 0 else conc)
	Props.box(root, Vector3(0.3, 2.72, 0), Vector3(1.9, 0.14, 5.6), conc)
	Props.box(root, Vector3(0.55, 0.45, 0), Vector3(0.4, 0.08, 3.6), Props.mat(Color(0.32, 0.22, 0.14), 0.8))
	var pole := Props.cyl(root, Vector3(-1.0, 1.25, 3.2), 0.04, 2.5, Props.mat(Color(0.5, 0.5, 0.5), 0.5, 0.6))
	pole.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var sign := Label3D.new()
	sign.text = "А\nСанаторий\n«Оромгох»"
	sign.font_size = 42
	sign.pixel_size = 0.004
	sign.modulate = Color(0.1, 0.1, 0.1)
	sign.outline_size = 0
	sign.position = Vector3(-1.0, 2.3, 3.2)
	sign.rotation.y = -PI * 0.5
	root.add_child(sign)
	var plate := Props.box(root, Vector3(-1.01, 2.3, 3.2), Vector3(0.02, 0.5, 0.42), Props.mat(Color(0.92, 0.9, 0.8), 0.6))
	plate.position.x -= 0.0
	# табличка у начала тропинки
	var p0: Vector3 = path[min(3, path.size() - 1)]
	var arrow := Label3D.new()
	arrow.text = "Санаторий «Оромгох» →\n120 м"
	arrow.font_size = 40
	arrow.pixel_size = 0.004
	arrow.modulate = Color(0.95, 0.93, 0.85)
	arrow.outline_size = 6
	arrow.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	add_child(arrow)
	arrow.global_position = p0 + Vector3(1.4, 1.5, 0)


func _build_building() -> void:
	var res: Resource = load("res://sanatorium/assets/sanatorium.glb")
	if not (res is PackedScene):
		return
	building = (res as PackedScene).instantiate() as Node3D
	add_child(building)
	var b: Dictionary = site["building"]
	building.global_position = Vector3(float(b["origin"][0]), float(b["origin"][1]), float(b["origin"][2]))
	building.rotation.y = float(b["yaw"])
	var interior: Node = building.find_child("Interior", true, false)
	if interior:
		# внутри — отдельная сцена; здесь только тамбур и вестибюль за входной дверью (в них заезжаем)
		for room_name in KEEP_ROOMS:
			var room: Node = interior.find_child(room_name, true, false)
			if room:
				room.reparent(building, true)
		interior.queue_free()
	var broken: Node = building.find_child("Fix_0029", true, false)      # этот плафон в здании перегорел
	if broken:
		broken.queue_free()
	var wall: Node = building.find_child("Lobby_CurtainWall_Doors", true, false)
	if wall is MeshInstance3D:
		entrance = EntranceDoor.new()
		add_child(entrance)
		if not entrance.build(wall):
			entrance = null
	door_open = entrance == null
	var lamp_col: Color = Color(1.0, 0.83, 0.62).lerp(Color(1.0, 0.85, 0.6), 0.18)
	for lp in VEST_LAMPS:
		var ol := OmniLight3D.new()
		ol.light_color = lamp_col
		ol.light_energy = 70.0 / 44.0 * 0.5
		ol.omni_range = 6.0
		ol.omni_attenuation = 1.0
		ol.light_specular = 0.35
		ol.light_volumetric_fog_energy = 0.5
		building.add_child(ol)
		ol.position = lp
	# внутри воздух без уличной дымки (как в автобусе)
	var clear := FogVolume.new()
	clear.size = Vector3(8.2, 3.4, 13.4)
	clear.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
	var fm := FogMaterial.new()
	fm.density = -1.0
	clear.material = fm
	building.add_child(clear)
	clear.position = Vector3(31.6, 2.75, 6.3)
	# внутри свой рассеянный свет (не небо): тускло-тёплый, как в здании
	var probe := ReflectionProbe.new()
	probe.size = Vector3(8.0, 3.2, 14.0)
	probe.interior = true
	probe.box_projection = true
	probe.ambient_mode = ReflectionProbe.AMBIENT_COLOR
	probe.ambient_color = Color(0.5, 0.47, 0.42)
	probe.ambient_color_energy = 0.25
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	building.add_child(probe)
	probe.position = Vector3(31.6, 2.7, 6.0)
	# одно горящее окно на 2-м этаже (палата деда)
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.78, 0.45)
	l.light_energy = 2.5
	l.omni_range = 5.0
	building.add_child(l)
	l.position = Vector3(9.0, 6.0, -1.6)


# ================================================================================ сюжет поездки
func say(who: String, text: String, sec := 0.0) -> void:
	_skip = false
	talking = who == "mom" or who == "hero"
	mom_speaking = who == "mom"
	if mom_speaking and (phase == "ride" or phase == "arrive"):
		mom.play("talk_loop", 0.35)
	var t: float = ui.say(who, text, sec)
	while t > 0.0 and not _skip:
		await get_tree().process_frame
		if not get_tree().paused:
			t -= get_process_delta_time()
	_skip = false
	ui.hide_line()
	talking = false
	if mom_speaking and (phase == "ride" or phase == "arrive"):
		mom.play("idle_loop", 0.45)
	mom_speaking = false


func wait(sec: float) -> void:
	await get_tree().create_timer(sec, false).timeout


func _ride_story() -> void:
	await GameState.fade_to(0.0, 2.5)
	await ui.title("THE LAST SHAKE", "Последний Скачок · Soʻnggi Silkiniş", 2.5, 72)
	ui.set_objective("Поговори с мамой — наведи на неё взгляд и нажми E")
	ui.hint("Мышь — осмотреться   ·   E — поговорить (посмотри на маму)   ·   Tab — ускорить поездку   ·   Esc — меню", 9.0)
	await wait(1.5)
	await say("thought", "Опять этот туман. Даже дороги не видно.")


func _talk() -> void:
	if talked or talking:
		return
	talked = true
	ui.set_objective("")
	ui.set_prompt("")
	await say("hero", "Мам… А дедушка вообще знает, что мы едем?")
	await say("mom", "Знает.")
	await say("hero", "Ты ему звонила? Он же не любит, когда без предупреждения.")
	await wait(1.2)
	await say("mom", "Он нас ждёт, Саман.")
	await say("hero", "Почему его увезли так далеко? Тут же на сто километров никого.")
	await say("mom", "Врачи так решили. Там тихо.")
	await wait(1.5)
	await say("hero", "Ты с утра на меня даже не смотришь. Что-то случилось?")
	await say("mom", "Хватит. Смотри в окно. Скоро выходим.")
	ui.set_objective("Едем к деду в санаторий «Оромгох»")


func _arrival() -> void:
	phase = "arrive"
	ui.set_prompt("")
	await say("driver", "«Оромгох»… Вам точно сюда? Там же давно никого нет.")
	await say("mom", "Нам сюда.")
	if not talked:
		await say("mom", "Саман, выходим.")
	bus.door_open["middle"] = 0.0
	audio.play_sfx("hiss", 0.8)
	var tw := create_tween()
	tw.tween_method(_set_door, 0.0, 1.0, 1.6)
	await tw.finished
	await GameState.fade_to(1.0, 1.2)
	audio.play_sfx("ramp", 0.6)
	await wait(1.5)
	audio.set_motor(0.6)
	await wait(1.4)
	audio.set_motor(0.0)
	_go_outside()


func _set_door(f: float) -> void:
	bus.door_open["middle"] = f
	bus.door_open["front"] = f


func _go_outside() -> void:
	phase = "walk"
	ui.hide_line()
	# герой и мама — на остановке, у начала тропинки
	hero.reparent(self, false)
	hero.global_position = path[0]
	var d0: Vector3 = (path[4] - path[0]).normalized()
	hero.rotation = Vector3(0.0, atan2(-d0.x, -d0.z), 0.0)
	look_yaw = 0.0
	look_pitch = -0.05
	mom.reparent(self, false)
	mom_s = 3.0
	mom.global_position = _path_at(mom_s)
	mom.set_arm(null)
	mom.set_look(null)
	walk_s = 0.0
	set_day(0.45)
	audio.set_forest(0.0, 0.2)
	await wait(0.6)
	await GameState.fade_to(0.0, 1.5)
	_depart_bus()
	await say("mom", "Тут недалеко. Не отставай.")
	ui.set_objective("Езжай за мамой по тропинке к санаторию")
	ui.hint("W / S — ехать   ·   A / D — повернуть   ·   Shift — быстрее   ·   F — фонарик", 7.0)


func _depart_bus() -> void:
	audio.play_sfx("hiss", 0.6)
	var tw := create_tween()
	tw.tween_method(_set_door, 1.0, 0.0, 1.4)
	await tw.finished
	await wait(0.8)
	_bus_away = true
	_bus_v = 0.0


# ================================================================================ тропинка
func _path_at(dist: float) -> Vector3:
	dist = clampf(dist, 0.0, path_cum[-1])
	var i: int = path_cum.bsearch(dist)
	i = clampi(i, 1, path.size() - 1)
	var a: float = path_cum[i - 1]
	var b: float = path_cum[i]
	var f: float = (dist - a) / maxf(b - a, 0.0001)
	return (path[i - 1] as Vector3).lerp(path[i], f)


## Ближайшая точка тропинки: [расстояние от начала, точка].
func _path_nearest(p: Vector3) -> Array:
	var best := INF
	var bs := 0.0
	var bp: Vector3 = path[0]
	var lo: int = maxi(1, path_cum.bsearch(walk_s) - 12)
	var hi: int = mini(forest_count, lo + 30)                  # только лесная тропинка (дальше — маршрут)
	for i in range(lo, hi):
		var a: Vector3 = path[i - 1]
		var b: Vector3 = path[i]
		var ab := Vector3(b.x - a.x, 0, b.z - a.z)
		var t: float = clampf(Vector3(p.x - a.x, 0, p.z - a.z).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
		var q: Vector3 = a.lerp(b, t)
		var dd: float = Vector2(p.x - q.x, p.z - q.z).length_squared()
		if dd < best:
			best = dd
			bs = path_cum[i - 1] + (path_cum[i] - path_cum[i - 1]) * t
			bp = q
	return [bs, bp]


func _walk_events() -> void:
	_event_busy = true
	await _walk_event()
	_event_busy = false


func _walk_event() -> void:
	if walk_s > 25.0 and not _events.has("crow"):
		_events["crow"] = true
		audio.play_sfx("crow", 0.7)
		await say("hero", "Как тихо… Даже птиц не слышно.")
		await say("mom", "Не останавливайся.")
	elif walk_s > 55.0 and not _events.has("snap"):
		_events["snap"] = true
		audio.play_sfx("snap", 0.9)
		_mom_hold = true
		mom.face(path[0])
		mom.set_look(path[0] + Vector3(0, 1.5, 0))
		await say("mom", "Тихо.")
		await wait(1.4)
		await say("hero", "Что? Там кто-то есть?")
		await wait(0.8)
		mom.set_look(null)
		await say("mom", "Зверь, наверное. Пошли.")
		_mom_hold = false
	elif walk_s > 70.0 and not _events.has("dark"):
		_events["dark"] = true
		if not torch.visible:
			await say("mom", "Темнеет. Включи фонарь, он у тебя на коляске.")
			ui.hint("F — фонарик", 5.0)
	elif walk_s > 92.0 and not _events.has("building"):
		_events["building"] = true
		await say("mom", "Вот он.")
		await say("hero", "Мам… Тут окна выбиты. Здесь вообще кто-нибудь лечится?")
		await say("mom", "Поднимайся по пандусу. Дедушка ждёт.")
	elif guided and _mom_aside and walk_s > door_stop_s - 3.5 and not _events.has("door"):
		_events["door"] = true
		mom.set_look(head.global_position)
		await say("mom", "Открывай. Я за тобой.")
		mom.set_look(null)


# ================================================================================ кадр
func _process(dt: float) -> void:
	if phase == "load" or get_tree().paused:
		return
	time += dt
	if phase == "ride" or phase == "arrive":
		_update_ride(dt)
	elif phase == "walk" or phase == "end":
		_update_walk(dt)
	if _bus_away:
		_bus_v = minf(_bus_v + 0.9 * dt, 11.0)
		s += _bus_v * dt
		_place_bus(dt)
		audio.engine_gain = clampf(1.0 - bus.global_position.distance_to(hero.global_position) / 120.0, 0.0, 1.0) * 0.8
		audio.update(_bus_v, 0.9, true)
		if bus.global_position.distance_to(hero.global_position) > 260.0:
			_bus_away = false
			bus.visible = false
			audio.fade_engine_out()
	head.rotation = Vector3(look_pitch, look_yaw, 0.0)
	_update_globals()
	terrain.update_lods(cam.global_position)
	forest.lod_manager.update(cam)


func _update_ride(dt: float) -> void:
	var k: float = FAST if Input.is_action_pressed("fast_forward") and phase == "ride" else 1.0
	var sdt: float = dt * k
	var left: float = fposmod(s_stop - s, road.length)
	if left > road.length - 50.0:
		left = 0.0
	var vmax: float = minf(CRUISE, sqrt(LAT_ACC / maxf(_curvature(s + v * 2.5), 0.0001)))
	vmax = minf(vmax, sqrt(2.0 * DECEL * maxf(left - 0.5, 0.0)))
	var acc: float = ACCEL if v < vmax else -DECEL * 1.3
	v = clampf(v + acc * sdt, 0.0, maxf(vmax, 0.0))
	s += v * sdt
	_place_bus(dt)
	audio.update(v, acc, true)
	audio.set_forest(1.0, 0.0)
	set_day(lerpf(0.0, 0.38, 1.0 - left / RIDE_DISTANCE))
	if phase == "ride" and left < 0.6 and v < 0.05:
		v = 0.0
		_arrival()
	# коляска стоит на месте (на тормозе) — в автобусе не ездим, только смотрим
	chair_model.set_input(0.0, 0.0, dt)
	# мама стоит рядом: смотрит в окно — а в разговоре на сына
	if talking:
		mom.set_look(head.global_position)
	else:
		var base: Vector3 = mom.position
		var drift := Vector3(sin(time * 0.13) * 0.6, sin(time * 0.21) * 0.25, cos(time * 0.17) * 0.8)
		mom.set_look(bus.body.to_global(base + Vector3(-3.8, 1.4, -0.4) + drift))
	# навести взгляд на маму → E
	var to: Vector3 = mom.head_pos() - cam.global_position
	var aimed: bool = to.length() < 2.8 and (-cam.global_transform.basis.z).dot(to.normalized()) > 0.96
	ui.set_prompt("[E] Поговорить с мамой" if aimed and not talked and not talking and phase == "ride" else "")
	if aimed and Input.is_action_just_pressed("interact") and phase == "ride":
		_talk()


func _update_walk(dt: float) -> void:
	if phase == "end":
		return
	var drive: float = Input.get_action_strength("drive_forward") - Input.get_action_strength("drive_back")
	var turn: float = Input.get_action_strength("turn_left") - Input.get_action_strength("turn_right")
	if guided:
		_drive_guided(dt, drive)
	else:
		_drive_free(dt, drive, turn)
	# темнеет по мере продвижения по лесу (и просто со временем)
	set_day(maxf(day, lerpf(0.45, 0.88, minf(walk_s / maxf(forest_end_s, 1.0), 1.0))))
	set_day(day + dt * 0.0006)
	audio.set_forest(0.0, day)
	_drone.volume_db = lerpf(-40.0, -15.0, smoothstep(0.45, 0.9, day))
	_update_mom_walk(dt)
	if guided and not door_open and not _door_busy and _mom_aside and walk_s > door_stop_s - 0.6:
		ui.set_prompt("[E] Открыть дверь")
		if Input.is_action_just_pressed("interact"):
			_open_entrance()
	elif not _door_busy:
		ui.set_prompt("")
	if guided and door_open and walk_s >= path_cum[-1] - 0.03:
		_enter_building()
		return
	if not talking and not _event_busy:
		_walk_events()


## По тропинке: едешь сам (W A S D), но не дальше 1,6 м от неё.
func _drive_free(dt: float, drive: float, turn: float) -> void:
	var spd: float = WALK_SPEED * (1.5 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	hero.rotation.y += turn * 1.5 * dt
	hero.rotation.x = lerpf(hero.rotation.x, 0.0, 1.0 - exp(-8.0 * dt))
	var fwd: Vector3 = -hero.global_transform.basis.z
	var p: Vector3 = hero.global_position + Vector3(fwd.x, 0, fwd.z).normalized() * drive * spd * (0.5 if drive < 0.0 else 1.0) * dt
	var near: Array = _path_nearest(p)
	walk_s = float(near[0])
	var q: Vector3 = near[1]
	var off := Vector3(p.x - q.x, 0, p.z - q.z)
	if off.length() > PATH_HALF:
		off = off.normalized() * PATH_HALF
	p = Vector3(q.x + off.x, 0.0, q.z + off.z)
	p.y = lerpf(q.y, terrain.height_at(p.x, p.z), clampf(off.length() / PATH_HALF, 0.0, 1.0))
	# маму не обогнать: тропинка узкая, сквозь неё не проехать — едешь следом
	if not _mom_aside and walk_s > mom_s - 1.1:
		walk_s = maxf(mom_s - 1.1, 0.0)
		var q2: Vector3 = _path_at(walk_s)
		p = Vector3(q2.x + off.x, 0.0, q2.z + off.z)
		p.y = lerpf(q2.y, terrain.height_at(p.x, p.z), clampf(off.length() / PATH_HALF, 0.0, 1.0))
	hero.global_position = p
	chair_model.set_input(drive, -turn, dt)
	audio.set_motor(absf(drive) * 0.8 + absf(turn) * 0.3)
	# конец тропинки: дальше — пандус, коляска поедет по маршруту
	if walk_s >= forest_end_s - 0.35 and drive > 0.05:
		guided = true
		_g_off = Vector3(p.x - q.x, 0.0, p.z - q.z)
		ui.set_objective("Поднимись по пандусу ко входу", site_xf * DOOR_POINT, Vector3(0, 0.6, 0))
		ui.hint("W — ехать по пандусу   ·   S — назад   ·   мышь — смотреть", 6.0)
		if not _preload:
			_preload = true
			ResourceLoader.load_threaded_request(GameState.SANATORIUM)     # здание грузится заранее


## По пандусу: коляска едет по маршруту (W — вперёд, S — назад) и сама поворачивает на развороте,
## наклоняясь по уклону. Мышью можно смотреть по сторонам.
func _drive_guided(dt: float, drive: float) -> void:
	var limit: float = path_cum[-1] if door_open else door_stop_s
	if not _mom_aside:
		limit = minf(limit, mom_s - 1.2)                 # мама впереди на пандусе — не наехать на неё
	limit = maxf(limit, forest_end_s - 1.2)
	var spd: float = RAMP_SPEED * (0.6 if drive < 0.0 else 1.0)
	var ns: float = clampf(walk_s + drive * spd * dt, forest_end_s - 1.2, limit)
	var moved: float = absf(ns - walk_s)
	walk_s = ns
	_g_off *= exp(-moved * 1.4)
	var p: Vector3 = _path_at(walk_s) + _g_off
	hero.global_position = p
	# куда смотрит коляска: по касательной к маршруту чуть впереди (плавно, только пока едет)
	var ahead: Vector3 = _path_at(walk_s + 0.8) - _path_at(walk_s - 0.2)
	var yaw0: float = hero.rotation.y
	if Vector2(ahead.x, ahead.z).length() > 0.05:
		var want: float = atan2(-ahead.x, -ahead.z)
		hero.rotation.y = lerp_angle(yaw0, want, 1.0 - exp(-moved * 3.2))
	# уклон пандуса: нос вверх, когда едем вверх
	var up: Vector3 = _path_at(walk_s + 0.5) - _path_at(walk_s - 0.5)
	var slope: float = atan2(up.y, maxf(Vector2(up.x, up.z).length(), 0.05))
	hero.rotation.x = lerpf(hero.rotation.x, slope, 1.0 - exp(-6.0 * dt))
	var yaw_rate: float = angle_difference(yaw0, hero.rotation.y) / maxf(dt, 0.001)
	chair_model.set_input(signf(drive) * minf(absf(drive), 1.0) if moved > 0.0001 else 0.0, clampf(-yaw_rate / 1.5, -1.0, 1.0), dt)
	audio.set_motor(minf(moved / maxf(dt, 0.001) / RAMP_SPEED, 1.0) * 0.85)
	if walk_s < forest_end_s - 0.6 and drive < 0.0:
		guided = false                                   # съехал обратно на тропинку — снова руль


## Мама идёт на ~3 м впереди и ждёт, если отстал; наверху пандуса отходит к двери и ждёт там.
func _update_mom_walk(_dt: float) -> void:
	var want: float = minf(walk_s + 3.2, mom_stop_s)
	if _mom_hold:
		if not mom.is_moving():
			mom.play("talk_loop" if mom_speaking else "idle_loop", 0.4)
		return
	if mom_s >= mom_stop_s - 0.35 and not _mom_aside:          # дошла до площадки у двери
		_mom_aside = true
		_mom_hold = true
		_mom_to_door()
		return
	if mom_s < want - 0.3:
		mom_s = minf(mom_s + 1.25 * get_process_delta_time(), want)
		mom.global_position = _path_at(mom_s)
		mom.face(_path_at(mom_s + 1.5))
		mom.play("walk_loop", 0.25)
	else:
		mom.play("talk_loop" if mom_speaking else "idle_loop", 0.4)
		mom.face(hero.global_position)


func _mom_to_door() -> void:
	await mom.go_and_wait([site_xf * MOM_DOOR], 1.1)
	mom.face(hero.global_position)
	ui.set_objective("Открой дверь (E)", site_xf * DOOR_POINT, Vector3(0, 0.6, 0))


func _open_entrance() -> void:
	if door_open or _door_busy or entrance == null:
		return
	_door_busy = true
	ui.set_prompt("")
	audio.play_sfx("click", 0.4)
	await entrance.open(1.7)
	door_open = true
	_door_busy = false
	ui.set_objective("Заезжай внутрь", site_xf * Vector3(28.75, 1.2, 4.27), Vector3(0, 0.9, 0))


## В тамбуре: мама заходит следом, Саман оглядывается — дверь закрывается — дальше санаторий с этого места.
func _enter_building() -> void:
	phase = "end"
	ui.set_objective("")
	ui.set_prompt("")
	chair_model.set_input(0.0, 0.0, 0.05)
	audio.set_motor(0.0)
	_mom_hold = true
	mom.set_look(null)
	var pts := []
	for q in MOM_INSIDE:
		pts.append(site_xf * (q as Vector3))
	mom.go(pts, 1.1)
	await wait(0.5)
	var tw := create_tween()
	tw.tween_property(self, "look_yaw", 2.45, 1.8).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.parallel().tween_property(self, "look_pitch", -0.1, 1.8)
	while mom.is_moving():
		await get_tree().process_frame
	mom.face(hero.global_position)
	if entrance:
		await entrance.close(1.0)
	audio.set_forest(0.0, 0.0)
	await wait(0.5)
	var inv: Transform3D = site_xf.affine_inverse()
	GameState.entry = {"pos": inv * hero.global_position, "yaw": wrapf(hero.rotation.y - float(site["building"]["yaw"]), -PI, PI),
		"mom": inv * mom.global_position}
	GameState.go(GameState.SANATORIUM, "start", _preload)


func _unhandled_input(event: InputEvent) -> void:
	if get_tree().paused and not event.is_action_pressed("pause"):
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		look_yaw = clampf(look_yaw - event.relative.x * MOUSE_SENS, -2.2, 2.2)
		look_pitch = clampf(look_pitch - event.relative.y * MOUSE_SENS, -1.2, 1.0)
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not get_tree().paused:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("flashlight") and phase == "walk":
		torch.visible = not torch.visible
		audio.play_sfx("click", 0.5)
	elif event.is_action_pressed("pause"):
		_toggle_pause()
	elif event.is_action_pressed("quality"):
		GraphicsSettings.cycle()
		ui.hint("Графика: %s" % GraphicsSettings.settings["name"], 2.0)


func _toggle_pause() -> void:
	var p: bool = not get_tree().paused
	get_tree().paused = p
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if p else Input.MOUSE_MODE_CAPTURED
	if p:
		ui.show_title("Пауза", "Esc — продолжить   ·   M — выйти в меню", 48, 0.2)
	else:
		ui.clear_title(0.2)


func _input(event: InputEvent) -> void:
	if get_tree().paused and event is InputEventKey and event.pressed and event.physical_keycode == KEY_M:
		get_tree().paused = false
		GameState.to_menu()
