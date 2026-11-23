extends Node
## Проверка без игрока: загружает сцену, проматывает сюжет и сохраняет скриншоты.
## Запуск: godot --path . res://tests/shots.tscn -- --case=<имя> --out=<папка> [--quality=medium]
## Случаи: bus, bus_mom, walk, building, entrance, sanatorium, chase, void, floor3, items, tour, epilogue, menu, anim;
## playthrough — вся история (--from=глава, --snaps — со скриншотами).

var out := "user://shots"
var case_name := "bus"
var _log: Array = []


func _ready() -> void:
	GameStateRef().auto_lines = true           # реплики в тесте идут сами
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--case="):
			case_name = a.get_slice("=", 1)
		elif a.begins_with("--out="):
			out = a.get_slice("=", 1)
	DirAccess.make_dir_recursive_absolute(out)
	_run.call_deferred()


func shot(nm: String) -> void:
	# медленный программный рендер: лес и земля догружаются принудительно, как в игре за несколько кадров
	var sc: Node = get_tree().current_scene
	if sc and sc.get("forest") != null and sc.get("cam") != null:
		RenderingServer.global_shader_parameter_set("main_camera_pos", sc.cam.global_position)
		sc.terrain.update_lods(sc.cam.global_position, true)
		sc.forest.lod_manager.update_now(sc.cam)
	await get_tree().process_frame
	await get_tree().process_frame
	var img: Image = get_tree().root.get_viewport().get_texture().get_image()
	img.save_jpg("%s/%s.jpg" % [out, nm], 0.85)
	print("SHOT ", nm)


func frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func secs(t: float) -> void:
	var end: int = Time.get_ticks_msec() + int(t * 1000.0)
	while Time.get_ticks_msec() < end:
		await get_tree().process_frame


func _run() -> void:
	match case_name:
		"anim":
			await _anim()
		"bus", "bus_mom", "walk", "building", "torch":
			await _prologue()
		"entrance":
			await _entrance()
		"skytest":
			await _skytest()
		"sanatorium", "chase", "void", "floor3", "chair", "chase2", "trap", "void2", "brothers", "beatpose", "tour", "voidtour", "mompose", "items":
			await _sanatorium()
		"panorama":
			await _panorama()
		"lightlab":
			await _lightlab()
		"epilogue":
			get_tree().change_scene_to_file("res://story/epilogue.tscn")
			for k in 3:
				await secs(8.0)
				await shot("epilogue_%d" % k)
			if _arg("credits", "") != "":                    # до титров: время ×6, титры — как есть
				Engine.time_scale = 6.0
				var ep: Node = get_tree().current_scene
				var w := 0.0
				while not ep.get("_done") and w < 120.0:
					await get_tree().process_frame
					w += get_process_delta_time() / 6.0
				await shot("epilogue_end_0")
				Engine.time_scale = 1.0
				for k in [3.0, 6.0, 9.0]:
					await secs(k)
					await shot("epilogue_end_%d" % int(k))
		"forest_main":
			get_tree().change_scene_to_file("res://scenes/main.tscn")
			await secs(25.0)
			await shot("forest_main")
		"playthrough":
			await _playthrough()
		"prologue_play":
			await _prologue_play()
		"caught":
			await _caught_test()
		"fair":
			await _fair_test()
		"menu":
			get_tree().change_scene_to_file("res://story/menu.tscn")
			await secs(2.0)
			await shot("menu")
	print("CASE DONE ", case_name)
	get_tree().quit()


func _anim() -> void:
	for path in ["res://characters/mom.glb", "res://characters/grandpa.glb", "res://characters/psycho.glb"]:
		var sc: Node = (load(path) as PackedScene).instantiate()
		var ap: AnimationPlayer = sc.find_children("*", "AnimationPlayer", true, false)[0]
		var names: Array = []
		for n in ap.get_animation_list():
			names.append("%s(loop=%d, %.2fs)" % [n, ap.get_animation(n).loop_mode, ap.get_animation(n).length])
		print("ANIMS ", path, " ", names)
		sc.free()


func _prologue() -> void:
	get_tree().change_scene_to_file("res://story/prologue.tscn")
	await secs(1.0)
	var p: Node = get_tree().current_scene
	while p == null or p.get("phase") == "load":
		await get_tree().process_frame
		p = get_tree().current_scene
	GameStateRef().set_fade(0.0)
	match case_name:
		"bus":
			await secs(20.0)
			print("LOD ", p.forest.lod_manager.stats, " cam ", p.cam.global_position, " far ", p.cam.far, " s ", p.s)
			await shot("bus_window")
			p.look_yaw = -1.6
			p.look_pitch = 0.0
			await secs(6.0)
			await shot("bus_front_start")
			p.look_yaw = 0.0
			p.s = fposmod(p.s_stop - 900.0, p.road.length)
			await secs(30.0)
			print("LOD2 ", p.forest.lod_manager.stats, " cam ", p.cam.global_position, " s ", p.s)
			await shot("bus_window_later")
			p.look_yaw = -1.3
			p.look_pitch = 0.12
			await secs(1.5)
			await shot("bus_left_mom")
			p.look_yaw = -1.6
			p.look_pitch = 0.0
			await secs(1.5)
			await shot("bus_front")
		"bus_mom":
			p.look_yaw = -1.3
			p.look_pitch = 0.15
			await secs(8.0)
			await shot("bus_mom_window")
			p.talking = true
			await secs(10.0)
			await shot("bus_mom_talk")
			p.talking = false
			p.say("mom", "Он нас ждёт, Азиз.", 8.0)
			await secs(2.5)
			await shot("bus_mom_speaking")
		"walk", "building", "torch":
			p.s = p.s_stop - 0.2
			p.v = 0.0
			p.phase = "arrive"
			p._go_outside()
			await secs(4.0)
			await shot("walk_start")
			if case_name == "torch":
				p.hero.global_position = p._path_at(40.0)
				p.walk_s = 40.0
				p.mom_s = 44.0
				p.torch.visible = true
				p.set_day(0.9)
				await secs(3.0)
				await shot("torch_night")
				return
			if case_name == "building":
				p.walk_s = 95.0
				p.hero.global_position = p._path_at(95.0)
				p.mom_s = 98.0
				await secs(3.0)
				await shot("walk_building")
			else:
				p.hero.global_position = p._path_at(40.0)
				p.walk_s = 40.0
				p.mom_s = 43.0
				await secs(3.0)
				await shot("walk_mid")
				p.torch.visible = true
				p.set_day(0.85)
				await secs(1.0)
				await shot("walk_dark_torch")


