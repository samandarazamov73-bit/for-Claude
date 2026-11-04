extends Node3D
## НАЧАЛО ИГРЫ «Дедовская палата»: поездка с мамой на автобусе в больницу (3–5 минут).
##
## Игрок сидит в электроколяске в автобусе (вид от первого лица, можно осматриваться мышью), разговаривает
## с мамой (выбор ответов 1/2/3), просит водителя остановить у больницы. Автобус стоит на остановках и светофоре.
## У больницы он останавливается, экран темнеет, мама и коляска выходят — и загружается твой уровень.
##
## Все тексты — в story.gd, все числа — в cfg.gd.

const C = preload("res://intro/cfg.gd")
const Story = preload("res://intro/story.gd")
const RouteScript = preload("res://intro/route.gd")
const DriverScript = preload("res://intro/driver.gd")
const CityScript = preload("res://intro/city.gd")
const BusScript = preload("res://intro/bus.gd")
const TrafficScript = preload("res://intro/traffic.gd")
const HumanScript = preload("res://intro/human.gd")
const UIScript = preload("res://intro/ui.gd")
const AudioScript = preload("res://intro/audio.gd")
const WheelchairScript = preload("res://intro/wheelchair.gd")
const PersonScript = preload("res://intro/person.gd")

enum Phase { RIDE, ARRIVAL, DARK, END }

@export var ride_minutes: float = C.RIDE_MINUTES              # длина поездки, мин
@export var next_scene: String = C.NEXT_SCENE                 # куда идти после выхода из автобуса
@export var dark_seconds: float = C.DARK_SECONDS              # длина чёрного экрана
@export var mouse_sensitivity: float = C.MOUSE_SENS
@export var overcast: bool = true                             # пасмурный день (мрачнее)
@export_enum("start", "light", "market", "hospital", "arrival") var debug_skip: String = "start"

var phase: int = Phase.RIDE
var route
var driver
var city
var bus
var traffic
var ui
var audio
var mom
var hero_rig: Node3D
var head: Node3D
var cam: Camera3D

var look_yaw: float = 0.0
var look_pitch: float = -0.08
var time: float = 0.0
var sim_dt: float = 0.0

var _stop_busy: bool = false
var _light_cycle: bool = false
var _fired: Dictionary = {}
var _task_stop: bool = false
var _idle_index: int = 0
var _target: String = ""
var _mom_look_timer: float = 4.0
var _mom_look_window: float = 0.0

# Разговоры
var _dq: Array = []
var _dq_running: bool = false
var _dgen: int = 0
var _skip: bool = false
var _say_elapsed: float = 0.0
var _speaker: String = ""


func _ready() -> void:
	randomize()
	_setup_environment()
	route = RouteScript.new()
	route.fit_to_duration(ride_minutes * 60.0)
	driver = DriverScript.new(route)
	city = CityScript.new()
	city.build(self, route)
	bus = BusScript.new()
	bus.name = "Bus"
	add_child(bus)
	bus.build()
	var bus_model: String = "res://intro/assets/models/bus.glb"
	if ResourceLoader.exists(bus_model):
		var res: Resource = load(bus_model)
		if res is PackedScene:
			bus.use_model(res)
	traffic = TrafficScript.new()
	traffic.build(self, route, city)
	_build_people()
	_build_hero()
	if mom != null:                                    # сразу видно маму (поворот головы героя к ней)
		var lp: Vector3 = hero_rig.to_local(mom.focus_point()) - head.position
		look_yaw = clampf(atan2(-lp.x, -lp.z) * 0.8, -2.4, 2.4)
	ui = UIScript.new()
	add_child(ui)
	audio = AudioScript.new()
	add_child(audio)
	ui.pause_toggle.connect(_on_pause_toggle)
	ui.resume_pressed.connect(_on_resume)
	ui.menu_pressed.connect(_on_menu)
	ui.restart_pressed.connect(_on_restart)
	var final_ev: Dictionary = route.by_id["hospital"]
	var span: float = float(final_ev["s"]) - route.start_s
	var stops: Array = []
	for id in ["park", "market", "hospital"]:
		stops.append({"name": Story.STOPS[id], "at": (float(route.by_id[id]["s"]) - route.start_s) / span, "final": id == "hospital"})
	ui.setup_route(stops)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_place_bus(0.0, false)
	if debug_skip != "start":
		_jump_to(debug_skip)
	_begin_ride()


