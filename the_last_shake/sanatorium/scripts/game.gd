extends Node3D
## Sanatorium: first-person electric wheelchair in a half-abandoned Soviet sanatorium.
## Loads the building (assets/sanatorium.glb, exported by tools/blender/build_sanatorium.py) and the
## level description (assets/level.json), then builds collisions, occluders, doors, lamps and switches,
## the elevator, rats and cockroaches, sound and the player.

const Wheelchair = preload("res://sanatorium/scripts/wheelchair.gd")
const DoorGroup = preload("res://sanatorium/scripts/door_group.gd")
const LightManager = preload("res://sanatorium/scripts/lights.gd")
const Lift = preload("res://sanatorium/scripts/lift.gd")
const Critters = preload("res://sanatorium/scripts/critters.gd")
const Ambience = preload("res://sanatorium/scripts/ambience.gd")
const Hud = preload("res://sanatorium/scripts/hud.gd")
const Switch = preload("res://sanatorium/scripts/switch.gd")
const Quality = preload("res://sanatorium/scripts/quality.gd")
const Decor = preload("res://sanatorium/scripts/decor.gd")

const L_WORLD := 1
const L_PLAYER := 2
const L_DOORS := 4
const L_INTERACT := 8
const L_LIFT := 16

const COLLIDE_PREFIX := ["Shell_", "Pilasters_", "WindowReveals_", "WindowSills_", "OpeningLinings", "InteriorGlazing",
	"Stair1_Flights", "Stair2_Flights", "Stair3_Flights", "Lift_Landing", "Lift_Machine", "DoorFrame_"]

var level: Dictionary
var building: Node3D
var nodes := {}
var rooms := {}
var room_list := []
var player: CharacterBody3D
var hud: CanvasLayer
var lights: Node3D
var lift: Node3D
var critters: Node3D
var ambience: Node3D
var quality: Node
var env: Environment
var moon: DirectionalLight3D
var door_groups := []
var rng := RandomNumberGenerator.new()
var stats := {}


func _ready() -> void:
	rng.seed = 1975
	_setup_input()
	_fit_window_macos()
	_setup_audio_buses()
	level = JSON.parse_string(FileAccess.get_file_as_string("res://sanatorium/assets/level.json"))
	var t0 := Time.get_ticks_msec()
	building = (load("res://sanatorium/assets/sanatorium.glb") as PackedScene).instantiate()
	add_child(building)
	_index(building)
	stats["coplanar_fixed"] = fix_coplanar(building)
	for r in level["rooms"]:
		rooms[r["id"]] = r
		room_list.append(r)
	_setup_environment()
	_tune_materials()
	_build_static_colliders()
	_build_occluders_and_ranges()
	stats["models_swapped"] = swap_models(building)     # свои 3D-модели из sanatorium/models/
	stats["models_on_tables"] = dress_tables(building)  # термос, кружка, хлеб на столах; мониторы на столиках
	stats["lamps_swapped"] = swap_fixtures()            # свои лампы-трубки и абажуры на месте старых
	stats["decor"] = Decor.apply(building, model_type, has_model)   # свои картины, циферблаты, экраны, таблички
	_build_furniture_colliders()
	_build_blockers()
	hud = Hud.new()
	hud.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(hud)
	player = Wheelchair.new()
	player.game = self
	add_child(player)
	var sp: Dictionary = level["spawn"]
	player.global_position = _v3(sp["pos"]) + Vector3(0, 0.05, 0)
	player.rotation.y = float(sp["yaw"])
	player.reset_physics_interpolation()
	_build_doors()
	lights = LightManager.new()
	add_child(lights)
	lights.setup(self)
	_build_switches()
	lift = Lift.new()
	add_child(lift)
	lift.setup(self)
	_assign_storey_layers()
	critters = Critters.new()
	critters.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF   # they move in _process
	add_child(critters)
	critters.setup(self)
	ambience = Ambience.new()
	add_child(ambience)
	ambience.setup(self)
	quality = Quality.new()
	add_child(quality)
	quality.setup(self)
	stats["load_ms"] = Time.get_ticks_msec() - t0
	print("Sanatorium loaded in %d ms: %s" % [stats["load_ms"], str(stats)])
	var args := OS.get_cmdline_user_args()
	if "--test" in args or "--shots" in args or "--bench" in args:
		var tr: Node = load("res://sanatorium/tests/test_runner.gd").new()
		tr.game = self
		add_child(tr)
	elif has_node("Director"):
		get_node("Director").begin(self)        # сюжет «The Last Shake» (story/director.gd)
	else:
		hud.show_intro()


# ------------------------------------------------------------------------------ helpers
func _v3(a) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func _index(n: Node) -> void:
	nodes[String(n.name)] = n
	for c in n.get_children():
		_index(c)


func node(name: String) -> Node:
	return nodes.get(name)


## Room containing world point p (the smallest one when spaces overlap in height).
func room_at(p: Vector3) -> Dictionary:
	var best := {}
	for r in room_list:
		if p.y < float(r["floor_y"]) - 0.3 or p.y > float(r["ceil_y"]) + 0.1:
			continue
		for q in r["rects"]:
			if p.x >= q[0] and p.x <= q[1] and p.z >= q[2] and p.z <= q[3]:
				if best.is_empty() or (float(r["ceil_y"]) - float(r["floor_y"])) < (float(best["ceil_y"]) - float(best["floor_y"])):
					best = r
	return best


func play_at(stream_name: String, pos: Vector3, vol_db := 0.0, pitch := 1.0, max_dist := 25.0) -> void:
	var p := AudioStreamPlayer3D.new()
	p.stream = sfx(stream_name)
	p.volume_db = vol_db
	p.pitch_scale = pitch
	p.max_distance = max_dist
	p.unit_size = 3.0
	p.bus = "World"
	add_child(p)
	p.global_position = pos
	p.finished.connect(p.queue_free)
	p.play()


var _sfx_cache := {}


## Звук здания. Есть варианты (name_2.wav, name_3.wav …) — каждый раз случайный (петли — всегда основной).
func sfx(name: String, loop := false) -> AudioStream:
	if not loop:
		var vs: Array = sfx_variants("res://sanatorium/assets/sfx/", name, _sfx_cache)
		if vs.size() > 1:
			return vs[randi() % vs.size()]
	var key := name + ("#l" if loop else "")
	if _sfx_cache.has(key):
		return _sfx_cache[key]
	var s: AudioStreamWAV = load("res://sanatorium/assets/sfx/%s.wav" % name)
	if loop:
		s = s.duplicate()
		s.loop_mode = AudioStreamWAV.LOOP_FORWARD
		s.loop_begin = 0
		s.loop_end = int(s.get_length() * s.mix_rate)
	_sfx_cache[key] = s
	return s


