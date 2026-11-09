extends Node
## Проверка без игрока: загружает сцену, проматывает сюжет и сохраняет скриншоты.
## Запуск: godot --path . res://tests/shots.tscn -- --case=<имя> --out=<папка> [--quality=medium]
## Случаи: bus, bus_mom, walk, building, sanatorium, chase, void, floor3, maze, fight, epilogue, menu, anim

var out := "user://shots"
var case_name := "bus"
var _log: Array = []


func _ready() -> void:
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
		"sanatorium", "chase", "void", "floor3", "maze", "fight", "chair":
			await _sanatorium()
		"epilogue":
			get_tree().change_scene_to_file("res://story/epilogue.tscn")
			await secs(12.0)
			await shot("epilogue")
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
			p.look_yaw = 1.35
			p.look_pitch = 0.12
			await secs(1.5)
			await shot("bus_left_mom")
			p.look_yaw = -1.6
			p.look_pitch = 0.0
			await secs(1.5)
			await shot("bus_front")
		"bus_mom":
			p.look_yaw = 1.35
			p.look_pitch = 0.15
			await secs(8.0)
			await shot("bus_mom_window")
			p.talking = true
			await secs(10.0)
			await shot("bus_mom_talk")
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


func GameStateRef() -> Node:
	return get_tree().root.get_node("GameState")


func _sanatorium() -> void:
	var cp: String = case_name
	if case_name == "sanatorium" or case_name == "chair":
		cp = "start"
	elif case_name == "fight":
		cp = "maze"
	GameStateRef().checkpoint = cp
	get_tree().change_scene_to_file("res://sanatorium/main.tscn")
	await secs(3.0)
	var g: Node = get_tree().current_scene
	var d: Node = g.get_node("Director")
	await secs(4.0)
	GameStateRef().set_fade(0.0)
	await shot(case_name + "_start")
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
	elif case_name == "fight":
		d.has_ward_key = true
		var door = d.door(91)
		door.locked = false
		d.player.global_position = Vector3(8.8, 4.55, -4.6)
		d.player.rotation.y = PI
		await secs(2.0)
		Engine.time_scale = 3.0
		d._grandpa_at_door()
		await secs(5.0)
		await shot("fight_grandpa")
		while d.act != "fight":
			await get_tree().process_frame
		Engine.time_scale = 1.0
		await secs(2.0)
		await shot("fight_mom")
		while d.fight == "on":
			await get_tree().process_frame
		await secs(2.0)
		await shot("fight_cornered")
		while d.act != "quake":
			await get_tree().process_frame
		await secs(3.0)
		await shot("quake")
	elif case_name == "chair":
		d.player.look_pitch = -1.0
		d.player.look_yaw = -0.3
		d.player.input_override = Vector2(1.0, 1.0)
		await secs(3.0)
		d.player.input_override = Vector2(0, 0)
		d.player.chair_model.set_input(1.0, 1.0, 1.0)
		await shot("chair_joystick")


# ------------------------------------------------------------------ прохождение всей истории (без экрана)
var d: Node
var pl: Node


func step(msg: String) -> void:
	print("STEP ", msg, "  act=", d.act if d else "", " chase=", d.chase if d else "", " t=", Time.get_ticks_msec() / 1000)


func wait_for(cond: Callable, limit := 120.0, what := "") -> bool:
	var t := 0.0
	while not cond.call():
		await get_tree().process_frame
		t += get_process_delta_time() / maxf(Engine.time_scale, 0.001)
		if t > limit:
			print("TIMEOUT waiting for ", what, "  act=", d.act)
			return false
	return true


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