## Пандус, дверь, въезд в тамбур и переход в санаторий (кадры от первого лица и со стороны).
func _entrance() -> void:
	get_tree().change_scene_to_file("res://story/prologue.tscn")
	await secs(1.0)
	var p: Node = get_tree().current_scene
	while p == null or p.get("phase") == "load":
		await get_tree().process_frame
		p = get_tree().current_scene
	GameStateRef().set_fade(0.0)
	# дождаться, пока начало поездки (заголовок, задание, первая реплика) отыграет, чтобы не мешало на кадрах
	var waited := 0.0
	while not str(p.ui._objective.text).contains("Поговори") and waited < 180.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	await secs(1.0)
	p._skip = true
	await secs(1.0)
	p.s = p.s_stop - 0.2
	p.v = 0.0
	p.phase = "arrive"
	p._go_outside()
	await secs(4.0)
	p._skip = true
	p._events = {"crow": true, "snap": true, "dark": true, "building": true}
	# тест перескочил поездку: её заголовок и реплики ещё «идут» — на кадрах они не нужны
	p.ui._title.visible = false
	p.ui._subtitle2.visible = false
	p._skip = true
	p.set_day(0.86)
	p.walk_s = p.forest_end_s - 0.5
	p.hero.global_position = p._path_at(p.walk_s)
	p.mom_s = p.walk_s + 3.0
	await secs(1.5)
	print("ENT guided=", p.guided, " walk_s=", p.walk_s, " forest_end=", p.forest_end_s, " door_stop=", p.door_stop_s, " end=", p.path_cum[-1])
	for spot in [["ent_ramp_foot", 18.5], ["ent_ramp_lower", 24.0], ["ent_ramp_turn", 30.6], ["ent_ramp_upper", 38.0]]:
		p.mom_s = minf(p.forest_end_s + float(spot[1]) + 3.2, p.mom_stop_s)
		tp_route(p, p.forest_end_s + float(spot[1]))
		await secs(1.4)
		await shot(spot[0])
		if spot[0] == "ent_ramp_turn" or spot[0] == "ent_ramp_lower":
			var keep: Vector3 = p.cam.position
			p.cam.position = Vector3(1.2, 1.0, 3.2)
			p.cam.rotation = Vector3(-0.25, 0.3, 0.0)
			await secs(0.2)
			await shot(spot[0] + "_tp")
			p.cam.position = keep
			p.cam.rotation = Vector3.ZERO
	p.mom_s = p.mom_stop_s
	await secs(2.0)
	tp_route(p, p.door_stop_s - 0.05)
	await secs(3.0)
	print("ENT at door: walk_s=", p.walk_s, " mom_aside=", p._mom_aside, " door_open=", p.door_open)
	await shot("ent_door")
	var keep2: Vector3 = p.cam.position
	p.cam.position = Vector3(-1.4, 0.6, 2.6)
	p.cam.rotation = Vector3(-0.12, -0.45, 0.0)
	await secs(0.2)
	await shot("ent_door_tp")
	p.cam.position = keep2
	p.cam.rotation = Vector3.ZERO
	p._open_entrance()
	await secs(1.0)
	await shot("ent_door_opening")
	await secs(1.5)
	await shot("ent_door_open")
	for k in 8:
		tp_route(p, minf(p.door_stop_s + k * 0.25, p.path_cum[-1]))
		await secs(0.2)
	await shot("ent_threshold")
	tp_route(p, p.path_cum[-1])
	while is_instance_valid(p) and p.phase != "end":
		await get_tree().process_frame
	await secs(2.6)
	if is_instance_valid(p):
		await shot("ent_lookback")
	var t := 0.0
	while t < 30.0 and (get_tree().current_scene == null or not get_tree().current_scene.has_node("Director")):
		await get_tree().process_frame
		t += get_process_delta_time()
	print("ENT scene ", get_tree().current_scene.name if get_tree().current_scene else "null", " after ", t)
	await secs(2.5)
	await shot("ent_sanatorium")
	var g: Node = get_tree().current_scene
	if g and g.has_node("Director"):
		var dd: Node = g.get_node("Director")
		print("ENT player ", dd.player.global_position, " yaw ", dd.player.rotation.y, " mom ", dd.mom.global_position)
		await secs(9.0)
		await shot("ent_mom_vest_door")
		await secs(5.0)
		await shot("ent_mom_hall")
		print("ENT mom now ", dd.mom.global_position, " act ", dd.act)


## Что делает небо тёмным: один и тот же вид у санатория с разными выключенными эффектами.
func _skytest() -> void:
	get_tree().change_scene_to_file("res://story/prologue.tscn")
	await secs(1.0)
	var p: Node = get_tree().current_scene
	while p == null or p.get("phase") == "load":
		await get_tree().process_frame
		p = get_tree().current_scene
	GameStateRef().set_fade(0.0)
	p.s = p.s_stop - 0.2
	p.v = 0.0
	p.phase = "arrive"
	p._go_outside()
	await secs(5.0)
	p.walk_s = 95.0
	p.hero.global_position = p._path_at(95.0)
	p.mom_s = 98.0
	p.look_pitch = 0.25
	await secs(3.0)
	var env: Environment = p.env
	print("SKY day=", p.day, " fog=", env.fog_light_color, " top=", p.sky_mat.sky_top_color, " amb=", env.ambient_light_energy, " sun=", p.sun.light_energy)
	await shot("sky_a_base")
	env.volumetric_fog_enabled = false
	await secs(1.0)
	await shot("sky_b_novol")
	env.fog_enabled = false
	await secs(1.0)
	await shot("sky_c_nofog")
	env.adjustment_enabled = false
	await secs(1.0)
	await shot("sky_d_noadj")
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	await secs(1.0)
	await shot("sky_e_linear")


## Пролог: поставить коляску на маршрут (s — метры от начала тропинки), лицом по ходу.
func tp_route(p: Node, s: float) -> void:
	var a: Vector3 = p._path_at(s)
	var b: Vector3 = p._path_at(s + 0.6)
	p.walk_s = s
	p.hero.global_position = a
	p.hero.rotation.y = atan2(-(b.x - a.x), -(b.z - a.z))
	p.drive_model.stop()


func GameStateRef() -> Node:
	return get_tree().root.get_node("GameState")