static func sfx_variants(dir: String, name: String, cache: Dictionary) -> Array:
	var key := "#v" + dir + name
	if cache.has(key):
		return cache[key]
	var out: Array = []
	for k in range(1, 7):
		var p: String = dir + name + ("" if k == 1 else "_%d" % k) + ".wav"
		if ResourceLoader.exists(p):
			out.append(load(p))
	cache[key] = out
	return out


# ------------------------------------------------------------------------------ setup
func _setup_input() -> void:
	var keys := {
		"drive_forward": [KEY_W, KEY_UP], "drive_back": [KEY_S, KEY_DOWN], "turn_left": [KEY_A, KEY_LEFT],
		"turn_right": [KEY_D, KEY_RIGHT], "interact": [KEY_E], "flashlight": [KEY_F], "horn": [KEY_H],
		"speed_up": [KEY_EQUAL, KEY_KP_ADD, KEY_R], "speed_down": [KEY_MINUS, KEY_KP_SUBTRACT, KEY_Q],
		"pause": [KEY_ESCAPE], "fullscreen": [KEY_F11], "quality": [KEY_G, KEY_F2], "fps_limit": [KEY_L], "debug_info": [KEY_F3],
	}
	for a in keys:
		if not InputMap.has_action(a):
			InputMap.add_action(a, 0.2)
		for k in keys[a]:
			var ev := InputEventKey.new()
			ev.physical_keycode = k
			InputMap.action_add_event(a, ev)
	# Mac: Ctrl+Cmd+F is the system full-screen shortcut (F11 there shows the desktop)
	var mac_fs := InputEventKey.new()
	mac_fs.physical_keycode = KEY_F
	mac_fs.ctrl_pressed = true
	mac_fs.meta_pressed = true
	InputMap.action_add_event("fullscreen", mac_fs)
	var joy := {"interact": JOY_BUTTON_A, "flashlight": JOY_BUTTON_X, "horn": JOY_BUTTON_Y, "speed_up": JOY_BUTTON_RIGHT_SHOULDER,
		"speed_down": JOY_BUTTON_LEFT_SHOULDER, "pause": JOY_BUTTON_START}
	for a in joy:
		var jb := InputEventJoypadButton.new()
		jb.button_index = joy[a]
		InputMap.action_add_event(a, jb)
	for pair in [["drive_forward", JOY_AXIS_LEFT_Y, -1.0], ["drive_back", JOY_AXIS_LEFT_Y, 1.0],
			["turn_left", JOY_AXIS_LEFT_X, -1.0], ["turn_right", JOY_AXIS_LEFT_X, 1.0]]:
		var jm := InputEventJoypadMotion.new()
		jm.axis = pair[1]
		jm.axis_value = pair[2]
		InputMap.action_add_event(pair[0], jm)
	var wheel_up := InputEventMouseButton.new()
	wheel_up.button_index = MOUSE_BUTTON_WHEEL_UP
	InputMap.action_add_event("speed_up", wheel_up)
	var wheel_dn := InputEventMouseButton.new()
	wheel_dn.button_index = MOUSE_BUTTON_WHEEL_DOWN
	InputMap.action_add_event("speed_down", wheel_dn)
	# ЛКМ — удар («The Last Shake»): действие «attack» задаёт GameState


func _setup_audio_buses() -> void:
	if AudioServer.get_bus_index("World") >= 0:
		return
	AudioServer.add_bus()
	var i := AudioServer.bus_count - 1
	AudioServer.set_bus_name(i, "World")
	AudioServer.set_bus_send(i, "Master")
	var rv := AudioEffectReverb.new()
	rv.room_size = 0.55
	rv.damping = 0.45
	rv.wet = 0.22
	rv.dry = 0.9
	rv.predelay_msec = 28.0
	AudioServer.add_bus_effect(i, rv)


func _setup_environment() -> void:
	env = Environment.new()
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.02, 0.03, 0.06)
	sm.sky_horizon_color = Color(0.07, 0.08, 0.11)
	sm.ground_bottom_color = Color(0.01, 0.01, 0.012)
	sm.ground_horizon_color = Color(0.05, 0.05, 0.06)
	sm.sun_angle_max = 1.0
	sky.sky_material = sm
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# реалистично: ночь, свет только от ламп; почти нейтральный слабый рассеянный свет, без зелени
	env.ambient_light_color = Color(0.34, 0.35, 0.38)
	env.ambient_light_energy = 0.06
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.0
	env.ssao_enabled = true
	env.ssao_radius = 0.9
	env.ssao_intensity = 1.6
	env.ssao_power = 1.6
	env.ssao_detail = 0.6
	env.ssil_enabled = true
	env.ssil_radius = 4.0
	env.ssil_intensity = 1.0
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_bloom = 0.02
	env.glow_hdr_threshold = 1.4
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.012
	env.volumetric_fog_albedo = Color(0.8, 0.8, 0.78)
	env.volumetric_fog_anisotropy = 0.25
	env.volumetric_fog_emission = Color(0, 0, 0)
	env.volumetric_fog_length = 40.0
	env.volumetric_fog_ambient_inject = 0.0
	env.adjustment_enabled = true
	env.adjustment_saturation = 0.95
	env.adjustment_contrast = 1.06
	# цветокоррекция как у плёнки: тени чуть холоднее, света чуть теплее — без зелёного «фильтра»
	var grade := Gradient.new()
	grade.set_color(0, Color(0.0, 0.004, 0.012))
	grade.set_color(1, Color(1.0, 0.985, 0.95))
	grade.add_point(0.5, Color(0.5, 0.5, 0.49))
	var lut := GradientTexture1D.new()
	lut.gradient = grade
	lut.width = 256
	env.adjustment_color_correction = lut
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	moon = DirectionalLight3D.new()
	moon.light_color = Color(0.55, 0.62, 0.8)
	moon.light_energy = 0.35
	moon.shadow_enabled = true
	moon.directional_shadow_max_distance = 40.0
	moon.light_volumetric_fog_energy = 0.4
	moon.rotation_degrees = Vector3(-32, -150, 0)
	add_child(moon)


# Grime that follows causes instead of being sprinkled evenly (textures made by tools/grime_gen.py). The wall
# mask is one storey high and lined up with the floors (they are exactly 3.3 m apart, the lowest at 1.2 m):
# a dirty band and scuffs at the bottom of the walls, leak stains with tide marks and drips coming down
# from the ceiling, a dusty line under it, old slightly uneven paint in between. Ceilings get a few
# yellowed leak stains, floors a faint unevenness. Doors are left out: they turn, and grime laid in world
# space would slide over them.
const GRIME_WALL := ["M_Paint_WallBlue", "M_Paint_WallPeach", "M_Paint_WallBeige", "M_Plaster_White",
	"M_Tile_WallWhite", "M_Wallpaper_Geometric", "M_Wallpaper_Floral", "M_Concrete_Interior"]
