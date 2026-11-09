@tool
class_name ForestWorld
extends Node3D
## Main scene: loads the baked world (resources/world/world.json), builds the terrain, the road and
## the forest, places the car and the camera, applies graphics presets and drives the per-frame
## systems (terrain LOD, vegetation LOD, global shader parameters).
##
## Command-line options (after --):  --test  --shots --out=<dir>  --bench --out=<dir>  --quality=<low|medium|high|ultra>
##                                   --start=<metres along the road>  --mode=<chase|hood|cinematic|free>

@export_range(0.0, 1.0) var wetness := 0.4
@export var wind_direction := Vector2(0.8, 0.6)
@export_range(0.0, 2.0) var wind_strength := 0.55
@export var wind_speed := 1.0
@export var marking_style := 0      # 0 = double yellow centre line (as in the reference), 1 = European
## Build terrain, road and forest inside the editor too (generated nodes are never saved into the scene).
@export var editor_preview := true

@onready var terrain: TerrainSystem = $Terrain
@onready var road: RoadBuilder = $Road
@onready var forest: ForestGenerator = $Forest
@onready var env: WorldEnvironment = $WorldEnvironment
@onready var sun: DirectionalLight3D = $Sun
@onready var rig: CameraRig = $CameraRig
@onready var hud: ForestHUD = $HUD

var car: ForestCar
var meta: Dictionary = {}
var ready_done := false
var build_ms := {}
var _base_fog := 0.0
var _base_vol_fog := 0.0
var _base_exposure := 1.0
var _loading: Label
var debug_lod := false


func _ready() -> void:
	if Engine.is_editor_hint():
		if editor_preview:
			_build_editor_preview.call_deferred()
		return
	_setup_input()
	_loading = Label.new()
	_loading.text = "Loading the forest…"
	_loading.add_theme_font_size_override("font_size", 28)
	_loading.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	hud.add_child(_loading)
	await get_tree().process_frame
	await get_tree().process_frame
	_build()


func _build() -> void:
	var t0 := Time.get_ticks_msec()
	meta = JSON.parse_string(FileAccess.get_file_as_string("res://resources/world/world.json"))
	terrain.load_world(meta)
	build_ms["terrain"] = Time.get_ticks_msec() - t0
	var t1 := Time.get_ticks_msec()
	road.build(JSON.parse_string(FileAccess.get_file_as_string(str(meta["road"]))))
	build_ms["road"] = Time.get_ticks_msec() - t1
	var t2 := Time.get_ticks_msec()
	forest.build(meta, terrain)
	forest.lod_manager.sun_light = sun
	build_ms["forest"] = Time.get_ticks_msec() - t2
	car = preload("res://scenes/vehicle/car.tscn").instantiate()
	add_child(car)
	var start := 40.0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--start="):
			start = float(arg.get_slice("=", 1))
	car.reset_to(_road_spawn(start))
	rig.car = car
	rig.road = road
	rig.terrain = terrain
	var mode := CameraRig.Mode.CHASE
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mode="):
			mode = ["chase", "hood", "cinematic", "free"].find(arg.get_slice("=", 1)) as CameraRig.Mode
	rig.set_mode(maxi(int(mode), 0))
	rig.place_cinematic(start)
	_base_fog = env.environment.fog_density
	_base_vol_fog = env.environment.volumetric_fog_density
	_base_exposure = env.environment.tonemap_exposure
	GraphicsSettings.changed.connect(_apply_settings)
	_apply_settings(GraphicsSettings.settings)
	(road.material as ShaderMaterial).set_shader_parameter("marking_style", marking_style)
	_update_globals()
	terrain.update_lods(rig.camera.global_position, true)
	forest.lod_manager.update_now(rig.camera)
	build_ms["total"] = Time.get_ticks_msec() - t0
	_loading.queue_free()
	hud.world = self
	ready_done = true
	print("Forest Drive loaded in %d ms  %s" % [build_ms["total"], JSON.stringify(build_ms)])
	if GraphicsSettings.auto_detected:
		hud.toast("Graphics: %s (auto-detected, press G to change)" % GraphicsSettings.settings["name"])
	var args := OS.get_cmdline_user_args()
	if "--test" in args or "--shots" in args or "--bench" in args:
		var runner = load("res://tests/test_runner.gd").new()
		add_child(runner)
		runner.run(self, args)


