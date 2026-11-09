extends Node3D
## Пролог «The Last Shake» (акт 1, начало): старый ЛиАЗ едет по лесной дороге в густом сером тумане предгорий.
## Саман сам управляет электроколяской на задней площадке (W A S D, мышь); навести взгляд на маму (Барно) и
## нажать E — разговор. Остановка «Санаторий «Оромгох»» → темнота → остановка снаружи, автобус уезжает →
## по лесной тропинке за мамой в сумерках (F — фонарик) → у пандуса санатория затемнение → здание (main.tscn).
## Лес, земля и дорога — из forest_drive (scripts/, scenes/, resources/world/); место санатория и тропинку
## подготовил tools/godot_assets/prepare_world.py (resources/world/story_site.json).

const Bus = preload("res://intro/bus.gd")
const Audio = preload("res://intro/audio.gd")
const StoryUI = preload("res://story/story_ui.gd")
const Actor = preload("res://story/actor.gd")
const Props = preload("res://story/props.gd")
const ChairModel = preload("res://story/chair_model.gd")

const RIDE_DISTANCE := 1900.0       # метров до остановки (~2,5 минуты)
const CRUISE := 12.5                # м/с
const ACCEL := 0.8
const DECEL := 0.95
const LAT_ACC := 1.4                # боковое ускорение в поворотах
const LANE := 1.85                  # правая полоса (в forest_drive «плюс» — вправо по ходу)
const STOP_LANE := 2.85             # у остановки прижимается к обочине
const FAST := 6.0                   # Tab — перемотка поездки
const CHAIR_SPEED := 0.55           # по салону
const WALK_SPEED := 1.6             # по тропинке (Shift — 2.4)
const PATH_HALF := 1.6
const EYE := Vector3(0.0, 1.19, 0.20)
const MOUSE_SENS := 0.0022
const RAIL := Vector3(-0.42, 2.58, 0.0)       # верхний поручень над задней площадкой (координаты кузова, z — где мама)
const MOM_IN_BUS := Vector3(-0.5, 0.8, 4.6)     # Барно стоит слева от Самана, держится за поручень
const HERO_IN_BUS := Vector3(-0.6, 0.8, 3.85)   # задняя площадка, лицом к левому окну
const PLATFORM := Rect2(-0.75, 3.72, 1.05, 0.3)  # x, z, ширина, длина (где может быть центр коляски)

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
var _skip := false
var _bus_away := false
var _bus_v := 0.0
var _events := {}
var _event_busy := false
var bus_lamps: Array = []
var chair_model
var _drone: AudioStreamPlayer
var _lamp_t := 6.0
var _mom_hold := false


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
	var acc := 0.0
	path_cum.append(0.0)
	for i in range(1, path.size()):
		acc += (path[i] - path[i - 1]).length()
		path_cum.append(acc)
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
	env.fog_sun_scatter = 0.08
	env.fog_aerial_perspective = 0.4
	env.fog_height = -3.0
	env.fog_height_density = 0.04
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.008
	env.volumetric_fog_albedo = Color(0.9, 0.92, 0.93)
	env.volumetric_fog_anisotropy = 0.6
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
	sun.light_volumetric_fog_energy = 0.8
	add_child(sun)
	forest.lod_manager.sun_light = sun
	set_day(0.0)


# время: [t, высота солнца/луны °, цвет света, сила, верх неба, горизонт, туман, конец тумана м, рассеянный, насыщенность]
const DAY_KEYS := [
	[0.0, 17.0, Color(1.0, 0.95, 0.88), 1.15, Color(0.46, 0.51, 0.56), Color(0.70, 0.72, 0.72), Color(0.62, 0.65, 0.66), 175.0, 1.0, 0.72],
	[0.38, 7.0, Color(1.0, 0.74, 0.5), 1.0, Color(0.4, 0.42, 0.5), Color(0.78, 0.63, 0.52), Color(0.6, 0.54, 0.5), 150.0, 1.05, 0.72],
	[0.6, 2.0, Color(1.0, 0.52, 0.34), 0.45, Color(0.22, 0.24, 0.33), Color(0.55, 0.41, 0.37), Color(0.36, 0.31, 0.32), 115.0, 0.7, 0.64],
	[0.8, 25.0, Color(0.55, 0.62, 0.8), 0.08, Color(0.05, 0.06, 0.1), Color(0.13, 0.12, 0.15), Color(0.09, 0.09, 0.11), 80.0, 0.24, 0.56],
	[1.0, 32.0, Color(0.55, 0.62, 0.82), 0.12, Color(0.012, 0.015, 0.028), Color(0.03, 0.034, 0.05), Color(0.028, 0.03, 0.04), 60.0, 0.12, 0.5],
]