const GRIME_CEILING := ["M_Ceiling_Paint"]
const GRIME_FLOOR := ["M_Linoleum_Brown", "M_Linoleum_Parquet", "M_Terrazzo", "M_Tile_FloorCeramic"]
const STOREY := 3.3
const FIRST_FLOOR := 1.2


func _grime(m: BaseMaterial3D, tex: Texture2D, scale: Vector3, offset: Vector3) -> void:
	m.detail_enabled = true
	m.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MUL
	m.detail_albedo = tex
	m.detail_uv_layer = BaseMaterial3D.DETAIL_UV_2
	m.uv2_triplanar = true
	m.uv2_world_triplanar = true
	m.uv2_triplanar_sharpness = 8.0
	m.uv2_scale = scale
	m.uv2_offset = offset
	m.roughness = minf(1.0, m.roughness + 0.06)


## Indoors there is no sky to reflect, so fully metallic atlas regions would render black: tone metal down.
## Walls, floors and ceilings get grime laid over them in world space (so it never repeats tile by tile),
## lamp glass glows less, and window glass is a little dirty, so it no longer reads as an invisible wall.
## Текстуры стен, полов и фасада — свои (сгенерированы автором игры, поправлены tools/user_assets/), в той же
## раскладке UV, что старые: имя материала → [цвет, нормаль, ORM (R — затенение, G — шероховатость)].
const TEX_SET := {
	"M_Paint_WallBeige": ["wall_beige_albedo", "wall_beige_normal", "wall_beige_orm"],
	"M_Paint_WallBlue": ["wall_blue_albedo", "wall_blue_normal", "wall_blue_orm"],
	"M_Paint_WallPeach": ["wall_peach_albedo", "wall_peach_normal", "wall_peach_orm"],
	"M_Tile_WallWhite": ["wall_tile_albedo", "wall_tile_normal", "wall_tile_orm"],
	"M_Wallpaper_Floral": ["wallpaper_floral_albedo", "wallpaper_floral_normal", "wallpaper_floral_orm"],
	"M_Wallpaper_Geometric": ["wallpaper_geometric_albedo", "wallpaper_geometric_normal", "wallpaper_geometric_orm"],
	"M_Ceiling_Paint": ["plaster_albedo", "plaster_normal", "plaster_orm"],
	"M_Plaster_White": ["plaster_albedo", "plaster_normal", "plaster_orm"],
	"M_Linoleum_Brown": ["linoleum_albedo", "linoleum_normal", "linoleum_orm"],
	"M_Linoleum_Parquet": ["parquet_albedo", "parquet_normal", "parquet_orm"],
	"M_Tile_FloorCeramic": ["floor_ceramic_albedo", "floor_ceramic_normal", "floor_ceramic_orm"],
	"M_Terrazzo": ["terrazzo_albedo", "terrazzo_normal", "terrazzo_orm"],
	"M_Wood_DoorDark": ["door_albedo", "door_normal", "door_orm"],
	# снаружи: фасадные панели, цоколь, карнизы, отмостка, кровля
	"M_Concrete_FacadeWall": ["ext_facade_wall_albedo", "ext_facade_wall_normal", "ext_facade_wall_orm"],
	"M_Concrete_FacadePanel": ["ext_facade_panel_albedo", "ext_facade_panel_normal", "ext_facade_panel_orm"],
	"M_Concrete_Weathered": ["ext_concrete_weathered_albedo", "ext_concrete_weathered_normal", "ext_concrete_weathered_orm"],
	"M_Concrete_Trim": ["ext_concrete_trim_albedo", "ext_concrete_trim_normal", "ext_concrete_trim_orm"],
	"M_Concrete_Paving": ["ext_paving_albedo", "ext_paving_normal", "ext_paving_orm"],
	"M_Concrete_Interior": ["ext_concrete_interior_albedo", "ext_concrete_interior_normal", "ext_concrete_interior_orm"],
	"M_Roofing_Bitumen": ["ext_roofing_albedo", "ext_roofing_normal", "ext_roofing_orm"],
	"M_Ceramic_Tile_RedBrown": ["ext_brick_albedo", "ext_brick_normal", "ext_brick_orm"],
}


## Свои 3D-модели мебели вместо коробочных: положи <тип>.glb в sanatorium/models/ (типы — ниже и в таблице
## моделей). Все предметы этого типа в здании (и в прологе) заменятся: новая модель встаёт ровно на место старой
## (та же точка опоры и поворот), старая прячется (её имя и место остаются — сюжет их использует).
## Модель: 1 единица = 1 м, опора — на полу под центром предмета, спинка/изголовье — к −Z (в Blender: к +Y,
## лицом к виду «Спереди»). Свой коллайдер не нужен: столкновения остаются прежние (коробки из level.json).
const MODELS_DIR := "res://sanatorium/models/"
const MODEL_TYPES := [
	"armchair", "armchair_beige", "armchair_red", "bar_counter", "bathtub", "bed_a", "bed_b", "bed_hosp",
	"bed_strip", "bedside", "bench", "billiard", "bin", "binders", "boiler", "bookcase", "books", "bucket",
	"buvette", "call_panel", "carafe", "chair", "chair_soft", "chair_tube", "charcot_console", "cinema_row",
	"cleaning_cart", "clock", "coat_hooks", "coat_stand", "crates", "cubicle", "cubicle_wide", "cue_rack",
	"curtain_rail", "curtain_rail_s", "desk_office", "desk_small", "desk_wide", "dishwasher", "duct",
	"elec_cabinet", "elec_panel_wall", "ex_bike", "exam_couch", "filing", "fire_ext", "fridge", "fridge_ind",
	"fuse_box", "game_chess", "game_dominoes", "goods_rack", "grab_bar", "grab_bar_l", "grab_bar_v",
	"grab_fold", "gym_bench", "hose_cabinet", "hydro_bath", "inhaler", "instrument_table", "iv_stand", "kettle",
	"kitchen_hood", "kitchen_sink", "lab_rack", "laundry_cart", "linen_rack", "locker", "luggage_rack",
	"massage_table", "med_cabinet", "medbox_rack", "microscope", "mirror", "notice_board", "oxygen",
	"painting_1", "painting_2", "painting_3", "palm", "paper_stack", "peeler", "physio_device", "piano",
	"plant_stand", "prep_table", "projector", "pump", "radio", "recliner", "safe", "samovar", "scale", "screen",
	"seat_row", "shower", "shower_cubicle", "shower_s", "shower_seat", "shower_tray", "sink", "sofa_beige",
	"sofa_brown", "sofa_red", "stage", "stool", "stove", "stretcher", "suitcase_a", "suitcase_b", "table_cloth",
	"table_coffee", "table_lab", "table_read", "table_round", "table_small", "table_sq", "tea_shelf",
	"telephone", "toilet", "tool_rack", "towel_rail", "travel_bag", "tv_cabinet", "tv_small", "urinal", "vase",
	"wall_bars", "wardrobe", "wardrobe_wide", "wheelchair", "workbench", "Radiator"
]
## Свои модели автора под другими именами: тип предмета в здании → модели (если своих <тип>.glb нет).
## Кровати — советские металлические (epi_bed — застеленная, epi_bed_2 — голый матрас), шкафчик персонала,
## капельница, батарея с трубами, полка в ванной с полотенцами.
const MODEL_ALIASES := {
	"bed_a": ["epi_bed"], "bed_b": ["epi_bed"], "bed_hosp": ["epi_bed"], "bed_strip": ["epi_bed_2"],
	"locker": ["epi_cabinet"], "iv_stand": ["epi_iv"], "Radiator": ["radiator"], "towel_rail": ["bath_shelf"],
}
## Ещё варианты к своим моделям типа (больничная тумбочка — среди тумбочек).
const MODEL_EXTRA := {"bedside": ["epi_cabinet_2"]}
## Насколько модель может быть шире (x) и глубже (z) старой коробки; по умолчанию 1.15. Батарея — с трубами вдоль
## стены, полка — глубже вешалки для полотенец.
const SWAP_FIT := {"Radiator": Vector2(2.05, 99.0), "towel_rail": Vector2(1.3, 99.0)}