func _playthrough() -> void:
	Engine.time_scale = 6.0
	GameStateRef().checkpoint = "start"
	get_tree().change_scene_to_file("res://sanatorium/main.tscn")
	await secs(2.0)
	var g: Node = get_tree().current_scene
	d = g.get_node("Director")
	await wait_for(func(): return d.act == "act1", 60, "act1")
	pl = d.player
	step("act1 started")
	await tp(Vector3(31.0, 1.2, -3.0), PI)
	await wait_for(func(): return d.act == "scream", 400, "scream")
	step("scream")
	var door = d.door(74)
	await secs(4.0)
	await tp(Vector3(52.5, 1.2, -8.4), 0.0)
	door.interact(pl)
	await wait_for(func(): return door.angle > 18.0, 20, "scream door opens")
	await secs(5.0)
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
	await wait_for(func(): return d.lift.state == "open", 20, "cab open")
	press_cab("2")
	await wait_for(func(): return d.act == "void", 90, "void")
	step("void")
	await wait_for(func(): return d.lift.state == "open", 30, "doors open at 2")
	await tp(Vector3(9.0, 4.5, -3.5), 0.0)
	await wait_for(func(): return d.act == "void_done", 120, "void_done")
	step("void_done")
	await tp(Vector3(37.5, 4.5, -7.3), 0.0)
	press_call(1)
	await wait_for(func(): return d.lift.state == "open" and d.lift.floor_idx == 1, 30, "lift at 2")
	await tp(Vector3(37.5, 4.5, -5.0), PI)
	press_cab("3")
	await wait_for(func(): return d.act == "floor3_search", 90, "floor3")
	step("floor3")
	await tp(Vector3(20.0, 7.8, -8.1), 0.0)
	pl.v = 1.0
	await secs(4.0)
	d.scares.elapsed = 400.0
	d.scares.count = 10
	await secs(3.0)
	await tp(d.MAN_POS + Vector3(0, 0, -1.3), PI)
	await wait_for(func(): return d.act == "floor3_leave", 120, "man dialogue")
	step("floor3_leave")
	await tp(Vector3(37.5, 7.8, -7.6), 0.0)
	press_call(2)
	await wait_for(func(): return d.lift.state == "open" and d.lift.floor_idx == 2, 30, "lift at 3")
	await tp(Vector3(37.5, 7.8, -5.0), PI)
	press_cab("2")
	await wait_for(func(): return d.act == "maze", 120, "maze")
	step("maze")
	await secs(2.0)
	for c in g.get_children():
		if c is Node3D and c.get_child_count() > 0:
			for it in c.get_children():
				if it is Area3D and it.has_meta("interact") and str(it.get_meta("interact").get("text")).contains("204"):
					it.get_meta("interact").action.call()
	await wait_for(func(): return d.has_ward_key, 20, "ward key")
	step("ward key")
	await tp(Vector3(8.8, 4.5, -4.8), 0.0)
	await wait_for(func(): return d.act == "fight", 120, "fight")
	step("fight")
	await secs(3.0)
	d.hp = 10.0
	await wait_for(func(): return d.act == "quake", 120, "quake")
	step("quake")
	for wp in d.GRANDPA_RUN:
		await tp(wp, 0.0)
		await secs(0.6)
	await tp(Vector3(31.0, 4.5, -3.0), -PI * 0.5)
	for i in 6:
		await secs(3.0)
		if not is_instance_valid(d):
			break
		print("DBG pl ", pl.global_position, " gp ", d.grandpa.global_position, " moving ", d.grandpa.is_moving(), " act ", d.act)
	await wait_for(func(): return get_tree().current_scene == null or get_tree().current_scene.name == "Epilogue", 120, "epilogue")
	step("epilogue reached")
	await secs(10.0)
	Engine.time_scale = 1.0


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
	while is_instance_valid(p) and p.phase == "walk" and dist < p.path_cum[-1] + 2.0:
		dist += 2.0
		p.hero.global_position = p._path_at(dist)
		await secs(0.3)
	print("STEP end of path  phase=", p.phase if is_instance_valid(p) else "freed")
	await secs(8.0)
	print("STEP scene now ", get_tree().current_scene.name if get_tree().current_scene else "null")
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