## 0 — пасмурный серый день в тумане, 0.38 — вечер у остановки, 1 — ночь у санатория (свет — луна).
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
	sky_mat.energy_multiplier = 1.0
	env.fog_light_color = (a[6] as Color).lerp(b[6], k)
	env.fog_depth_begin = 10.0
	env.fog_depth_end = lerpf(float(a[7]), float(b[7]), k)
	env.fog_density = 0.94
	env.ambient_light_energy = lerpf(float(a[8]), float(b[8]), k)
	env.adjustment_saturation = lerpf(float(a[9]), float(b[9]), k)
	env.volumetric_fog_albedo = Color(0.9, 0.92, 0.93).lerp(Color(0.3, 0.32, 0.38), smoothstep(0.5, 1.0, day))


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
	probe.ambient_color = Color(0.55, 0.6, 0.66)
	probe.ambient_color_energy = 0.32
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	bus.body.add_child(probe)
	probe.position = Vector3(0, 1.9, 0)
	# плафоны: днём тусклые, холодные, старые — изредка мигают
	for l in bus.body.get_children():
		if l is OmniLight3D:
			var ol: OmniLight3D = l
			ol.light_color = Color(0.86, 0.93, 1.0)
			ol.light_energy = 0.35
			ol.omni_range = 5.5
			ol.light_volumetric_fog_energy = 0.0
			bus_lamps.append(ol)
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
	torch.light_energy = 7.0
	torch.spot_range = 26.0
	torch.spot_angle = 26.0
	torch.spot_attenuation = 1.1
	torch.light_volumetric_fog_energy = 2.0
	torch.shadow_enabled = true
	torch.shadow_bias = 0.05
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
		interior.queue_free()                         # внутри — отдельная сцена; снаружи только фасад
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
	var t: float = ui.say(who, text, sec)
	while t > 0.0 and not _skip:
		await get_tree().process_frame
		if not get_tree().paused:
			t -= get_process_delta_time()
	_skip = false
	ui.hide_line()
	talking = false


func wait(sec: float) -> void:
	await get_tree().create_timer(sec, false).timeout


func _ride_story() -> void:
	await GameState.fade_to(0.0, 2.5)
	await ui.title("THE LAST SHAKE", "Последний Скачок · Soʻnggi Silkiniş", 2.5, 72)
	ui.set_objective("Поговори с мамой — наведи на неё взгляд и нажми E")
	ui.hint("Мышь — осмотреться   ·   W A S D — коляска   ·   E — поговорить   ·   Tab — ускорить поездку   ·   Esc — меню", 9.0)
	await wait(1.5)
	await say("hero", "(про себя) Снова туман… Как будто едем в никуда.")


func _talk() -> void:
	if talked or talking:
		return
	talked = true
	ui.set_objective("")
	ui.set_prompt("")
	await say("hero", "Мам, а дедушка знает, что мы едем?")
	await say("mom", "Знает. Он нас ждёт… давно ждёт.")
	await say("hero", "Почему его положили так далеко? В лесу, в горах…")
	await say("mom", "Там тихо. Там ему лучше.")
	await wait(1.5)
	await say("hero", "Ты какая-то странная сегодня.")
	await say("mom", "Не задавай лишних вопросов, Саман. Смотри в окно. Скоро наша остановка.")
	ui.set_objective("Едем к деду в санаторий «Оромгох»")