## Тип предмета по имени узла: самый длинный тип из MODEL_TYPES, с которого начинается имя
## («armchair_beige_F2_001» → armchair_beige, «chair_EB_BAR_003» → chair). "" — не мебель.
static func model_type(node_name: String) -> String:
	var best := ""
	for t in MODEL_TYPES:
		var ts: String = t
		if ts.length() > best.length() and (node_name == ts or node_name.begins_with(ts + "_")):
			best = ts
	return best


## Варианты одного типа: <тип>.glb и <тип>__1.glb … <тип>__9.glb — предметы в разных комнатах берут разные
## (выбор по имени узла, всегда один и тот же). Модель ставится на место старой коробки: по центру по X, на тот
## же низ, спинкой к той же стене (−Z), и не шире старой больше чем на 15 % (иначе врежется в соседей).
## SWAP_TOP — у настенных предметов, где важна высота верха (раковина), а не низа.
const SWAP_TOP := {"sink": 0.86}


static func model_variants(t: String) -> Array:
	var out: Array = []
	var base: String = MODELS_DIR + t
	if ResourceLoader.exists(base + ".glb"):
		out.append(base + ".glb")
	for k in range(1, 10):
		if ResourceLoader.exists("%s__%d.glb" % [base, k]):
			out.append("%s__%d.glb" % [base, k])
	if out.is_empty():
		for a in MODEL_ALIASES.get(t, []):
			if ResourceLoader.exists(MODELS_DIR + a + ".glb"):
				out.append(MODELS_DIR + a + ".glb")
	if not out.is_empty():
		for a in MODEL_EXTRA.get(t, []):
			if ResourceLoader.exists(MODELS_DIR + a + ".glb"):
				out.append(MODELS_DIR + a + ".glb")
	return out


static func has_model(t: String) -> bool:
	return not model_variants(t).is_empty()