# --- Сцена: небо, свет, туман ----------------------------------------------------------------

func _setup_environment() -> void:
	var sky_mat: ProceduralSkyMaterial = ProceduralSkyMaterial.new()
	if overcast:
		sky_mat.sky_top_color = Color(0.46, 0.52, 0.58)
		sky_mat.sky_horizon_color = Color(0.74, 0.77, 0.78)
		sky_mat.ground_horizon_color = Color(0.70, 0.72, 0.72)
		sky_mat.ground_bottom_color = Color(0.45, 0.47, 0.45)
	else:
		sky_mat.sky_top_color = Color(0.25, 0.49, 0.79)
		sky_mat.sky_horizon_color = Color(0.81, 0.88, 0.93)
		sky_mat.ground_horizon_color = Color(0.78, 0.85, 0.9)
		sky_mat.ground_bottom_color = Color(0.45, 0.5, 0.45)
	var sky: Sky = Sky.new()
	sky.sky_material = sky_mat
	var env: Environment = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color(0.72, 0.75, 0.77) if overcast else Color(0.81, 0.88, 0.93)
	env.fog_density = 0.0028
	env.adjustment_enabled = true
	env.adjustment_saturation = 0.88 if overcast else 1.0
	var we: WorldEnvironment = WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -30.0, 0.0)
	sun.light_energy = 1.05 if overcast else 1.7
	sun.light_color = Color(1.0, 0.96, 0.9)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 80.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	add_child(sun)


# --- Люди ----------------------------------------------------------------------------------------

func _build_people() -> void:
	if bus.has_model and ResourceLoader.exists(C.PEOPLE_DIR + "mom.glb"):
		_build_people_models()
		if mom != null:
			return
	mom = HumanScript.new()
	mom.setup({"height": 1.62, "shirt": "#8e3b46", "pants": "#2b2d42", "hair": "#2a1b12", "shoes": "#3a2a20",
		"hair_style": "bun", "sit_height": 0.47, "shadows": false})
	bus.body.add_child(mom)
	mom.position = bus.anchor_mom                       # напротив места коляски, лицом вперёд (на героя)
	mom.set_pose("sit")
	if bus.has_model:                                  # настоящий автобус, но моделей людей нет: мама стоит у коляски
		mom.transform = bus.anchor_xf.get("anchor_mom", mom.transform)
		mom.set_pose("stand")
		return

	var drv: Node3D = HumanScript.new()
	drv.setup({"height": 1.75, "shirt": "#7da6d1", "pants": "#2c2c34", "hair": "#3b2a20", "sit_height": 0.5, "shadows": false})
	bus.body.add_child(drv)
	drv.position = Vector3(-0.72, C.FLOOR_Y, -4.85)
	drv.set_pose("sit")

	var shirts: Array = ["#8e5b3c", "#4b7f52", "#a83e3e", "#5d5f9c", "#c79a2a", "#38707a", "#6d6d6d", "#b05f8c"]
	var pants: Array = ["#2d2d36", "#3b4a63", "#4a3b2f"]
	var hairs: Array = ["#1e140d", "#4a3020", "#888888", "#b8913f"]
	var free: Array = []
	for sp in bus.seats:
		var v: Vector3 = sp
		if absf(v.z - bus.anchor_mom.z) < 0.2 and v.x < 0.0:
			continue                                     # места рядом с мамой не занимаем
		free.append(v)
	var r: RandomNumberGenerator = RandomNumberGenerator.new()
	r.seed = 7
	for idx in [3, 6, 9, 12, 15, 19, 22]:
		var seat: Vector3 = free[int(idx) % free.size()]
		var p: Node3D = HumanScript.new()
		p.setup({"height": r.randf_range(1.6, 1.82), "shirt": shirts[r.randi_range(0, shirts.size() - 1)],
			"pants": pants[r.randi_range(0, pants.size() - 1)], "hair": hairs[r.randi_range(0, hairs.size() - 1)],
			"hair_style": "long" if r.randf() < 0.4 else "short", "sit_height": 0.5, "shadows": false})
		bus.body.add_child(p)
		p.position = seat
		p.set_pose("sit")