func _arrival() -> void:
	phase = "arrive"
	ui.set_prompt("")
	await say("driver", "«Санаторий «Оромгох»»! Конечная для вас… Туда давно никто не ездит.")
	if not talked:
		await say("mom", "Саман, мы приехали. Выходим.")
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
	await say("mom", "Тут недалеко. Держись за мной.")
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
	var hi: int = mini(path.size(), lo + 30)
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
		await say("hero", "Тут так тихо… Даже птицы не поют.")
		await say("mom", "Не отставай.")
	elif walk_s > 55.0 and not _events.has("snap"):
		_events["snap"] = true
		audio.play_sfx("snap", 0.9)
		_mom_hold = true
		mom.play("idle_loop", 0.3)
		mom.face(path[0])
		mom.set_look(path[0] + Vector3(0, 1.5, 0))
		await say("mom", "…Ты слышал?")
		await wait(1.2)
		await say("hero", "Что? Там кто-то есть?")
		mom.set_look(null)
		await say("mom", "Показалось. Пойдём.")
		_mom_hold = false
	elif walk_s > 70.0 and not _events.has("dark"):
		_events["dark"] = true
		if not torch.visible:
			await say("mom", "Темнеет. Включи фонарик, он у тебя на коляске.")
			ui.hint("F — фонарик", 5.0)
	elif walk_s > 92.0 and not _events.has("building"):
		_events["building"] = true
		await say("mom", "Вот он. «Оромгох».")
		await say("hero", "Это… санаторий? Он же заброшенный.")
		await say("mom", "Заезжай по пандусу. Дедушка ждёт.")
	elif walk_s > path_cum[-1] - 2.5 and not _events.has("end"):
		_events["end"] = true
		phase = "end"
		ui.set_objective("")
		await GameState.fade_to(1.0, 1.6)
		GameState.go(GameState.SANATORIUM, "start")


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
	_lamp_t -= dt
	if _lamp_t <= 0.0 and not bus_lamps.is_empty():
		_lamp_t = randf_range(0.04, 0.12) if randf() < 0.7 else randf_range(6.0, 16.0)
		var l: OmniLight3D = bus_lamps[randi() % bus_lamps.size()]
		l.light_energy = 0.35 if l.light_energy < 0.1 else randf_range(0.0, 0.08)
	elif _lamp_t > 5.0:
		for l in bus_lamps:
			(l as OmniLight3D).light_energy = 0.35
	set_day(lerpf(0.0, 0.38, 1.0 - left / RIDE_DISTANCE))
	if phase == "ride" and left < 0.6 and v < 0.05:
		v = 0.0
		_arrival()
	# коляска по задней площадке
	var drive: float = Input.get_action_strength("drive_forward") - Input.get_action_strength("drive_back")
	var turn: float = Input.get_action_strength("turn_left") - Input.get_action_strength("turn_right")
	hero.rotation.y += turn * 1.4 * dt
	var fwd: Vector3 = -hero.transform.basis.z
	var np: Vector3 = hero.position + fwd * drive * CHAIR_SPEED * dt
	np.x = clampf(np.x, PLATFORM.position.x, PLATFORM.position.x + PLATFORM.size.x)
	np.z = clampf(np.z, PLATFORM.position.y, PLATFORM.position.y + PLATFORM.size.y)
	hero.position = np
	chair_model.set_input(drive, -turn, dt)
	audio.set_motor(absf(drive) * 0.7 + absf(turn) * 0.3)
	# мама держится за поручень: в окно — а в разговоре смотрит на сына
	mom.set_arm(bus.body.to_global(Vector3(RAIL.x, RAIL.y, MOM_IN_BUS.z - 0.18)))
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
	var spd: float = WALK_SPEED * (1.5 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	hero.rotation.y += turn * 1.5 * dt
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
	hero.global_position = p
	chair_model.set_input(drive, -turn, dt)
	audio.set_motor(absf(drive) * 0.8 + absf(turn) * 0.3)
	# темнеет по мере продвижения (и просто со временем)
	set_day(maxf(day, lerpf(0.45, 0.88, walk_s / maxf(path_cum[-1], 1.0))))
	set_day(day + dt * 0.0006)
	audio.set_forest(0.0, day)
	_drone.volume_db = lerpf(-40.0, -15.0, smoothstep(0.45, 0.9, day))
	# мама идёт на ~3 м впереди и ждёт, если отстал
	var want: float = minf(walk_s + 3.2, path_cum[-1] + 1.0)
	if _mom_hold:
		pass
	elif mom_s < want - 0.3:
		mom_s = minf(mom_s + 1.25 * dt, want)
		mom.global_position = _path_at(mom_s)
		mom.face(_path_at(mom_s + 1.5))
		mom.play("walk_loop", 0.25)
	else:
		mom.play("idle_loop", 0.4)
		mom.face(hero.global_position)
	if not talking and not _event_busy:
		_walk_events()


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