static func _scene_aabb(n: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for g in n.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = g
		if mi.mesh == null:
			continue
		var xf: Transform3D = Transform3D.IDENTITY
		var p: Node = mi
		while p != n and p is Node3D:
			xf = (p as Node3D).transform * xf
			p = p.get_parent()
		var b: AABB = xf * mi.mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


static func swap_models(root: Node) -> int:
	var have := {}
	for t in MODEL_TYPES:
		var v: Array = model_variants(t)
		if not v.is_empty():
			have[t] = v
	if have.is_empty():
		return 0
	var scenes := {}
	var n := 0
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var old: MeshInstance3D = mi
		var t := model_type(String(old.name))
		if t == "" or not have.has(t) or not old.visible or old.mesh == null:
			continue
		var paths: Array = have[t]
		var path: String = paths[absi(hash(String(old.name))) % paths.size()]
		if not scenes.has(path):
			scenes[path] = load(path)
		var ps: PackedScene = scenes[path]
		if ps == null:
			continue
		var inst: Node3D = ps.instantiate()
		var holder := Node3D.new()
		holder.name = String(old.name) + "_model"
		old.get_parent().add_child(holder)
		holder.transform = old.transform
		holder.add_child(inst)
		var ob: AABB = old.mesh.get_aabb()
		var nb: AABB = _scene_aabb(inst)
		var k := 1.0
		var fit: Vector2 = SWAP_FIT.get(t, Vector2(1.15, 1.15))
		if nb.size.x > 0.05 and ob.size.x > 0.05:
			k = minf(k, ob.size.x * fit.x / nb.size.x)
		if nb.size.z > 0.05 and ob.size.z > 0.05:
			k = minf(k, ob.size.z * fit.y / nb.size.z)
		inst.scale = Vector3.ONE * k
		nb = AABB(nb.position * k, nb.size * k)
		var y: float = ob.position.y - nb.position.y
		if SWAP_TOP.has(t):
			y = float(SWAP_TOP[t]) - nb.end.y
		inst.position = Vector3(ob.get_center().x - nb.get_center().x, y, ob.position.z - nb.position.z)
		for g in inst.find_children("*", "GeometryInstance3D", true, false):
			var gi: GeometryInstance3D = g
			gi.visibility_range_end = old.visibility_range_end
			gi.visibility_range_end_margin = old.visibility_range_end_margin
			gi.visibility_range_fade_mode = old.visibility_range_fade_mode
			gi.layers = old.layers
		old.visible = false
		n += 1
	return n


## Модель на месте старого предмета: копирует слои и дальность видимости (чтобы прятаться вместе с этажом).
static func _model_like(old: GeometryInstance3D, path: String) -> Node3D:
	var ps: PackedScene = load(path)
	if ps == null:
		return null
	var inst: Node3D = ps.instantiate()
	for g in inst.find_children("*", "GeometryInstance3D", true, false):
		var gi: GeometryInstance3D = g
		gi.visibility_range_end = old.visibility_range_end
		gi.visibility_range_end_margin = old.visibility_range_end_margin
		gi.visibility_range_fade_mode = old.visibility_range_fade_mode
		gi.layers = old.layers
	return inst


## Верх стола (в системе координат старого узла): у заменённого стола — по своей модели.
static func _table_top(old: MeshInstance3D) -> float:
	var top: float = old.mesh.get_aabb().end.y
	var holder: Node = old.get_parent().get_node_or_null(String(old.name) + "_model")
	if holder is Node3D:
		var b := _scene_aabb(holder as Node3D)
		if b.size.y > 0.2:
			top = b.end.y
	return top


## На столы — термос, кружка и хлеб (table_items, примерно на двух столах из трёх), на столики с инструментами —
## кардиомонитор (epi_monitor). Выбор по имени узла — всегда один и тот же.
const TABLE_ITEMS := ["table_sq", "table_round", "table_cloth", "table_coffee", "table_read"]


static func dress_tables(root: Node) -> int:
	var items := MODELS_DIR + "table_items.glb"
	var mon := MODELS_DIR + "epi_monitor.glb"
	var have_items := ResourceLoader.exists(items)
	var have_mon := ResourceLoader.exists(mon)
	var n := 0
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var old: MeshInstance3D = mi
		if old.mesh == null:
			continue
		var t := model_type(String(old.name))
		var h: int = absi(hash(String(old.name)))
		var path := ""
		if t in TABLE_ITEMS and have_items and h % 3 != 0:
			path = items
		elif t == "instrument_table" and have_mon and h % 2 == 0:
			path = mon
		if path == "":
			continue
		var inst := _model_like(old, path)
		if inst == null:
			continue
		var holder := Node3D.new()
		holder.name = String(old.name) + "_ontop"
		old.get_parent().add_child(holder)
		holder.transform = old.transform
		holder.add_child(inst)
		var c: Vector3 = old.mesh.get_aabb().get_center()
		inst.position = Vector3(c.x, _table_top(old) + 0.002, c.z)
		inst.rotation.y = float(h % 360) * PI / 180.0 if path == items else 0.0   # монитор — экраном в комнату
		n += 1
	return n


## Лампы: трубки (fluo) — своя лампа epi_lamp, голые лампочки (bulb) — эмалевый абажур story_void_lamp.
## Модель висит верхом у потолка там же, где старая; старая прячется (свет — от тех же источников).
const FIXTURE_MODELS := {"fluo": ["epi_lamp", 1.0], "bulb": ["story_void_lamp", 0.75]}


func swap_fixtures() -> int:
	var n := 0
	for f in level["fixtures"]:
		var kind: String = f["kind"]
		if not FIXTURE_MODELS.has(kind):
			continue
		var path: String = MODELS_DIR + str(FIXTURE_MODELS[kind][0]) + ".glb"
		if not ResourceLoader.exists(path):
			continue
		var old = node(f["name"])
		if not (old is MeshInstance3D) or (old as MeshInstance3D).mesh == null:
			continue
		var om: MeshInstance3D = old
		var inst := _model_like(om, path)
		if inst == null:
			continue
		var holder := Node3D.new()
		holder.name = String(om.name) + "_model"
		om.get_parent().add_child(holder)
		holder.transform = om.transform
		holder.add_child(inst)
		var k: float = FIXTURE_MODELS[kind][1]
		inst.scale = Vector3.ONE * k
		var ob: AABB = om.mesh.get_aabb()
		var nb := _scene_aabb(inst)
		nb = AABB(nb.position * k, nb.size * k)
		# длинная трубка — вдоль длинной стороны старой лампы
		if kind == "fluo" and ob.size.z > ob.size.x * 1.5:
			inst.rotation.y = PI * 0.5
			nb = AABB(Vector3(nb.position.z, nb.position.y, nb.position.x), Vector3(nb.size.z, nb.size.y, nb.size.x))
		var c: Vector3 = ob.get_center()
		inst.position = Vector3(c.x, ob.end.y - nb.end.y, c.z)
		om.visible = false
		n += 1
	return n


## Мебель, лестницы и крыша в модели здания собраны из коробок. У части из них грани разных деталей лежат в
## одной плоскости, смотрят в одну сторону и перекрываются: торцы всех кроватей (спинка и рама), площадки
## маршей, стёкла в рамах, крыша. Такие грани мерцают «рябью» (z-fighting) — «глючит низ кровати».
## Меньшую из двух граней утапливаем внутрь на 2,5 мм (третью — на 5 и т. д.): глазу не видно, мерцания нет.
const COPLANAR_FIX := ["bed_", "Stair", "Roof_Structures", "InteriorGlazing", "Lift_Machine", "projector_"]
const COPLANAR_STEP := 0.0025


static func fix_coplanar(root: Node) -> int:
	var done := {}
	var fixed := 0
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m3: MeshInstance3D = mi
		var nm := String(m3.name)
		var want := false
		for pre in COPLANAR_FIX:
			if nm.begins_with(pre):
				want = true
				break
		if not want or not (m3.mesh is ArrayMesh):
			continue
		var src: ArrayMesh = m3.mesh
		if not done.has(src):
			done[src] = _decoplanar(src)
		var out: ArrayMesh = done[src]
		if out:
			m3.mesh = out
			fixed += 1
	return fixed


static func _decoplanar(src: ArrayMesh) -> ArrayMesh:
	# все поверхности меша вместе: крыша спорит гранями разных материалов (кровля и парапет)
	var surfaces: Array = []
	var allv := PackedVector3Array()
	var alli := PackedInt32Array()
	var base := PackedInt32Array()
	for s in src.get_surface_count():
		var arr: Array = src.surface_get_arrays(s)
		surfaces.append(arr)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		base.append(allv.size())
		if src.surface_get_primitive_type(s) == Mesh.PRIMITIVE_TRIANGLES:
			var idx := PackedInt32Array()
			if arr[Mesh.ARRAY_INDEX] != null:
				idx = arr[Mesh.ARRAY_INDEX]
			if idx.is_empty():
				idx.resize(v.size())
				for i in v.size():
					idx[i] = i
			for i in idx:
				alli.append(i + allv.size())
		allv.append_array(v)
	if not _decoplanar_verts(allv, alli):
		return null
	for s in surfaces.size():
		var arr: Array = surfaces[s]
		var n: int = (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		arr[Mesh.ARRAY_VERTEX] = allv.slice(base[s], base[s] + n)
	var out := ArrayMesh.new()
	for s in surfaces.size():
		out.add_surface_from_arrays(src.surface_get_primitive_type(s), surfaces[s])
		out.surface_set_material(s, src.surface_get_material(s))
		out.surface_set_name(s, src.surface_get_name(s))
	out.resource_name = src.resource_name
	return out


static func _uf_find(par: PackedInt32Array, i: int) -> int:
	while par[i] != i:
		par[i] = par[par[i]]
		i = par[i]
	return i


## v — вершины (меняются на месте), idx — треугольники. true, если что-то сдвинули.
static func _decoplanar_verts(v: PackedVector3Array, idx: PackedInt32Array) -> bool:
	# детали = связные куски треугольников с общими вершинами (у разных коробок вершины свои)
	var par := PackedInt32Array()
	par.resize(v.size())
	for i in v.size():
		par[i] = i
	var nt := idx.size() / 3
	for t in nt:
		for k in [1, 2]:
			var ra := _uf_find(par, idx[t * 3])
			var rb := _uf_find(par, idx[t * 3 + k])
			if ra != rb:
				par[rb] = ra
	var tn: Array = []
	var td := PackedFloat32Array()
	var comp := PackedInt32Array()
	var area := {}
	tn.resize(nt)
	td.resize(nt)
	comp.resize(nt)
	var buckets := {}
	var pairs := {}
	for t in nt:
		var a: Vector3 = v[idx[t * 3]]
		var b: Vector3 = v[idx[t * 3 + 1]]
		var c: Vector3 = v[idx[t * 3 + 2]]
		var n: Vector3 = (b - a).cross(c - a)
		var l := n.length()
		comp[t] = _uf_find(par, idx[t * 3])
		if l < 2e-6:
			tn[t] = Vector3.ZERO
			continue
		n /= l
		tn[t] = n
		td[t] = n.dot(a)
		area[comp[t]] = float(area.get(comp[t], 0.0)) + l * 0.5
		var key := Vector4i(roundi(n.x * 40.0), roundi(n.y * 40.0), roundi(n.z * 40.0), roundi(td[t] / 0.002))
		var cen := (a + b + c) / 3.0
		var probes: Array = [cen, a.lerp(cen, 0.15), b.lerp(cen, 0.15), c.lerp(cen, 0.15)]
		for dk in [-1, 0, 1]:
			var k2 := Vector4i(key.x, key.y, key.z, key.w + dk)
			if not buckets.has(k2):
				continue
			for u in buckets[k2]:
				if comp[u] == comp[t] or absf(td[u] - td[t]) > 0.002 or (tn[u] as Vector3).dot(n) < 0.999:
					continue
				var a2: Vector3 = v[idx[u * 3]]
				var b2: Vector3 = v[idx[u * 3 + 1]]
				var c2: Vector3 = v[idx[u * 3 + 2]]
				var cen2 := (a2 + b2 + c2) / 3.0
				var probes2: Array = [cen2, a2.lerp(cen2, 0.15), b2.lerp(cen2, 0.15), c2.lerp(cen2, 0.15)]
				var hit := false
				for q in probes:
					if Geometry3D.ray_intersects_triangle(q + n * 0.01, -n, a2, b2, c2) != null:
						hit = true
						break
				if not hit:
					for q in probes2:
						if Geometry3D.ray_intersects_triangle(q + n * 0.01, -n, a, b, c) != null:
							hit = true
							break
				if hit:
					pairs[Vector2i(mini(comp[t], comp[u]), maxi(comp[t], comp[u]))] = n
		if not buckets.has(key):
			buckets[key] = []
		buckets[key].append(t)
	if pairs.is_empty():
		return false
	# глубина: самая большая деталь остаётся на месте, каждая меньшая — на шаг глубже той, с которой спорит
	var comps: Array = []
	var partners := {}
	for pr in pairs:
		for c in [pr.x, pr.y]:
			if not partners.has(c):
				partners[c] = []
				comps.append(c)
		partners[pr.x].append(pr.y)
		partners[pr.y].append(pr.x)
	comps.sort_custom(func(x, y): return float(area.get(x, 0.0)) > float(area.get(y, 0.0)))
	var depth := {}
	for c in comps:
		var dep := 0.0
		for o in partners[c]:
			if depth.has(o):
				dep = maxf(dep, float(depth[o]) + COPLANAR_STEP)
		depth[c] = dep
	var moved := {}
	for t in nt:
		var dep: float = float(depth.get(comp[t], 0.0))
		if dep <= 0.0 or (tn[t] as Vector3) == Vector3.ZERO:
			continue
		for k in 3:
			var vi: int = idx[t * 3 + k]
			if not moved.has(vi):
				moved[vi] = true
				v[vi] -= (tn[t] as Vector3) * dep
	return not moved.is_empty()


static func retexture(m: BaseMaterial3D, files: Array) -> void:
	var dir := "res://sanatorium/assets/tex/%s.jpg"
	for f in files:
		if not ResourceLoader.exists(dir % f):
			return
	var alb: Texture2D = load(dir % files[0])
	var nrm: Texture2D = load(dir % files[1])
	var orm: Texture2D = load(dir % files[2])
	if alb == null or nrm == null or orm == null:
		return                                       # не загрузилось (не импортировано) — остаются старые текстуры
	m.albedo_texture = alb
	m.albedo_color = Color.WHITE
	m.normal_enabled = true
	m.normal_texture = nrm
	m.normal_scale = 1.0
	m.roughness_texture = orm
	m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	m.roughness = 1.0
	m.metallic_texture = null
	m.metallic = 0.0
	m.metallic_specular = 0.5
	m.ao_enabled = true
	m.ao_texture = orm
	m.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	m.ao_light_affect = 0.0
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC


## Атлас мебели (tools/godot_assets/make_furniture_atlas.py): вдвое крупнее, настоящий шпон и ткани.
## Каналы ORM те же, что у модели (металл остаётся металлом) — меняются только сами текстуры.
static func retexture_atlas(m: BaseMaterial3D) -> void:
	var dir := "res://sanatorium/assets/tex/%s.jpg"
	for f in ["furniture_albedo", "furniture_normal", "furniture_orm"]:
		if not ResourceLoader.exists(dir % f):
			return
	var alb: Texture2D = load(dir % "furniture_albedo")
	var nrm: Texture2D = load(dir % "furniture_normal")
	var orm: Texture2D = load(dir % "furniture_orm")
	if alb == null or nrm == null or orm == null:
		return
	m.albedo_texture = alb
	m.normal_enabled = true
	m.normal_texture = nrm
	m.roughness_texture = orm
	m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	m.roughness = 1.0
	m.metallic_texture = orm
	m.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
	m.ao_enabled = true
	m.ao_texture = orm
	m.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	m.ao_light_affect = 0.0
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC


func _tune_materials() -> void:
	var seen := {}
	var g_wall: Texture2D = load("res://sanatorium/assets/grime_wall.png")
	var g_ceiling: Texture2D = load("res://sanatorium/assets/grime_ceiling.png")
	var g_floor: Texture2D = load("res://sanatorium/assets/grime_floor.png")
	for key in nodes:
		var mi = nodes[key]
		if not (mi is MeshInstance3D) or mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var m = mi.mesh.surface_get_material(i)
			if m == null or seen.has(m) or not (m is BaseMaterial3D):
				continue
			seen[m] = true
			var nm: String = m.resource_name
			if TEX_SET.has(nm):
				retexture(m, TEX_SET[nm])
			elif nm == "M_Atlas_Furniture":
				retexture_atlas(m)
			if nm in ["M_Atlas_Furniture", "M_Metal_Painted", "M_Metal_DarkSteel"]:
				m.metallic = 0.35
				m.metallic_specular = 0.5
			# Furniture is built from open boxes and single sheets (screens, partitions, backs that stand
			# against a wall), doors and signs from thin panels: drawn from one side only, such a part vanished
			# when seen from behind and left holes. Drawn from both sides (Godot flips the normal on the back).
			if nm in ["M_Atlas_Furniture", "M_Wood_DoorDark", "M_Atlas_Signs"]:
				m.cull_mode = BaseMaterial3D.CULL_DISABLED
			if nm in GRIME_WALL:
				# triplanar UV v = -(y * scale.y + offset.y): one texture height per storey, the bottom row at floor level
				_grime(m, g_wall, Vector3(1.0 / 12.0, 1.0 / STOREY, 1.0 / 12.0), Vector3(0.0, -FIRST_FLOOR / STOREY, 0.0))
			elif nm in GRIME_CEILING:
				_grime(m, g_ceiling, Vector3(1.0 / 10.0, 1.0, 1.0 / 10.0), Vector3.ZERO)
			elif nm in GRIME_FLOOR:
				_grime(m, g_floor, Vector3(1.0 / 10.0, 1.0, 1.0 / 10.0), Vector3.ZERO)
			elif nm.begins_with("M_Emissive_"):
				m.emission_energy_multiplier *= 0.45
			elif nm == "M_Glass_Clear":
				m.roughness = maxf(m.roughness, 0.22)
				if m.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
					m.albedo_color = Color(m.albedo_color.r * 0.85, m.albedo_color.g * 0.88, m.albedo_color.b * 0.8,
						maxf(m.albedo_color.a, 0.3))
	stats["materials"] = seen.size()


## Каждый этаж здания — на своём слое отрисовки (11…14), высокие общие части (лестничные марши, шахта лифта,
## фасад) — на слое 15. Лампы светят только свой этаж (lights.gd): без этого свет ламп, у которых нет тени,
## проходил сквозь перекрытия и подсвечивал стены соседних этажей там, где никакой лампы нет.
const STOREY_NODES := ["Floor1_Ground", "Floor2", "Floor3", "Floor4"]
const STOREY_BIT0 := 10
const SHARED_BIT := 14


func _assign_storey_layers() -> void:
	# марши лестниц касались стены лестничной клетки той же плоскостью — тень на стене «рябила»: на 4 мм от стены
	for nm in ["Stair1_Flights", "Stair2_Flights", "Stair3_Flights"]:
		var fl3: Node = building.find_child(nm, true, false)
		if fl3 is Node3D:
			(fl3 as Node3D).position.z += 0.004
	var inter: Node = building.find_child("Interior", true, false)
	var shared := 1 << SHARED_BIT
	var n := 0
	if inter:
		for fl in inter.get_children():
			var s: int = STOREY_NODES.find(String(fl.name))
			for gi in fl.find_children("*", "GeometryInstance3D", true, false):
				var g3: GeometryInstance3D = gi
				var box: AABB = g3.global_transform * g3.get_aabb()
				g3.layers = shared if (s < 0 or box.size.y > 3.7) else (1 << (STOREY_BIT0 + s))
				n += 1
	for gi in building.find_children("*", "GeometryInstance3D", true, false):
		if inter and inter.is_ancestor_of(gi):
			continue
		(gi as GeometryInstance3D).layers = shared
	# кабина лифта ездит между этажами — её освещает тот этаж, где игрок
	if lift and lift.cabin:
		for gi in lift.cabin.find_children("*", "GeometryInstance3D", true, false):
			(gi as GeometryInstance3D).layers = 1
	stats["storey_layered"] = n


func _build_static_colliders() -> void:
	var n := 0
	var ext: Node = node("SovietSchool_1970s")
	var targets := []
	for key in nodes:
		var nd = nodes[key]
		if not (nd is MeshInstance3D):
			continue
		for p in COLLIDE_PREFIX:
			if String(key).begins_with(p):
				targets.append(nd)
				break
	if ext:
		var stack := [ext]
		while stack.size() > 0:
			var e: Node = stack.pop_back()
			if e is MeshInstance3D:
				targets.append(e)
			stack.append_array(e.get_children())
	for mi in targets:
		if mi.mesh == null:
			continue
		var body := StaticBody3D.new()
		body.collision_layer = L_WORLD
		body.collision_mask = 0
		var cs := CollisionShape3D.new()
		cs.shape = mi.mesh.create_trimesh_shape()
		body.add_child(cs)
		mi.add_child(body)
		n += 1
	stats["trimesh_colliders"] = n


func _build_occluders_and_ranges() -> void:
	var occ := 0
	var ranged := 0
	for key in nodes:
		var mi = nodes[key]
		if not (mi is MeshInstance3D) or mi.mesh == null:
			continue
		var sk := String(key)
		if sk.begins_with("Shell_"):
			var verts := PackedVector3Array()
			var idx := PackedInt32Array()
			for s in mi.mesh.get_surface_count():
				var arr: Array = mi.mesh.surface_get_arrays(s)
				var base := verts.size()
				verts.append_array(arr[Mesh.ARRAY_VERTEX])
				var ii: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
				for k in ii:
					idx.append(base + k)
			var ao := ArrayOccluder3D.new()
			ao.set_arrays(verts, idx)
			var oi := OccluderInstance3D.new()
			oi.occluder = ao
			mi.add_child(oi)
			occ += 1
			continue
		if sk.begins_with(("Fix_")) or sk.begins_with("Shell") or sk.begins_with("Stair") or sk.begins_with("Lift"):
			continue
		# Small things and furniture are not drawn far away (occlusion by the walls hides most of them anyway).
		# They used to vanish at 12 and 32 m with a visible pop; now they are kept to 25 and 45 m and fade out
		# smoothly (Godot draws them with transparency only while they fade). Farther still cost too much on a
		# MacBook: every piece of furniture in range also draws into the moon's shadow. Up close every mesh also uses
		# Godot's automatic LODs: fewer triangles the smaller it is on screen.
		var aabb: AABB = mi.get_aabb()
		var sz: float = aabb.size.length()
		if sz < 0.45:
			mi.visibility_range_end = 25.0
			mi.visibility_range_end_margin = 5.0
			mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			ranged += 1
		elif sz < 2.6 and aabb.position.length() < 6.0:
			mi.visibility_range_end = 45.0
			mi.visibility_range_end_margin = 8.0
			mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			ranged += 1
	stats["occluders"] = occ
	stats["ranged_meshes"] = ranged


func _box_shape(body: Node3D, mn: Vector3, mx: Vector3) -> CollisionShape3D:
	var a: Vector3 = mn.min(mx)
	var b: Vector3 = mn.max(mx)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = (b - a).max(Vector3(0.02, 0.02, 0.02))
	cs.shape = bs
	cs.position = (a + b) * 0.5
	body.add_child(cs)
	return cs


func _build_furniture_colliders() -> void:
	var body := StaticBody3D.new()
	body.name = "FurnitureColliders"
	body.collision_layer = L_WORLD
	body.collision_mask = 0
	add_child(body)
	for b in level["boxes"]:
		_box_shape(body, _v3(b["min"]), _v3(b["max"]))
	for b in level["rot_boxes"]:
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = _v3(b["size"])
		cs.shape = bs
		cs.position = _v3(b["center"])
		cs.rotation.y = float(b["yaw"])
		body.add_child(cs)
	stats["furniture_boxes"] = body.get_child_count()


var _blockers: StaticBody3D


## Invisible walls where a flight of stairs starts or the floor drops away (the chair cannot use stairs).
## level.json draws each one across the whole stair well; _trim_blockers keeps only the stretches that
## really border a step or a drop, so no invisible wall stands on open floor.
func _build_blockers() -> void:
	_blockers = StaticBody3D.new()
	_blockers.name = "StairBlockers"
	_blockers.collision_layer = L_WORLD
	add_child(_blockers)
	for b in level["blockers"]:
		_box_shape(_blockers, _v3(b["min"]), _v3(b["max"]))
	stats["stair_blockers"] = _blockers.get_child_count()
	_trim_blockers.call_deferred()


func _trim_blockers() -> void:
	await get_tree().physics_frame      # the building's colliders are in the physics space now
	var space := get_world_3d().direct_space_state
	var kept := []
	for b in level["blockers"]:
		var mn := _v3(b["min"])
		var mx := _v3(b["max"])
		var along_x: bool = (mx.x - mn.x) > (mx.z - mn.z)
		var a: float = mn.x if along_x else mn.z
		var span: float = (mx.x - mn.x) if along_x else (mx.z - mn.z)
		var thin: float = (mn.z + mx.z) * 0.5 if along_x else (mn.x + mx.x) * 0.5
		var in_run := false
		var run_start := 0.0
		var n := int(ceil(span / 0.1))
		for i in n + 1:
			var s: float = a + minf(i * 0.1, span)
			var need := false
			if i < n:
				var probe := s + 0.05
				for side in [-0.3, 0.3]:
					var p := Vector3(probe, mn.y + 1.4, thin + side) if along_x else Vector3(thin + side, mn.y + 1.4, probe)
					var q := PhysicsRayQueryParameters3D.create(p, p + Vector3(0, -3.0, 0), L_WORLD, [_blockers.get_rid()])
					var hit := space.intersect_ray(q)
					if hit.is_empty() or absf(float(hit["position"].y) - mn.y) > 0.04:
						need = true
			if need and not in_run:
				in_run = true
				run_start = s
			elif not need and in_run:
				kept.append([along_x, run_start - 0.05, s + 0.05, mn, mx])
				in_run = false
		if in_run:
			kept.append([along_x, run_start - 0.05, a + span + 0.05, mn, mx])
	for c in _blockers.get_children():
		c.free()
	for k in kept:
		var mn: Vector3 = k[3]
		var mx: Vector3 = k[4]
		if k[0]:
			_box_shape(_blockers, Vector3(maxf(k[1], mn.x - 0.05), mn.y, mn.z), Vector3(minf(k[2], mx.x + 0.05), mx.y, mx.z))
		else:
			_box_shape(_blockers, Vector3(mn.x, mn.y, maxf(k[1], mn.z - 0.05)), Vector3(mx.x, mx.y, minf(k[2], mx.z + 0.05)))
	stats["stair_blockers"] = _blockers.get_child_count()


func _build_doors() -> void:
	var holder := Node3D.new()
	holder.name = "Doors"
	add_child(holder)
	var groups := {}
	for d in level["doors"]:
		var g = groups.get(d["group"])
		if g == null:
			g = DoorGroup.new()
			g.game = self
			holder.add_child(g)
			groups[d["group"]] = g
			door_groups.append(g)
		g.add_leaf(d, node(d["name"]))
	var opened := 0
	for g in door_groups:
		g.finish_setup()
		# the building is half abandoned: some doors were left ajar
		if not g.locked and not g.ext and rng.randf() < 0.14:
			g.set_angle(rng.randf_range(12.0, 75.0))
			opened += 1
	stats["doors"] = door_groups.size()
	stats["doors_ajar"] = opened


func _build_switches() -> void:
	var n := 0
	for s in level["switches"]:
		var sw = Switch.new()
		sw.game = self
		sw.room = s["room"]
		add_child(sw)
		sw.global_position = _v3(s["pos"])
		n += 1
	stats["switches"] = n


## On a Retina Mac the 1280x720 window from project.godot opens at half size: make it about
## 80 % of the screen instead (the UI scales with it, see window/stretch in project.godot).
func _fit_window_macos() -> void:
	if not OS.has_feature("macos") or DisplayServer.get_name() == "headless":
		return
	var w := get_window()
	w.title = "Санаторий"   # the Mac bundle is named "Sanatorium" (project.godot config/name.macos)
	if w.mode != Window.MODE_WINDOWED:
		return
	var area: Rect2i = DisplayServer.screen_get_usable_rect(w.current_screen)
	var width := int(min(area.size.x * 0.8, area.size.y * 0.8 * 16.0 / 9.0))
	w.size = Vector2i(width, int(width * 9.0 / 16.0))
	w.position = area.position + (area.size - w.size) / 2


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("quality") and quality:
		quality.cycle()
		return
	if event.is_action_pressed("fps_limit") and quality:
		quality.toggle_fps_limit()
		return
	if event.is_action_pressed("fullscreen"):
		var w := get_window()
		w.mode = Window.MODE_WINDOWED if w.mode == Window.MODE_FULLSCREEN else Window.MODE_FULLSCREEN