## Мама, водитель и пассажиры из intro/assets/models/people/ на метках из bus.glb.
func _build_people_models() -> void:
	mom = _spawn_person("mom", "anchor_mom")
	_spawn_person("driver", "anchor_driver")
	for seat_name in C.PASSENGERS:
		var p = _spawn_person(str(C.PASSENGERS[seat_name]), str(seat_name))
		if p != null:
			p.glances = true


func _spawn_person(file_name: String, anchor: String):
	var path: String = C.PEOPLE_DIR + file_name + ".glb"
	if not bus.anchor_xf.has(anchor) or not ResourceLoader.exists(path):
		return null
	var res: Resource = load(path)
	if not (res is PackedScene):
		return null
	var p = PersonScript.new()
	p.name = file_name
	bus.body.add_child(p)
	p.transform = bus.anchor_xf[anchor]
	p.setup(res)
	return p


func _build_hero() -> void:
	hero_rig = Node3D.new()
	hero_rig.name = "Hero"
	bus.body.add_child(hero_rig)
	if bus.anchor_xf.has("anchor_wheelchair"):
		hero_rig.transform = bus.anchor_xf["anchor_wheelchair"]   # место для коляски у задней двери, лицом вперёд
	else:
		hero_rig.position = bus.anchor_wheelchair
		hero_rig.rotation.y = PI                      # заглушка: лицом назад, на маму; спина к упору
	var eye: Vector3 = Vector3(0, C.EYE_HEIGHT, -0.06)
	var chair_model: String = C.MODELS_DIR + "wheelchair.glb"
	var res: Resource = load(chair_model) if ResourceLoader.exists(chair_model) else null
	if res is PackedScene:
		# Модель коляски уже с сидящим героем (без головы — вид от первого лица), своё тело не нужно.
		var fix: Node3D = Node3D.new()
		fix.name = "WheelchairModel"
		hero_rig.add_child(fix)
		fix.position.y = C.WHEELCHAIR_LIFT
		fix.rotation.y = deg_to_rad(C.WHEELCHAIR_YAW_DEG)
		fix.scale = Vector3.ONE * C.WHEELCHAIR_SCALE
		fix.add_child((res as PackedScene).instantiate())
		eye = C.WHEELCHAIR_EYE
	else:
		hero_rig.add_child(WheelchairScript.build())
		var body = HumanScript.new()
		body.setup({"height": 1.75, "shirt": "#3a6ea5", "pants": "#2f3e5c", "hair": "#21160f",
			"sit_height": WheelchairScript.SEAT_HEIGHT, "shadows": false})
		hero_rig.add_child(body)
		body.position = Vector3(0, 0, 0.04)
		body.set_pose("wheelchair")
		body.set_head_visible(false)                  # свою голову изнутри не видно
	head = Node3D.new()
	head.position = eye
	hero_rig.add_child(head)
	cam = Camera3D.new()
	cam.fov = 70.0
	cam.near = 0.05
	cam.far = 700.0
	head.add_child(cam)
	cam.make_current()


# --- Старт ------------------------------------------------------------------------------------------

func _begin_ride() -> void:
	ui.set_fade(1.0)
	ui.set_objective(Story.OBJECTIVE_RIDE)
	_start_sequence()


func _start_sequence() -> void:
	_fade_to(0.0, 2.5)
	_title_card(Story.TITLE, Story.SUBTITLE, 2.5)
	await _wait(3.0, false)
	audio.play_sfx("chime")
	play([["announcer", Story.ANNOUNCE_NEXT % Story.STOPS["park"]]])
	play(Story.INTRO)
	await _wait(5.0, false)
	for i in 10:                                       # подсказка управления плавно появляется и исчезает
		ui.set_hint_alpha(float(i + 1) / 10.0)
		await _wait(0.1, false)
	await _wait(9.0, false)
	for i in 10:
		ui.set_hint_alpha(1.0 - float(i + 1) / 10.0)
		await _wait(0.2, false)


func _title_card(a: String, b: String, hold: float) -> void:
	for i in 20:
		ui.set_title(a, b, float(i + 1) / 20.0)
		await _wait(0.05, false)
	await _wait(hold, false)
	for i in 20:
		ui.set_title(a, b, 1.0 - float(i + 1) / 20.0)
		await _wait(0.05, false)
	ui.set_title("", "", 0.0)