## Editor preview: same world, LOD driven by the editor's 3D camera, High preset settings.
func _build_editor_preview() -> void:
	meta = JSON.parse_string(FileAccess.get_file_as_string("res://resources/world/world.json"))
	terrain.load_world(meta, false)
	road.build(JSON.parse_string(FileAccess.get_file_as_string(str(meta["road"]))), false)
	forest.build(meta, terrain)
	forest.lod_manager.sun_light = sun
	var s: Dictionary = preload("res://scripts/graphics_settings.gd").PRESETS[2].duplicate()
	s["name"] = "High"
	forest.configure(s)
	RenderingServer.global_shader_parameter_set("far_shadow", Vector2(100.0, 130.0))
	ready_done = true
	print("Forest Drive editor preview: %d instances in %d variants" % [
		forest.lod_manager.total_instances(), forest.lod_manager.variants.size()])


func _editor_camera() -> Camera3D:
	var ei := Engine.get_singleton("EditorInterface")
	if ei == null:
		return null
	var vp: SubViewport = ei.call("get_editor_viewport_3d", 0)
	return vp.get_camera_3d() if vp else null


func _road_spawn(s: float) -> Transform3D:
	var xf := road.sample(s, -road.lane_width * 0.5)
	xf.origin += Vector3.UP * 0.6
	return xf


func _process(_delta: float) -> void:
	if not ready_done:
		return
	if Engine.is_editor_hint():
		var cam := _editor_camera()
		if cam:
			RenderingServer.global_shader_parameter_set("main_camera_pos", cam.global_position)
			terrain.update_lods(cam.global_position)
			forest.lod_manager.update(cam)
		return
	_update_globals()
	terrain.update_lods(rig.camera.global_position)
	forest.lod_manager.update(rig.camera)


func _update_globals() -> void:
	RenderingServer.global_shader_parameter_set("main_camera_pos", rig.camera.global_position)
	var wd := wind_direction.normalized()
	RenderingServer.global_shader_parameter_set("wind", Vector4(wd.x, wd.y, wind_strength, wind_speed))
	RenderingServer.global_shader_parameter_set("wetness", wetness)


func _apply_settings(s: Dictionary) -> void:
	var e := env.environment
	e.ssao_enabled = s["ssao"]
	e.ssil_enabled = s["ssil"]
	e.ssr_enabled = s["ssr"]
	e.glow_enabled = s["glow"]
	e.volumetric_fog_enabled = s["volumetric_fog"]
	e.fog_density = _base_fog * float(s["fog_scale"]) * (0.75 if s["volumetric_fog"] else 1.0)
	e.volumetric_fog_density = _base_vol_fog
	# the Mobile renderer has a narrower HDR range and no SSAO/SSIL: lift the exposure a little
	e.tonemap_exposure = _base_exposure * (1.3 if GraphicsSettings.is_mobile_renderer() else 1.0)
	sun.directional_shadow_max_distance = s["shadow_distance"]
	# 2 or 4 PSSM splits; "3" = 4 splits with the last one folded away by the split ratios
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if int(s["shadow_splits"]) <= 2 else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	match int(s["shadow_splits"]):
		3:
			sun.directional_shadow_split_1 = 0.1
			sun.directional_shadow_split_2 = 0.33
			sun.directional_shadow_split_3 = 0.999
		4:
			sun.directional_shadow_split_1 = 0.07
			sun.directional_shadow_split_2 = 0.2
			sun.directional_shadow_split_3 = 0.45
		_:
			sun.directional_shadow_split_1 = 0.2
	sun.light_angular_distance = s["sun_angular"]
	var sd := float(s["shadow_distance"])
	RenderingServer.global_shader_parameter_set("far_shadow", Vector2(sd * 0.75, sd * 0.98))
	RenderingServer.global_shader_parameter_set("shadow_coarse", bool(s["shadow_coarse"]))
	rig.camera.far = s["far_plane"]
	terrain.lod_scale = s["terrain_lod_scale"]
	terrain.near_chunk_shadows = int(s["preset"]) >= GraphicsSettings.Preset.HIGH
	for c in terrain.chunks:
		c["lod"] = -1          # re-apply LOD + shadow flags
	terrain.update_lods(rig.camera.global_position, true)
	(terrain.material as ShaderMaterial).set_shader_parameter("anti_tiling", s["terrain_anti_tiling"])
	forest.configure(s)
	if ready_done:
		hud.toast("Graphics: %s" % s["name"])


