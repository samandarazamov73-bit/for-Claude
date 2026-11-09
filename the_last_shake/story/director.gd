extends Node
## Сюжет «The Last Shake» внутри санатория (акты 1–6). Висит в sanatorium/main.tscn узлом Director;
## game.gd вызывает begin(game), когда здание построено. Глава (откуда начать) — GameState.checkpoint:
##   start — вход с мамой и лестница; key — после крика: ключ администратора; chase — с ключом у лифта;
##   void — 2-й этаж (пустая комната); floor3 — 3-й этаж; maze — лабиринт и палата 204.
## Все реплики — здесь (поменять текст — правь строки в кавычках).

const StoryUI = preload("res://story/story_ui.gd")
const Actor = preload("res://story/actor.gd")
const Sets = preload("res://story/floor_sets.gd")
const Scares = preload("res://story/scares.gd")
const Props = preload("res://story/props.gd")
const Interactable = preload("res://story/interactable.gd")

# --- точки здания (метры, координаты Godot) ---
const SPAWN := Vector3(28.75, 1.2, 4.27)        # тамбур: сюда заезжаем с улицы (пролог кончается здесь же)
const SPAWN_YAW := -PI * 0.5                     # лицом в здание (+X)
const MOM_START := Vector3(28.2, 1.2, 3.25)      # мама зашла следом, слева сзади
const DOOR_VEST := 1                             # стеклянная дверь тамбур → вестибюль напротив входа
const MOM_AT_VEST_DOOR := [Vector3(29.0, 1.2, 3.2), Vector3(29.6, 1.2, 3.25)]     # слева от коляски, у двери
const VEST_TO_HALL := [Vector3(29.8, 1.2, 3.75), Vector3(30.6, 1.2, 4.27), Vector3(31.3, 1.2, 4.27),
	Vector3(32.9, 1.2, 2.4)]
const STAIR_FOOT := Vector3(30.9, 1.2, -5.8)
## мама поднимается по главной лестнице №1: 1-й марш вдоль +X, площадка, 2-й марш обратно, 2-й этаж
const STAIRS_UP := [Vector3(31.45, 1.2, -5.8), Vector3(34.4, 2.7, -5.8), Vector3(35.0, 2.85, -5.3),
	Vector3(34.4, 3.0, -4.25), Vector3(31.6, 4.35, -4.25), Vector3(31.0, 4.5, -3.2), Vector3(31.2, 4.5, -1.4)]
const HALL_TO_STAIRS := [Vector3(33.4, 1.2, 4.0), Vector3(33.0, 1.2, 0.7), Vector3(33.0, 1.2, -1.2),
	Vector3(31.0, 1.2, -2.4), Vector3(30.85, 1.2, -4.6), Vector3(30.9, 1.2, -5.8)]
const SCREAM_ROOM := Vector3(52.5, 1.6, -13.0)
const CRASH_POS := Vector3(52.8, 1.6, -13.8)
const DOOR_SCREAM := 74          # процедурный кабинет 139 (L0.R17) — «моя комната» психа
const DOOR_ADMIN := 56           # администрация 134 (L0.F14), дверь с матовым стеклом
const DOOR_GURNEY := 72          # кабинет 136 (L0.R15): оттуда выкатывается каталка
const DOOR_HALL_STAIRS := 18
const LIFT_CALL := Vector3(37.5, 1.2, -6.9)        # перед дверями лифта, 1-й этаж (на других — +3,3 м по высоте)
const SCREAM_DOOR := Vector3(52.5, 1.2, -9.9)      # дверь процедурного кабинета 139
const ADMIN_DOOR := Vector3(43.5, 1.2, -6.3)       # дверь кабинета 134 «Администрация»
const ROOM213_DOOR := Vector3(31.5, 4.5, -9.9)
const NIGHTSTAND_POS := Vector3(42.36, 1.2, -4.6)
const GURNEY_FROM := Vector3(46.5, 1.2, -11.3)
const GURNEY_TO := Vector3(46.5, 1.2, -7.45)
const PSYCHO_SPAWN := Vector3(72.0, 1.2, -8.1)
const CHASE_RESTART := Vector3(43.5, 1.2, -7.7)
const PSYCHO_SPEED := 3.8         # м/с; после каждой поимки чуть медленнее
const MAN_POS := Vector3(37.0, 7.8, -8.5)          # человек в коляске у лифта на 3-м этаже
const KEY204_POS := Vector3(30.3, 5.43, -14.65)    # ключ от палаты — на инструментальном столике в 213
const ROOM204_DOOR := Vector3(8.83, 4.5, -6.5)
const GRANDPA_RUN := [Vector3(8.83, 4.5, -5.6), Vector3(8.83, 4.5, -8.1), Vector3(12.0, 4.5, -8.1),
	Vector3(30.9, 4.5, -8.1), Vector3(30.9, 4.5, -6.2), Vector3(30.75, 4.5, -4.6), Vector3(31.2, 4.5, -2.6),
	Vector3(32.9, 4.5, -1.8)]

var game
var player
var lift
var ui                          # story/story_ui.gd
var sets
var scares
var mom                         # story/actor.gd
var grandpa
var psycho
var has_lift_key := false
var has_ward_key := false
var act := ""
var chase := "off"               # off, run, caught, safe
var fight := "off"               # off, on, cornered, done
var hp := 100.0
var quake := 0.0                 # сила землетрясения 0..1
var gurney: Node3D
var nightstand: Dictionary = {}
var fist: Node3D
var _skip := false
var _snd_cache := {}
var _bang_t := 0.0
var _mom_cd := 0.0
var _punch_cd := 0.0
var _fight_t := 0.0
var _debris_t := 0.0
var _dust: GPUParticles3D
var _psycho_bang_t := 0.0
var _rumble: AudioStreamPlayer
var _drone: AudioStreamPlayer
var _moan_t := 0.0
var _scream_door_open := false
var _flick_t := 1.0
var _psycho_speed := PSYCHO_SPEED