# --- Время и затемнение ----------------------------------------------------------------------------

## Ждёт seconds. use_sim=true — по «времени поездки» (ускоряется перемоткой Tab), иначе по обычному.
func _wait(seconds: float, use_sim: bool = true) -> void:
	var t: float = 0.0
	while t < seconds:
		await get_tree().process_frame
		if not is_inside_tree():
			return
		if not get_tree().paused:
			t += sim_dt if use_sim else get_process_delta_time()


func _after(seconds: float, action: Callable) -> void:
	await _wait(seconds)
	if is_inside_tree():
		action.call()


func _fade_to(target: float, seconds: float) -> void:
	var from_v: float = ui.get_fade()
	var t: float = 0.0
	while t < seconds:
		await get_tree().process_frame
		if not is_inside_tree():
			return
		if not get_tree().paused:
			t += get_process_delta_time()
		ui.set_fade(lerpf(from_v, target, C.smooth(0.0, 1.0, t / seconds)))
	ui.set_fade(target)


# --- Разговоры ---------------------------------------------------------------------------------------

func play(steps: Array) -> void:
	if steps.is_empty():
		return
	_dq.append(steps)
	if not _dq_running:
		_run_queue()


func _run_queue() -> void:
	_dq_running = true
	while not _dq.is_empty():
		var conv: Array = _dq.pop_front()
		await _run_steps(conv, _dgen)
		if not is_inside_tree():
			return
	_dq_running = false


func _run_steps(list: Array, gen: int) -> void:
	for step in list:
		if gen != _dgen or not is_inside_tree():
			return
		if step is Array:
			await _say(str(step[0]), str(step[1]))
		elif step is Dictionary:
			if step.has("choice"):
				var opts: Array = step["choice"]
				var texts: Array = []
				for o in opts:
					texts.append(str(o["text"]))
				var i: int = await ui.choose(texts)
				if i < 0 or gen != _dgen or not is_inside_tree():
					return
				await _say("hero", texts[i])
				await _run_steps(opts[i].get("then", []), gen)
			elif step.has("pause"):
				await _wait(float(step["pause"]))
			elif step.has("action"):
				_do_action(str(step["action"]))


func _say(who: String, text: String) -> void:
	var duration: float = clampf(1.3 + float(text.length()) * 0.055, 2.0, 7.5)
	_say_elapsed = 0.0
	_skip = false
	_speaker = who
	ui.show_line(who, text)
	if who == "mom":
		mom.talking = duration
	while not _skip and _say_elapsed < duration:
		await get_tree().process_frame
		if not is_inside_tree():
			return
	if who == "mom":
		mom.talking = 0.0
	_speaker = ""
	ui.hide_line()
	await _wait(0.25)


func _play_and_wait(steps: Array) -> void:
	play(steps)
	while _dq_running or not _dq.is_empty():
		await get_tree().process_frame
		if not is_inside_tree():
			return


## Обрывает текущий разговор и отменяет ждущие (например, при прибытии).
func _clear_dialogue() -> void:
	_dgen += 1
	_dq.clear()
	_skip = true
	ui.cancel_choice()


func _do_action(action: String) -> void:
	if action == "stop_button_task":
		_task_stop = true
		if not bus.stop_requested:
			ui.set_objective(Story.OBJECTIVE_PRESS_STOP)


func _press_stop(by_mom: bool) -> void:
	if bus.stop_requested:
		return
	bus.set_stop_requested(true)
	if bus.stop_button.visible:
		audio.play_sfx("ding")
	if _task_stop:
		ui.set_objective(Story.OBJECTIVE_RIDE)
		play(Story.STOP_MOM_PRESSED if by_mom else Story.STOP_PRESSED)
		_task_stop = false


func _talk_to_mom() -> void:
	if _dq_running:
		return
	if _idle_index < Story.IDLE.size():
		play(Story.IDLE[_idle_index])
		_idle_index += 1
	else:
		play(Story.IDLE_REPEAT[randi() % Story.IDLE_REPEAT.size()])


# --- Каждый кадр -------------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	time += delta
	_say_elapsed += delta
	var fast: bool = Input.is_key_pressed(KEY_TAB) and phase == Phase.RIDE and not ui.is_choosing()
	sim_dt = delta * (C.FAST_FORWARD if fast else 1.0)
	if phase == Phase.RIDE:
		_update_ride(delta)
	else:
		_place_bus(delta)
		traffic.update(delta, driver.s, driver.v)
	head.rotation = Vector3(look_pitch, look_yaw, 0.0)
	_update_mom(delta)
	_update_interaction()