func _sanatorium() -> void:
	var cp: String = case_name
	if case_name == "sanatorium" or case_name == "chair" or case_name == "trap":
		cp = "start"
	elif case_name == "chase2":
		cp = "chase"
	elif case_name == "void2":
		cp = "void"
	elif case_name == "brothers" or case_name == "beatpose":
		cp = "floor3"
	elif case_name == "tour" or case_name == "mompose" or case_name == "items":
		cp = "start"
	elif case_name == "voidtour":
		cp = "void"
	GameStateRef().checkpoint = cp
	get_tree().change_scene_to_file("res://sanatorium/main.tscn")
	await secs(3.0)
	var g: Node = get_tree().current_scene
	var d: Node = g.get_node("Director")
	await secs(4.0)
	GameStateRef().set_fade(0.0)
	await shot(case_name + "_start")
	if case_name == "items":
		await _items_test(g, d)
		return
	if case_name == "sanatorium":
		await secs(6.0)
		await shot("sanatorium_mom_walk")
	elif case_name == "chase":
		d.player.global_position = Vector3(37.5, 1.25, -7.6)
		d.lift.locked = false
		d.lift.request(0)
		await secs(3.0)
		d.player.look_yaw = 1.5
		await secs(3.0)
		await shot("chase_psycho")
	elif case_name == "brothers":
		await _brothers_test(d)
	elif case_name == "beatpose":
		await _beatpose_test(g, d)
	elif case_name == "tour" or case_name == "voidtour":
		await _tour_test(d, case_name == "voidtour")
	elif case_name == "mompose":
		await _mompose_test(g, d)
	elif case_name == "void2":
		# пустой этаж: виды из разных точек во все стороны (ищем дыры)
		var spots := [Vector3(37.5, 4.55, -8.5), Vector3(20.0, 4.55, -8.0), Vector3(50.0, 4.55, -8.0), Vector3(8.8, 4.55, -8.5),
			Vector3(66.0, 4.55, -4.0)]
		var n := 0
		for sp in spots:
			for yaw in [0.0, PI * 0.5, PI, -PI * 0.5]:
				d.player.global_position = sp
				d.player.rotation.y = yaw
				d.player.look_yaw = 0.0
				d.player.look_pitch = 0.1
				d.player.torch_on = true
				await secs(0.6)
				await shot("void2_%02d" % n)
				n += 1
	elif case_name == "trap":
		var dr = d.door(74)
		dr.set_angle(90.0)
		d.player.global_position = Vector3(52.5, 1.25, -12.6)
		d.player.rotation.y = PI
		d._locked_in_room()
		while not d.minigame.running:
			await get_tree().process_frame
		await secs(1.0)
		await shot("trap_push")
		d.minigame.cheat = true
		while d.minigame.running:
			d.minigame.press()
			await secs(0.3)
		while not d.objective_text().contains("поддеть"):
			await get_tree().process_frame
		d.player.look_yaw = 0.6
		d.player.look_pitch = -0.35
		await secs(1.5)
		await shot("trap_scalpel")
	elif case_name == "chase2":
		# погоня по этапам: стоит в конце коридора → ближе → бежит
		d.player.global_position = Vector3(38.2, 1.25, -7.5)
		d.player.rotation.y = -PI * 0.5
		d.player.look_yaw = 0.0
		d.player.look_pitch = 0.02
		var ps: Node3D = d.psycho
		var w := 0.0
		while not (ps.visible and d.game.lights.is_on("L0.C")) and w < 120.0:
			await get_tree().process_frame
			w += get_process_delta_time()
		await frames(2)
		await shot("chase2_far")
		while ps.global_position.distance_to(d.PSYCHO_NEAR) > 0.1 and d.chase != "run" and w < 240.0:
			await get_tree().process_frame
			w += get_process_delta_time()
		while not d.game.lights.is_on("L0.C") and w < 300.0:
			await get_tree().process_frame
			w += get_process_delta_time()
		await frames(2)
		await shot("chase2_near")
		while d.chase != "run" and w < 400.0:
			await get_tree().process_frame
			w += get_process_delta_time()
		while ps.global_position.x > 44.0 and d.chase == "run":
			await get_tree().process_frame
		await shot("chase2_run")
		print("CHASE2 psycho at ", ps.global_position, " chase ", d.chase)
	elif case_name == "chair":
		d.player.look_pitch = -1.0
		d.player.look_yaw = -0.3
		d.player.input_override = Vector2(1.0, 1.0)
		await secs(3.0)
		d.player.input_override = Vector2(0, 0)
		d.player.chair_model.set_input(1.0, 1.0, 1.0)
		await shot("chair_joystick")
		d.player.chair_model.set_input(0.0, 0.0, 1.0)
		d.player.look_pitch = -0.95
		d.player.look_yaw = -0.75
		d.player.speed_level = 3
		d.player.chair_model.set_speed(3)
		await secs(1.0)
		await shot("chair_joystick2")
		# крупный план пульта отдельной камерой
		var ctl: Node3D = d.player.chair_model.root.find_child("Controller", true, false)
		if ctl:
			var cam := Camera3D.new()
			cam.fov = 35.0
			cam.near = 0.01
			g.add_child(cam)
			var c: Vector3 = ctl.global_transform * Vector3(-0.259, 0.15, 0.14)
			cam.global_position = c + d.player.global_transform.basis * Vector3(0.18, 0.2, -0.12)
			cam.look_at(c, Vector3.UP)
			cam.current = true
			var lamp := OmniLight3D.new()
			lamp.light_energy = 0.6
			lamp.omni_range = 2.0
			g.add_child(lamp)
			lamp.global_position = cam.global_position + Vector3(0, 0.3, 0)
			await secs(1.0)
			await shot("chair_joystick_close")
			cam.current = false
			d.player.cam.current = true


# ------------------------------------------------------------------ прохождение всей истории (без экрана)
var d: Node
var pl: Node


func step(msg: String) -> void:
	print("STEP ", msg, "  act=", d.act if d else "", " chase=", d.chase if d else "", " t=", Time.get_ticks_msec() / 1000)


func wait_for(cond: Callable, limit := 120.0, what := "") -> bool:
	var t := 0.0
	if shoot:
		limit *= 5.0                                      # с экраном программный рендер медленный
	while not cond.call():
		await get_tree().process_frame
		t += get_process_delta_time() / maxf(Engine.time_scale, 0.001)
		if t > limit:
			print("TIMEOUT waiting for ", what, "  act=", d.act)
			return false
	return true


func wait_for_d(dd: Node, cond: Callable, limit: float) -> void:
	var t := 0.0
	while not cond.call() and t < limit:
		await get_tree().process_frame
		t += get_process_delta_time()
	if t >= limit:
		print("TIMEOUT (shot case) act=", dd.act)


func tp(p: Vector3, yaw := 0.0) -> void:
	pl.global_position = p + Vector3(0, 0.05, 0)
	pl.rotation.y = yaw
	pl.v = 0.0
	pl.reset_physics_interpolation()
	await get_tree().physics_frame
	await get_tree().physics_frame


func press_call(level: int) -> void:
	var b = d.lift.landings[level]["button"]
	b.get_meta("interact").interact(pl)


func press_cab(key: String) -> void:
	for a in d.lift.cabin.get_children():
		if a is Area3D and a.has_meta("button") and a.get_meta("button").what.get("cab", "") == key:
			a.get_meta("interact").interact(pl)
			return
	print("NO CAB BUTTON ", key)


## Всё прохождение. --from=start|void|floor3|pharmacy|forest|real — с какой главы; --snaps — со скриншотами
## (запускать с экраном: xvfb-run … --rendering-driver vulkan).
var shoot := false


func _arg(k: String, def: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % k):
			return a.get_slice("=", 1)
		if a == "--" + k:
			return "1"
	return def


## Скриншот в режиме --shots; look — куда повернуть голову (точка в мире).
func snap(nm: String, look: Variant = null) -> void:
	if not shoot:
		return
	if look != null and pl:
		var to: Vector3 = (look as Vector3) - pl.head.global_position
		pl.rotation.y = atan2(-to.x, -to.z)
		pl.look_yaw = 0.0
		pl.look_pitch = clampf(atan2(to.y, Vector2(to.x, to.z).length()), -0.9, 0.9)
		await frames(3)
	await shot(nm)


func _playthrough() -> void:
	shoot = _arg("snaps", "") != ""
	var from := _arg("from", "start")
	Engine.time_scale = 2.0 if shoot else 6.0
	if from == "forest":
		GameStateRef().checkpoint = "pharmacy_out"
		get_tree().change_scene_to_file(GameStateRef().PROLOGUE)
		await wait_for_scene(func(sc): return sc.get("pharmacy") == true and sc.phase == "walk", 240)
		await _seg_forest()
		if _arg("until", "") != "forest":
			await _seg_real()
		Engine.time_scale = 1.0
		return
	GameStateRef().checkpoint = from
	get_tree().change_scene_to_file("res://sanatorium/main.tscn")
	await secs(2.0)
	var g: Node = get_tree().current_scene
	d = g.get_node("Director")
	await wait_for(func(): return d.player != null and d.act != "", 60, "director")
	pl = d.player
	d.minigame.cheat = true                               # мини-игры в тесте проходятся сами
	match from:
		"start":
			await _seg_start()
			await _seg_void()
			await _seg_f3()
			await _seg_pills()
		"void":
			await _seg_void()
			await _seg_f3()
			await _seg_pills()
		"floor3":
			await _seg_f3()
			await _seg_pills()
		"pharmacy":
			await _seg_pills()
		"real":
			await _seg_real()
			Engine.time_scale = 1.0
			return
	await wait_for_scene(func(sc): return sc.get("pharmacy") == true and sc.phase == "walk", 240)
	await _seg_forest()
	await _seg_real()
	Engine.time_scale = 1.0


func wait_for_scene(cond: Callable, limit: float) -> bool:
	return await wait_for(func():
		var sc: Node = get_tree().current_scene
		return sc != null and sc.name != "Sanatorium" and sc.get("phase") != null and cond.call(sc), limit, "scene")