# ================================================================================ запуск
func begin(g) -> void:
	game = g
	player = g.player
	lift = g.lift
	ui = StoryUI.new()
	add_child(ui)
	ui.line_skipped.connect(_on_skip)
	sets = Sets.new()
	game.add_child(sets)
	sets.setup(game)
	scares = Scares.new()
	add_child(scares)
	mom = _actor("res://characters/mom.glb", "Барно")
	grandpa = _actor("res://characters/grandpa.glb", "Анвар")
	grandpa.natural = {"walk_loop": 0.26, "run_loop": 2.45}
	psycho = _actor("res://characters/psycho.glb", "Псих")
	psycho.natural = {"walk_loop": 1.3, "run_loop": 3.6, "sprint_loop": 2.13}
	psycho.step_volume = 2.0
	for a in [grandpa, psycho]:
		a.visible = false
	lift.locked = true
	lift.lock_text = "Лифт заперт на ключ"
	lift.on_locked = _on_lift_locked
	lift.park_closed(0)
	lift.arrived.connect(_on_lift_arrived)
	lift.departed.connect(_on_lift_departed)
	# сюжетные двери 1-го этажа — закрыты (в здании часть дверей случайно приоткрыта)
	for id in [DOOR_SCREAM, DOOR_ADMIN, DOOR_GURNEY]:
		var sd = door(id)
		if sd:
			sd.set_angle(0.0)
	fist = Props.fist_arm()
	player.cam.add_child(fist)
	fist.position = Vector3(0.2, -0.24, 0.05)
	fist.visible = false
	_dust = Props.dust(Vector3(2.5, 0.1, 2.5))
	game.add_child(_dust)
	_drone = AudioStreamPlayer.new()
	_drone.stream = stream("drone_low", true)
	_drone.volume_db = -60.0
	add_child(_drone)
	_drone.play()
	ui.set_crosshair(false)
	GameState.set_fade(1.0)
	var cp: String = GameState.checkpoint
	match cp:
		"key":
			_setup_after_scream()
			_act2_key()
		"chase":
			_setup_after_scream()
			_take_lift_key(false)
			_act2_return()
		"void":
			_jump_to_lift(1)
			_act3()
		"floor3":
			sets.build_void()
			_jump_to_lift(2)
			_act4()
		"maze":
			_jump_to_lift(1, false)
			sets.build_maze()
			_act5()
		_:
			_act1()


func _actor(path: String, nm: String):
	var a = Actor.new()
	a.name = nm
	game.add_child(a)
	a.setup(path)
	return a


# ================================================================================ помощники
func stream(sound: String, loop := false) -> AudioStream:
	var key: String = sound + ("#l" if loop else "")
	if _snd_cache.has(key):
		return _snd_cache[key]
	var s: AudioStream = load("res://story/sfx/%s.wav" % sound)
	if loop and s is AudioStreamWAV:
		var w: AudioStreamWAV = (s as AudioStreamWAV).duplicate()
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = int(w.get_length() * w.mix_rate)
		s = w
	_snd_cache[key] = s
	return s


## Звук один раз: pos = null — «в голове» (без направления), иначе — из точки.
func snd(sound: String, pos: Variant = null, vol := 0.0, pitch := 1.0, dist := 30.0) -> Node:
	var st: AudioStream = stream(sound)
	if pos == null:
		var p := AudioStreamPlayer.new()
		p.stream = st
		p.volume_db = vol
		p.pitch_scale = pitch
		add_child(p)
		p.finished.connect(p.queue_free)
		p.play()
		return p
	var p3 := AudioStreamPlayer3D.new()
	p3.stream = st
	p3.volume_db = vol
	p3.pitch_scale = pitch
	p3.unit_size = 3.0
	p3.max_distance = dist
	p3.bus = "World"
	game.add_child(p3)
	p3.global_position = pos
	p3.finished.connect(p3.queue_free)
	p3.play()
	return p3


func wait(sec: float) -> void:
	await get_tree().create_timer(sec, false).timeout


## Ждать, пока условие станет правдой (timeout > 0 — не дольше стольких секунд).
func until(cond: Callable, timeout := -1.0) -> void:
	var t := 0.0
	while not cond.call():
		await get_tree().process_frame
		if not get_tree().paused:
			t += get_process_delta_time()
		if timeout > 0.0 and t >= timeout:
			return


## Реплика с подписью; ждёт, пока её прочитают (Enter / пробел — дальше).
func say(who: String, text: String, sec := 0.0) -> void:
	_skip = false
	# кто стоит и говорит — жестикулирует только во время своей реплики, потом снова спокойно стоит
	var speaker = mom if who == "mom" else (grandpa if who == "grandpa" else null)
	var gestures: bool = speaker != null and speaker.visible and not speaker.is_moving() \
			and (speaker.current == "idle_loop" or speaker.current == "talk_loop")
	if gestures and speaker.current != "talk_loop":
		speaker.play("talk_loop", 0.35)
	var t: float = ui.say(who, text, sec)
	while t > 0.0 and not _skip:
		await get_tree().process_frame
		if not get_tree().paused:
			t -= get_process_delta_time()
	_skip = false
	ui.hide_line()
	if gestures and speaker.current == "talk_loop" and not speaker.is_moving():
		speaker.play("idle_loop", 0.45)


## Задание наверху слева; target — куда показывает маркер (точка или персонаж), null — без маркера.
func objective(text: String, target: Variant = null, offset := Vector3(0, 1.0, 0)) -> void:
	ui.set_objective(text, target, offset)
	if text != "":
		snd("monitor_beep", null, -16.0, 0.6)


func ppos() -> Vector3:
	return player.global_position


func room_id() -> String:
	return str(game.room_at(ppos() + Vector3(0, 0.3, 0)).get("id", ""))


func near(p: Vector3, r: float) -> bool:
	return Vector2(ppos().x - p.x, ppos().z - p.z).length() < r and absf(ppos().y - p.y) < 2.0


func freeze(on: bool) -> void:
	player.story_lock = on
	player.input_override = Vector2.ZERO if on else null


func place_player(p: Vector3, yaw: float) -> void:
	player.global_position = p + Vector3(0, 0.05, 0)
	player.rotation.y = yaw
	player.v = 0.0
	player.w = 0.0
	player.look_yaw = 0.0
	player.look_pitch = -0.08
	player.reset_physics_interpolation()


## Плавно повернуть взгляд Самана к точке за seconds.
func look_at_point(p: Vector3, seconds := 0.6) -> void:
	var t := 0.0
	while t < seconds:
		await get_tree().process_frame
		var dt: float = get_process_delta_time()
		t += dt
		player.aim_at(p, clampf(dt * 6.0, 0.0, 1.0))