func _update_ride(delta: float) -> void:
	var ev: Variant = driver.next_event()
	# Светофор: перед автобусом загорается жёлтый, потом красный.
	if ev != null and ev["kind"] == "light" and not _light_cycle and float(ev["s"]) - driver.s < 150.0:
		_light_cycle = true
		city.set_light("yellow")
		_after(2.2, func() -> void: city.set_light("red"))
	# Поворотник к бордюру перед остановкой.
	if ev != null and ev["kind"] != "light" and not driver.stopped:
		if float(ev["s"]) - driver.s < 90.0:
			bus.indicator = 1
		elif bus.indicator == 1:
			bus.indicator = 0
	# Ведём автобус мелкими шагами (при перемотке шаг большой).
	var steps: int = maxi(1, int(ceil(sim_dt / 0.04)))
	for i in steps:
		driver.update(sim_dt / float(steps))
	if driver.stopped and not _stop_busy:
		_stop_busy = true
		_handle_stop(driver.next_event())
	_place_bus(delta)

	# События по доле пути.
	var final_ev: Dictionary = route.by_id["hospital"]
	var progress: float = (driver.s - route.start_s) / (float(final_ev["s"]) - route.start_s)
	ui.set_route_progress(progress)
	for p in Story.PROGRESS:
		var key: String = "p" + str(p["at"])
		if progress >= float(p["at"]) and not _fired.has(key):
			_fired[key] = true
			play(p["steps"])
	var to_final: float = float(final_ev["s"]) - driver.s
	if to_final < 430.0 and not _fired.has("approach"):
		_fired["approach"] = true
		audio.play_sfx("chime")
		play([["announcer", Story.ANNOUNCE_NEXT % Story.STOPS["hospital"]]])
		play(Story.APPROACH_HOSPITAL)
	if _task_stop and not bus.stop_requested and to_final < 140.0:
		_press_stop(true)                              # игрок не нажал — мама нажимает сама

	# Табло в салоне.
	if driver.stopped and ev != null and ev["kind"] != "light":
		bus.set_led(Story.STOPS[ev["id"]])
	else:
		bus.set_led("След.: " + _next_stop_name())

	traffic.update(sim_dt, driver.s, driver.v)
	audio.update(driver.v, driver.accel, true)


func _next_stop_name() -> String:
	for i in range(driver.index, route.events.size()):
		var e: Dictionary = route.events[i]
		if e["kind"] != "light":
			return Story.STOPS[e["id"]]
	return Story.STOPS["hospital"]


func _curb_weight(s: float) -> float:
	var w: float = 0.0
	for ev in route.events:
		if ev["kind"] == "light":
			continue
		var d: float = float(ev["s"]) - s
		w = maxf(w, C.smooth(80.0, 14.0, d) if d >= 0.0 else C.smooth(-50.0, -6.0, d))
	return w


func _bus_lateral(s: float) -> float:
	return lerpf(C.LANE_OFFSET, C.CURB_OFFSET, _curb_weight(s))


func _place_bus(dt: float, moving: bool = true) -> void:
	var s: float = driver.s
	bus.position = route.point(s, _bus_lateral(s), 0.0)
	var slope: float = (_bus_lateral(s + 1.0) - _bus_lateral(s - 1.0)) / 2.0
	bus.rotation.y = route.yaw(s) - atan(slope)
	bus.update(dt, driver.v if moving else 0.0, driver.accel if moving else 0.0, route.curvature(s), time)


## Мама смотрит на сына, иногда — в окно.
func _update_mom(delta: float) -> void:
	_mom_look_timer -= delta
	if _mom_look_timer <= 0.0:
		_mom_look_window = 0.0 if _mom_look_window > 0.0 else 4.0
		_mom_look_timer = 4.0 if _mom_look_window > 0.0 else 6.0 + randf() * 8.0
	var talking: bool = _speaker != "" and _speaker != "announcer"
	if _mom_look_window > 0.0 and not talking:
		mom.look_target = bus.body.to_global(bus.body.to_local(mom.focus_point()) + Vector3(-1.8, 0.05, -0.6))
	else:
		mom.look_target = head.global_position