func _seg_start() -> void:
	await wait_for(func(): return d.act == "act1", 60, "act1")
	step("act1 started")
	await tp(Vector3(31.0, 1.2, -3.0), PI)
	await wait_for(func(): return d.act == "scream", 400, "scream")
	step("scream")
	var door = d.door(74)
	await secs(4.0)
	await tp(Vector3(52.5, 1.2, -8.4), 0.0)
	door.interact(pl)
	await wait_for(func(): return door.angle > 18.0, 20, "scream door opens")
	await secs(1.0)
	await tp(Vector3(52.5, 1.2, -12.6), PI)
	await wait_for(func(): return d.act == "locked", 30, "locked in")
	step("locked in the room")
	d.minigame.cheat = true
	await wait_for(func(): return d.minigame.running, 60, "push minigame")
	step("push minigame")
	while d.minigame.running:
		d.minigame.press()
		await secs(0.2)
	await wait_for(func(): return d.objective_text().contains("поддеть"), 30, "scalpel objective")
	step("door holds, look for scalpel")
	for c in d.game.get_children():
		for it in c.get_children():
			if it is Area3D and it.has_meta("interact") and str(it.get_meta("interact").get("text")).contains("скальпель"):
				it.get_meta("interact").action.call()
	await wait_for(func(): return d.has_scalpel, 10, "scalpel")
	await tp(d.TRAP_SPOT, PI)
	await wait_for(func(): return d.minigame.running, 30, "pick minigame")
	step("pick minigame")
	while d.minigame.running:
		d.minigame.press()
		await secs(0.2)
	await wait_for(func(): return d.act == "scream" and not door.locked, 30, "door unlocked")
	step("escaped the room")
	await tp(Vector3(37.5, 1.2, -7.3), 0.0)
	await wait_for(func(): return d.act == "need_key", 120, "need_key")
	step("need_key")
	press_call(0)
	await wait_for(func(): return d.act == "find_admin", 30, "find_admin")
	await tp(Vector3(41.5, 1.2, -8.1), -PI * 0.5)
	await secs(1.0)
	await tp(Vector3(43.3, 1.2, -4.9), PI * 0.5)
	await wait_for(func(): return d.nightstand.has("area"), 30, "nightstand")
	step("take key")
	d.nightstand["area"].action.call()
	await wait_for(func(): return d.act == "lift_key", 60, "lift_key")
	step("lift_key")
	await tp(Vector3(37.5, 1.2, -7.3), 0.0)
	press_call(0)
	await wait_for(func(): return d.act == "chase", 30, "chase")
	step("chase")
	await tp(Vector3(37.5, 1.2, -5.0), PI)
	await wait_for(func(): return d.act == "void", 90, "void (lift goes up by itself in the chase)")
	step("void")


func _seg_void() -> void:
	await wait_for(func(): return d.lift.state == "open", 30, "doors open at 2")
	await tp(Vector3(9.0, 4.5, -3.5), 0.0)
	await wait_for(func(): return d.objective_text().contains("палату деда"), 60, "notes")
	d._read_note("diary")
	await wait_for(func(): return d.objective_text().contains("Вернись к лифту"), 120, "back to the lift")
	step("radio done")
	await tp(Vector3(8.83, 4.5, -7.6), -PI * 0.5)
	await wait_for(func(): return d.act == "faceless", 30, "faceless chase")
	step("faceless chase")
	if shoot:                                              # снимок — с остановленным временем
		var ts := Engine.time_scale
		Engine.time_scale = 0.0001
		await snap("10_faceless_behind", d._faceless[0].global_position + Vector3(0, 1.4, 0))
		pl.rotation.y = -PI * 0.5
		pl.look_yaw = 0.0
		await frames(2)
		Engine.time_scale = ts
	await secs(1.0 / Engine.time_scale)                   # как человек: секунда на реакцию
	pl.input_override = Vector2(1.0, 0.0)                 # честно: едем к лифту на 3-й скорости
	await wait_for(func(): return pl.global_position.x > 30.0 or d.faceless_state != "run", 40, "drive to the lift")
	if shoot:
		var ts2 := Engine.time_scale
		Engine.time_scale = 0.0001
		await snap("11_mom_at_lift", d.mom.global_position + Vector3(0, 1.5, 0))
		Engine.time_scale = ts2
	await wait_for(func(): return pl.global_position.x > 35.6 or d.faceless_state != "run", 20, "drive to the lift 2")
	pl.input_override = null
	var near := 99.0
	for f in d._faceless:
		near = minf(near, f.global_position.distance_to(pl.global_position))
	step("at the lift: state=%s nearest faceless %.1f m" % [d.faceless_state, near])
	await tp(Vector3(37.5, 4.5, -5.0), PI)
	await wait_for(func(): return d.faceless_state == "door", 20, "in the cabin")
	await wait_for(func(): return d._nearest_faceless(d.VOID_LIFT) < 1.6 or d.lift.state == "moving", 20, "crowd at the doors")
	await snap("12_faceless_at_doors", Vector3(37.5, 5.6, -8.0))
	await wait_for(func(): return d.act == "f3_call", 90, "lift with mom to 3, she leaves")
	step("mom vanishes on 3")
	await snap("13_mom_on_3", d.mom.global_position + Vector3(0, 1.5, 0))
	await secs(1.2)
	await snap("14_mom_walks_away", d.mom.global_position + Vector3(0, 1.5, 0))
	await wait_for(func(): return not d.mom.visible, 60, "mom gone")
	await secs(1.0)
	await tp(Vector3(37.5, 7.8, -7.8), PI)
	await secs(0.5)
	await snap("15_empty_corridor", Vector3(30.0, 9.0, -8.1))
	await wait_for(func(): return d.act == "floor3_search", 60, "floor3")
	step("floor3")


func _seg_f3() -> void:
	await tp(Vector3(20.0, 7.8, -8.1), 0.0)
	pl.v = 1.0
	await secs(4.0)
	d.scares.elapsed = 400.0
	d.scares.count = 10
	await wait_for(func(): return d.act == "brothers", 60, "brothers")
	step("brothers")
	await secs(1.0)
	await snap("20_brothers")
	await wait_for(func(): return d.act == "lounge", 90, "caught by the brothers")
	step("lounge: tied")
	await secs(1.0)
	await snap("21_lounge")
	await secs(2.0)
	if d.player.input_override != Vector2.ZERO:
		step("FAIL: hands not tied")
	await wait_for(func(): return d.minigame.running and d.minigame.mode == "hold", 240, "bite minigame")
	step("bite minigame")
	await wait_for(func(): return not d._tied, 60, "hands free")
	step("hands free")
	await wait_for(func(): return d.act == "mom_back", 60, "searching for mom")
	await tp(Vector3(24.0, 7.8, -8.1), -PI * 0.5)
	await wait_for(func(): return d.mom.visible, 120, "mom comes back behind")
	step("mom behind")
	await secs(2.0)
	var to_m: Vector3 = d.mom.global_position - pl.global_position
	pl.rotation.y = atan2(-to_m.x, -to_m.z)
	pl.look_yaw = 0.0
	await snap("22_mom_behind", d.mom.global_position + Vector3(0, 1.5, 0))
	await wait_for(func(): return d.act == "room_scare", 120, "mom noticed")
	step("mom noticed, going to the lift")
	await wait_for(func(): return d.objective_text().contains("Загляни"), 120, "look into the room")
	step("look into the room")
	var dg = d.door(167)
	var dc: Vector3 = dg.center if dg else Vector3(31.6, 7.8, -9.7)
	await tp(Vector3(dc.x, 7.8, -9.4), PI)
	if shoot:
		await wait_for(func(): return d.ui.line_visible() and str(d.ui._sub_text.text).contains("Твою"), 30, "scare line")
		await snap("23_jump_scare")
	await wait_for(func(): return d.act == "f3_lift", 60, "scare done")
	step("jump scare done")
	await wait_for(func(): return not d.mom.is_moving(), 60, "mom in the cabin")
	await tp(Vector3(37.5, 7.8, -5.0), PI)
	await wait_for(func(): return d.act == "pills", 90, "floor 2 with mom")
	step("pills")
	await secs(2.0)
	await snap("30_floor2_mom", d.mom.global_position + Vector3(0, 1.5, 0))