func _unhandled_input(event: InputEvent) -> void:
	if not ready_done or Engine.is_editor_hint():
		return
	if event.is_action_pressed("camera_next"):
		rig.next_mode()
		hud.toast(CameraRig.MODE_NAMES[rig.mode])
	elif event.is_action_pressed("quality_next"):
		GraphicsSettings.cycle()
	elif event.is_action_pressed("fps_cap"):
		GraphicsSettings.toggle_fps_cap()
		hud.toast("Frame cap: %s" % ("30 fps" if GraphicsSettings.fps_cap > 0 else "off"))
	elif event.is_action_pressed("toggle_stats"):
		hud.toggle_stats()
	elif event.is_action_pressed("toggle_help"):
		hud.toggle_help()
	elif event.is_action_pressed("debug_lod"):
		debug_lod = not debug_lod
		RenderingServer.global_shader_parameter_set("debug_lod", debug_lod)
		hud.toast("LOD view: red LOD0 · green LOD1 · blue LOD2 · yellow ground cover" if debug_lod else "LOD view off")
	elif event.is_action_pressed("reset_car"):
		car.reset_to(_road_spawn(road.nearest_s(car.global_position)))
	elif event.is_action_pressed("wetter"):
		wetness = minf(wetness + 0.1, 1.0)
		hud.toast("Road wetness %d %%" % int(wetness * 100))
	elif event.is_action_pressed("drier"):
		wetness = maxf(wetness - 0.1, 0.0)
		hud.toast("Road wetness %d %%" % int(wetness * 100))
	elif event.is_action_pressed("fullscreen"):
		var w := get_window()
		w.mode = Window.MODE_WINDOWED if w.mode == Window.MODE_FULLSCREEN else Window.MODE_FULLSCREEN
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func hud_line() -> String:
	var spd := car.speed_kmh if rig.mode != CameraRig.Mode.CINEMATIC else rig.cinematic_speed * 3.6
	return "%3d km/h    %3d fps    %s    %s" % [absi(int(spd)), Engine.get_frames_per_second(),
			GraphicsSettings.settings["name"], CameraRig.MODE_NAMES[rig.mode]]


func get_terrain_triangles() -> int:
	return int(terrain.stats["allocated_triangles"])


func get_road_triangles() -> int:
	return road.triangles


func stats_text() -> String:
	var p := PerfStats.snapshot(self)
	var lm := forest.lod_manager.stats
	return "GPU %s (%s)\nframe %.1f ms   draw calls %d main + %d shadow   objects %d\ntriangles submitted: %s main + %s shadow\ninstances drawn  LOD0 %d  LOD1 %d  LOD2 %d  ground cover %d\nterrain chunks by LOD %s   LOD update %.1f ms (+%.1f ms upload)\nvideo memory %.0f MB (textures %.0f MB, buffers %.0f MB)   RAM %.0f MB   nodes %d" % [
		p["gpu"], p["renderer"], p["frame_ms"], p["main_draw_calls"], p["shadow_draw_calls"], p["main_objects"],
		_fmt(p["main_primitives"]), _fmt(p["shadow_primitives"]),
		lm["visible_instances"][0], lm["visible_instances"][1], lm["visible_instances"][2], lm["visible_instances"][3],
		str(terrain.stats["chunk_lods"]), lm["last_update_ms"], lm["apply_ms"],
		p["video_mem_mb"], p["texture_mem_mb"], p["buffer_mem_mb"], p["ram_static_mb"], p["nodes"]]


static func _fmt(n: float) -> String:
	if n >= 1e6:
		return "%.2fM" % (n / 1e6)
	return "%dk" % int(n / 1000.0)


func _setup_input() -> void:
	var map := {
		"accelerate": [KEY_W, KEY_UP], "brake": [KEY_S, KEY_DOWN], "steer_left": [KEY_A, KEY_LEFT],
		"steer_right": [KEY_D, KEY_RIGHT], "handbrake": [KEY_SPACE], "reset_car": [KEY_R],
		"camera_next": [KEY_C, KEY_TAB], "quality_next": [KEY_G], "fps_cap": [KEY_L], "toggle_stats": [KEY_F3],
		"toggle_help": [KEY_F1], "free_up": [KEY_E], "free_down": [KEY_Q], "free_fast": [KEY_SHIFT],
		"wetter": [KEY_BRACKETRIGHT], "drier": [KEY_BRACKETLEFT], "fullscreen": [KEY_F11], "debug_lod": [KEY_F4],
	}
	for action in map:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.2)
		for key in map[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)
	var pads := {"accelerate": JOY_AXIS_TRIGGER_RIGHT, "brake": JOY_AXIS_TRIGGER_LEFT}
	for action in pads:
		var ev := InputEventJoypadMotion.new()
		ev.axis = pads[action]
		ev.axis_value = 1.0
		InputMap.action_add_event(action, ev)
	for spec in [["steer_left", -1.0], ["steer_right", 1.0]]:
		var ev := InputEventJoypadMotion.new()
		ev.axis = JOY_AXIS_LEFT_X
		ev.axis_value = spec[1]
		InputMap.action_add_event(spec[0], ev)
	var cam_btn := InputEventJoypadButton.new()
	cam_btn.button_index = JOY_BUTTON_Y
	InputMap.action_add_event("camera_next", cam_btn)