# --- Взаимодействие (клавиша E) ------------------------------------------------------------------------------

func _update_interaction() -> void:
	if phase != Phase.RIDE or get_tree().paused:
		_target = ""
		ui.set_prompt("")
		return
	var cam_pos: Vector3 = cam.global_position
	var fwd: Vector3 = -cam.global_transform.basis.z
	var best: String = ""
	var best_dot: float = 0.975
	var cands: Array = [["mom", mom.focus_point()]]
	if bus.stop_button.visible:
		cands.append(["button", bus.stop_button.global_position])
	for cand in cands:
		var to: Vector3 = (cand[1] as Vector3) - cam_pos
		var dist: float = to.length()
		if dist > 2.8 or dist < 0.05:
			continue
		var d: float = fwd.dot(to / dist)
		if d > best_dot:
			best_dot = d
			best = str(cand[0])
	_target = best
	if best == "mom":
		ui.set_prompt("" if _dq_running else "E — поговорить с мамой")
	elif best == "button":
		ui.set_prompt("Остановка запрошена" if bus.stop_requested else "E — нажать кнопку остановки")
	elif _task_stop and not bus.stop_requested:
		_target = "driver"                             # куда ни смотри — можно крикнуть водителю
		ui.set_prompt("E — " + Story.CALL_DRIVER_PROMPT)
	else:
		ui.set_prompt("")


func _interact() -> void:
	if phase != Phase.RIDE:
		return
	if _target == "mom":
		_talk_to_mom()
	elif _target == "button" or _target == "driver":
		_press_stop(false)


# --- Остановки ---------------------------------------------------------------------------------------------------

func _open_doors(open: bool, use_sim: bool = true) -> void:
	audio.play_sfx("hiss")
	var from_f: float = bus.door_open["front"]
	var from_m: float = bus.door_open["middle"]
	var to_v: float = 1.0 if open else 0.0
	var dur: float = 1.2
	var t: float = 0.0
	while t < dur:
		await get_tree().process_frame
		if not is_inside_tree():
			return
		if not get_tree().paused:
			t += sim_dt if use_sim else get_process_delta_time()
		var k: float = C.smooth(0.0, 1.0, t / dur)
		bus.door_open["front"] = lerpf(from_f, to_v, k)
		bus.door_open["middle"] = lerpf(from_m, to_v, k)


func _handle_stop(ev: Dictionary) -> void:
	bus.indicator = 0
	var kind: String = str(ev["kind"])
	if kind == "light":
		play(Story.REDLIGHT)
		await _wait(C.BUS_RED_LIGHT)
		city.set_light("green")
		driver.release()
		_stop_busy = false
		return
	if kind == "final":
		_arrival()
		return
	await _open_doors(true)
	audio.play_sfx("chime")
	var stop_id: String = str(ev["id"])
	var line: String = Story.ANNOUNCE_ARRIVE % Story.STOPS[stop_id]
	if stop_id == "park":
		line += " " + Story.ANNOUNCE_NEXT % Story.STOPS["market"]
	elif stop_id == "market":
		line += " " + Story.ANNOUNCE_NEXT % Story.STOPS["hospital"]
	play([["announcer", line]])
	if stop_id == "park":
		play(Story.ARRIVE_PARK)
	elif stop_id == "market":
		play(Story.ARRIVE_MARKET)
	await _wait(C.BUS_DWELL)
	audio.play_sfx("beeps")
	await _wait(1.0)
	await _open_doors(false)
	bus.set_stop_requested(false)
	bus.indicator = -1
	driver.release()
	_stop_busy = false
	_after(4.0, func() -> void:
		if bus.indicator == -1:
			bus.indicator = 0)


# --- Прибытие: двери, затемнение, выход в темноте, переход на уровень ----------------------------------------------

func _arrival() -> void:
	phase = Phase.ARRIVAL
	_clear_dialogue()
	ui.set_prompt("")
	ui.set_objective("")
	ui.set_crosshair(false)
	ui.set_hint_alpha(0.0)
	bus.indicator = 0
	await _open_doors(true, false)
	audio.play_sfx("chime")
	await _play_and_wait([["announcer", Story.ANNOUNCE_ARRIVE % Story.STOPS["hospital"]]])
	await _play_and_wait(Story.ARRIVE_HOSPITAL)
	await _fade_to(1.0, 1.3)
	phase = Phase.DARK
	audio.fade_engine_out()
	await _dark_sequence()
	_finish()