func _seg_pills() -> void:
	await wait_for(func(): return d.objective_text().contains("аптек"), 120, "pharmacy objective")
	press_cab("1")
	await wait_for(func(): return d.lift.floor_idx == 0 and d.lift.state == "open", 60, "down to 1")
	step("floor 1")
	await snap("31_floor1")
	await wait_for(func(): return d.objective_text().contains("улицу"), 60, "go outside")
	for c in d.game.get_children():
		if c is Area3D and c.has_meta("interact") and str(c.get_meta("interact").get("text")).contains("Выйти"):
			c.get_meta("interact").action.call()


func _seg_forest() -> void:
	var pr: Node = get_tree().current_scene
	step("forest: pharmacy")
	await secs(3.0)
	tp_route(pr, 1.0)
	await secs(2.0)
	if shoot:
		pr.hero.rotation.y = atan2(-(pr.kiosk_point.x - pr.hero.global_position.x), -(pr.kiosk_point.z - pr.hero.global_position.z))
		await secs(0.5)
		await shot("40_kiosk")
	pr._buy_pills()
	await secs(2.0)
	print("STEP pills bought: ", pr.has_pills)
	await snap("41_kiosk_bought")
	if shoot:                                              # рассвет по пути назад: середина и почти у здания
		var from: float = pr.walk_s
		for k in [0.35, 0.65, 0.9]:
			tp_route(pr, lerpf(from, pr.door_stop_s - 0.4, k))
			await secs(2.0)
			await shot("41_dawn_%d" % int(k * 100))
	tp_route(pr, pr.door_stop_s - 0.4)
	await secs(1.0)
	await snap("42_back_at_door")
	print("STEP dawn at the door: %.2f" % float(pr.get("dawn")))
	if _arg("until", "") == "forest":
		return
	pr._open_entrance()
	await secs(3.0)
	tp_route(pr, pr.path_cum[-1] - 0.05)


func _seg_real() -> void:
	var g: Node
	await wait_for(func(): return get_tree().current_scene != null and get_tree().current_scene.has_node("Director") and get_tree().current_scene.get_node("Director").act == "real", 240, "real hospital")
	g = get_tree().current_scene
	d = g.get_node("Director")
	pl = d.player
	step("real hospital")
	await secs(3.0)
	await snap("50_real_hall")
	if shoot:
		await tp(Vector3(33.0, 1.2, 4.0), PI * 0.5)
		await secs(0.5)
		await snap("51_real_hall_people", Vector3(30.0, 1.6, 7.5))
		await tp(Vector3(37.5, 4.5, -7.6), -PI * 0.5)
		await secs(0.5)
		await snap("52_real_floor2", Vector3(20.0, 5.6, -8.0))
	await tp(Vector3(8.83, 4.5, -4.0), PI)
	await secs(1.5)
	await snap("53_room204", Vector3(10.7, 5.3, -0.74))
	if _arg("until", "") == "room204":                    # только свет больницы — без конца истории
		return
	if shoot:
		await wait_for(func(): return not is_instance_valid(d) or (d.ui.line_visible() and str(d.ui._sub_text.text).contains("сын")), 90, "real son line")
		await snap("54_real_son", Vector3(10.25, 5.3, -0.74))
	await wait_for(func(): return d.act == "panic", 120, "panic attack")
	step("panic")
	await secs(2.5)
	await snap("55_panic")
	if shoot:
		await wait_for(func(): return not is_instance_valid(d) or (d.ui.line_visible() and str(d.ui._sub_text.text).contains("Доктор")), 60, "doctor call")
		await snap("56_fallen")
	await wait_for(func(): return get_tree().current_scene == null or get_tree().current_scene.name == "Epilogue", 120, "epilogue")
	step("epilogue reached")
	if shoot:
		Engine.time_scale = 1.0
		for k in 6:
			await secs(7.0)
			await shot("6%d_epilogue" % k)
	else:
		await secs(10.0)


func _prologue_play() -> void:
	Engine.time_scale = 6.0
	get_tree().change_scene_to_file("res://story/prologue.tscn")
	await secs(1.0)
	var p: Node = get_tree().current_scene
	while p == null or p.get("phase") == "load":
		await get_tree().process_frame
		p = get_tree().current_scene
	print("STEP prologue ride  s=", p.s)
	await secs(3.0)
	p._talk()
	await secs(12.0)
	print("STEP talked=", p.talked)
	p.s = fposmod(p.s_stop - 120.0, p.road.length)
	await wait_for_p(func(): return p.phase == "walk", 120, "walk", p)
	print("STEP walk  bus_away=", p._bus_away)
	var dist := 0.0
	while is_instance_valid(p) and p.phase == "walk" and dist < p.forest_end_s - 1.0:
		dist = minf(minf(dist + 2.0, p.forest_end_s - 1.0), maxf(p.mom_s - 1.5, dist))    # за мамой
		p.hero.global_position = p._path_at(dist)
		await secs(0.3)
	print("STEP forest end  walk_s=", p.walk_s, " of ", p.forest_end_s)
	while is_instance_valid(p) and dist < p.door_stop_s - 0.05:
		var cap: float = p.door_stop_s - 0.05 if p._mom_aside else maxf(p.mom_s - 1.5, dist)
		dist = minf(dist + 1.0, cap)
		tp_route(p, dist)
		await secs(0.2)
	print("STEP at door  guided=", p.guided, " mom_aside=", p._mom_aside)
	await secs(1.0)
	p._open_entrance()
	await wait_for_p(func(): return p.door_open, 30, "door open", p)
	print("STEP door open")
	for k in 12:
		if is_instance_valid(p) and p.phase != "end":
			tp_route(p, minf(p.door_stop_s + k * 0.2, p.path_cum[-1]))
		await secs(0.15)
	await wait_for_p(func(): return not is_instance_valid(p) or p.phase == "end", 60, "inside", p)
	print("STEP end of path  phase=", p.phase if is_instance_valid(p) else "freed")
	for i in 6:
		await secs(0.12)
		if is_instance_valid(p):
			print("STEP look back  look_yaw=%.2f door=%.2f mom=%s" % [p.look_yaw, p.entrance.amount if p.entrance else -1.0, p.site_xf.affine_inverse() * p.mom.global_position])
	await secs(8.0)
	print("STEP scene now ", get_tree().current_scene.name if get_tree().current_scene else "null")
	var sc: Node = get_tree().current_scene
	if sc and sc.has_node("Director"):
		var dd: Node = sc.get_node("Director")
		print("STEP sanatorium player ", dd.player.global_position, " act ", dd.act)
		for i in 8:
			await secs(1.0)
			print("STEP mom ", dd.mom.global_position, " anim ", dd.mom.current, " door1 ", dd.door(1).angle if dd.door(1) else -1.0, " line ", dd.ui.line_visible() if dd.ui.has_method("line_visible") else "")
	Engine.time_scale = 1.0


func wait_for_p(cond: Callable, limit: float, what: String, p: Node) -> bool:
	var t := 0.0
	while not cond.call():
		await get_tree().process_frame
		t += get_process_delta_time() / maxf(Engine.time_scale, 0.001)
		if t > limit:
			print("TIMEOUT waiting for ", what, " phase=", p.phase)
			return false
	return true


