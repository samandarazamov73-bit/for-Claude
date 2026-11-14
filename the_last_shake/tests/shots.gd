extends Node
## Проверка без игрока: загружает сцену, проматывает сюжет и сохраняет скриншоты.
## Запуск: godot --path . res://tests/shots.tscn -- --case=<имя> --out=<папка> [--quality=medium]
## Случаи: bus, bus_mom, walk, building, entrance, sanatorium, chase, void, floor3, maze, fight, epilogue, menu, anim

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
		"sanatorium", "chase", "void", "floor3", "maze", "fight", "chair", "chase2", "trap", "void2":
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
			p.say("mom", "Он нас ждёт, Саман.", 8.0)
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
		while not d.objective_text().contains("столик"):
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
	await wait_for(func(): return d.objective_text().contains("столик"), 30, "scalpel objective")
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
	await wait_for(func(): return d.lift.state == "open", 30, "doors open at 2")
	await tp(Vector3(9.0, 4.5, -3.5), 0.0)
	await wait_for(func(): return d.objective_text().contains("бумаги"), 60, "notes")
	d._read_note("diary")
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