## Чёрный экран: слышно, как откидывается пандус, едет коляска, мама говорит, автобус уезжает (~10 секунд).
func _dark_sequence() -> void:
	var u: float = maxf(dark_seconds, 4.0) / 8.0
	await _wait(0.4 * u, false)
	audio.play_sfx("ramp")
	play([Story.DARK_LINES[0]])
	await _wait(2.3 * u, false)
	audio.set_motor(1.0)                               # мотор коляски
	play([Story.DARK_LINES[1]])
	await _wait(2.5 * u, false)
	audio.set_motor(0.0)
	audio.play_sfx("hiss")                             # закрываются двери
	await _wait(0.6 * u, false)
	audio.play_sfx("beeps")
	await _wait(0.8 * u, false)
	for i in 6:                                        # автобус уезжает
		audio.update(1.5 + float(i) * 1.5, 0.9, true)
		await _wait(0.27 * u, false)
	audio.fade_engine_out()
	play([Story.DARK_LINES[2]])
	await _play_and_wait([])                           # ждём, пока мама договорит
	await _wait(1.0, false)


func _finish() -> void:
	phase = Phase.END
	if ResourceLoader.exists(next_scene):
		get_tree().change_scene_to_file(next_scene)
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		ui.show_end()


# --- Ввод, пауза ------------------------------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if phase <= Phase.ARRIVAL and not get_tree().paused:
			look_yaw = clampf(look_yaw - event.relative.x * mouse_sensitivity, -2.4, 2.4)
			look_pitch = clampf(look_pitch - event.relative.y * mouse_sensitivity, -1.25, 1.1)
	elif event is InputEventKey and event.pressed and not event.echo and not get_tree().paused:
		var k: int = event.physical_keycode
		if k == KEY_E:
			_interact()
		elif k == KEY_1:
			ui.pick(0)
		elif k == KEY_2:
			ui.pick(1)
		elif k == KEY_3:
			ui.pick(2)
		elif k == KEY_ENTER or k == KEY_KP_ENTER:
			_skip = true
	elif event is InputEventMouseButton and event.pressed and not get_tree().paused:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		else:
			_interact()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and is_node_ready() and not get_tree().paused and phase < Phase.END:
		_set_paused(true)


func _set_paused(p: bool) -> void:
	get_tree().paused = p
	ui.show_pause(p)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if p else Input.MOUSE_MODE_CAPTURED


func _on_pause_toggle() -> void:
	if phase != Phase.END:
		_set_paused(not get_tree().paused)


func _on_resume() -> void:
	_set_paused(false)


func _on_menu() -> void:
	get_tree().paused = false
	if ResourceLoader.exists(C.MENU_SCENE):
		get_tree().change_scene_to_file(C.MENU_SCENE)
	else:
		get_tree().quit()


func _on_restart() -> void:
	get_tree().paused = false
	get_tree().reload_current_scene()


# --- Отладка: свойство debug_skip в инспекторе перескакивает к нужному месту -----------------------------------------------

func _jump_to(where: String) -> void:
	var final_ev: Dictionary = route.by_id["hospital"]
	var target_s: float = route.start_s
	if where == "light":
		target_s = float(route.by_id["light"]["s"]) - 180.0
	elif where == "market":
		target_s = float(route.by_id["market"]["s"]) - 150.0
	elif where == "hospital":
		target_s = float(final_ev["s"]) - 460.0
	elif where == "arrival":
		target_s = float(final_ev["s"]) - 40.0
	driver.s = target_s
	driver.v = C.BUS_CRUISE * 0.6
	driver.stopped = false
	driver.index = route.events.size()
	for i in route.events.size():
		if float(route.events[i]["s"]) > target_s + 0.5:
			driver.index = i
			break
	var progress: float = (target_s - route.start_s) / (float(final_ev["s"]) - route.start_s)
	for p in Story.PROGRESS:
		if float(p["at"]) < progress:
			_fired["p" + str(p["at"])] = true
	if target_s > float(route.by_id["light"]["s"]) - 200.0:
		_light_cycle = true
	city.set_light("green")