## Честность погони: медленный игрок (после открытия дверей ещё 1,5 с стоит) сам заезжает в лифт.
func _fair_test() -> void:
	GameStateRef().checkpoint = "chase"
	get_tree().change_scene_to_file("res://sanatorium/main.tscn")
	await secs(2.0)
	d = get_tree().current_scene.get_node("Director")
	await wait_for(func(): return d.act == "lift_key", 60, "lift_key")
	pl = d.player
	await tp(Vector3(37.5, 1.2, -7.4), PI)                # лицом к лифту (+Z)
	var t0 := Time.get_ticks_msec()
	press_call(0)
	await wait_for(func(): return d.lift.state == "open", 20, "open")
	await secs(1.5)
	step("driving in after %.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))
	pl.input_override = Vector2(1.0, 0.0)
	await wait_for(func(): return d.lift.player_in_cabin() or d.chase == "caught", 20, "in cabin")
	pl.input_override = Vector2.ZERO
	step("in cabin=%s after %.1f s, psycho %.1f m away" % [str(d.lift.player_in_cabin()), (Time.get_ticks_msec() - t0) / 1000.0, d.psycho.global_position.distance_to(pl.global_position)])
	await wait_for(func(): return d.act == "void" or d.chase == "caught", 30, "result")
	step("RESULT " + ("escaped" if d.act == "void" else "caught") + " after %.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))


## Сцена с братьями: снимки в ключевые моменты (погоня, холл, удар, избиение, взгляд, бинты).
func _brothers_test(dd: Node) -> void:
	d = dd
	pl = dd.player
	d.minigame.cheat = true
	await secs(2.0)
	d.scares.elapsed = 400.0
	d.scares.count = 10
	await tp(Vector3(30.0, 7.8, -8.1), -PI * 0.5)
	await wait_for(func(): return d.act == "brothers" and d.younger.visible, 60, "brothers appear")
	await secs(2.5)
	await shot("bro_1_corridor")
	await wait_for(func(): return d.act == "lounge", 90, "caught")
	step("lounge")
	await wait_for(func(): return GameStateRef().fade_target() < 0.5, 30, "fade in")
	await secs(3.5)
	await shot("bro_2_room")
	await wait_for(func(): return d.younger.current == "walk_loop" or d.younger.is_moving(), 60, "younger creeps")
	await secs(4.0)
	await shot("bro_3_creep")
	await wait_for(func(): return d.psycho.current == "hit", 60, "elder strikes")
	await secs(0.62)
	await shot("bro_4_hit")
	await secs(1.4)
	await shot("bro_5_fall")
	await wait_for(func(): return d.psycho.current == "kneel_loop", 30, "kneel")
	await secs(2.5)
	await shot("bro_6_beat")
	await secs(1.13)
	await shot("bro_7_beat")
	await secs(4.0)
	await shot("bro_8_beat")
	await wait_for(func(): return d.psycho.current == "idle_loop" and not d.psycho.is_moving() and d._track != null and d.psycho.global_position.distance_to(d.ELDER_STARE) < 0.5, 60, "stare")
	await secs(3.0)
	await shot("bro_9_stare")
	await wait_for(func(): return d.minigame.running, 60, "bite")
	await secs(1.5)
	await shot("bro_10_bite")
	await wait_for(func(): return not d._tied, 30, "free")
	step("free")
	await secs(2.0)
	d.player.look_yaw = 0.3
	await secs(0.5)
	await shot("bro_11_after")


## Поза «сидит верхом и бьёт»: младший лежит, старший на коленях; камера сбоку, при свете.
func _beatpose_test(g: Node, d: Node) -> void:
	pl = d.player
	d.scares.stop()
	d.set_process(false)
	d._setup_lounge()
	var y: Node = d.younger
	var e: Node = d.psycho
	y.visible = true
	e.visible = true
	y.global_position = Vector3(24.3, 7.8, -11.35)
	y.set_yaw(0.0)
	y.play("lie_loop", 0.0)
	pl.global_position = Vector3(30, 7.85, -8.1)
	await secs(1.0)
	var k: Dictionary = d._kneel_frame()
	e.global_position = k["at"]
	e.set_yaw(k["ye"])
	e.play("kneel_loop", 0.0)
	var cam := Camera3D.new()
	g.add_child(cam)
	var ax: Vector3 = k["axis"]
	var side := Vector3(-ax.z, 0, ax.x)
	var lamp := OmniLight3D.new()
	lamp.light_energy = 3.0
	lamp.omni_range = 7.0
	g.add_child(lamp)
	var views := [k["belly"] + side * 2.2 + Vector3(0, 1.1, 0), k["belly"] - ax * 2.4 + side * 0.6 + Vector3(0, 1.3, 0)]
	var cfgs := [[0.0, ""], [0.62, "chest"], [0.62, "raised"], [0.78, "hit"]]
	for vi in views.size():
		cam.global_position = views[vi]
		cam.look_at(k["belly"] + Vector3(0, 0.45, 0) + ax * 0.15)
		cam.current = true
		lamp.global_position = views[vi] + Vector3(0, 0.6, 0)
		for ci in cfgs.size():
			var c: Array = cfgs[ci]
			e.set_lean(c[0])
			match c[1]:
				"chest":
					e.set_hands(k["chest"], k["chest"], 1.0)
				"raised":
					e.set_hands(k["raised"][0], k["chest"], 1.0)
				"hit":
					e.set_hands(k["hit"], k["chest"], 1.0)
				_:
					e.set_hands(null, null, 0.0)
			await secs(0.6)
			await shot("bp_v%d_%d" % [vi, ci])


## Лифт на 3-м этаже: двери закрываются медленно, мама увозит человека в коляске.
## Свет утренней палаты 204: один запуск — несколько вариантов настроек (рассеянный свет, свет окон, солнце,
## тональная кривая), по кадру на каждый. Варианты — в LAB_VARIANTS.
const LAB_VARIANTS := [
	{"name": "final"},
	{"name": "low", "low": 1},
]


## Свет палаты 204: каждый вариант — свой кадр. Сюжет на время съёмки стоит (дерево на паузе: реплики не идут,
## паническая атака не начинается), картинка и адаптация глаза при этом рисуются.
func _lightlab() -> void:
	shoot = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	GameStateRef().checkpoint = "real"
	get_tree().change_scene_to_file("res://sanatorium/main.tscn")
	await secs(2.0)
	var g: Node = get_tree().current_scene
	d = g.get_node("Director")
	await wait_for(func(): return d.act == "real", 120, "real")
	pl = d.player
	await secs(2.0)
	await tp(Vector3(8.83, 4.5, -4.0), PI)
	await secs(1.0)
	var to: Vector3 = Vector3(10.7, 5.3, -0.74) - pl.head.global_position
	pl.rotation.y = atan2(-to.x, -to.z)
	pl.look_yaw = 0.0
	pl.look_pitch = clampf(atan2(to.y, Vector2(to.x, to.z).length()), -0.9, 0.9)
	await secs(1.5)
	get_tree().paused = true
	if _arg("probe", "") != "":                          # что висит в окне палаты: сетки и материалы
		var wpos := Vector3(11.4, 6.0, 1.2)
		for w in g.find_windows():
			if (w["pos"] as Vector3).distance_to(Vector3(10.7, 4.6, 0.0)) < (wpos - Vector3(0, 1.3, 0)).distance_to(Vector3(10.7, 4.6, 0.0)):
				wpos = (w["pos"] as Vector3) + Vector3(0, 1.2, 0)
		print("PROBE window at ", wpos)
		for n in g.building.find_children("*", "MeshInstance3D", true, false):
			var mi: MeshInstance3D = n
			var bb: AABB = mi.global_transform * mi.get_aabb()
			if bb.grow(0.4).has_point(wpos) and bb.size.length() < 60.0:
				for i in mi.mesh.get_surface_count():
					var m = mi.get_active_material(i)
					print("PROBE ", mi.name, " ", m.resource_name if m else "-", " tr=", m.transparency if m is BaseMaterial3D else -1, " a=", m.albedo_color.a if m is BaseMaterial3D else -1.0)
	pl.process_mode = Node.PROCESS_MODE_ALWAYS             # камера игрока обновляется и на паузе
	RenderingServer.environment_set_sdfgi_frames_to_converge(RenderingServer.ENV_SDFGI_CONVERGE_IN_5_FRAMES)
	g.cam_attr.auto_exposure_speed = 8.0
	var only := _arg("variants", "")
	for v in LAB_VARIANTS:
		if only != "" and not only.contains(v["name"]):
			continue
		var look: Dictionary = (g.DAY_LOOK_LOW if v.has("low") else g.DAY_LOOK).duplicate()
		look.merge(v, true)
		g.apply_day_look(look)
		var f0: int = Engine.get_frames_drawn()
		await secs(3.0)
		if float(look["gi"]) > 0.0:
			await frames(maxi(0, 45 - (Engine.get_frames_drawn() - f0)))   # глобальное освещение набирает свет
		print("frames: ", Engine.get_frames_drawn() - f0)
		for i in 4:                                        # сюжет мог повернуть голову — смотрим снова туда же
			pl.rotation.y = atan2(-to.x, -to.z)
			pl.look_yaw = 0.0
			pl.look_pitch = clampf(atan2(to.y, Vector2(to.x, to.z).length()), -0.9, 0.9)
			await get_tree().process_frame
		await shot("lab_" + v["name"])
		print("LAB ", v)
	get_tree().paused = false


## Вид из окон утренней больницы: лес на рассвете вокруг здания (пролог, глава 5, солнце взошло). Шесть кадров
## куба 90° из точки на месте здания на высоте 2-го этажа, само здание скрыто; оси — как у здания (site_xf).
## Из них tools/godot_assets/make_window_panorama.py склеивает панораму неба для санатория (game.gd set_morning).
func _panorama() -> void:
	GameStateRef().checkpoint = "pharmacy_out"
	get_tree().change_scene_to_file("res://story/prologue.tscn")
	await wait_for_scene(func(sc): return sc.get("pharmacy") == true and sc.phase == "walk", 300)
	var pr: Node = get_tree().current_scene
	await secs(2.0)
	pr.has_pills = true
	pr.set_process(false)                                   # пролог больше не двигает рассвет сам
	pr.set_physics_process(false)
	pr.set_dawn(1.0)
	# в больнице уже ясное утро: солнце ~20° над лесом, воздух прозрачный, небо голубое
	var sd: Vector3 = pr.site_xf.basis * Vector3(-0.5, 0.0, -1.0)
	sd.y = 0.0
	var sdir: Vector3 = (sd.normalized() * cos(deg_to_rad(20.0)) + Vector3.DOWN * sin(deg_to_rad(20.0))).normalized()
	pr.sun.global_transform = Transform3D(Basis.looking_at(sdir, Vector3.UP), Vector3.ZERO)
	pr.sun.light_color = Color(1.0, 0.93, 0.84)
	pr.sun.light_energy = 2.6
	pr.sky_mat.sky_top_color = Color(0.3, 0.47, 0.8)
	pr.sky_mat.sky_horizon_color = Color(0.78, 0.84, 0.9)
	pr.sky_mat.ground_horizon_color = Color(0.6, 0.62, 0.6)
	pr.sky_mat.energy_multiplier = 1.25
	pr.env.fog_light_color = Color(0.8, 0.85, 0.92)
	pr.env.fog_depth_end = 700.0
	pr.env.volumetric_fog_density *= 0.25
	pr.env.ambient_light_energy = 1.0
	pr.env.adjustment_saturation = 1.0
	pr.env.fog_sun_scatter = 0.1
	pr.torch.visible = false
	if pr.building:
		pr.building.visible = false
	pr.hero.visible = false
	var xf: Transform3D = pr.site_xf
	var center: Vector3 = xf * Vector3(37.0, 5.8, -8.0)
	var vp := SubViewport.new()
	vp.size = Vector2i(1024, 1024)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	pr.add_child(vp)
	var cam := Camera3D.new()
	cam.fov = 90.0
	cam.far = 4000.0
	cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF   # грань — сразу в своём повороте
	vp.add_child(cam)
	cam.current = true
	# грани куба: +X, -X, +Y, -Y, +Z, -Z (в осях здания)
	var faces := {"px": [Vector3(1, 0, 0), Vector3.UP], "nx": [Vector3(-1, 0, 0), Vector3.UP],
		"py": [Vector3(0, 1, 0), Vector3(0, 0, 1)], "ny": [Vector3(0, -1, 0), Vector3(0, 0, -1)],
		"pz": [Vector3(0, 0, 1), Vector3.UP], "nz": [Vector3(0, 0, -1), Vector3.UP]}
	for k in faces:
		var fwd: Vector3 = xf.basis * (faces[k][0] as Vector3)
		var up: Vector3 = xf.basis * (faces[k][1] as Vector3)
		cam.global_transform = Transform3D(Basis.looking_at(fwd, up), center)
		cam.reset_physics_interpolation()
		RenderingServer.global_shader_parameter_set("main_camera_pos", center)
		pr.terrain.update_lods(center, true)
		pr.forest.lod_manager.update_now(cam)
		await secs(2.5)
		var img: Image = vp.get_texture().get_image()
		img.save_png("%s/cube_%s.png" % [out, k])
		print("SHOT cube_", k)


## Стиральная машина (закрыта и с открытым люком), крыса и таракан — крупно, при свете.
func _critters_shots(g: Node, cam: Camera3D, lamp: OmniLight3D) -> void:
	var Props: Script = load("res://story/props.gd")
	var spot := Vector3(26.2, 7.8, -11.0)                 # комната на 3-м этаже
	g.lights.set_room("L2.R7", true)
	var w: Node3D = Props.washer()
	g.add_child(w)
	w.global_position = spot
	cam.global_position = spot + Vector3(0.6, 1.1, -1.5)
	cam.look_at(spot + Vector3(0, 0.45, 0), Vector3.UP)
	cam.current = true
	lamp.global_position = cam.global_position + Vector3(0, 0.6, 0)
	await secs(1.0)
	await shot("washer_closed")
	var hatch: Node3D = w.get_node_or_null("Hatch")
	if hatch:
		hatch.rotation.y = deg_to_rad(105.0)
	await secs(0.8)
	await shot("washer_open")
	w.queue_free()
	for kind in ["rats", "roaches"]:
		var list: Array = g.critters.get(kind)
		if list.is_empty():
			continue
		var n: Node3D = list[0]["node"]
		var size := 0.45 if kind == "rats" else 0.12
		var c: Vector3 = n.global_position
		cam.global_position = c + Vector3(size * 0.8, size * 0.6, size)
		cam.look_at(c + Vector3(0, size * 0.1, 0), Vector3.UP)
		lamp.global_position = cam.global_position + Vector3(0, 0.4, 0)
		g.critters.set_process(false)
		await secs(0.8)
		await shot("critter_" + kind)


## Кадры из разных мест здания: текстуры, свет, цвет (комнаты включены).
## [точка, поворот (рад), наклон взгляда, комната со светом или ""]
const TOUR := [
	[Vector3(28.9, 1.2, 4.27), -PI * 0.5, -0.05, ""],
	[Vector3(30.95, 1.2, -7.9), PI * 0.9, 0.18, ""],
	[Vector3(39.0, 1.2, -8.1), -PI * 0.5, -0.05, ""],
	[Vector3(52.5, 1.2, -11.2), 0.0, -0.15, "L0.R17"],
	[Vector3(44.0, 1.2, -6.8), PI, -0.25, "L0.F14"],
	[Vector3(26.2, 7.8, -11.0), PI * 0.55, -0.12, "L2.R7"],
	[Vector3(37.5, 7.8, -8.4), PI * 0.5, -0.05, ""],
	[Vector3(8.0, 4.5, -4.7), -2.35, -0.18, "L1.F2"],
	[Vector3(9.3, 4.5, -2.0), PI * 0.5, -0.25, "L1.F2"],
]
const VOID_TOUR := [
	[Vector3(37.5, 4.5, -8.9), PI, 0.05, ""],
	[Vector3(36.9, 4.5, -7.2), PI * 0.75, 0.0, ""],
	[Vector3(30.0, 4.5, -8.3), PI * 0.5, 0.0, ""],
	[Vector3(8.83, 4.5, -8.3), PI, -0.55, "open204"],
	[Vector3(7.2, 4.5, -2.5), 0.81, -0.45, "notes"],
	[Vector3(8.2, 4.5, -2.4), 2.58, -0.5, ""],
	[Vector3(9.6, 4.5, -2.6), -2.17, -0.4, ""],
]


func _tour_test(dir: Node, void_floor: bool) -> void:
	d = dir
	pl = dir.player
	dir.scares.stop()
	await secs(2.0)
	var spots: Array = VOID_TOUR if void_floor else TOUR
	var only := _arg("spots", "")
	var settle := float(_arg("settle", "1.5"))           # секунд на привыкание глаза (автоэкспозиция)
	for i in spots.size():
		if only != "" and not (str(i) in only.split(",")):
			continue
		var sp: Array = spots[i]
		if sp[3] == "notes":
			await tp(Vector3(9.0, 4.5, -3.0), 0.0)
			await wait_for_d(dir, func(): return dir.objective_text().contains("Осмотри"), 60)
			await secs(2.0)
		elif sp[3] == "open204":
			dir.sets.door(dir.sets.DOOR_204).set_angle(90.0)
		elif sp[3] != "":
			dir.game.lights.set_room(sp[3], true)
		await tp(sp[0], sp[1])
		pl.look_yaw = 0.0
		pl.look_pitch = sp[2]
		await secs(settle)
		await shot("%s_%02d" % ["voidtour" if void_floor else "tour", i])


## Стойка мамы в полный рост: спереди, сбоку, сзади — отдельной камерой на уровне глаз.
func _mompose_test(g: Node, dir: Node) -> void:
	d = dir
	pl = dir.player
	var m: Node3D = dir.mom
	await wait_for_d(dir, func(): return dir.act == "act1" and not m.is_moving() and m.global_position.distance_to(dir.STAIR_FOOT) < 0.6, 90)
	await secs(1.0)
	dir.set_process(false)
	m.global_position = Vector3(31.6, 1.2, 1.6)          # в просторном холле
	m.set_yaw(-PI * 0.5)
	m.play("idle_loop", 0.0)
	await secs(1.5)
	var cam := Camera3D.new()
	cam.fov = 40.0
	g.add_child(cam)
	var lamp := OmniLight3D.new()
	lamp.light_energy = 1.2
	lamp.omni_range = 6.0
	g.add_child(lamp)
	var c: Vector3 = m.global_position + Vector3(0, 0.95, 0)
	var fwd: Vector3 = -m.global_transform.basis.z
	var right: Vector3 = m.global_transform.basis.x
	var views := [fwd * 2.2, right * 2.2, -fwd * 2.2, (fwd + right).normalized() * 2.2]
	for i in views.size():
		cam.global_position = c + views[i] + Vector3(0, 0.25, 0)
		cam.look_at(c, Vector3.UP)
		cam.current = true
		lamp.global_position = cam.global_position + Vector3(0, 0.8, 0)
		await secs(0.8)
		await shot("mompose_%d" % i)


func _caught_test() -> void:
	Engine.time_scale = 3.0
	GameStateRef().checkpoint = "chase"
	get_tree().change_scene_to_file("res://sanatorium/main.tscn")
	await secs(2.0)
	d = get_tree().current_scene.get_node("Director")
	await wait_for(func(): return d.act == "lift_key", 60, "lift_key")
	pl = d.player
	await tp(Vector3(37.5, 1.2, -7.6), 0.0)
	press_call(0)
	await wait_for(func(): return d.chase == "run", 30, "chase run")
	step("chase running, staying outside the lift")
	await tp(Vector3(42.0, 1.2, -8.1), PI * 0.5)
	await wait_for(func(): return d.chase == "caught", 60, "caught")
	step("caught")
	await wait_for(func(): return d.act == "lift_key" and d.chase == "off", 60, "restart")
	step("restarted at " + str(pl.global_position) + " deaths=" + str(GameStateRef().deaths))
	press_call(0)
	await wait_for(func(): return d.chase == "run", 30, "chase again")
	step("second chase started, speed " + str(d._psycho_speed))
	Engine.time_scale = 1.0


## Каждый тип предмета со своей моделью или картинкой — крупно, отдельной камерой перед ним (свет в комнате включён).
const ITEM_TYPES := ["armchair_beige", "armchair", "armchair_red", "bedside", "table_small", "table_sq", "wardrobe", "bathtub",
	"toilet", "sink", "wheelchair", "chair", "painting_1", "painting_2", "painting_3", "notice_board", "clock", "radio",
	"tv_small", "telephone", "call_panel", "fire_ext", "game_chess", "fuse_box", "electro_warning",
	"bed_a", "bed_b", "bed_strip", "bed_hosp", "locker", "iv_stand", "Radiator", "towel_rail", "table_round",
	"table_cloth", "instrument_table", "fix_fluo", "fix_bulb"]


func _items_test(g: Node, dir: Node) -> void:
	dir.set_process(false)
	dir.scares.stop()
	var Game: Script = load("res://sanatorium/scripts/game.gd")
	var cam := Camera3D.new()
	cam.fov = 55.0
	g.add_child(cam)
	var lamp := OmniLight3D.new()
	lamp.light_energy = 0.8
	lamp.omni_range = 5.0
	g.add_child(lamp)
	if _arg("critters", "") != "":
		await _critters_shots(g, cam, lamp)
		return
	var seen := {}
	var fix_kind := {}
	for f in g.level["fixtures"]:
		fix_kind[String(f["name"])] = "fix_" + String(f["kind"])
	var meshes: Array = g.building.find_children("*", "Node3D", true, false)
	var only := _arg("types", "")
	for t in ITEM_TYPES:
		if only != "" and not (t in only.split(",")):
			continue
		var k := 0
		for n in meshes:
			var nm := String(n.name)
			var base: String = nm.trim_suffix("_model").trim_suffix("_pic").trim_suffix("_ontop")
			var tt: String = "electro_warning" if nm.begins_with("electro_warning") else Game.model_type(base)
			if fix_kind.has(base):
				tt = fix_kind[base]
			if tt != t or not (nm.ends_with("_model") or nm.ends_with("_pic") or nm.ends_with("_ontop")):
				continue
			var node: Node3D = n
			if not node.is_inside_tree():
				continue
			k += 1
			if k > 2:
				break
			var xf: Transform3D = node.global_transform
			var src: Node = node.get_parent().get_node_or_null(base)
			var size := 1.0
			if src is MeshInstance3D and (src as MeshInstance3D).mesh:
				var bb: AABB = (src as MeshInstance3D).mesh.get_aabb()
				size = maxf(bb.size.length(), 0.25)
				xf = xf * Transform3D(Basis.IDENTITY, bb.get_center())
			var front: Vector3 = xf.basis.z.normalized()
			var c: Vector3 = xf.origin
			cam.global_position = c + front * (size * 1.25 + 0.3) + Vector3(0, size * 0.35, 0)
			if t.begins_with("fix_"):                   # лампа под потолком: снизу и сбоку
				cam.global_position = c + Vector3(0.45, -1.35, 0.5)
			elif t == "iv_stand":
				cam.global_position = c + front * 1.3 + Vector3(0, 0.2, 0)
			cam.look_at(c, Vector3.UP)
			cam.current = true
			lamp.global_position = cam.global_position + Vector3(0, 0.6, 0)
			var room: Dictionary = g.room_at(c + Vector3(0, 0.2, 0))
			if room.has("id"):
				g.lights.set_room(String(room["id"]), true)
			await secs(1.2)
			await shot("item_%s_%d" % [t, k])