func shake(amount: float, seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		await get_tree().process_frame
		t += get_process_delta_time()
		var k: float = amount * (1.0 - t / seconds)
		player.view_offset = Transform3D(Basis.from_euler(Vector3(randf_range(-1, 1) * 0.03 * k, randf_range(-1, 1) * 0.02 * k,
			randf_range(-1, 1) * 0.04 * k)), Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * 0.02 * k)
	player.view_offset = Transform3D.IDENTITY


func door(id: int):
	return sets.door(id)


func _jump_to_lift(f: int, with_void := true) -> void:
	if f == 1 and with_void:
		sets.build_void()
	lift.locked = false
	lift.park_open(f)
	place_player(Vector3(37.5, lift.levels[f], -5.0), 0.0)
	mom.visible = false


# ================================================================================ АКТ 1: вход, лестница, мама уходит
func _act1() -> void:
	act = "act1"
	# с улицы (пролог) — то же место и поворот, что были в тамбуре; из меню глав — середина тамбура
	var e: Dictionary = GameState.entry
	GameState.entry = {}
	place_player(e.get("pos", SPAWN) as Vector3, float(e.get("yaw", SPAWN_YAW)))
	mom.global_position = e.get("mom", MOM_START) as Vector3
	mom.face(ppos(), true)
	mom.visible = true
	for id in [DOOR_VEST, 2]:
		var vd = door(id)
		if vd:
			vd.set_angle(0.0)
	freeze(true)
	await GameState.fade_to(0.0, 1.2)
	ui.title("Санаторий «Оромгох»", "1975 год", 2.0, 54)
	await wait(1.0)
	freeze(false)
	mom.set_look(player.head.global_position)
	await say("mom", "Дедушка где-то наверху. Пойдём к лестнице.")
	mom.set_look(null)
	objective("Следуй за мамой к лестнице", mom, Vector3(0, 1.9, 0))
	ui.hint("W / S — ехать, A / D — поворот, мышь — смотреть, F — фонарик, E — действие", 8.0)
	# мама толкает стеклянную дверь из тамбура от себя, в вестибюль: тамбур тесный, створки не задевают коляску
	await mom.go_and_wait(MOM_AT_VEST_DOOR, 1.0)
	var vest = door(DOOR_VEST)
	if vest:
		mom.face(vest.center)
		await wait(0.3)
		game.play_at("door_open_wood", vest.center, -3.0, 0.9, 25.0)
		vest.swing_to(-92.0, 1.1)
		await wait(0.8)
	await mom.go_and_wait(VEST_TO_HALL + HALL_TO_STAIRS.slice(1, 2), 1.15)
	var d = door(DOOR_HALL_STAIRS)
	if d:
		snd("door_creak_slow", d.center, -6.0)
		d.swing_to(95.0, 1.2)
		await wait(0.9)
	await mom.go_and_wait(HALL_TO_STAIRS.slice(2), 1.15)
	mom.face(ppos())
	await until(func(): return near(STAIR_FOOT, 4.5) or room_id() == "L0.STAIR1")
	mom.face(ppos())
	mom.set_look(player.head.global_position)
	mom.play("talk_loop")
	await say("mom", "Я сейчас спущу его сюда. Подожди здесь.")
	mom.set_look(null)
	objective("Подожди маму у лестницы")
	await mom.go_and_wait(STAIRS_UP, 1.0)
	mom.visible = false
	await wait(40.0)                                   # «через 30–60 секунд она возвращается»
	mom.visible = true
	var down: Array = STAIRS_UP.duplicate()
	down.reverse()
	down.append(STAIR_FOOT)
	await mom.go_and_wait(down, 1.0)
	mom.face(ppos())
	if not near(STAIR_FOOT, 5.0):
		await say("mom", "Саман? Ты где? Подъедь сюда!")
		objective("Вернись к маме, к лестнице", mom, Vector3(0, 1.9, 0))
		await until(func(): return near(STAIR_FOOT, 4.5))
	mom.face(ppos())
	mom.set_look(player.head.global_position)
	mom.play("talk_loop")
	await say("mom", "Странно, твоего дедушки наверху нет. Я сейчас другие этажи посмотрю, может, он на 3-м этаже.")
	await say("mom", "Подожди здесь, я быстро найду его.")
	await say("hero", "Хорошо, но найди его побыстрее, а то здесь что-то не так.")
	mom.set_look(null)
	await mom.go_and_wait(STAIRS_UP, 1.1)
	mom.visible = false
	objective("Осмотри первый этаж")
	_drone.volume_db = -26.0
	await wait(60.0)                                   # «через 1 минуту … раздаётся пронзительный крик»
	_act2_scream()


# ================================================================================ АКТ 2: крик, «моя комната», лифт без ключа
func _setup_after_scream() -> void:
	place_player(Vector3(36.0, 1.2, -8.1), PI * 0.5)
	mom.visible = false
	_drone.volume_db = -24.0
	GameState.fade_to(0.0, 1.5)


func _act2_scream() -> void:
	act = "scream"
	snd("scream_pain", SCREAM_ROOM, 6.0, 1.0, 70.0)
	game.lights.set_room("L0.R17", true)           # в кабинете загорается и мигает свет — видно из коридора
	snd("stinger", null, -10.0)
	await wait(1.5)
	await say("thought", "Что это было?!")
	objective("Проверь, что это было — крик из процедурного кабинета 139 (в конце коридора, справа)", SCREAM_DOOR)
	var d = door(DOOR_SCREAM)
	_moan_t = 10.0
	# пока не откроет дверь — изредка из комнаты слышен стон
	await until(func(): return (d != null and d.angle > 18.0) or room_id() == "L0.R17")
	_scream_door_open = true
	await wait(0.6)
	await say("hero", "Дедушка?.. Есть тут кто?")
	await wait(5.0)
	snd("crash_heavy", CRASH_POS, 8.0, 1.0, 40.0)
	shake(1.0, 0.7)
	game.critters.scare(CRASH_POS, 10.0)
	objective("Вернись к лестнице", STAIR_FOOT + Vector3(0, 0, 2.0))
	await wait(5.0)
	snd("psycho_shout", SCREAM_ROOM, 6.0, 1.0, 50.0)
	await say("psycho", "Кто зашёл в мою комнату?!?! Если я найду тебя — я тебя не прощу!!")
	await until(func(): return ppos().x < 40.5 and ppos().z < -0.5 and ppos().z > -10.0)
	await say("thought", "Там был лифт… Нужно подняться на нём на второй этаж.")
	objective("Поднимись на лифте на 2-й этаж — лифт рядом с лестницей, вызови его кнопкой (E)", LIFT_CALL)
	act = "need_key"


func _on_lift_locked() -> void:
	if act == "need_key":
		act = "find_admin"
		_act2_key()
	elif act == "floor3_search":
		say("thought", "Сначала найду маму.")


func _act2_key() -> void:
	act = "find_admin"
	await say("thought", "Заперт… Ключ от лифта должен быть у администратора.")
	objective("Найди комнату Администратора — кабинет 134, по коридору направо от лифта", ADMIN_DOOR)
	_build_nightstand()
	# каталка: выкатывается из тёмного кабинета прямо перед коляской
	await until(func(): return ppos().x > 40.6 and ppos().z < -6.6 and ppos().z > -9.6 and ppos().y < 2.5)
	_gurney_scare()
	await until(func(): return room_id() == "L0.F14" or has_lift_key)
	if not has_lift_key:
		objective("Обыщи тумбочку у левой стены (E)", NIGHTSTAND_POS, Vector3(0, 0.8, 0))


func _build_nightstand() -> void:
	if not nightstand.is_empty():
		return
	nightstand = Props.nightstand()
	var root: Node3D = nightstand["root"]
	game.add_child(root)
	root.global_position = NIGHTSTAND_POS
	root.rotation.y = -PI * 0.5                      # ящик смотрит в комнату (+X)
	var key := Props.glb("res://props/key_lift.glb", 0.065, 0.476)
	nightstand["drawer"].add_child(key)
	key.position = Vector3(0, -0.01, 0.15)
	key.rotation = Vector3(-PI * 0.5, 0, 0)
	var it: Area3D = Interactable.new()
	root.add_child(it)
	it.position = Vector3(0, 0.45, 0)
	it.setup(Vector3(0.5, 0.5, 0.55), "[E] Обыскать тумбочку", _take_lift_key.bind(true))
	nightstand["area"] = it


func _gurney_scare() -> void:
	var d = door(DOOR_GURNEY)
	gurney = Props.gurney()
	gurney.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	game.add_child(gurney)
	gurney.global_position = GURNEY_FROM
	var body := AnimatableBody3D.new()
	body.collision_layer = game.L_WORLD
	body.sync_to_physics = false
	gurney.add_child(body)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(0.62, 1.0, 1.9)
	cs.shape = bs
	cs.position.y = 0.5
	body.add_child(cs)
	if d:
		d.swing_to(100.0, 0.25)
		game.play_at("door_slam_far", d.center, 2.0, 1.2, 30.0)
	snd("gurney_roll", GURNEY_FROM, 6.0, 1.0, 35.0)
	snd("stinger", null, -6.0, 1.1)
	var tw := create_tween()
	tw.tween_property(gurney, "global_position", GURNEY_TO, 1.4).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.parallel().tween_property(gurney, "rotation:y", deg_to_rad(80.0), 1.4).set_ease(Tween.EASE_IN)
	await tw.finished
	snd("metal_bang", GURNEY_TO + Vector3(0, 0.8, 0.5), 4.0, 1.0, 30.0)
	game.critters.scare(GURNEY_TO, 8.0)


func _take_lift_key(play_scene: bool) -> void:
	if has_lift_key:
		return
	has_lift_key = true
	if nightstand.has("area"):
		(nightstand["area"] as Area3D).queue_free()
		nightstand.erase("area")
	if not play_scene:
		lift.locked = false
		lift.forced_floor = 1
		return
	var drawer: Node3D = nightstand["drawer"]
	var tw := create_tween()
	tw.tween_property(drawer, "position:z", drawer.position.z - 0.28, 0.35)
	game.play_at("door_open_wood2", drawer.global_position, -10.0, 1.6, 8.0)
	await tw.finished
	ui.hint("Ключ от лифта — у тебя", 3.0)
	await wait(0.4)
	for c in drawer.get_children():
		if c.get_child_count() > 0 and c is Node3D and not (c is MeshInstance3D):
			c.visible = false
	lift.locked = false
	lift.forced_floor = 1
	# дверь кабинета сама захлопывается, кто-то бьёт ладонями по матовому стеклу и убегает
	var d = door(DOOR_ADMIN)
	if d:
		await until(func(): return not d._blocked(0.0), 6.0)
		await d.slam()
	snd("stinger", null, -4.0)
	shake(0.7, 0.4)
	psycho.visible = true
	psycho.global_position = Vector3(43.5, 1.2, -7.25)
	psycho.face(Vector3(43.5, 1.2, -6.0), true)
	psycho.play("hit", 0.1)
	await wait(0.35)
	snd("glass_bang", Vector3(43.5, 2.1, -6.55), 8.0, 1.0, 30.0)
	if d:
		for i in 3:
			d.rattle(2.0)
			await wait(0.43)
	await wait(0.4)
	var run := snd("run_steps", psycho.global_position, 2.0, 1.1, 40.0)
	psycho.go([Vector3(44.6, 1.2, -8.6), Vector3(48.5, 1.2, -8.6), Vector3(68.0, 1.2, -8.4)], 4.2, "run_loop")
	await wait(2.6)
	psycho.visible = false
	psycho.stop()
	if is_instance_valid(run):
		run.queue_free()
	await say("hero", "Кто… кто это был?!")
	_act2_return()


func _act2_return() -> void:
	act = "lift_key"
	GameState.checkpoint = "chase"
	objective("Вернись к лифту и поднимись на 2-й этаж", LIFT_CALL)
	chase = "off"
	await until(func(): return lift.state in ["opening", "open"] and lift.floor_idx == 0 and near(Vector3(37.5, 1.2, -7.0), 7.0))
	_start_chase()


# ================================================================================ погоня у лифта
func _start_chase() -> void:
	act = "chase"
	psycho.visible = true
	psycho.global_position = PSYCHO_SPAWN
	psycho.face(ppos(), true)
	snd("psycho_roar", PSYCHO_SPAWN + Vector3(0, 1.6, 0), 8.0, 1.0, 60.0)
	snd("stinger", null, -2.0)
	_drone.volume_db = -14.0
	objective("Быстрее в лифт! Развернись к кнопкам и нажми «2» (E)", Vector3(38.3, 1.2, -6.2), Vector3(0, 1.3, 0))
	ui.say("psycho", "Ты зашёл в мою комнату, сука!!!!", 3.0)
	await wait(0.5)
	_psycho_speed = PSYCHO_SPEED - 0.2 * mini(GameState.deaths, 3)
	psycho.play("run_loop", 0.2, _psycho_speed / 3.6)
	chase = "run"


func _chase_target() -> Vector3:
	var p: Vector3 = ppos()
	var in_cab: bool = lift.player_in_cabin()
	if in_cab or (p.x > 36.0 and p.x < 39.0 and p.z > -6.9):
		if psycho.global_position.z < -6.8 and absf(psycho.global_position.x - 37.5) > 0.4:
			return Vector3(37.5, 1.2, -7.4)
		return Vector3(37.5, 1.2, p.z)
	return Vector3(p.x, 1.2, clampf(p.z, -9.3, -6.9)) if p.z < -6.6 else p


func _update_chase(dt: float) -> void:
	var safe: bool = lift.player_in_cabin() and (lift.state == "moving" or (lift.state in ["closing", "closed"] and lift.open_f < 0.45))
	var target: Vector3 = Vector3(37.5, 1.2, -7.15) if safe else _chase_target()
	var to: Vector3 = target - psycho.global_position
	to.y = 0.0
	var step: float = _psycho_speed * dt
	_heartbeat(dt, clampf(1.0 - psycho.global_position.distance_to(ppos()) / 25.0, 0.0, 1.0))
	if to.length() > step:
		psycho.global_position += to.normalized() * step
		psycho.step_moved(step)
		psycho.face(target if safe else ppos())
		if chase == "safe":
			chase = "run"
			psycho.play("run_loop", 0.2, _psycho_speed / 3.6)
	elif safe:
		# двери закрылись перед носом — бьёт по ним
		if chase != "safe":
			chase = "safe"
			psycho.face(Vector3(37.5, 1.2, -5.0), true)
			_psycho_bang_t = 0.0
		_psycho_bang_t -= dt
		if _psycho_bang_t <= 0.0:
			_psycho_bang_t = 0.75
			psycho.play_once("hit", 0.05)
			snd("metal_bang", Vector3(37.5, 2.2, -6.6), 0.0, randf_range(0.9, 1.15), 25.0)
		return
	if not safe and Vector2(ppos().x - psycho.global_position.x, ppos().z - psycho.global_position.z).length() < 1.15:
		chase = "caught"
		_caught()


var _hb_t := 0.0


## Сердцебиение Самана: чем ближе опасность (0..1), тем чаще и громче.
func _heartbeat(dt: float, fear: float) -> void:
	if fear <= 0.05:
		return
	_hb_t -= dt
	if _hb_t <= 0.0:
		_hb_t = lerpf(0.95, 0.42, fear)
		snd("heartbeat", null, lerpf(-14.0, 0.0, fear), 1.0)


## Псих догнал: бьёт (как в анимации), Саман отлетает, падает на пол, темнота — заново у кабинета с ключом.
func _caught() -> void:
	freeze(true)
	GameState.deaths += 1
	psycho.face(ppos(), true)
	psycho.play("hit", 0.05)
	look_at_point(psycho.head_pos(), 0.35)
	snd("psycho_roar", psycho.head_pos(), 6.0, 1.15)
	await wait(0.62)                                   # момент удара в анимации
	snd("punch", null, 4.0, 0.8)
	snd("body_fall", null, 0.0, 0.9)
	ui.flash(Color(0.8, 0.0, 0.0, 0.85), 0.6)
	var away: Vector3 = (ppos() - psycho.global_position)
	away.y = 0.0
	away = away.normalized() if away.length() > 0.01 else -player.global_transform.basis.z
	var q := PhysicsRayQueryParameters3D.create(ppos() + Vector3(0, 0.6, 0), ppos() + Vector3(0, 0.6, 0) + away * 1.8,
		game.L_WORLD | game.L_DOORS | game.L_LIFT, [player.get_rid()])
	var hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(q)
	var dist: float = 1.6
	if not hit.is_empty():
		dist = maxf(0.0, ppos().distance_to(hit["position"]) - 0.75)
	var tw := create_tween()
	tw.tween_property(player, "global_position", ppos() + away * dist, 0.35).set_ease(Tween.EASE_OUT)
	# камера: удар — назад и вбок, потом падение на пол
	var fall := create_tween()
	fall.tween_property(player, "view_offset", Transform3D(Basis.from_euler(Vector3(0.5, 0.3, 0.6)), Vector3(0.1, -0.3, 0.2)), 0.35)
	fall.tween_property(player, "view_offset", Transform3D(Basis.from_euler(Vector3(0.35, 0.2, 1.35)), Vector3(0.25, -0.95, 0.3)), 0.45).set_ease(Tween.EASE_IN)
	await fall.finished
	snd("body_fall", null, 2.0, 0.7)
	shake(0.5, 0.3)
	ui.set_damage(0.6)
	await wait(1.4)
	psycho.go([psycho.global_position + Vector3(6.0, 0, 0)], 1.3, "walk_loop")
	await GameState.fade_to(1.0, 2.5)
	await wait(1.0)
	# заново: у двери администратора, с ключом
	psycho.stop()
	psycho.visible = false
	ui.set_damage(0.0)
	player.view_offset = Transform3D.IDENTITY
	lift.park_closed(0)
	place_player(CHASE_RESTART, PI * 0.5)
	freeze(false)
	chase = "off"
	_drone.volume_db = -24.0
	await GameState.fade_to(0.0, 1.5)
	_act2_return()


func _on_lift_departed(f: int) -> void:
	if act == "chase" and f == 0:
		sets.build_void()
		await wait(2.5)
		chase = "off"
		psycho.visible = false
		psycho.stop()
	elif act == "floor3_leave" and f == 2:
		_on_leave_floor3()


func _on_lift_arrived(f: int) -> void:
	if act == "chase" and f == 1:
		_act3()
	elif act == "void_done" and f == 2:
		_act4()
	elif act == "floor3_down" and f == 1:
		_act5()


# ================================================================================ АКТ 3: пустая комната, радио
func _act3() -> void:
	act = "void"
	GameState.checkpoint = "void"
	_drone.volume_db = -18.0
	lift.forced_floor = -1
	lift.locked = true
	lift.lock_text = "Кнопки не реагируют…"
	if GameState.fade_target() > 0.5:
		await GameState.fade_to(0.0, 1.5)
	await wait(1.2)
	await say("thought", "Что это?.. Где все комнаты?.. Там одна дверь…")
	objective("Найди комнату деда — дверь с лампой вдалеке", ROOM204_DOOR + Vector3(0, 0, -0.3))
	await until(func(): return room_id() == "L1.F2")
	await wait(2.0)
	var radio_pos := ROOM204_DOOR + Vector3(-1.4, 0.7, 5.6)
	var rn: Node = game.node("radio_F2")
	if rn is Node3D:
		radio_pos = (rn as Node3D).global_position
	var hiss := AudioStreamPlayer3D.new()
	hiss.stream = stream("radio_hiss", true)
	hiss.volume_db = 4.0
	hiss.unit_size = 3.0
	hiss.bus = "World"
	game.add_child(hiss)
	hiss.global_position = radio_pos
	hiss.play()
	snd("stinger", null, -12.0, 0.8)
	await wait(1.6)
	snd("radio_whisper", radio_pos, 8.0, 0.95, 20.0)
	await say("radio", "Не оборачивайся…", 3.0)
	await wait(5.0)                                   # если обернуться — сзади никого
	var tw := create_tween()
	tw.tween_property(hiss, "volume_db", -40.0, 4.0)
	tw.tween_callback(hiss.queue_free)
	await say("thought", "Здесь никого нет… Мама говорила про третий этаж.")
	objective("Поднимись на лифте на 3-й этаж и найди маму", Vector3(37.5, 4.5, -6.9))
	lift.locked = false
	lift.forced_floor = 2
	act = "void_done"


# ================================================================================ АКТ 4: третий этаж, звуки, человек в коляске
func _act4() -> void:
	act = "floor3_search"
	GameState.checkpoint = "floor3"
	if GameState.fade_target() > 0.5:
		await GameState.fade_to(0.0, 1.5)
	if game.critters:
		game.critters.visible = true
	lift.forced_floor = -1
	lift.locked = true
	lift.lock_text = "Сначала найди маму"
	objective("Найди маму на 3-м этаже")
	_drone.volume_db = -16.0
	scares.start(self)
	await until(func(): return scares.elapsed > 200.0 and scares.count >= 8, 260.0)   # 3–4 минуты
	scares.stop()
	# лёгкий скрип металла в коридоре — человек в обычной коляске у лифта
	var man := Props.glb("res://characters/wheelchair_man_static.glb", 1.4, 0.476)
	game.add_child(man)
	man.global_position = MAN_POS
	snd("metal_creak", MAN_POS + Vector3(0, 0.6, 0), 4.0, 1.0, 40.0)
	objective("Проверь коридор у лифта", MAN_POS, Vector3(0, 1.4, 0))
	var talk_area: Area3D = Interactable.new()
	man.add_child(talk_area)
	talk_area.position = Vector3(0, 0.8, 0)
	var asked := [false]
	talk_area.setup(Vector3(0.9, 1.4, 0.9), "[E] Спросить про маму", _set_flag.bind(asked))
	await until(func(): return asked[0] or near(MAN_POS, 1.6))
	talk_area.queue_free()
	freeze(true)
	await look_at_point(MAN_POS + Vector3(0, 1.2, 0), 0.6)
	await say("hero", "Извините, я хотел спросить: вы не видели здесь женщину в коричневом платье?")
	await wait(6.5)                                    # пауза 5–8 секунд
	await say("man", "Она только что по лестнице вниз пошла. Я всё тебе сказал, теперь не беспокой меня, уходи.")
	await say("hero", "Хорошо, спасибо.")
	freeze(false)
	objective("Вернись в лифт", Vector3(37.5, 7.8, -5.2))
	lift.locked = false
	lift.forced_floor = 1
	act = "floor3_leave"
	# когда двери начнут закрываться — за ними мама увозит этого человека в другую сторону
	await until(func(): return lift.player_in_cabin() and lift.state == "closing")
	man.visible = false
	var pair := Props.glb("res://characters/mom_confused_static.glb", 2.1, 0.384)
	pair.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	game.add_child(pair)
	pair.global_position = MAN_POS + Vector3(0.42, 0, 0)
	pair.rotation.y = -PI * 0.5
	var away := create_tween()
	away.tween_property(pair, "global_position", MAN_POS + Vector3(-9.0, 0, 0), 11.0)
	look_at_point(MAN_POS + Vector3(0.6, 1.3, 0), 0.5)
	await wait(4.0)
	pair.queue_free()
	man.queue_free()


func _set_flag(flag: Array) -> void:
	flag[0] = true


func _on_leave_floor3() -> void:
	act = "floor3_down"
	sets.build_maze()


# ================================================================================ АКТ 5: лабиринт, палата 204, дед, драка
func _act5() -> void:
	act = "maze"
	GameState.checkpoint = "maze"
	if GameState.fade_target() > 0.5:
		await GameState.fade_to(0.0, 1.5)
	if game.critters:
		game.critters.visible = false
	lift.forced_floor = -1
	lift.locked = true
	lift.lock_text = "Лифт больше не работает"
	_drone.volume_db = -12.0
	await wait(1.0)
	await say("hero", "Что происходит?.. Я что, умер?")
	objective("Найди комнату деда (Палата №204)", ROOM204_DOOR + Vector3(0, 0, -0.3))
	_place_ward_key()
	await until(func(): return near(ROOM204_DOOR + Vector3(0, 0, -1.0), 2.2) or has_ward_key)
	if not has_ward_key:
		await say("thought", "Заперто… Нужен ключ. Может, в процедурном кабинете?")
		objective("Найди ключ от палаты — процедурный кабинет 213", ROOM213_DOOR)
		await until(func(): return has_ward_key)
	objective("Открой палату №204 и заезжай", ROOM204_DOOR + Vector3(0, 0, 0.6))
	await until(func(): return room_id() == "L1.F2" and ppos().z > -5.3)
	await _grandpa_at_door()


func _place_ward_key() -> void:
	var holder := Node3D.new()
	game.add_child(holder)
	holder.global_position = KEY204_POS
	var key := Props.glb("res://props/key_ward.glb", 0.018)
	holder.add_child(key)
	key.rotation = Vector3(0, 0.6, 0)
	var shine := OmniLight3D.new()
	shine.light_color = Color(1.0, 0.85, 0.55)
	shine.light_energy = 0.25
	shine.omni_range = 1.2
	holder.add_child(shine)
	shine.position.y = 0.3
	var it: Area3D = Interactable.new()
	holder.add_child(it)
	it.setup(Vector3(0.45, 0.35, 0.45), "[E] Взять ключ от палаты №204", _take_ward_key.bind(holder))


func _take_ward_key(holder: Node3D) -> void:
	has_ward_key = true
	var d = door(Sets.DOOR_204)
	if d:
		d.locked = false
	game.play_at("button", KEY204_POS, -6.0, 0.7, 6.0)
	ui.hint("Ключ от палаты №204 — у тебя", 3.0)
	holder.queue_free()


func _grandpa_at_door() -> void:
	act = "grandpa"
	freeze(true)
	game.lights.set_room("L1.F2", true)            # в палате тусклый свет (мигает в драке)
	game.lights.set_room("L1.F2b", true)
	objective("")
	var d0 = door(Sets.DOOR_204)
	if d0 and d0.angle < 60.0:
		d0.swing_to(95.0, 0.3)
	# Саман резко поворачивается назад: в коридоре за дверью стоит дед
	grandpa.visible = true
	grandpa.global_position = Vector3(8.85, 4.5, -7.6)
	grandpa.face(ppos(), true)
	grandpa.play("idle_loop")
	snd("stinger", null, -8.0, 0.9)
	var tw := create_tween()
	tw.tween_property(player, "rotation:y", player.rotation.y + PI, 0.45).set_ease(Tween.EASE_OUT)
	player.look_yaw = 0.0
	await tw.finished
	await look_at_point(grandpa.head_pos(), 0.4)
	grandpa.set_look(player.head.global_position)
	grandpa.play("talk_loop")
	await say("grandpa", "Внучок, привет… Как ты?")
	grandpa.play("idle_loop")
	await say("hero", "Г-где моя мама?..")
	await wait(1.2)
	# дед молча делает шаг вперёд, Саман пятится, дверь захлопывается перед лицом деда
	grandpa.go([Vector3(8.85, 4.5, -6.9)], 0.35, "walk_loop")
	player.input_override = Vector2(-0.7, 0.0)
	await wait(0.9)
	player.input_override = Vector2.ZERO
	var d = door(Sets.DOOR_204)
	if d:
		await until(func(): return not d._blocked(0.0), 3.0)
		await d.slam()
		d.locked = true
		d.locked_text = "Дверь не открывается"
	shake(0.6, 0.3)
	grandpa.visible = false
	grandpa.stop()
	await wait(1.4)
	# из тени палаты выходит мама
	var bath = door(Sets.DOOR_204_BATH)
	mom.visible = true
	mom.global_position = Vector3(7.0, 4.5, -5.2)
	mom.face(Vector3(9.0, 4.5, -5.0), true)
	if bath:
		snd("door_creak_slow", bath.center, -2.0, 0.8)
		bath.swing_to(90.0, 1.6)
	await wait(1.2)
	await mom.go_and_wait([Vector3(8.6, 4.5, -5.0)], 0.7)
	mom.face(ppos())
	await look_at_point(mom.head_pos(), 0.5)
	mom.set_look(player.head.global_position)
	await say("hero", "Мама!.. Мама, это я! Я твой сын!")
	snd("mom_scream", mom.head_pos(), 4.0)
	mom.play("talk_loop", 0.1, 1.5)
	await say("mom", "Ты не мой сын!! Убирайся, или я убью тебя и твоё мясо отдам собакам! Иди сюда!!!", 4.5)
	_start_fight()


# ================================================================================ драка
func _start_fight() -> void:
	act = "fight"
	hp = 100.0
	_fight_t = 0.0
	_mom_cd = 0.8
	freeze(false)
	objective("Отбивайся!")
	ui.hint("ЛКМ — ударить, W A S D — уворачиваться", 6.0)
	_drone.volume_db = -8.0
	fight = "on"


func _update_fight(dt: float) -> void:
	_fight_t += dt
	# свет в палате мигает от ударов в дверь
	_flick_t -= dt
	if _flick_t <= 0.0:
		var off: bool = game.lights.is_on("L1.F2") and randf() < 0.5
		game.lights.set_room("L1.F2", not off)
		_flick_t = randf_range(0.05, 0.18) if off else randf_range(0.6, 2.4)
	_mom_cd -= dt
	_punch_cd -= dt
	_bang_t -= dt
	if _bang_t <= 0.0:
		_bang_t = randf_range(1.3, 2.6)
		var d = door(Sets.DOOR_204)
		snd("grandpa_bang", ROOM204_DOOR + Vector3(0, 1.2, -0.4), 4.0, randf_range(0.9, 1.1), 25.0)
		if d:
			d.rattle(2.5)
		if randf() < 0.3:
			ui.say("grandpa", ["Открой!!", "Барно, не трогай его!", "Внучок!!"][randi() % 3], 1.6)
	if fight != "on":
		return
	var to: Vector3 = ppos() - mom.global_position
	to.y = 0.0
	var dist: float = to.length()
	mom.face(ppos())
	if mom.current != "attack" or _mom_cd < 0.6:
		if dist > 1.05:
			var np: Vector3 = mom.global_position + to.normalized() * minf(1.7 * dt, dist - 1.0)
			mom.global_position = _clamp_room204(np)
			mom.play("walk_loop", 0.2, 1.4)
		elif _mom_cd <= 0.0:
			_mom_attack()
		else:
			mom.play("idle_loop", 0.2)
	if hp <= 25.0 or _fight_t > 42.0:
		fight = "cornered"
		_cornered()


func _clamp_room204(p: Vector3) -> Vector3:
	var x: float = clampf(p.x, 6.7, 9.75)
	var z: float = clampf(p.z, -6.15, -1.7)
	if z < -4.05:
		x = maxf(x, 8.2)
	return Vector3(x, 4.5, z)


func _mom_attack() -> void:
	_mom_cd = 2.0
	mom.play("attack", 0.1, 1.15)
	snd("whoosh", mom.head_pos(), 0.0, 0.9)
	await wait(0.55)
	if fight != "on":
		return
	var to: Vector3 = ppos() - mom.global_position
	to.y = 0.0
	if to.length() < 1.6:
		hp -= 13.0
		snd("punch", null, 2.0, 0.9)
		snd("choke", null, -6.0, 1.2)
		ui.flash(Color(0.7, 0.0, 0.0, 0.6), 0.4)
		ui.set_damage(1.0 - hp / 100.0)
		shake(0.8, 0.35)


func _hide_fist() -> void:
	fist.visible = false


func _on_skip() -> void:
	_skip = true


func _punch() -> void:
	if _punch_cd > 0.0 or fight != "on":
		return
	_punch_cd = 0.55
	fist.visible = true
	var tw := create_tween()
	tw.tween_property(fist, "position", Vector3(0.06, -0.12, -0.18), 0.09)
	tw.tween_property(fist, "position", Vector3(0.2, -0.24, 0.05), 0.2)
	tw.tween_callback(_hide_fist)
	snd("whoosh", null, -4.0, 1.3)
	var to: Vector3 = mom.global_position + Vector3(0, 1.3, 0) - player.cam.global_position
	var flat := Vector3(to.x, 0, to.z)
	if flat.length() < 1.75 and player.view_dir().dot(to.normalized()) > 0.6:
		await wait(0.08)
		snd("punch", mom.head_pos(), 4.0, 1.1)
		snd("mom_scream", mom.head_pos(), -4.0, 1.3)
		_mom_cd = maxf(_mom_cd, 0.9)
		var back: Vector3 = mom.global_position + flat.normalized() * 0.55
		var mt := create_tween()
		mt.tween_property(mom, "global_position", _clamp_room204(back), 0.18)


## Барно зажимает его в угол и почти убивает — в последний момент дверь слетает с петель.
func _cornered() -> void:
	freeze(true)
	mom.play("attack", 0.1, 0.6)
	var to: Vector3 = mom.global_position - ppos()
	to.y = 0.0
	var tw := create_tween()
	tw.tween_property(mom, "global_position", _clamp_room204(ppos() + to.normalized() * 0.75), 0.4)
	look_at_point(mom.head_pos(), 0.3)
	snd("choke", null, 2.0, 0.95)
	var t := 0.0
	while t < 3.2:
		await get_tree().process_frame
		var dt: float = get_process_delta_time()
		t += dt
		ui.set_damage(0.75 + 0.25 * t / 3.2)
		player.view_offset = Transform3D(Basis.from_euler(Vector3(randf_range(-0.03, 0.03), randf_range(-0.03, 0.03), 0.25 * t / 3.2)), Vector3.ZERO)
	await _rescue()


func _rescue() -> void:
	act = "rescue"
	fight = "done"
	var d = door(Sets.DOOR_204)
	snd("door_burst", ROOM204_DOOR + Vector3(0, 1.2, 0), 10.0, 1.0, 40.0)
	shake(1.2, 0.5)
	if d:
		for b in d.leaf_bodies():
			var body: Node3D = b
			(b as CollisionObject3D).collision_layer = 0
			var tw := create_tween()
			tw.tween_property(body, "global_position", body.global_position + Vector3(0.3, -0.1, 2.0), 0.45).set_ease(Tween.EASE_OUT)
			tw.parallel().tween_property(body, "rotation:x", -PI * 0.5, 0.45)
	player.view_offset = Transform3D.IDENTITY
	ui.set_damage(0.45)
	game.lights.set_room("L1.F2", true)
	grandpa.visible = true
	grandpa.global_position = Vector3(8.85, 4.5, -7.0)
	grandpa.set_look(null)
	var target: Vector3 = mom.global_position + (ROOM204_DOOR - mom.global_position).normalized() * 0.8
	target.y = 4.5
	await grandpa.go_and_wait([Vector3(8.85, 4.5, -5.9), target], 3.0, "run_loop")
	grandpa.face(mom.global_position, true)
	grandpa.play("push", 0.1, 1.2)
	await wait(0.65)
	# Барно отлетает, ударяется головой о чугунную спинку кровати и падает без сознания
	snd("punch", mom.head_pos(), 6.0, 0.8)
	var bed := Vector3(9.75, 4.5, -3.5)
	var fly := create_tween()
	fly.tween_property(mom, "global_position", bed, 0.35).set_ease(Tween.EASE_OUT)
	mom.set_look(null)
	mom.face(grandpa.global_position, true)
	mom.play("fall", 0.05)
	await wait(0.35)
	snd("metal_bang", bed + Vector3(0.2, 0.8, 0), 6.0, 0.6, 20.0)
	snd("body_fall", bed, 4.0, 0.8)
	await wait(1.0)
	grandpa.face(ppos(), true)
	grandpa.set_look(player.head.global_position)
	grandpa.play("talk_loop")
	ui.set_damage(0.25)
	freeze(false)
	await say("grandpa", "Уходим, пока не поздно! Давай быстрее за мной!")
	_act6()


# ================================================================================ АКТ 6: землетрясение, бег, лестница
func _act6() -> void:
	act = "quake"
	quake = 1.0
	_rumble = AudioStreamPlayer.new()
	_rumble.stream = stream("quake_rumble", true)
	_rumble.volume_db = 2.0
	add_child(_rumble)
	_rumble.play()
	_dust.emitting = true
	snd("beam_hit", null, -2.0, 0.7)
	sets.quake_open_route()
	var sd = door(Sets.DOOR_STAIR1_F2)
	if sd:
		sd.swing_to(95.0, 0.6)
	player.speed_level = 4
	game.hud.set_speed(4, 5)
	objective("Беги за дедом!", grandpa, Vector3(0, 2.0, 0))
	ui.hint("Коляска — на полной скорости", 4.0)
	grandpa.set_look(null)
	var path: Array = GRANDPA_RUN.duplicate()
	var shouted := false
	while not path.is_empty():
		var next: Vector3 = path.pop_front()
		grandpa.go([next], 2.6, "run_loop")
		while grandpa.is_moving():
			await get_tree().process_frame
			var goal: Vector3 = GRANDPA_RUN[-1]
			var lagging: bool = ppos().distance_to(goal) > grandpa.global_position.distance_to(goal) + 1.0
			if lagging and grandpa.global_position.distance_to(ppos()) > 7.5:
				grandpa.stop("talk_loop")
				grandpa.face(ppos())
				if not shouted:
					shouted = true
					ui.say("grandpa", "Быстрее, внучок!", 2.0)
				await until(func(): return grandpa.global_position.distance_to(ppos()) < 4.5, 20.0)
				grandpa.go([next], 2.6, "run_loop")
	grandpa.stop("idle_loop")
	grandpa.face(ppos())
	await until(func(): return ppos().y > 4.0 and ppos().z > -6.4 and ppos().x > 29.9 and ppos().x < 36.0, 60.0)
	freeze(true)
	await look_at_point(grandpa.head_pos(), 0.5)
	await say("hero", "Дедушка, там лифт есть!")
	grandpa.play("talk_loop")
	await say("grandpa", "В первый раз слышу такое слово! Давай быстрее!", 2.6)
	await _finale()


func _finale() -> void:
	# слева — удар огромной конструкции; деда отбрасывает вправо
	var right: Vector3 = player.cam.global_transform.basis.x
	right.y = 0.0
	right = right.normalized()
	var gp: Vector3 = grandpa.global_position
	var beam := Props.beam(4.2)
	beam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	game.add_child(beam)
	beam.global_position = gp - right * 3.6 + Vector3(0, 2.4, 0)
	beam.look_at(gp + Vector3(0, 1.2, 0), Vector3.UP)
	snd("beam_hit", gp + Vector3(0, 1.2, 0), 10.0, 1.0, 40.0)
	var tw := create_tween()
	tw.tween_property(beam, "global_position", gp + right * 0.4 + Vector3(0, 1.1, 0), 0.22).set_ease(Tween.EASE_IN)
	await tw.finished
	var thrown := Vector3(clampf(gp.x + right.x * 1.7, 31.6, 35.5), gp.y, clampf(gp.z + right.z * 1.7, -3.3, -0.75))
	var gt := create_tween()
	gt.tween_property(grandpa, "global_position", thrown, 0.35).set_ease(Tween.EASE_OUT)
	grandpa.face(gp - right, true)
	grandpa.play("fall", 0.05, 1.3)
	var bt := create_tween()
	bt.tween_property(beam, "global_position", gp + right * 1.0 + Vector3(0, 0.25, 0), 0.4).set_ease(Tween.EASE_IN)
	bt.parallel().tween_property(beam, "rotation:z", 0.4, 0.4)
	shake(1.5, 0.6)
	await wait(0.5)
	snd("body_fall", thrown, 6.0, 0.8)
	await wait(0.4)
	snd("hero_scream", null, 4.0)
	ui.say("hero", "ДЕДУШКА!!!", 2.0)
	await wait(1.3)
	# сверху на Самана обрушивается огромный кусок потолка
	snd("ceiling_collapse", null, 6.0)
	var top: Vector3 = player.cam.global_position + Vector3(0, 3.0, 0)
	look_at_point(top, 0.35)
	var slab := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(2.2, 0.45, 2.2)
	slab.mesh = bm
	slab.material_override = Props.concrete()
	slab.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	game.add_child(slab)
	slab.global_position = top
	slab.rotation = Vector3(0.2, 0.5, 0.15)
	var st := create_tween()
	st.tween_property(slab, "global_position", player.cam.global_position + Vector3(0, 0.25, 0), 0.75).set_ease(Tween.EASE_IN)
	await st.finished
	GameState.set_fade(1.0)
	quake = 0.0
	AudioServer.set_bus_mute(0, true)
	await wait(3.0)
	AudioServer.set_bus_mute(0, false)
	GameState.go(GameState.EPILOGUE)


# ================================================================================ кадр
func _physics_process(dt: float) -> void:
	if game == null:
		return
	if chase == "run" or chase == "safe":
		_update_chase(dt)
	if act == "fight" or fight == "cornered":
		_update_fight(dt)


func _process(dt: float) -> void:
	if game == null:
		return
	if act == "scream" and not _scream_door_open:
		_flick_t -= dt
		if _flick_t <= 0.0:
			var on: bool = not game.lights.is_on("L0.R17")
			game.lights.set_room("L0.R17", on)
			_flick_t = randf_range(0.6, 2.5) if on else randf_range(0.05, 0.25)
		_moan_t -= dt
		if _moan_t <= 0.0:
			_moan_t = randf_range(9.0, 15.0)
			snd("crying", SCREAM_ROOM, -6.0, 0.62, 30.0)
	if quake > 0.0:
		_dust.global_position = ppos() + Vector3(0, 3.0, 0)
		player.view_offset = Transform3D(Basis.from_euler(Vector3(randf_range(-1, 1) * 0.012, randf_range(-1, 1) * 0.01,
			randf_range(-1, 1) * 0.02) * quake), Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * 0.012 * quake)
		sets.set_lamps(randf_range(0.2, 1.1))
		_debris_t -= dt
		if _debris_t <= 0.0:
			_debris_t = randf_range(0.35, 0.9)
			_drop_debris()


func _drop_debris() -> void:
	var fwd: Vector3 = -player.global_transform.basis.z
	var p: Vector3 = ppos() + fwd * randf_range(1.5, 6.0) + Vector3(randf_range(-1.5, 1.5), 0, randf_range(-1.5, 1.5))
	var c := Props.chunk(randf_range(0.15, 0.45))
	c.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	game.add_child(c)
	c.global_position = Vector3(p.x, ppos().y + 3.0, p.z)
	var tw := create_tween()
	tw.tween_property(c, "global_position:y", ppos().y + 0.1, 0.45).set_ease(Tween.EASE_IN)
	tw.tween_callback(func(): snd("debris", c.global_position, -2.0, randf_range(0.8, 1.2), 18.0))
	tw.tween_interval(8.0)
	tw.tween_callback(c.queue_free)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("attack") and fight == "on":
		_punch()
