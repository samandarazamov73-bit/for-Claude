extends Node3D
## Entry point: sets up environment, generates the city, camera, character and HUD.
##
## Command-line options (after "--"), used for automated screenshots:
##   view=hero|street|bakery|bank|avenue|aerial|top|walk   time=day|golden|dusk|night
##   quality=low|medium|high   shot=<file name>   frames=<n>  (saves user://shots/<file>.png and quits)

const VIEWS := {
	"hero": [Vector3(-5.0, 1.7, 15.5), Vector3(11.0, 11.2, -10.7), 59.0],
	"street": [Vector3(0.6, 1.7, -2.5), Vector3(0.6, 5.5, -80.0), 62.0],
	"avenue": [Vector3(-2.0, 1.2, 6.0), Vector3(1.0, 14.0, -60.0), 72.0],
	"bakery": [Vector3(-5.5, 2.2, -36.0), Vector3(11.0, 8.0, -40.0), 70.0],
	"bank": [Vector3(4.0, 3.0, 4.0), Vector3(-14.0, 6.0, -16.0), 66.0],
	"aerial": [Vector3(-120.0, 120.0, 120.0), Vector3(10.0, 0.0, -40.0), 50.0],
	"skyline": [Vector3(-380.0, 70.0, 260.0), Vector3(0.0, 20.0, -60.0), 45.0],
}

var env_ctrl: EnvironmentController
var city: CityGenerator
var cam: CameraController
var player: Player
var hud: Hud
var night_lights: NightLights
var args := {}
var _gen_time := 0.0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			args[kv[0]] = kv[1]
	env_ctrl = EnvironmentController.new()
	env_ctrl.name = "Environment"
	add_child(env_ctrl)
	if args.has("quality"):
		env_ctrl.set_quality(args.quality)
	hud = Hud.new()
	add_child(hud)
	cam = CameraController.new()
	cam.name = "Camera"
	add_child(cam)
	await get_tree().process_frame
	await get_tree().process_frame

	var t0 := Time.get_ticks_msec()
	city = CityGenerator.new()
	city.name = "City"
	add_child(city)
	city.generate(env_ctrl.quality_settings())
	_gen_time = (Time.get_ticks_msec() - t0) / 1000.0
	print("City generated in %.2f s (%d chunks, %d buildings)" % [_gen_time, city.chunks.size(), city.bgen.buildings.size()])

	# ground collision at asphalt level (sidewalk slabs and buildings have their own shapes)
	var ground := StaticBody3D.new()
	var gs := CollisionShape3D.new()
	gs.shape = WorldBoundaryShape3D.new()
	ground.add_child(gs)
	ground.position.y = -CityGenerator.CURB_H
	add_child(ground)

	player = Player.new()
	player.name = "Player"
	add_child(player)
	player.teleport(Vector3(-8.0, 0.2, 9.0))
	cam.player = player

	night_lights = NightLights.new()
	night_lights.env_ctrl = env_ctrl
	add_child(night_lights)
	night_lights.setup(city.lamp_lights, 16 if env_ctrl.current_quality == "high" else 10)

	hud.main_ref = self
	hud.set_loading("")
	if args.has("time"):
		env_ctrl.set_time(args.time, true)
	if args.has("view"):
		_apply_view(args.view)
	if args.get("adaptive", "1") == "0":
		env_ctrl.adaptive = false
	if args.has("shot"):
		_take_shot_and_quit()
	elif args.has("shots"):
		_take_shots_and_quit(args.shots.split(","))


func _apply_view(v: String) -> void:
	if v == "top":
		cam.pivot = Vector3(0, 0, -60)
		cam.top_height = 640.0
		cam.set_mode(CameraController.Mode.TOP)
		return
	if v == "walk":
		cam.pivot = Vector3(-8, 0, 8)
		cam.set_mode(CameraController.Mode.WALK)
		cam.walk_yaw = deg_to_rad(-140.0)
		return
	if VIEWS.has(v):
		var d: Array = VIEWS[v]
		cam.set_mode(CameraController.Mode.FLY)
		cam.global_position = d[0]
		cam.look_at(d[1], Vector3.UP)
		cam.fov = d[2]


func _take_shot_and_quit() -> void:
	var frames := int(args.get("frames", "12"))
	for i in frames:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("user://shots")
	img.save_png("user://shots/%s.png" % args.shot)
	var info := "draws=%d objects=%d prims=%d vram=%.0fMB gen=%.2fs" % [
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / 1048576.0, _gen_time]
	print("SHOT %s %s" % [args.shot, info])
	get_tree().quit()


## Batch mode: shots=view[:time],view[:time],...  -> user://shots/<view>_<time>.png
func _take_shots_and_quit(list: PackedStringArray) -> void:
	hud.help.visible = false
	for item in list:
		var parts := item.split(":")
		var v := parts[0]
		var t := parts[1] if parts.size() > 1 else "day"
		env_ctrl.set_time(t, true)
		_apply_view(v)
		for i in int(args.get("frames", "8")):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		DirAccess.make_dir_recursive_absolute("user://shots")
		get_viewport().get_texture().get_image().save_png("user://shots/%s_%s.png" % [v, t])
		print("SHOT %s_%s draws=%d prims=%d" % [v, t,
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)])
	get_tree().quit()


func status_text() -> String:
	return "%s\nTime: %s   Quality: %s%s" % [cam.mode_name(), env_ctrl.current_time.capitalize(),
		env_ctrl.current_quality.capitalize(), "  (adaptive)" if env_ctrl.adaptive else ""]


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match (event as InputEventKey).keycode:
		KEY_1: cam.set_mode(CameraController.Mode.ORBIT)
		KEY_2: cam.set_mode(CameraController.Mode.TOP)
		KEY_3: cam.set_mode(CameraController.Mode.FLY)
		KEY_4, KEY_G: cam.set_mode(CameraController.Mode.WALK)
		KEY_R, KEY_HOME: cam.reset_view()
		KEY_N: env_ctrl.cycle_time()
		KEY_F2:
			env_ctrl.cycle_quality()
			night_lights.setup(city.lamp_lights, 16 if env_ctrl.current_quality == "high" else 10)
		KEY_F3: hud.show_stats = not hud.show_stats
		KEY_F4: env_ctrl.adaptive = not env_ctrl.adaptive
		KEY_H: hud.help.visible = not hud.help.visible
		KEY_F12:
			DirAccess.make_dir_recursive_absolute("user://screenshots")
			var path := "user://screenshots/city_%d.png" % Time.get_unix_time_from_system()
			get_viewport().get_texture().get_image().save_png(path)
			print("Saved ", ProjectSettings.globalize_path(path))
		KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
