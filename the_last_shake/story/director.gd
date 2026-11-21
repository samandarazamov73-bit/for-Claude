extends Node
## Сюжет «The Last Shake» внутри санатория (акты 1–6). Висит в sanatorium/main.tscn узлом Director;
## game.gd вызывает begin(game), когда здание построено. Глава (откуда начать) — GameState.checkpoint:
##   start — вход с мамой и лестница; key — после крика: ключ администратора; chase — с ключом у лифта;
##   void — 2-й этаж (пустая комната); floor3 — 3-й этаж; maze — снова настоящий 2-й этаж и палата 204.
## Все реплики — здесь (поменять текст — правь строки в кавычках).

const StoryUI = preload("res://story/story_ui.gd")
const Actor = preload("res://story/actor.gd")
const Sets = preload("res://story/floor_sets.gd")
const Scares = preload("res://story/scares.gd")
const Props = preload("res://story/props.gd")
const Interactable = preload("res://story/interactable.gd")
const Minigame = preload("res://story/minigame.gd")

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
const TRAP_SPOT := Vector3(52.5, 1.2, -10.75)      # запертый в кабинете 139: коляска лицом к двери
const SCALPEL_POS := Vector3(51.3, 2.14, -14.65)   # скальпель на инструментальном столике
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
const PSYCHO_FAR := Vector3(52.0, 1.2, -8.1)       # погоня: стоит в коридоре (~14 м), когда загорается свет
const PSYCHO_NEAR := Vector3(45.5, 1.2, -8.1)      # …свет гаснет на миг — он уже в 8 м
const CHASE_RESTART := Vector3(43.5, 1.2, -7.7)
const PSYCHO_SPEED := 3.3         # м/с; после каждой поимки чуть медленнее
const MAN_POS := Vector3(37.85, 7.8, -9.0)         # человек в коляске напротив лифта (виден в проёме дверей)
# братья: холл отдыха 309 (L2.R7) — сюда притаскивают Азиза; старший брат — тот самый мужчина в белом
const LOUNGE := "L2.R7"
const DOOR_LOUNGE := 165
const TIED_POS := Vector3(25.9, 7.8, -11.3)        # коляска с привязанными руками, лицом к двери (−X)
const TIED_YAW := PI * 0.5
const WASHERS := [Vector3(24.35, 7.8, -10.02), Vector3(25.05, 7.8, -10.02)]
const YOUNGER_ROOM := [Vector3(22.9, 7.8, -11.55), Vector3(23.65, 7.8, -11.45), Vector3(24.3, 7.8, -11.35)]
const ELDER_ROOM := Vector3(23.4, 7.8, -10.45)     # старший — у закрытой двери, сторожит выход, на виду
const ELDER_STARE := Vector3(24.65, 7.8, -10.75)
const ELDER_EXIT := [Vector3(23.3, 7.8, -10.45), Vector3(22.88, 7.8, -9.8), Vector3(22.88, 7.8, -8.1), Vector3(6.0, 7.8, -8.1)]
const WRISTS := [Vector3(0.307, 0.8, 0.02), Vector3(-0.307, 0.8, 0.02)]   # кисти Азиза (координаты коляски)
# поза лежащего младшего (модель, после падения): живот, ось тела к голове
const LIE_BELLY := Vector3(-0.097, 0.0, 1.044)
const LIE_AXIS := Vector3(-0.391, 0.0, 0.92)
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
var act := ""
var chase := "off"               # off, run, caught, safe
var gurney: Node3D
var nightstand: Dictionary = {}
var _skip := false
var _snd_cache := {}
var _bang_t := 0.0
var _psycho_bang_t := 0.0
var _drone: AudioStreamPlayer
var _moan_t := 0.0
var _scream_door_open := false
var minigame                     # story/minigame.gd
var has_scalpel := false
var _flick_t := 1.0
var _psycho_speed := PSYCHO_SPEED
var younger                      # младший брат (characters/younger.glb)
var _tied := false               # руки привязаны к коляске: ехать нельзя, вверху надпись
var _tied_msg_t := 0.0
var _bandages: Array = []
var _track: Variant = null       # Callable → Vector3: куда сюжет держит взгляд Азиза (сцена в холле)
var _lounge_props: Array = []
var _lift_thought := false       # Азиз говорит сам с собой в лифте — 2-й этаж ждёт конца реплики


# ================================================================================ запуск
func begin(g) -> void:
	game = g
	player = g.player
	lift = g.lift
	ui = StoryUI.new()
	add_child(ui)
	ui.line_skipped.connect(_on_skip)
	minigame = Minigame.new()
	minigame.process_mode = Node.PROCESS_MODE_PAUSABLE
	ui.add_child(minigame)
	sets = Sets.new()
	game.add_child(sets)
	sets.setup(game)
	scares = Scares.new()
	add_child(scares)
	mom = _actor("res://characters/mom.glb", "Дилором")
	grandpa = _actor("res://characters/grandpa.glb", "Анвар")
	grandpa.natural = {"walk_loop": 0.26, "run_loop": 2.45}
	psycho = _actor("res://characters/psycho.glb", "Псих")
	psycho.natural = {"walk_loop": 1.3, "run_loop": 3.6, "sprint_loop": 2.13}
	psycho.step_volume = 2.0
	younger = _actor("res://characters/younger.glb", "Младший")
	younger.natural = {"walk_loop": 1.3, "run_loop": 3.6}
	younger.step_volume = 0.0
	for a in [grandpa, psycho, younger]:
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
			place_player(CHASE_RESTART, PI * 0.5)       # у кабинета администратора, ключ уже взят
			_take_lift_key(false)
			_act2_return()
		"void":
			_jump_to_lift(1)
			_act3()
		"floor3", "floor3b":
			sets.build_void()
			_jump_to_lift(2)
			_act4(cp == "floor3b")
		"pharmacy":
			sets.build_real2(false)
			_jump_to_lift(1, false)
			mom.visible = true
			mom.global_position = Vector3(CAB_CORNER.x, 4.5, CAB_CORNER.z)
			mom.face(Vector3(37.5, 4.5, -7.0), true)
			_act5()
		"real":
			_act6()
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
	if not loop:                                  # варианты звука (knock_2, knock_3 …) — каждый раз случайный
		var vs: Array = game.sfx_variants("res://story/sfx/", sound, _snd_cache)
		if vs.size() > 1:
			return vs[randi() % vs.size()]
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


## Реплика следом за другой, не дожидаясь её (в погоне сюжет не останавливается).
func _after_line(delay: float, who: String, text: String, sec: float) -> void:
	await wait(delay)
	ui.say(who, text, sec)


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
	await ui.line(who, text, sec)
	_skip = false
	if gestures and speaker.current == "talk_loop" and not speaker.is_moving():
		speaker.play("idle_loop", 0.45)


## Задание наверху слева; target — куда показывает маркер (точка или персонаж), null — без маркера.
var _objective_text := ""


func objective_text() -> String:
	return _objective_text


## Маркеров «куда ехать» нет: игрок сам ищет комнату по названию (вверху экрана — название комнаты, где он).
func objective(text: String, _target: Variant = null, _offset := Vector3(0, 1.0, 0)) -> void:
	_objective_text = text
	ui.set_objective(text, null)
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


## Плавно повернуть взгляд Азиза к точке за seconds.
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
	await say("mom", "Его палата на втором. Сначала к лестнице.")
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
	await say("mom", "Жди здесь. Я поднимусь за ним и приведу его.")
	mom.set_look(null)
	objective("Подожди маму у лестницы")
	await mom.go_and_wait(STAIRS_UP, 1.0)
	mom.visible = false
	_wait_scares_stairs()
	await wait(40.0)                                   # «через 30–60 секунд она возвращается»
	mom.visible = true
	var down: Array = STAIRS_UP.duplicate()
	down.reverse()
	down.append(STAIR_FOOT)
	await mom.go_and_wait(down, 1.0)
	mom.face(ppos())
	if not near(STAIR_FOOT, 5.0):
		await say("mom", "Азиз! Ты где? Подъезжай сюда.")
		objective("Вернись к маме, к лестнице", mom, Vector3(0, 1.9, 0))
		await until(func(): return near(STAIR_FOOT, 4.5))
	mom.face(ppos())
	mom.set_look(player.head.global_position)
	mom.play("talk_loop")
	await say("mom", "Его там нет. В палате пусто… Может, его перевели на третий.")
	await say("mom", "Стой здесь. Никуда не уезжай, слышишь?")
	await say("hero", "Только быстрее, ладно? Мне здесь, блин, не по себе.")
	mom.set_look(null)
	await mom.go_and_wait(STAIRS_UP, 1.1)
	mom.visible = false
	objective("Осмотри первый этаж")
	_drone.volume_db = -26.0
	_wait_scares_floor1()
	await wait(60.0)                                   # «через 1 минуту … раздаётся пронзительный крик»
	_act2_scream()


## Пока ждёшь маму у лестницы: кто-то ходит наверху, свет в коридоре скачет, далеко хлопает дверь.
func _wait_scares_stairs() -> void:
	await wait(9.0)
	if act != "act1":
		return
	snd("barefoot_steps", STAIR_FOOT + Vector3(3.0, 3.6, 1.0), -2.0, 0.85, 25.0)
	await wait(12.0)
	if act != "act1":
		return
	await _corridor_flicker(4)
	await wait(10.0)
	if act != "act1":
		return
	game.play_at("door_slam_far", Vector3(70.0, 2.0, -8.1), 2.0, 0.9, 70.0)


## Пока бродишь по первому этажу: стук из-за двери рядом, а потом — фигура в конце коридора, пока мигает свет.
func _wait_scares_floor1() -> void:
	await wait(14.0)
	if act != "act1":
		return
	var side := Vector3(0, 0, 1.6) if randf() < 0.5 else Vector3(0, 0, -1.6)
	snd("knock", ppos() + side + Vector3(0, 1.2, 0), 2.0, 0.9, 12.0)
	# фигура: только если смотришь вдоль коридора и до конца далеко
	var t := 0.0
	while t < 30.0 and act == "act1":
		await wait(0.5)
		t += 0.5
		if t < 10.0 or room_id() != "L0.C":
			continue
		var fwd: Vector3 = -player.cam.global_transform.basis.z
		var end_x: float = 73.6 if fwd.x > 0.0 else 1.3
		if absf(fwd.x) > 0.85 and absf(end_x - ppos().x) > 16.0:
			await _figure_at_corridor_end(Vector3(end_x, 1.2, -8.1))
			return


func _figure_at_corridor_end(p: Vector3) -> void:
	game.lights.set_room("L0.C", false)
	game.play_at("flicker", ppos() + Vector3(0, 2.8, 0), -4.0, 0.8, 20.0)
	psycho.visible = true
	psycho.global_position = p
	psycho.face(ppos(), true)
	psycho.play("idle_loop", 0.0)
	psycho.set_look(player.head.global_position)
	await wait(0.25)
	game.lights.set_room("L0.C", true)
	await wait(0.9)
	game.lights.set_room("L0.C", false)
	await wait(0.3)
	psycho.visible = false
	psycho.set_look(null)
	game.lights.set_room("L0.C", true)
	_heartbeat_burst(4)


## Свет в коридоре 1-го этажа мигает n раз (с треском).
func _corridor_flicker(n: int) -> void:
	for i in n:
		game.lights.set_room("L0.C", false)
		if i == 0:
			game.play_at("flicker", ppos() + Vector3(0, 2.8, 0), -6.0, randf_range(0.8, 1.1), 20.0)
		await wait(randf_range(0.06, 0.2))
		game.lights.set_room("L0.C", true)
		await wait(randf_range(0.08, 0.35))


func _heartbeat_burst(n: int) -> void:
	for i in n:
		snd("heartbeat", null, -4.0, 1.0)
		await wait(0.5)


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
	await say("thought", "Кто это кричал?..")
	objective("Проверь, откуда крик — процедурный кабинет 139", SCREAM_DOOR)
	var d = door(DOOR_SCREAM)
	_moan_t = 10.0
	# пока не откроет дверь — изредка из комнаты слышен стон
	await until(func(): return (d != null and d.angle > 18.0) or room_id() == "L0.R17")
	_scream_door_open = true
	game.lights.set_room("L0.R17", true)
	await wait(0.6)
	await say("hero", "Дедушка?.. Здесь есть кто-нибудь?")
	objective("Осмотри кабинет 139", SCREAM_ROOM + Vector3(0, -0.4, 0))
	# заехал вглубь (за створку двери) — дверь за спиной захлопывается
	await until(func(): return room_id() == "L0.R17" and ppos().z < -11.6)
	await _locked_in_room()
	await until(func(): return ppos().x < 40.5 and ppos().z < -0.5 and ppos().z > -10.0)
	await say("thought", "Лифт… Надо уехать отсюда наверх, к маме. Пока он не вернулся.")
	objective("Поднимись на лифте на 2-й этаж", LIFT_CALL)
	act = "need_key"


## Псих запирает Азиза в своём кабинете и говорит через дверь; дверь не выбить — мини-игра «толкай»;
## другой способ — скальпель со столика: поддеть язычок замка (вторая мини-игра). Потом — к лифту.
func _locked_in_room() -> void:
	act = "locked"
	objective("")
	game.lights.set_room("L0.R17", true)
	snd("instruments_fall", CRASH_POS, 2.0, 1.0, 25.0)
	await wait(0.9)
	var d = door(DOOR_SCREAM)
	if d:
		await until(func(): return not d._blocked(0.0), 4.0)
		await d.slam()
		d.locked = true
		d.locked_text = "Заперто снаружи"
	shake(0.8, 0.4)
	snd("stinger", null, -2.0, 0.9)
	freeze(true)
	await look_at_point(SCREAM_DOOR + Vector3(0, 1.2, 0), 0.5)
	await wait(0.5)
	game.play_at("door_locked", SCREAM_DOOR + Vector3(0, 1.1, 0), 4.0, 0.75, 15.0)    # ключ в замке
	await wait(0.9)
	snd("breathing", SCREAM_DOOR + Vector3(0, 1.6, 0.3), 2.0, 0.8, 12.0)
	await say("psycho", "Тш-ш-ш… Не шуми. Здесь все сначала шумят.", 3.2)
	await say("hero", "Открой, слышишь?! Выпусти меня, урод!", 2.4)
	await wait(0.8)
	await say("psycho", "Я тебя знаю. Ты внук старика из двести четвёртой. Он про тебя всё время рассказывает.", 4.0)
	await say("psycho", "Посиди. Подумай. А я схожу… за твоей мамой. И брата приведу.", 4.2)
	snd("laughter", SCREAM_DOOR + Vector3(2.0, 1.6, 0.6), 0.0, 0.9, 30.0)
	snd("barefoot_steps", SCREAM_DOOR + Vector3(5.0, 1.0, 1.5), 0.0, 1.0, 30.0)
	await wait(1.6)
	await say("hero", "Нет… НЕТ! Открой, лысый ебаный!!", 2.4)
	# 1) выбить дверь: не выходит
	place_player(TRAP_SPOT, PI)
	player.look_pitch = -0.05
	objective("Выбей дверь!")
	minigame.hit.connect(_on_push_hit)
	await minigame.run("Толкни дверь", 4, 190.0, 54.0, {"shrink": true})
	minigame.hit.disconnect(_on_push_hit)
	await wait(0.3)
	game.play_at("door_locked", SCREAM_DOOR + Vector3(0, 1.1, 0), 2.0, 0.7, 15.0)
	await say("thought", "Не поддаётся… Сука. Замок. Нужно чем-то поддеть язычок.")
	freeze(false)
	# 2) другой способ: скальпель на столике
	var holder := _place_scalpel()
	objective("Найди, чем поддеть замок", SCALPEL_POS + Vector3(0, -0.3, 0), Vector3(0, 0.5, 0))
	await until(func(): return has_scalpel)
	holder.queue_free()
	objective("Поддень язычок замка", SCREAM_DOOR + Vector3(0, 0, -0.9), Vector3(0, 1.0, 0))
	await until(func(): return room_id() == "L0.R17" and ppos().distance_to(TRAP_SPOT) < 1.0)
	freeze(true)
	place_player(TRAP_SPOT, PI)
	objective("Поддень язычок замка скальпелем")
	minigame.hit.connect(_on_pick_hit)
	await minigame.run("Поддень язычок", 3, 230.0, 34.0, {"lose_on_miss": true, "reverse": true})
	minigame.hit.disconnect(_on_pick_hit)
	game.play_at("button", SCREAM_DOOR + Vector3(0, 1.1, 0), 2.0, 0.6, 10.0)
	await wait(0.4)
	if d:
		d.locked = false
		d.locked_text = ""
		d.swing_to(35.0, 0.9)
		game.play_at("door_open_wood2", d.center, -2.0, 0.85, 20.0)
	freeze(false)
	await say("thought", "Открыл… Надо выбираться. Быстро.")
	act = "scream"
	objective("Выбирайся к лестнице", STAIR_FOOT + Vector3(0, 0, 2.0))


func _on_push_hit(ok: bool) -> void:
	var d = door(DOOR_SCREAM)
	if ok:
		snd("knock", SCREAM_DOOR + Vector3(0, 1.0, 0), 8.0, 0.55, 20.0)
		if d:
			d.rattle(3.5)
		shake(0.6, 0.25)
		player.input_override = Vector2(0.9, 0.0)        # коляска рывком в дверь
		await wait(0.18)
		player.input_override = Vector2.ZERO
		await wait(0.2)
		place_player(TRAP_SPOT, PI)
	else:
		game.play_at("bump", SCREAM_DOOR + Vector3(0, 0.8, 0), -6.0, 1.2, 10.0)


func _on_pick_hit(ok: bool) -> void:
	if ok:
		game.play_at("button", SCREAM_DOOR + Vector3(0, 1.1, 0), -4.0, 1.4, 8.0)
	else:
		snd("knock", SCREAM_DOOR + Vector3(0, 1.1, 0), -10.0, 1.8, 8.0)
		ui.hint("Соскользнул…", 1.2)


func _place_scalpel() -> Node3D:
	var holder := Node3D.new()
	game.add_child(holder)
	holder.global_position = SCALPEL_POS
	var blade := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.16, 0.006, 0.018)
	blade.mesh = bm
	blade.material_override = Props.mat(Color(0.75, 0.77, 0.8), 0.25, 0.9)
	holder.add_child(blade)
	blade.rotation.y = 0.5
	var it: Area3D = Interactable.new()
	holder.add_child(it)
	it.setup(Vector3(0.5, 0.35, 0.5), "[E] Взять скальпель", func():
		has_scalpel = true
		game.play_at("button", SCALPEL_POS, -6.0, 1.6, 6.0)
		ui.hint("Скальпель — у тебя", 2.5))
	return holder


func _on_lift_locked() -> void:
	if act == "need_key":
		act = "find_admin"
		_act2_key()
	elif act in ["floor3_search", "mom_back", "brothers"]:
		say("thought", "Нет. Сначала мама.")


func _act2_key() -> void:
	act = "find_admin"
	await say("thought", "Заперт. Ключи обычно у администратора…")
	objective("Найди кабинет 134 «Администрация»", ADMIN_DOOR)
	_build_nightstand()
	# каталка: выкатывается из тёмного кабинета прямо перед коляской
	await until(func(): return ppos().x > 40.6 and ppos().z < -6.6 and ppos().z > -9.6 and ppos().y < 2.5)
	_gurney_scare()
	await until(func(): return room_id() == "L0.F14" or has_lift_key)
	if not has_lift_key:
		objective("Найди ключ от лифта", NIGHTSTAND_POS, Vector3(0, 0.8, 0))


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
	psycho.strike(Vector3(43.5, 2.1, -6.55), "hit", 0.35)
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
	await say("hero", "Кто это?.. Что этой твари от меня надо?..")
	_act2_return()


func _act2_return() -> void:
	act = "lift_key"
	GameState.checkpoint = "chase"
	objective("Вернись к лифту и поднимись на 2-й этаж", LIFT_CALL)
	chase = "off"
	# вызвал лифт (двери уже открываются) — тогда и появляется он: время доехать до кабины есть
	await until(func(): return ppos().y < 2.5 and lift.state in ["opening", "open"] and lift.floor_idx == 0 \
		and near(Vector3(37.5, 1.2, -7.0), 7.0))
	_start_chase()


# ================================================================================ погоня у лифта
## Погоня: свет в коридоре гаснет — когда загорается, в конце коридора стоит он и смотрит. Ещё раз темнота —
## он уже ближе. Крик — и бежит; свет мигает, всё громче шаги и сердце. Успей вызвать лифт, заехать и нажать «2».
func _start_chase() -> void:
	act = "chase"
	var retry: bool = GameState.deaths > 0
	_psycho_speed = PSYCHO_SPEED - 0.25 * mini(GameState.deaths, 3)
	_drone.volume_db = -14.0
	objective("Быстрее в лифт!", Vector3(37.5, 1.2, -5.2), Vector3(0, 1.3, 0))
	_auto_lift()
	await _corridor_flicker(3 if not retry else 1)
	game.lights.set_room("L0.C", false)
	game.play_at("flicker", Vector3(50.0, 3.6, -8.1), 0.0, 0.7, 60.0)
	psycho.visible = true
	psycho.global_position = PSYCHO_FAR
	psycho.face(ppos(), true)
	psycho.play("idle_loop", 0.0)
	psycho.set_look(player.head.global_position)
	await wait(0.9 if not retry else 0.5)
	game.lights.set_room("L0.C", true)
	if _chase_over():
		return
	if not retry:
		look_at_point(psycho.head_pos(), 0.6)          # первый раз — сам поворачиваешься на дыхание
	snd("stinger", null, -4.0, 0.8)
	snd("breathing", PSYCHO_FAR + Vector3(0, 1.6, 0), 6.0, 0.75, 45.0)
	_heartbeat_burst(3)
	await wait(1.5 if not retry else 0.9)
	if _chase_over():
		return
	game.lights.set_room("L0.C", false)
	await wait(0.45 if not retry else 0.3)
	psycho.global_position = PSYCHO_NEAR
	psycho.face(ppos(), true)
	game.lights.set_room("L0.C", true)
	snd("stinger", null, -8.0, 1.2)
	await wait(0.75 if not retry else 0.5)
	if _chase_over():
		return
	psycho.set_look(null)
	snd("psycho_roar", psycho.head_pos(), 9.0, 1.0, 60.0)
	ui.say("psycho", "Это ты был в моей комнате?! Стой!!", 2.6)
	psycho.play("run_loop", 0.15, _psycho_speed / 3.4)
	_after_line(2.6, "hero", "Чёрт, чёрт, чёрт!", 1.8)
	_strobe_t = 0.2
	chase = "run"


## В погоне: заехал в кабину — Азиз сам доезжает до середины (иначе двери упираются в коляску)
## и жмёт «2»; если двери почему-то снова открылись — жмёт ещё раз.
func _auto_lift() -> void:
	var pressed := false
	while act == "chase" and not (lift.state == "moving" and lift.player_in_cabin()):
		await get_tree().physics_frame
		if chase == "caught" or not lift.player_in_cabin() or lift.floor_idx != 0:
			continue
		if ppos().z < -5.35:
			var goal := Vector3(37.5, ppos().y, -5.15)
			var tw := create_tween()
			tw.tween_property(player, "global_position", goal, 0.45).set_ease(Tween.EASE_OUT)
			await tw.finished
		if lift.state in ["open", "opening"] and not (1 in lift.queue):
			if not pressed:
				await wait(0.15)
			lift.request(1)
			if not pressed:
				game.play_at("button", Vector3(38.3, 2.2, -5.2), -4.0, 1.0, 8.0)
			pressed = true


## Уже уехал на лифте, пока он показывался, — дальше не бежит (на 2-м этаже его нет).
func _chase_over() -> bool:
	if act == "chase" and not (lift.player_in_cabin() and lift.state == "moving"):
		return false
	psycho.set_look(null)
	if act != "chase":
		psycho.visible = false
		psycho.stop()
	else:
		chase = "safe"                 # двери уже закрылись: бьёт в них, пока лифт уходит
	game.lights.set_room("L0.C", true)
	return true


func _chase_target() -> Vector3:
	var p: Vector3 = ppos()
	var in_cab: bool = lift.player_in_cabin()
	if in_cab or (p.x > 36.0 and p.x < 39.0 and p.z > -6.9):
		if psycho.global_position.z < -6.8 and absf(psycho.global_position.x - 37.5) > 0.4:
			return Vector3(37.5, 1.2, -7.4)
		return Vector3(37.5, 1.2, p.z)
	return Vector3(p.x, 1.2, clampf(p.z, -9.3, -6.9)) if p.z < -6.6 else p


func _update_chase(dt: float) -> void:
	var safe: bool = lift.player_in_cabin() and (lift.state == "moving" or (lift.state in ["closing", "closed"] and lift.open_f < 0.8))
	var target: Vector3 = Vector3(37.5, 1.2, -7.15) if safe else _chase_target()
	var to: Vector3 = target - psycho.global_position
	to.y = 0.0
	var step: float = _psycho_speed * dt
	var dist: float = psycho.global_position.distance_to(ppos())
	_heartbeat(dt, clampf(1.0 - dist / 25.0, 0.0, 1.0))
	# свет в коридоре дёргается, пока он бежит; чем ближе — тем сильнее трясёт картинку
	_strobe_t -= dt
	if _strobe_t <= 0.0 and not safe:
		var on: bool = not game.lights.is_on("L0.C")
		game.lights.set_room("L0.C", on)
		_strobe_t = randf_range(0.25, 0.9) if on else randf_range(0.05, 0.16)
	var k: float = clampf(1.0 - dist / 9.0, 0.0, 1.0) * (0.0 if safe else 1.0)
	player.view_offset = Transform3D(Basis.from_euler(Vector3(randf_range(-1, 1) * 0.008, randf_range(-1, 1) * 0.006,
		randf_range(-1, 1) * 0.01) * k), Vector3.ZERO)
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
			game.lights.set_room("L0.C", true)
			player.view_offset = Transform3D.IDENTITY
			snd("psycho_shout", Vector3(37.5, 2.2, -6.8), 6.0, 0.95, 30.0)
			ui.say("psycho", "Открой!! Открой, я сказал!!", 2.2)
		_psycho_bang_t -= dt
		if _psycho_bang_t <= 0.0:
			_psycho_bang_t = 0.75
			psycho.strike(Vector3(37.5, 2.2, -6.62), "hit", 0.4)
			snd("metal_bang", Vector3(37.5, 2.2, -6.6), 0.0, randf_range(0.9, 1.15), 25.0)
		return
	if not safe and Vector2(ppos().x - psycho.global_position.x, ppos().z - psycho.global_position.z).length() < 1.15:
		chase = "caught"
		game.lights.set_room("L0.C", true)
		_caught()


var _hb_t := 0.0
var _strobe_t := 0.0


## Сердцебиение Азиза: чем ближе опасность (0..1), тем чаще и громче.
func _heartbeat(dt: float, fear: float) -> void:
	if fear <= 0.05:
		return
	_hb_t -= dt
	if _hb_t <= 0.0:
		_hb_t = lerpf(0.95, 0.42, fear)
		snd("heartbeat", null, lerpf(-14.0, 0.0, fear), 1.0)


## Псих догнал: бьёт (как в анимации), Азиз отлетает, падает на пол, темнота — заново у кабинета с ключом.
func _caught() -> void:
	freeze(true)
	GameState.deaths += 1
	psycho.face(ppos(), true)
	psycho.strike(func() -> Vector3: return player.head.global_position, "hit", 0.62)
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
		game.lights.set_room("L0.C", true)
		player.view_offset = Transform3D.IDENTITY


func _on_lift_arrived(f: int) -> void:
	if act == "chase" and f == 1:
		_act3()


# ================================================================================ АКТ 3: пустая комната, радио
func _act3() -> void:
	act = "void"
	mom.visible = false                               # мама появляется только по сюжету (и при старте с главы)
	GameState.checkpoint = "void"
	_drone.volume_db = -18.0
	lift.forced_floor = -1
	lift.locked = true
	lift.lock_text = "Кнопки не реагируют…"
	if GameState.fade_target() > 0.5:
		await GameState.fade_to(0.0, 1.5)
	await wait(1.2)
	await say("thought", "Какого хрена… Где всё? Тут же были палаты… Осталась одна дверь.")
	objective("Найди палату деда — №204", ROOM204_DOOR + Vector3(0, 0, -0.3))
	await until(func(): return room_id() == "L1.F2")
	# в палате — бумаги деда: про маму, про него самого и его записка про это место
	objective("Осмотри палату деда")
	_place_notes()
	_build_faceless()                                 # толпа готовится заранее (невидимая) — без рывка в погоне
	await wait(1.0)
	await say("thought", "Его вещи… На столе и на кровати какие-то бумаги. Надо посмотреть.")
	await until(func(): return _notes_read.has("diary") or (_notes_read.size() >= 2 and not _note_open), 240.0)
	while _note_open:
		await get_tree().process_frame
	objective("")
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
	await say("thought", "Никого. Мама говорила — третий этаж.")
	objective("Вернись к лифту")
	await until(func(): return ppos().z < -6.9 and absf(ppos().y - 4.5) < 1.0)   # вышел из палаты в пустоту
	await _faceless_chase()


## Бумаги деда в палате 204. [заголовок, точка на поверхности мебели (высоты сняты с модели здания: коллайдер
## кровати — коробка до верха изголовья, по нему лист висел в воздухе), текст, текстура,
## поворот]. Текст тот же, что нарисован на бумаге (tools/godot_assets/make_note_textures.py).
const NOTES := {
	"mom": ["Выписка из истории болезни (в папке «Дело»)", Vector3(6.36, 5.25, -3.3),
		"Больная: Дилором Анваровна К., 34 года.\n" +
		"Диагноз: болезнь Альцгеймера, ранняя форма.\n\n" +
		"Анамнез: в 1972 г. муж (Рустам) ушёл из семьи. После этого — бессонница, тяжёлый стресс. " +
		"Через год появились провалы в памяти: забывает слова и дорогу домой, путает годы, не узнаёт соседей. " +
		"Со слов отца, однажды не узнала его самого.\n\n" +
		"Когда её поправляют — вспышки гнева, агрессия.\n\n" +
		"В таком возрасте болезнь встречается редко. Прогноз неблагоприятный.\n" +
		"Рекомендовано: наблюдение невропатолога. Одну не оставлять.",
		"note_typed", 0.12],
	"anvar": ["Направление на санаторно-курортное лечение", Vector3(7.36, 5.22, -1.05),
		"Каримов Анвар Каримович, 74 года.\n\n" +
		"Диагноз: стенокардия; невроз после смерти жены. Бессонница, отказывается от еды.\n\n" +
		"Санаторий «Оромгох», 2 этаж, палата 204. Срок — 45 дней.\n\n" +
		"Родные: дочь Дилором; внук Азиз, 16 лет (на коляске).\n\n" +
		"Особая отметка: острые предметы из палаты убрать.",
		"note_form", -0.35],
	"diary": ["Записка карандашом (почерк деда)", Vector3(11.05, 5.065, -1.62),
		"Дилором опять не узнала меня по телефону. Спросила, кто говорит. Врач сказал — Альцгеймер, " +
		"в тридцать четыре так почти не бывает. А у неё бывает. Рустам ушёл — не выдержал. " +
		"Я его понимаю, и мне стыдно, что понимаю.\n" +
		"Азиза она пока помнит. Пока.\n\n" +
		"Здесь никто не спит. Ночью кто-то идёт по коридору и стучит в каждую дверь — три раза. " +
		"Я считаю двери. До моей он ещё не дошёл.\n\n" +
		"Санитар говорит, в 139-й давно никого нет. Я спросил, кто же там тогда кричит. " +
		"Он засмеялся и выключил мне свет.\n\n" +
		"Я устал. Если утром меня найдут — не будите. Пусть Азиз меня таким не видит.\n— А.",
		"note_pencil", 1.35],
}
var _notes_read := {}
var _note_open := false


## Бумаги лежат на настоящей поверхности (луч сверху вниз находит стол, тумбочку, кровать): листы с текстом,
## выписка — на картонной папке. Уголок листа чуть приподнимается от сквозняка — глаз за это цепляется.
func _place_notes() -> void:
	for key in NOTES:
		var n: Array = NOTES[key]
		var top: Vector3 = n[1]
		var holder := Node3D.new()
		game.add_child(holder)
		holder.global_position = top + Vector3(0, 0.006, 0)
		holder.rotation.y = float(n[4])
		if key == "mom":                                   # папка под выпиской
			_paper(holder, "note_folder", Vector2(0.24, 0.33), Vector3(-0.012, -0.002, 0.01), 0.0)
		var sheet: Node3D = _paper(holder, String(n[3]), Vector2(0.21, 0.297), Vector3.ZERO, 0.0)
		_flutter(sheet)
		var it: Area3D = Interactable.new()
		holder.add_child(it)
		it.setup(Vector3(0.4, 0.25, 0.45), "[E] Прочитать", _read_note.bind(key))


## Лист бумаги с текстурой: шарнир у дальнего края (для сквозняка), плоскость лицом вверх.
func _paper(parent: Node3D, tex: String, size: Vector2, offset: Vector3, yaw: float) -> Node3D:
	var pivot := Node3D.new()
	parent.add_child(pivot)
	pivot.position = offset + Vector3(0, 0, -size.y * 0.5)
	pivot.rotation.y = yaw
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = size
	mi.mesh = pm
	var m := StandardMaterial3D.new()
	var path := "res://story/notes/%s.jpg" % tex
	if ResourceLoader.exists(path):
		m.albedo_texture = load(path)
	else:
		m.albedo_color = Color(0.86, 0.83, 0.74)
	m.roughness = 0.92
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pivot.add_child(mi)
	mi.position = Vector3(0, 0, size.y * 0.5)
	return pivot


func _flutter(sheet: Node3D) -> void:
	var tw := create_tween().set_loops()
	tw.tween_interval(randf_range(2.0, 4.5))
	tw.tween_property(sheet, "rotation:x", deg_to_rad(-2.5), 0.6).set_trans(Tween.TRANS_SINE)
	tw.tween_property(sheet, "rotation:x", 0.0, 0.9).set_trans(Tween.TRANS_SINE)


func _read_note(key: String) -> void:
	if _note_open:
		return
	_note_open = true
	freeze(true)
	snd("cloth_tear", null, -14.0, 1.9)                 # шорох бумаги
	await ui.note(NOTES[key][0], NOTES[key][2])
	_notes_read[key] = true
	freeze(false)
	_note_open = false


# ================================================================================ безликие (конец акта 3)
## Азиз выезжает из палаты в пустоту — из темноты сзади бегут 15–20 психов без лиц. У открытого лифта ждёт
## мама. Успел — двери закрываются перед ними, они бьют в двери, лифт едет на 3-й. Догнали — темнота, заново
## от двери палаты 204.
const FACELESS_N := 16
const VOID_LIFT := Vector3(37.5, 4.5, -7.05)         # перед дверями лифта (пустой 2-й этаж)
const CAB_CORNER := Vector3(36.95, 0.0, -4.55)       # мама в кабине — в дальнем левом углу (y — от пола кабины)
const CAB_DOOR := Vector3(37.5, 0.0, -6.45)          # мама в проёме кабины
const VOID_RESTART := Vector3(8.83, 4.5, -7.6)       # заново — у двери палаты 204, лицом к лифту
var _faceless: Array = []
var _eggs: Array = []
var _crowd: Array = []
var faceless_state := "off"       # off, run, door, caught
var _mom_ride := false            # мама едет в кабине: её высота — по полу кабины
var _hold_lift := false           # сюжет держит двери лифта открытыми
var _bang_t2 := 0.0
var _chase_lamps: Array = []
var _strobe_t := 0.0
## Блоки пустого этажа (лестницы, палата деда): толпа их обходит, а не проходит насквозь. [x0, z0, x1, z1]
const VOID_BLOCKS := [[3.0, -15.8, 9.0, -9.6], [6.0, -6.6, 12.0, -0.3], [30.0, -6.6, 39.0, -0.3], [66.0, -15.8, 72.0, -9.6]]


func _build_faceless() -> void:
	if not _faceless.is_empty():
		return
	var bodies := ["res://characters/psycho.glb", "res://characters/younger.glb", "res://characters/grandpa.glb"]
	for i in FACELESS_N:
		var a = Actor.new()
		a.name = "Безликий%d" % i
		game.add_child(a)
		a.setup(bodies[i % bodies.size()], randf_range(0.94, 1.05))
		a.natural = {"walk_loop": 1.3, "run_loop": 3.6}
		a.step_volume = -80.0
		_eggs.append(Props.faceless(a))
		a.visible = false
		a.set_meta("spd", randf_range(2.45, 2.85))
		a.set_meta("slot", Vector3(randf_range(-1.8, 1.8), 0.0, randf_range(-1.3, 1.3)))
		_faceless.append(a)
	# свет погони: две холодные лампы над тёмной частью зала мигают — видно толпу; одна у лифта
	for lp in [Vector3(2.2, 6.9, -3.6), Vector3(2.6, 6.9, -9.0), Vector3(37.5, 6.7, -8.4)]:
		var l := OmniLight3D.new()
		l.light_color = Color(0.72, 0.82, 1.0)
		l.omni_range = 7.5 if lp.x < 10.0 else 4.5
		l.omni_attenuation = 1.2
		l.light_energy = 0.0
		l.visible = false
		l.set_meta("base", 1.3 if lp.x < 10.0 else 0.7)
		game.add_child(l)
		l.global_position = lp
		_chase_lamps.append(l)


func _chase_lights(on: bool) -> void:
	for l in _chase_lamps:
		(l as OmniLight3D).visible = on
		(l as OmniLight3D).light_energy = 0.0


## Топот и хрипы толпы (свой звук crowd_run.wav — если есть, иначе несколько слоёв бега).
func _crowd_sound(on: bool) -> void:
	for p in _crowd:
		if is_instance_valid(p):
			p.queue_free()
	_crowd.clear()
	if not on:
		return
	var custom: bool = ResourceLoader.exists("res://story/sfx/crowd_run.wav")
	for i in (2 if custom else 4):
		var p := AudioStreamPlayer3D.new()
		p.stream = stream("crowd_run" if custom else "run_steps", true)
		p.pitch_scale = randf_range(0.85, 1.15)
		p.volume_db = 4.0
		p.unit_size = 4.0
		p.max_distance = 45.0
		p.bus = "World"
		(_faceless[(i * 3) % _faceless.size()] as Node3D).add_child(p)
		p.position = Vector3(0, 1.0, 0)
		p.play(randf() * 1.5)
		_crowd.append(p)
	var b := AudioStreamPlayer3D.new()
	b.stream = stream("breathing", true)
	b.volume_db = 6.0
	b.unit_size = 3.0
	b.bus = "World"
	(_faceless[1] as Node3D).add_child(b)
	b.position = Vector3(0, 1.6, 0)
	b.play()
	_crowd.append(b)


func _faceless_chase() -> void:
	act = "faceless"
	_build_faceless()
	lift.locked = false
	lift.forced_floor = 2
	if not (lift.floor_idx == 1 and lift.state in ["open", "opening"]):
		lift.park_open(1)
	_hold_lift = true
	_mom_ride = false
	mom.stop()
	mom.step_volume = -8.0
	mom.global_position = Vector3(CAB_DOOR.x, 4.5, CAB_DOOR.z)
	mom.face(ppos(), true)
	mom.play("idle_loop", 0.0)
	mom.visible = true
	var p: Vector3 = ppos()
	for a in _faceless:
		var sp := Vector3(clampf(p.x - randf_range(7.5, 12.5), 0.8, 70.0), 4.5, clampf(p.z - randf_range(0.5, 2.0), -9.2, -7.0))
		for k in 40:                                  # тёмная часть зала за спиной: не ближе 7 м и не в блоке
			var c := Vector3(randf_range(0.8, 5.6), 4.5, randf_range(-1.0, -9.2))
			if c.distance_to(Vector3(p.x, 4.5, p.z)) >= 7.0 and not _in_block(c, 0.4):
				sp = c
				break
		a.global_position = sp
		a.face(p, true)
		a.visible = true
		a.play("run_loop", 0.0, 0.75)
	_crowd_sound(true)
	_chase_lights(true)
	_strobe_t = 0.0
	game.play_at("flicker", Vector3(2.4, 6.9, -6.0), 2.0, 0.8, 30.0)
	snd("stinger", null, -2.0, 0.85)
	if player.speed_level < 3:
		player.speed_level = 3
		game.hud.set_speed(3, 5)
	faceless_state = "run"
	_drone.volume_db = -10.0
	objective("Быстрее в лифт!")
	ui.hint("R — быстрее   ·   Q — медленнее", 4.0)
	look_at_point((_faceless[0] as Node3D).global_position + Vector3(0, 1.5, 0), 0.45)
	await say("hero", "Чёрт! Чёрт, чёрт!", 1.8)
	if faceless_state != "run":
		return
	mom.set_look(player.head.global_position)
	ui.say("mom", "Быстрее, Азиз! Двигайся!", 2.4)
	await until(func(): return faceless_state != "run" or ppos().distance_to(VOID_LIFT) < 3.5)
	if faceless_state != "run":
		return
	mom.set_look(null)
	mom.go([Vector3(CAB_CORNER.x, 4.5, CAB_CORNER.z)], 1.6)
	await until(func(): return faceless_state != "run" or lift.player_in_cabin())
	if faceless_state != "run":
		return
	faceless_state = "door"
	objective("")
	player.view_offset = Transform3D.IDENTITY
	# кнопку Азиз жмёт, когда толпа уже близко: двери закрываются прямо перед ними
	await until(func(): return _nearest_faceless(VOID_LIFT) < 4.0, 2.5)
	await _cab_center_and_go(2)
	await until(func(): return lift.state == "moving")
	_mom_ride = true
	await wait(1.6)
	faceless_state = "off"
	for a in _faceless:
		a.visible = false
		a.stop()
	_crowd_sound(false)
	_chase_lights(false)
	_drone.volume_db = -18.0
	await say("hero", "Мам, что это было?!")
	mom.face(ppos())
	mom.set_look(player.head.global_position)
	await say("mom", "Даже не знаю. Я видела дедушку на третьем этаже. Надо к нему подняться — и уезжать отсюда, побыстрее.")
	await until(func(): return lift.floor_idx == 2 and lift.state in ["opening", "open"])
	_mom_ride = false
	mom.global_position.y = 7.8
	_hold_lift = true
	GameState.checkpoint = "floor3"
	await _mom_vanishes()


## Заехал в кабину: Азиз сам доезжает до середины (иначе двери упираются в коляску) и жмёт кнопку этажа.
func _cab_center_and_go(f: int) -> void:
	_hold_lift = false
	freeze(true)
	var goal := Vector3(37.5, ppos().y, -5.15)
	if ppos().distance_to(goal) > 0.15:
		var tw := create_tween()
		tw.tween_property(player, "global_position", goal, 0.45).set_ease(Tween.EASE_OUT)
		await tw.finished
	await wait(0.2)
	game.play_at("button", Vector3(38.3, ppos().y + 1.0, -5.2), -4.0, 1.0, 8.0)
	lift.locked = false
	lift.forced_floor = f
	lift.request(f)
	await until(func(): return lift.state == "moving", 8.0)
	freeze(false)


## Безликий догнал: удар, падение, темнота — заново от двери палаты 204.
func _faceless_caught() -> void:
	faceless_state = "caught"
	freeze(true)
	GameState.deaths += 1
	snd("psycho_roar", ppos() + Vector3(0, 1.4, 0), 6.0, 1.2)
	snd("slap", null, 4.0, 0.9)
	ui.flash(Color(0.8, 0.0, 0.0, 0.85), 0.6)
	var fall := create_tween()
	fall.tween_property(player, "view_offset", Transform3D(Basis.from_euler(Vector3(0.5, 0.3, 0.6)), Vector3(0.1, -0.3, 0.2)), 0.35)
	fall.tween_property(player, "view_offset", Transform3D(Basis.from_euler(Vector3(0.35, 0.2, 1.35)), Vector3(0.25, -0.95, 0.3)), 0.45).set_ease(Tween.EASE_IN)
	await fall.finished
	snd("body_fall", null, 2.0, 0.7)
	ui.set_damage(0.6)
	await GameState.fade_to(1.0, 1.6)
	_crowd_sound(false)
	_chase_lights(false)
	for a in _faceless:
		a.visible = false
		a.stop()
	mom.visible = false
	ui.set_damage(0.0)
	player.view_offset = Transform3D.IDENTITY
	place_player(VOID_RESTART, -PI * 0.5)
	freeze(false)
	await wait(0.8)
	await GameState.fade_to(0.0, 1.2)
	await wait(0.6)
	_faceless_chase()


func _update_faceless(dt: float) -> void:
	var at_door: bool = faceless_state == "door"
	var p: Vector3 = ppos()
	var nearest := 99.0
	for i in _faceless.size():
		var a = _faceless[i]
		var slot: Vector3 = a.get_meta("slot")
		var tgt: Vector3 = VOID_LIFT + Vector3(slot.x * 0.55, 0.0, -0.25 - absf(slot.z) * 0.9) if at_door else p + slot * 0.6
		tgt.y = 4.5
		var to: Vector3 = tgt - a.global_position
		to.y = 0.0
		for b in _faceless:
			if b != a:
				var dd: Vector3 = a.global_position - b.global_position
				dd.y = 0.0
				var l: float = dd.length()
				if l < 0.65 and l > 0.001:
					to += dd / l * (0.65 - l) * 2.5
		var spd: float = a.get_meta("spd")
		var dist: float = to.length()
		if dist > 0.12:
			var np: Vector3 = a.global_position + to / dist * minf(spd * dt, dist)
			if np.x > 29.5 and np.x < 39.6:
				np.z = minf(np.z, -6.85)             # в кабину и в шахту — нельзя
			np.x = clampf(np.x, 0.7, 74.3)
			np.z = clampf(np.z, -15.5, -0.6)
			np = _out_of_blocks(np, 0.35)
			a.global_position = np
			a.face(np + to)
			a.play("run_loop", 0.2, spd / 3.6)
		elif at_door:
			a.face(Vector3(a.global_position.x, 4.5, -5.0))
			a.play("idle_loop", 0.3)
		nearest = minf(nearest, Vector2(a.global_position.x - p.x, a.global_position.z - p.z).length())
		var egg: MeshInstance3D = _eggs[i]
		egg.global_position = a.head_pos() + Vector3(0, 0.02, 0)
		egg.rotation.y = a.rotation.y
	_strobe_t -= dt
	if _strobe_t <= 0.0:                              # лампы погони: то горят, то гаснут
		_strobe_t = randf_range(0.05, 0.35)
		for l in _chase_lamps:
			var on: bool = randf() < (0.8 if l.global_position.x > 10.0 else 0.6)
			(l as OmniLight3D).light_energy = (l.get_meta("base") as float) * (randf_range(0.7, 1.0) if on else 0.0)
	if at_door:
		_bang_t2 -= dt
		if _bang_t2 <= 0.0 and lift.state != "moving":
			_bang_t2 = randf_range(0.18, 0.4)
			var a2 = _faceless[randi() % _faceless.size()]
			if a2.global_position.distance_to(VOID_LIFT) < 2.0:
				a2.strike(Vector3(a2.global_position.x, 5.9, -6.62), "hit", 0.4)
			snd("metal_bang", Vector3(37.5 + randf_range(-0.6, 0.6), 5.7, -6.6), randf_range(-4.0, 2.0), randf_range(0.85, 1.2), 25.0)
		return
	_heartbeat(dt, clampf(1.0 - nearest / 14.0, 0.0, 1.0))
	var k: float = clampf(1.0 - nearest / 8.0, 0.0, 1.0)
	player.view_offset = Transform3D(Basis.from_euler(Vector3(randf_range(-1, 1) * 0.006, randf_range(-1, 1) * 0.005,
		randf_range(-1, 1) * 0.008) * k), Vector3.ZERO)
	if faceless_state == "run" and nearest < 1.05 and not lift.player_in_cabin():
		_faceless_caught()


func _in_block(p: Vector3, m: float) -> bool:
	for b in VOID_BLOCKS:
		if p.x > b[0] - m and p.x < b[2] + m and p.z > b[1] - m and p.z < b[3] + m:
			return true
	return false


## Точка внутри блока — вытолкнуть к ближайшему краю (толпа скользит вдоль стены).
func _out_of_blocks(p: Vector3, m: float) -> Vector3:
	for b in VOID_BLOCKS:
		var x0: float = b[0] - m
		var z0: float = b[1] - m
		var x1: float = b[2] + m
		var z1: float = b[3] + m
		if p.x > x0 and p.x < x1 and p.z > z0 and p.z < z1:
			var dx0: float = p.x - x0
			var dx1: float = x1 - p.x
			var dz0: float = p.z - z0
			var dz1: float = z1 - p.z
			var mn: float = minf(minf(dx0, dx1), minf(dz0, dz1))
			if mn == dx0:
				p.x = x0
			elif mn == dx1:
				p.x = x1
			elif mn == dz0:
				p.z = z0
			else:
				p.z = z1
	return p


func _nearest_faceless(to: Vector3) -> float:
	var n := 99.0
	for a in _faceless:
		n = minf(n, Vector2(a.global_position.x - to.x, a.global_position.z - to.z).length())
	return n


## 3-й этаж: «Стой здесь…» — мама выходит, сворачивает за угол и исчезает. В кабине — «[E] Позвать маму»:
## тишина, сколько ни зови. Что её нет, видно, только когда выезжаешь: коридор пуст в обе стороны.
func _mom_vanishes() -> void:
	act = "f3_call"
	await wait(0.6)
	mom.face(ppos())
	await say("mom", "Стой здесь. Я быстро осмотрюсь — потом выйдешь.")
	mom.set_look(null)
	freeze(true)
	mom.go([Vector3(36.85, 7.8, -5.7), Vector3(37.05, 7.8, -6.8), Vector3(36.9, 7.8, -7.6), Vector3(36.3, 7.8, -8.1), Vector3(32.5, 7.8, -8.1)], 1.15)
	await until(func(): return mom.global_position.x < 35.7 or not mom.is_moving(), 12.0)
	mom.visible = false
	mom.stop()
	freeze(false)
	lift.locked = true
	lift.forced_floor = -1
	lift.lock_text = "Сначала найди маму"
	objective("")
	var call: Area3D = Interactable.new()
	lift.cabin.add_child(call)
	call.global_position = Vector3(37.5, 7.8 + 1.25, -6.3)
	var calls := [0]
	call.setup(Vector3(1.2, 1.6, 0.12), "[E] Позвать маму", func():
		calls[0] += 1
		var lines := ["Мам?!", "Мама!", "Мам, ты где?!", "Мам!.."]
		ui.say("hero", lines[mini(calls[0] - 1, lines.size() - 1)], 1.8))
	await until(func(): return not lift.player_in_cabin() and ppos().z < -6.75)
	call.queue_free()
	_hold_lift = false
	await wait(0.6)
	await say("thought", "Где она? Как она исчезла? Что тут, блин, происходит?")
	await say("thought", "Мне этот грёбаный санаторий с самого начала не понравился.")
	_act4()


# ================================================================================ АКТ 4: третий этаж
func _act4(after_brothers := false) -> void:
	act = "floor3_search"
	mom.visible = false                               # мама появляется только по сюжету (и при старте с главы)
	GameState.checkpoint = "floor3b" if after_brothers else "floor3"
	if GameState.fade_target() > 0.5:
		await GameState.fade_to(0.0, 1.5)
	if game.critters:
		game.critters.visible = true
	lift.forced_floor = -1
	lift.locked = true
	lift.lock_text = "Сначала найди маму"
	objective("Найди маму на 3-м этаже")
	_drone.volume_db = -16.0
	if not after_brothers:
		scares.start(self)
		await until(func(): return scares.elapsed > 70.0 and scares.count >= 3, 110.0)   # минута-полторы
		scares.stop()
		await _brothers()
	await _mom_returns()
	await _room_scare()
	await _ride_to_two()


## Мама возвращается: через полминуты поисков беззвучно идёт за коляской, чуть сбоку. Не заметишь, пока не
## обернёшься (или она сама не позовёт).
func _mom_returns() -> void:
	act = "mom_back"
	objective("Найди маму на 3-м этаже")
	scares.start(self)
	await until(func(): return room_id() == "L2.C", 120.0)
	await wait(28.0)
	scares.stop()
	await until(func(): return room_id() == "L2.C", 90.0)
	mom.step_volume = -80.0
	mom.stop()
	mom.set_look(null)
	mom.global_position = _behind(2.8)
	mom.face(ppos(), true)
	mom.play("idle_loop", 0.0)
	mom.visible = true
	var t := 0.0
	var seen := false
	while not seen:
		await get_tree().process_frame
		if get_tree().paused:
			continue
		var dt: float = get_process_delta_time()
		t += dt
		var goal: Vector3 = _behind(1.7)
		var to: Vector3 = goal - mom.global_position
		to.y = 0.0
		var dist: float = to.length()
		if dist > 0.2:
			var v: float = minf(dist * 1.6, 2.2)
			mom.global_position += to / dist * minf(v * dt, dist)
			mom.face(mom.global_position + to)
			mom.play("walk_loop", 0.3, clampf(v / 1.24, 0.5, 1.6))
		else:
			mom.face(ppos())
			mom.play("idle_loop", 0.4)
		var cam_f: Vector3 = -player.cam.global_transform.basis.z
		var to_m: Vector3 = mom.head_pos() - player.cam.global_position
		if to_m.length() < 5.0 and cam_f.dot(to_m.normalized()) > 0.8:
			seen = true
		elif t > 45.0:
			ui.say("mom", "Азиз.", 1.6)
			seen = true
	mom.step_volume = -8.0
	freeze(true)
	mom.stop()
	mom.face(ppos())
	snd("stinger", null, -12.0, 1.1)
	await look_at_point(mom.head_pos(), 0.35)
	mom.set_look(player.head.global_position)
	objective("")
	await say("hero", "Мам, ты где была?!")
	await say("mom", "Ты же сказал, что отвезёшь нас к дедушке. Где твой дедушка?")
	await wait(1.0)
	await say("hero", "Он, наверное, на втором этаже. Я тоже его ищу.")
	await say("mom", "Ты какой-то странный. Устал, что ли?")
	await say("hero", "Да… наверное.")
	mom.set_look(null)
	freeze(false)


## Точка за коляской (k м назад, чуть вправо), в пределах коридора 3-го этажа.
func _behind(k: float) -> Vector3:
	var b: Basis = player.global_transform.basis
	var p: Vector3 = ppos() + b.z.normalized() * k + b.x.normalized() * 0.45
	if room_id() == "L2.C":
		p.z = clampf(p.z, -9.35, -6.85)
	p.x = clampf(p.x, 1.0, 74.0)
	p.y = 7.8
	return p


## По дороге к лифту из палаты — странный звук. Мама заходит туда и молчит; Азиз заглядывает — она выскакивает
## на него из темноты. [группа дверей, комната, точка внутри]: процедурная 313, ординаторская 317, палата 321 —
## та, что по пути от мамы к лифту.
const SCARE_ROOMS := [[167, "L2.R10", Vector3(31.45, 7.8, -12.0)], [146, "L2.F13", Vector3(40.4, 7.8, -4.2)],
	[173, "L2.R14", Vector3(45.6, 7.8, -11.0)]]


func _room_scare() -> void:
	act = "room_scare"
	objective("Иди с мамой к лифту")
	var mx: float = mom.global_position.x
	var pick: Array = SCARE_ROOMS[0] if mx < 32.0 else (SCARE_ROOMS[1] if mx < 40.6 else SCARE_ROOMS[2])
	var d = door(int(pick[0]))
	var room: String = pick[1]
	var inside: Vector3 = pick[2]
	var dc: Vector3 = d.center if d else inside
	dc.y = 7.8
	var near_door := Vector3(dc.x, 7.8, -8.1 + (0.45 if dc.z > -8.1 else -0.45))
	if d:
		d.set_angle(0.0)
		d.locked = false
	game.lights.set_room(room, false)
	await mom.go_and_wait([Vector3(mom.global_position.x, 7.8, -8.1), near_door], 1.1)
	snd("metal_creak", inside + Vector3(0, 1.0, 0), 2.0, 0.8, 20.0)
	await wait(0.5)
	snd("knock", inside + Vector3(0, 1.2, 0), -2.0, 0.7, 20.0)
	mom.face(dc)
	await until(func(): return ppos().distance_to(near_door) < 4.0, 40.0)
	mom.face(ppos())
	mom.set_look(player.head.global_position)
	await say("mom", "Стоп. Что это было? Тихо. Проверим — иди за мной.")
	await say("hero", "Мам, не надо. Пошли отсюда.")
	mom.set_look(null)
	if d:
		mom.face(dc)
		await wait(0.3)
		game.play_at("door_open_wood", dc, -4.0, 0.9, 20.0)
		d.swing_to(90.0, 1.0)
		await wait(0.6)
	await mom.go_and_wait([dc, inside], 1.0)
	mom.visible = false                                # в темноте — тишина, не отзывается
	mom.stop()
	objective("Загляни в палату")
	await until(func(): return room_id() == room or Vector2(ppos().x - dc.x, ppos().z - dc.z).length() < 1.3)
	# скример: выскакивает из темноты прямо перед ним
	freeze(true)
	var fwd: Vector3 = -player.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	mom.global_position = Vector3(ppos().x, 7.8, ppos().z) + fwd * 0.95
	mom.face(ppos(), true)
	mom.visible = true
	mom.play_once("attack", 0.0, 1.4)
	mom.set_look(player.head.global_position)
	snd("stinger", null, 6.0, 1.0)
	snd("mom_scream", mom.head_pos(), 6.0, 1.05)
	ui.flash(Color(1.0, 1.0, 1.0, 0.5), 0.25)
	shake(1.2, 0.5)
	await look_at_point(mom.head_pos(), 0.12)
	await wait(0.7)
	await say("hero", "Твою ж мать!! Ты чё творишь?!")
	mom.play("idle_loop", 0.4)
	await say("mom", "Тише, тише. Первый раз в жизни испугался? Пошли.")
	mom.set_look(null)
	freeze(false)


## Вместе в лифт: Азиз жмёт «2». Внизу — обычный второй этаж (пустоты больше нет).
func _ride_to_two() -> void:
	act = "f3_lift"
	objective("Поезжай с мамой на лифте на 2-й этаж")
	lift.locked = false
	lift.forced_floor = 1
	if lift.floor_idx == 2:
		lift.open_here()
	else:
		lift.park_open(2)
	_hold_lift = true
	mom.go([Vector3(37.5, 7.8, -7.5), Vector3(37.5, 7.8, -5.9), Vector3(CAB_CORNER.x, 7.8, CAB_CORNER.z)], 1.15)
	await until(func(): return lift.player_in_cabin() and not mom.is_moving())
	mom.face(Vector3(37.5, 7.8, -7.0))
	_on_leave_floor3()
	_mom_ride = true
	await _cab_center_and_go(1)
	await until(func(): return lift.floor_idx == 1 and lift.state in ["opening", "open"])
	_mom_ride = false
	mom.global_position.y = 4.5
	_act5()


func _set_flag(flag: Array) -> void:
	flag[0] = true


func _on_leave_floor3() -> void:
	younger.visible = false
	younger.stop()
	psycho.visible = false
	psycho.stop()
	for n in _lounge_props:
		if is_instance_valid(n):
			n.queue_free()
	_lounge_props.clear()
	sets.build_real2(false)


# ------------------------------------------------------------------------------- братья
## Два брата-психа: появляются в конце коридора, догоняют, оглушают и притаскивают Азиза в холл отдыха;
## руки привязаны к коляске. Младший хочет засунуть его в стиральную машину, старший не даёт — и убивает
## младшего: удар, падение, бьёт сидя на нём; потом встаёт, долго смотрит на Азиза и убегает. Азиз
## перегрызает бинты (мини-игра: держать E).
func _brothers() -> void:
	act = "brothers"
	await until(func(): return room_id() == "L2.C", 30.0)
	await wait(1.5)
	# в ~20 м по коридору, с той стороны, где коридор длиннее
	var dir_x: float = 1.0 if ppos().x < 37.5 else -1.0
	var base := Vector3(clampf(ppos().x + dir_x * 20.0, 3.0, 72.0), 7.8, -8.1)
	game.lights.set_room("L2.C", false)
	game.play_at("flicker", ppos() + Vector3(0, 2.8, 0), -4.0, 0.8, 20.0)
	await wait(0.5)
	younger.global_position = base + Vector3(0, 0, 0.45)
	psycho.global_position = base + Vector3(0, 0, -0.45)
	for b in [younger, psycho]:
		b.visible = true
		b.face(ppos(), true)
		b.play("idle_loop", 0.0)
		b.set_look(player.head.global_position)
	game.lights.set_room("L2.C", true)
	_heartbeat_burst(3)
	snd("laugh_evil", younger.head_pos(), 4.0, 1.0, 60.0)
	ui.say("younger", "Братик, смотри… Новенький.", 2.6)
	await wait(2.4)
	ui.say("elder", "Взять его.", 1.6)
	snd("psycho_roar", psycho.head_pos(), 6.0, 0.9, 60.0)
	await wait(0.6)
	_after_line(1.0, "hero", "Твою мать…", 1.6)
	objective("Беги!")
	for b in [younger, psycho]:
		b.set_look(null)
	var run: Node3D = snd("run_steps", younger.global_position, 2.0, 1.15, 50.0) as Node3D
	var t := 0.0
	var jumped := false
	var caught := false
	while not caught:
		await get_tree().process_frame
		if get_tree().paused:
			continue
		var dt: float = get_process_delta_time()
		t += dt
		for b in [younger, psycho]:
			var tgt: Vector3 = _hunt_target(b, 0.4 if b == younger else -0.4)
			var to: Vector3 = tgt - b.global_position
			to.y = 0.0
			var spd: float = 4.6 if b == younger else 4.3
			var step: float = minf(spd * dt, to.length())
			if to.length() > 0.05:
				b.global_position += to.normalized() * step
				b.step_moved(step)
				b.face(b.global_position + to)
			b.play("run_loop", 0.2, spd / 3.6)
			var d: float = Vector2(b.global_position.x - ppos().x, b.global_position.z - ppos().z).length()
			var in_corridor: bool = ppos().z > -9.5 and ppos().z < -6.7
			if d < 1.35 or (not in_corridor and d < 2.4):
				caught = true
		if run and is_instance_valid(run):
			run.global_position = younger.global_position
		# далеко убежал — свет гаснет на миг, и они уже за спиной
		if t > 14.0 and not jumped and younger.global_position.distance_to(ppos()) > 8.0:
			jumped = true
			game.lights.set_room("L2.C", false)
			await wait(0.35)
			var back: float = signf(younger.global_position.x - ppos().x)
			younger.global_position = Vector3(ppos().x + back * 4.5, 7.8, -7.7)
			psycho.global_position = Vector3(ppos().x + back * 5.3, 7.8, -8.5)
			game.lights.set_room("L2.C", true)
			snd("laugh_evil", younger.head_pos(), 6.0, 1.1, 40.0)
		if t > 40.0:
			caught = true
	await _brothers_catch()
	await _lounge_scene()


## Куда бежит брат: по коридору прямо к Азизу; если Азиз заехал в комнату — к её двери по коридору.
func _hunt_target(b, side: float) -> Vector3:
	var p: Vector3 = ppos()
	if p.z > -9.5 and p.z < -6.7:
		return Vector3(p.x, 7.8, clampf(p.z + side, -9.2, -7.0))
	var c := Vector3(p.x, 7.8, -8.1 + side * 0.5)
	if absf(b.global_position.x - p.x) > 0.8 or absf(b.global_position.z + 8.1) > 0.6:
		return c
	return Vector3(p.x, 7.8, p.z)


## Поймали: старший бьёт, Азиз падает, темнота.
func _brothers_catch() -> void:
	freeze(true)
	objective("")
	younger.face(ppos(), true)
	younger.play("idle_loop", 0.2)
	# старший подходит вплотную (удар рукой достаёт ~0,8 м), только потом бьёт
	var to_me: Vector3 = ppos() - psycho.global_position
	to_me.y = 0.0
	var reach: Vector3 = ppos() - to_me.normalized() * 0.78
	reach.y = psycho.global_position.y
	psycho.face(ppos(), true)
	var step_in := create_tween()
	step_in.tween_property(psycho, "global_position", reach, 0.22)
	psycho.strike(func() -> Vector3: return player.head.global_position, "hit", 0.62)
	look_at_point(psycho.head_pos(), 0.3)
	snd("laugh_evil", younger.head_pos(), 3.0, 1.15)
	await wait(0.62)
	snd("punch", null, 4.0, 0.8)
	ui.flash(Color(0.8, 0.0, 0.0, 0.85), 0.6)
	var fall := create_tween()
	fall.tween_property(player, "view_offset", Transform3D(Basis.from_euler(Vector3(0.5, 0.3, 0.6)), Vector3(0.1, -0.3, 0.2)), 0.35)
	fall.tween_property(player, "view_offset", Transform3D(Basis.from_euler(Vector3(0.35, 0.2, 1.35)), Vector3(0.25, -0.95, 0.3)), 0.45).set_ease(Tween.EASE_IN)
	await fall.finished
	snd("body_fall", null, 2.0, 0.7)
	shake(0.5, 0.3)
	ui.set_damage(0.6)
	await GameState.fade_to(1.0, 1.4)
	ui.set_damage(0.0)
	player.view_offset = Transform3D.IDENTITY
	# в темноте: тащат коляску по коридору, младший хихикает
	snd("gurney_roll", null, -4.0, 0.55)
	await wait(1.2)
	await say("younger", "Хи-хи… Тяжёлый. Он живой, братик?")
	snd("gurney_roll", null, -6.0, 0.5)
	await say("elder", "Живой. Пока.")
	await wait(1.0)


## Холл отдыха: стиральные машины, Азиз привязан, братья.
func _setup_lounge() -> void:
	for wp in WASHERS:
		var w: Node3D = Props.washer()
		game.add_child(w)
		w.global_position = wp
		_lounge_props.append(w)
	var dg = door(DOOR_LOUNGE)
	if dg:
		dg.set_angle(0.0)                         # закрыли за собой: створка не загораживает никого
	game.lights.set_room(LOUNGE, true)
	game.lights.set_room("L2.C", true)


func _tie(on: bool) -> void:
	_tied = on
	for b in _bandages:
		if is_instance_valid(b):
			b.queue_free()
	_bandages.clear()
	if on:
		var cloth := Props.mat(Color(0.8, 0.78, 0.7), 0.95)
		var stain := Props.mat(Color(0.35, 0.05, 0.03), 0.6)
		for w in WRISTS:
			var b := Node3D.new()
			player.add_child(b)
			b.position = w
			for i in 3:                                                  # витки бинта вокруг запястья и подлокотника
				Props.cyl(b, Vector3(0, -0.012 * i, -0.04 + 0.045 * i), 0.047 - 0.004 * i, 0.04, cloth, Vector3(PI * 0.5, 0, 0.15 * (i - 1)))
			Props.box(b, Vector3(0.0, 0.044, 0.0), Vector3(0.035, 0.006, 0.03), stain)
			Props.box(b, Vector3(0.0, -0.06, 0.02), Vector3(0.07, 0.04, 0.12), cloth)    # узел под подлокотником
			for gi in b.find_children("*", "GeometryInstance3D", true, false):
				(gi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_bandages.append(b)
		player.input_override = Vector2.ZERO
	else:
		player.input_override = null


func _wrist_world() -> Vector3:
	return player.global_transform * WRISTS[0]


func _lounge_scene() -> void:
	act = "lounge"
	scares.stop()
	_setup_lounge()
	place_player(TIED_POS, TIED_YAW)
	younger.stop()
	psycho.stop()
	younger.global_position = YOUNGER_ROOM[0]
	younger.face(ppos(), true)
	younger.set_look(null)
	psycho.global_position = ELDER_ROOM
	psycho.face(ppos(), true)
	psycho.set_look(player.head.global_position)
	_tie(true)
	await wait(0.8)
	player.story_lock = false
	await GameState.fade_to(0.0, 3.0)
	await say("thought", "Голова… Где я?")
	ui.alert("Руки привязаны к коляске — не пошевелиться", 3.0)
	await look_at_point(_wrist_world(), 0.9)
	await wait(0.8)
	await say("thought", "Бинты… Эти уроды привязали мне руки.")
	# младший: стиральная машина
	younger.set_look(player.head.global_position)
	await look_at_point(younger.head_pos(), 0.8)
	snd("laugh_evil", younger.head_pos(), 2.0, 1.0)
	await wait(0.6)
	var hatch: Node3D = (_lounge_props[0] as Node3D).get_node_or_null("Hatch")
	if hatch:
		snd("door_creak_slow", WASHERS[0] + Vector3(0, 0.5, -0.3), -2.0, 1.4, 20.0)
		create_tween().tween_property(hatch, "rotation:y", deg_to_rad(105.0), 1.6).set_trans(Tween.TRANS_SINE)
	younger.set_arm(WASHERS[0] + Vector3(0, 0.5, -0.4))           # показывает рукой на люк
	await say("younger", "Нужно убить его внутри стиральной машины. Будет красиво.")
	younger.set_arm(null)
	snd("laugh_evil", younger.head_pos(), 3.0, 0.92)
	await wait(1.2)
	await say("elder", "Нет. Не сразу.")
	# младший медленно идёт к коляске, останавливается, снова идёт
	await younger.go_and_wait([YOUNGER_ROOM[1]], 0.75)
	younger.face(ppos())
	snd("laugh_evil", younger.head_pos(), 0.0, 1.2)
	await say("elder", "Нет, не убьём сразу — даже не представляй!")
	await younger.go_and_wait([YOUNGER_ROOM[2]], 0.75)
	younger.face(ppos())
	younger.set_arm(player.head.global_position + Vector3(0, -0.1, 0))   # тянется к лицу
	await say("younger", "Тш-ш-ш… Он поместится. Я его сложу. Аккуратно.")
	# старший — «Я сказал — НЕТ!!» и бросается
	player.story_lock = true
	_track = func() -> Vector3: return younger.head_pos() + Vector3(0, -0.6, 0)
	snd("psycho_roar", psycho.head_pos(), 8.0, 0.85, 40.0)
	psycho.set_look(null)
	ui.say("elder", "Я сказал — НЕТ!!", 2.4)
	younger.set_arm(null)
	younger.set_look(null)
	younger.face(psycho.global_position)                          # оборачивается на крик
	younger.play("idle_loop", 0.15)
	await wait(0.35)
	# старший подлетает со стороны стиральных машин; удар разворачивает младшего, и тот падает от него
	var strike: Vector3 = younger.global_position + Vector3(0, 0, 0.7)
	await psycho.go_and_wait([strike], 3.6, "run_loop")
	younger.face(strike, true)
	psycho.face(younger.global_position, true)
	psycho.strike(younger.head_pos() + Vector3(0, -0.08, 0), "hit", 0.6)
	await wait(0.6)
	snd("punch_flesh", younger.head_pos(), 6.0, 0.8)
	snd("scream_pain", younger.head_pos(), -2.0, 1.25)
	shake(0.2, 0.25)
	younger.play_once("fall", 0.05)
	var y0: float = younger.rotation.y
	var spin := create_tween()
	spin.tween_method(younger.set_yaw, y0, y0 + PI, 0.32).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await wait(3.0)
	snd("body_fall", younger.global_position + Vector3(0, 0, -0.9), 4.0, 0.8)
	shake(0.15, 0.2)
	younger.play("lie_loop", 0.15)
	await wait(0.6)
	await _beat_down()
	await _elder_stare_and_run()
	await _bite_free()


## Старший садится младшему на живот и бьёт по лицу ~12 секунд.
## Где и как старшему сесть на лежащего младшего: верхом на живот, лицом к его голове.
func _kneel_frame() -> Dictionary:
	var yb := Basis(Vector3.UP, younger.rotation.y + PI)
	var belly: Vector3 = younger.global_position + yb * LIE_BELLY
	var axis: Vector3 = (yb * LIE_AXIS).normalized()
	var ye: float = atan2(-axis.x, -axis.z)
	var eb := Basis(Vector3.UP, ye + PI)
	var kneel_at: Vector3 = belly - eb * Vector3(0.004, 0.0, -0.059) + Vector3(0, -0.06, 0)
	var er := Basis(Vector3.UP, ye)
	var face_p: Vector3 = younger.head_pos() + Vector3(0, 0.08, 0)
	return {"belly": belly, "axis": axis, "ye": ye, "at": kneel_at, "face": face_p,
		"chest": belly + axis * 0.2 + Vector3(0, 0.32, 0), "hit": face_p + Vector3(0, 0.1, 0),
		"raised": [kneel_at + er * Vector3(0.24, 1.04, 0.12), kneel_at + er * Vector3(-0.24, 1.04, 0.12)]}   # кулак у плеча


func _beat_down() -> void:
	var k: Dictionary = _kneel_frame()
	var belly: Vector3 = k["belly"]
	var axis: Vector3 = k["axis"]
	var ye: float = k["ye"]
	var kneel_at: Vector3 = k["at"]
	# подходит сбоку и садится
	var approach: Vector3 = kneel_at + Basis(Vector3.UP, ye) * Vector3(-0.55, 0, 0.15)
	approach.y = 7.8
	await psycho.go_and_wait([approach], 1.3)
	psycho.face(kneel_at)
	await wait(0.25)
	var drop := create_tween()
	drop.tween_property(psycho, "global_position", kneel_at, 0.45).set_trans(Tween.TRANS_SINE)
	psycho.set_yaw(ye)
	psycho.play("kneel_loop", 0.45)
	await drop.finished
	snd("body_fall", belly, 0.0, 1.2)
	snd("choke", younger.head_pos(), -2.0, 1.1)
	var face_p: Vector3 = k["face"]
	var chest: Vector3 = k["chest"]
	_track = func() -> Vector3: return face_p.lerp(psycho.head_pos(), 0.35)
	psycho.set_look(face_p)
	var raised: Array = k["raised"]
	var hit_p: Vector3 = k["hit"]
	var lean_tw := create_tween()
	lean_tw.tween_method(psycho.set_lean, 0.0, 0.62, 0.6)
	await lean_tw.finished
	# кровь под головой растёт
	var pool := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 1.0
	cm.bottom_radius = 1.0
	cm.height = 0.004
	cm.radial_segments = 20
	pool.mesh = cm
	pool.material_override = Props.mat(Color(0.18, 0.0, 0.0), 0.12)
	game.add_child(pool)
	pool.global_position = Vector3(face_p.x, 7.803, face_p.z) + axis * 0.08
	pool.scale = Vector3(0.05, 1.0, 0.05)
	_lounge_props.append(pool)
	var hands := [chest, chest]                    # [правая, левая]
	var ybase: Vector3 = younger.global_position
	var t := 0.0
	var n := 0
	while t < 12.0:
		var r: int = n % 2                         # 0 — правой, 1 — левой
		var other: int = 1 - r
		var dur: float = randf_range(0.36, 0.5) if t < 9.0 else randf_range(0.55, 0.8)   # к концу — реже, тяжелее
		var phase := 0.0
		while phase < 1.0:
			await get_tree().process_frame
			var dt: float = get_process_delta_time()
			if get_tree().paused:
				continue
			phase += dt / dur
			t += dt
			var fist: Vector3
			if phase < 0.6:
				fist = (hands[r] as Vector3).lerp(raised[r], sin(phase / 0.6 * PI * 0.5))
			elif phase < 0.78:
				var q: float = (phase - 0.6) / 0.18
				fist = (raised[r] as Vector3).lerp(hit_p, q * q)
			else:
				fist = hit_p
			hands[r] = fist
			younger.global_position = younger.global_position.lerp(ybase, clampf(dt * 12.0, 0.0, 1.0))
			hands[other] = (hands[other] as Vector3).lerp(chest, clampf(dt * 8.0, 0.0, 1.0))  # другой рукой прижимает грудь
			psycho.set_hands(hands[0], hands[1], 1.0)
			psycho.set_lean(0.62 + 0.16 * clampf((phase - 0.45) * 3.0, 0.0, 1.0) * (1.0 if phase < 0.85 else 0.5))
			if phase >= 0.78 and phase - dt / dur < 0.78:
				snd("punch_flesh", face_p, randf_range(2.0, 6.0), randf_range(0.8, 1.1), 25.0)
				younger.global_position = ybase + Vector3(randf_range(-0.015, 0.015), -0.012, randf_range(-0.015, 0.015))
				if n % 4 == 1 and t < 7.0:
					snd("choke", face_p, -6.0, randf_range(1.0, 1.25))
				if n % 3 == 0:
					_blood_spot(face_p, axis)
				var rr: float = lerpf(0.05, 0.42, clampf(t / 11.0, 0.0, 1.0))
				pool.scale = Vector3(rr, 1.0, rr * 0.85)
		n += 1
	younger.global_position = ybase
	# встаёт
	var up := create_tween()
	up.tween_method(func(w: float) -> void: psycho.set_hands(hands[0], hands[1], w), 1.0, 0.0, 0.6)
	up.parallel().tween_method(psycho.set_lean, 0.62, 0.0, 0.8)
	await up.finished
	psycho.set_hands(null, null, 0.0)
	psycho.set_look(null)
	await wait(1.5)                                  # тяжело дышит, сидя на нём
	var stand_at: Vector3 = kneel_at + Vector3(0, 0.06, 0)
	stand_at.y = 7.8
	var st := create_tween()
	st.tween_property(psycho, "global_position", stand_at, 0.9).set_trans(Tween.TRANS_SINE)
	psycho.play("idle_loop", 0.9)
	await st.finished


func _blood_spot(at: Vector3, axis: Vector3) -> void:
	var spot := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = randf_range(0.015, 0.04)
	cm.bottom_radius = cm.top_radius
	cm.height = 0.003
	cm.radial_segments = 8
	spot.mesh = cm
	spot.material_override = Props.mat(Color(0.22, 0.0, 0.0), 0.2)
	game.add_child(spot)
	var side := Vector3(axis.z, 0, -axis.x)
	spot.global_position = Vector3(at.x, 7.804, at.z) + axis * randf_range(0.05, 0.35) + side * randf_range(-0.35, 0.35)
	_lounge_props.append(spot)


## Старший встаёт и долго смотрит на Азиза… и вдруг убегает из комнаты.
func _elder_stare_and_run() -> void:
	await psycho.go_and_wait([ELDER_STARE], 0.9)
	psycho.face(ppos())
	psycho.set_look(player.head.global_position)
	_track = func() -> Vector3: return psycho.head_pos() + Vector3(0, -0.05, 0)
	var breath := AudioStreamPlayer3D.new()
	breath.stream = stream("breathing", true)
	breath.unit_size = 2.0
	breath.volume_db = 2.0
	game.add_child(breath)
	breath.global_position = psycho.head_pos()
	breath.play()
	_drone.volume_db = -10.0
	var t := 0.0
	var stepped := false
	while t < 14.0:
		await wait(0.5)
		t += 0.5
		if int(t * 2.0) % 2 == 0:
			snd("heartbeat", null, -4.0 + t * 0.3, 1.0)
		if t >= 7.0 and not stepped:
			stepped = true
			var close: Vector3 = ELDER_STARE + (ppos() - ELDER_STARE).normalized() * 0.3
			close.y = 7.8
			psycho.go([close], 0.5)
		if t >= 10.0:
			psycho.set_look(player.head.global_position + Vector3(0.25, 0.1, 0))   # склоняет голову набок
	breath.queue_free()
	# резко: разворот и бегом из комнаты
	psycho.set_look(null)
	snd("whoosh", psycho.head_pos(), 2.0, 0.8)
	_track = null
	var run: Node3D = snd("run_steps", psycho.global_position, 4.0, 1.2, 40.0) as Node3D
	psycho.go(ELDER_EXIT, 5.2, "run_loop")
	await wait(0.35)
	var dg = door(DOOR_LOUNGE)
	if dg:
		dg.set_angle(92.0)                        # с размаху распахивает дверь
		snd("door_burst", Vector3(22.88, 8.8, -9.7), 2.0, 1.0, 30.0)
	await wait(1.2)
	await until(func(): return not psycho.is_moving(), 6.0)
	psycho.visible = false
	psycho.stop()
	if run and is_instance_valid(run):
		run.queue_free()
	_drone.volume_db = -16.0
	player.story_lock = false


## Перегрызть бинты: держать E. Каждый рывок — треск ткани.
func _bite_free() -> void:
	await wait(1.2)
	await say("thought", "Он… он его убил. Из-за меня.")
	await say("thought", "Он вернётся. Руки… Зубами. Давай, давай.")
	objective("Освободи руки — перегрызи бинты")
	player.story_lock = true
	var lean_xf := Transform3D(Basis(Vector3.RIGHT, -0.12), Vector3(0.05, -0.06, -0.03))   # наклонился к руке
	var bite := create_tween()
	bite.tween_property(player, "view_offset", lean_xf, 0.6).set_trans(Tween.TRANS_SINE)
	_track = _wrist_world
	var on_tug := func(_ok: bool) -> void:
		snd("cloth_tear", _wrist_world(), randf_range(-2.0, 2.0), randf_range(0.85, 1.15), 10.0)
		player.view_offset = lean_xf * Transform3D(Basis.from_euler(Vector3(randf_range(-0.05, 0.05), randf_range(-0.08, 0.08),
			randf_range(-0.06, 0.06))), Vector3.ZERO)
		create_tween().tween_property(player, "view_offset", lean_xf, 0.22)
	minigame.hit.connect(on_tug)
	await minigame.hold("Перегрызи бинты", 7.0)
	minigame.hit.disconnect(on_tug)
	snd("cloth_tear", _wrist_world(), 4.0, 0.8, 10.0)
	_track = null
	var back := create_tween()
	back.tween_property(player, "view_offset", Transform3D.IDENTITY, 0.5)
	await back.finished
	_tie(false)
	player.story_lock = false
	ui.alert("Руки свободны", 2.0)
	objective("")
	await wait(1.0)
	GameState.checkpoint = "floor3b"
	await say("thought", "Мама. Мне нужно найти маму.")
	objective("Найди маму на 3-м этаже")


# ================================================================================ АКТ 5: таблетка
## Обычный второй этаж. У мамы болит голова — просит сходить за цитрамоном в аптеку у остановки и уходит в
## палату деда. Азиз — на лифте вниз и на улицу (дальше — лес, story/prologue.gd в режиме «аптека»).
const EXIT_DOOR := Vector3(27.7, 1.2, 4.27)          # входная дверь изнутри тамбура


func _act5() -> void:
	act = "pills"
	GameState.checkpoint = "pharmacy"
	if game.critters:
		game.critters.visible = false
	_drone.volume_db = -26.0
	lift.locked = true
	lift.lock_text = ""
	if GameState.fade_target() > 0.5:
		await GameState.fade_to(0.0, 1.5)
	freeze(true)
	await wait(0.8)
	objective("")
	await say("thought", "Тут же пусто было…")
	mom.face(ppos())
	mom.set_look(player.head.global_position)
	await say("mom", "Ох… Голова болит, всё кружится. У остановки была аптека. Сходишь за таблеткой?")
	await say("hero", "Ладно. Что за таблетка? Название скажи. И денег дай.")
	await say("mom", "Цитрамон. Вот деньги, вот бумажка — там написано.")
	snd("cloth_tear", null, -14.0, 1.9)
	ui.hint("Деньги и записка «Цитрамон» — у тебя", 3.0)
	mom.set_look(null)
	freeze(false)
	# мама уходит в палату деда, 204
	mom.go([Vector3(36.85, 4.5, -5.7), Vector3(37.05, 4.5, -6.8), Vector3(36.6, 4.5, -8.1), Vector3(9.5, 4.5, -8.1),
		Vector3(8.83, 4.5, -7.3), Vector3(8.83, 4.5, -5.4)], 1.1)
	_mom_into_204()
	objective("Сходи в аптеку у остановки")
	lift.locked = false
	lift.forced_floor = 0
	_hold_lift = false
	await until(func(): return lift.player_in_cabin() and lift.state == "moving")
	await say("thought", "Лишь бы мы отсюда нормально ушли.")
	await until(func(): return lift.floor_idx == 0 and lift.state in ["opening", "open"])
	lift.forced_floor = -1
	objective("Выезжай на улицу и езжай к остановке")
	for id in [DOOR_VEST, 2]:
		var vd = door(id)
		if vd and absf(vd.angle) < 60.0:
			vd.swing_to(-92.0, 0.1)
	var it: Area3D = Interactable.new()
	game.add_child(it)
	it.global_position = EXIT_DOOR + Vector3(0, 1.1, 0)
	it.setup(Vector3(0.3, 2.0, 1.8), "[E] Выйти на улицу", func():
		it.enabled = false
		freeze(true)
		game.play_at("door_open_metal", EXIT_DOOR + Vector3(0, 1.1, 0), -2.0, 1.0, 15.0)
		GameState.go(GameState.PROLOGUE, "pharmacy_out"))


func _mom_into_204() -> void:
	var d = door(Sets.DOOR_204)
	if d:
		d.locked = false
	await until(func(): return mom.global_position.distance_to(Vector3(8.83, 4.5, -7.3)) < 0.7, 90.0)
	if d and d.angle < 60.0:
		d.swing_to(95.0, 0.8)
	await until(func(): return not mom.is_moving(), 20.0)
	mom.visible = false
	mom.stop()
	if d:
		d.swing_to(0.0, 1.4)


# ================================================================================ АКТ 6: настоящая больница
## С таблеткой назад — а внутри всё другое: светло, обычная больница 1975 года, люди ждут в холле, ходят врачи.
## В палате 204 у кровати деда — Дилором и парень лет шестнадцати. «Я не ваша мама. Вот мой сын.»
## Паническая атака: Азиз падает из коляски, темнота, только звуки. Дальше — эпилог.
const SON_CHAIR := Vector3(10.25, 4.5, -0.74)         # стулья за кроватью деда (палата 204), лицом к двери (−Z)
const MOM_CHAIR := Vector3(11.15, 4.5, -0.74)
var _people: Array = []


func _act6() -> void:
	act = "real"
	GameState.checkpoint = "real"
	_setup_real_hospital()
	var e: Dictionary = GameState.entry
	GameState.entry = {}
	place_player(e.get("pos", SPAWN) as Vector3, float(e.get("yaw", SPAWN_YAW)))
	mom.visible = false
	lift.locked = false
	lift.forced_floor = -1
	lift.park_closed(0)
	await GameState.fade_to(0.0, 1.6)
	objective("Отнеси таблетку маме — палата 204")
	ui.hint("Лифт — в конце холла, направо", 5.0)
	await until(func(): return room_id() in ["L1.F2", "L1.F2b"] or (ppos().y > 4.0 and ppos().distance_to(Vector3(8.83, 4.5, -5.6)) < 1.4))
	await _real_son()


## Свет — ровный и яркий, страшного звука нет; люди в холле и в коридоре; палата деда.
func _setup_real_hospital() -> void:
	game.lights.hospital_day()
	if game.critters:
		game.critters.visible = false
	if game.ambience:
		game.ambience.set_process(false)
		if game.ambience.drone:
			game.ambience.drone.volume_db = -36.0
	_drone.volume_db = -80.0
	for c in game.get_children():
		if c is WorldEnvironment and (c as WorldEnvironment).environment:
			var env: Environment = (c as WorldEnvironment).environment
			env.ambient_light_energy *= 1.6
	var bed := AudioStreamPlayer.new()
	bed.stream = stream("hospital_alive", true)
	bed.volume_db = -14.0
	add_child(bed)
	bed.play()
	var hall := AudioStreamPlayer3D.new()               # гомон в холле и у регистратуры
	hall.stream = stream("hospital_alive", true)
	hall.volume_db = 2.0
	hall.unit_size = 8.0
	hall.max_distance = 40.0
	hall.bus = "World"
	game.add_child(hall)
	hall.global_position = Vector3(33.0, 2.6, 7.0)
	hall.play(7.0)
	_spawn_people()
	var d = door(Sets.DOOR_204)
	if d:
		d.locked = false
		d.set_angle(80.0)


## Люди: сидят и ждут в холле (модели пассажиров из пролога или свои story_people_sit_*.glb), врач и пациент
## ходят по коридору 1-го этажа, в палате 204 — Дилором и её сын.
func _spawn_people() -> void:
	var sitting: Array = []
	for k in range(1, 7):
		var p := "res://sanatorium/models/story_people_sit_%d.glb" % k
		if ResourceLoader.exists(p):
			sitting.append(p)
	if sitting.is_empty():
		sitting = ["res://intro/assets/models/people/grandma_scarf.glb", "res://intro/assets/models/people/man_newspaper.glb",
			"res://intro/assets/models/people/mother_baby.glb"]
	var seats: Array = _hall_seats()
	for i in mini(seats.size(), sitting.size() + 1):
		var s: Transform3D = seats[i]
		var path: String = sitting[i % sitting.size()]
		var m := Props.glb(path, 1.0)
		game.add_child(m)
		var lift_up: float = _feet_offset(m)
		m.global_transform = s
		m.global_position += Vector3(0, lift_up, 0) + s.basis.z * 0.08
		_people.append(m)
	# врач ходит по коридору туда-сюда, пожилой пациент медленно идёт к лестнице
	var doc = _actor("res://characters/psycho.glb", "Врач")
	doc.natural = {"walk_loop": 1.3}
	doc.global_position = Vector3(44.0, 1.2, -8.1)
	_patrol(doc, [Vector3(44.0, 1.2, -8.1), Vector3(56.0, 1.2, -8.1)], 1.0)
	var old = _actor("res://characters/grandpa.glb", "Пациент")
	old.natural = {"walk_loop": 0.26}
	old.global_position = Vector3(32.2, 1.2, 9.5)
	_patrol(old, [Vector3(32.2, 1.2, 9.5), Vector3(32.2, 1.2, 2.5)], 0.35)
	_people.append_array([doc, old])


func _patrol(a, pts: Array, speed: float) -> void:
	var i := 0
	while is_instance_valid(a) and act == "real":
		await a.go_and_wait([pts[i % pts.size()]], speed)
		a.play("idle_loop", 0.4)
		await wait(randf_range(1.5, 4.0))
		i += 1


## Высота от начала модели до её самой нижней точки (ступни) — чтобы поставить на пол.
func _feet_offset(m: Node3D) -> float:
	var lo := 99.0
	for g in m.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = g
		if mi.mesh == null:
			continue
		var xf: Transform3D = Transform3D.IDENTITY
		var p: Node = mi
		while p != m and p is Node3D:
			xf = (p as Node3D).transform * xf
			p = p.get_parent()
		lo = minf(lo, (xf * mi.mesh.get_aabb()).position.y)
	return -lo if lo < 98.0 else 0.0


## Места в холле: диван, скамья, кресла — где они стоят в здании (лицом в зал).
func _hall_seats() -> Array:
	var out: Array = []
	for g in game.building.find_children("*", "Node3D", true, false):
		var n: Node3D = g
		var nm := String(n.name)
		if not (nm.ends_with("_EB_HALL") or nm.contains("_EB_HALL_")) or nm.ends_with("_model") or nm.ends_with("_pic"):
			continue
		if nm.begins_with("bench") or nm.begins_with("sofa") or nm.begins_with("armchair"):
			out.append(n.global_transform)
	return out


## Палата 204: у кровати деда сидят Дилором и парень. Разговор — и паническая атака.
func _real_son() -> void:
	act = "son"
	for c in [SON_CHAIR, MOM_CHAIR]:
		var ch := Props.glb("res://sanatorium/models/chair.glb", 1.0)
		game.add_child(ch)
		ch.global_position = c
		ch.rotation.y = PI                               # сиденьем к двери (−Z)
		_people.append(ch)
	var son_path := "res://sanatorium/models/story_son.glb"
	var son: Node3D
	if ResourceLoader.exists(son_path):
		son = Props.glb(son_path, 1.0)
		game.add_child(son)
		son.global_position = SON_CHAIR + Vector3(0, _feet_offset(son), 0)
		son.rotation.y = PI
	else:
		var a = _actor("res://characters/younger.glb", "Сын")
		a.global_position = SON_CHAIR
		a.face(SON_CHAIR + Vector3(0, 0, -1), true)
		a.set_sit(true)
		a.set_hands(SON_CHAIR + Vector3(0.12, 0.55, -0.38), SON_CHAIR + Vector3(-0.12, 0.55, -0.38), 0.8)
		son = a
	_people.append(son)
	mom.visible = true
	mom.stop()
	mom.global_position = MOM_CHAIR
	mom.face(MOM_CHAIR + Vector3(0, 0, -1), true)
	mom.set_sit(true)
	mom.set_hands(MOM_CHAIR + Vector3(0.11, 0.55, -0.36), MOM_CHAIR + Vector3(-0.11, 0.55, -0.36), 0.9)
	mom.play("idle_loop", 0.0)
	freeze(true)
	objective("")
	await look_at_point(MOM_CHAIR + Vector3(0, 1.0, 0), 0.8)
	await say("hero", "Мам, вот таблетка.")
	mom.set_look(player.head.global_position)
	await wait(1.0)
	await say("mom", "Не поняла… Вы кто? Вы, по-моему, ошиблись. Я не ваша мама. Вот мой сын.")
	mom.set_look(son.global_position + Vector3(0, 1.0, 0))
	await look_at_point(son.global_position + Vector3(0, 1.0, 0), 0.7)
	await wait(1.6)
	await look_at_point(mom.head_pos(), 0.5)
	mom.set_look(player.head.global_position)
	await say("hero", "Вы чё, издеваетесь надо мной?")
	await say("hero", "Мы же вместе приехали! На автобусе, к деду на второй этаж! Нас человек пятнадцать хотели поймать, мы на лифте ушли… Ты сама попросила сходить за таблеткой — вот, я пришёл! Чёрт… что происходит?!")
	await _panic_attack()


## Паническая атака: дыхание и сердце всё чаще, картинка плывёт и темнеет, Азиз падает из коляски на пол.
## «Доктор! Доктора сюда, быстро!» — темнота, несколько секунд слышно только, что вокруг. Потом тишина.
func _panic_attack() -> void:
	act = "panic"
	var breath := AudioStreamPlayer.new()
	breath.stream = stream("breathing", true)
	breath.volume_db = -6.0
	add_child(breath)
	breath.play()
	var heart := AudioStreamPlayer.new()
	heart.stream = stream("heartbeat_full", true)
	heart.volume_db = -4.0
	add_child(heart)
	heart.play()
	var ring := AudioStreamPlayer.new()                  # звон в ушах
	ring.stream = _tone(6400.0, 4.0)
	ring.volume_db = -40.0
	add_child(ring)
	ring.play()
	var t := 0.0
	while t < 6.0:
		await get_tree().process_frame
		var dt: float = get_process_delta_time()
		t += dt
		var k: float = t / 6.0
		heart.pitch_scale = 1.0 + k * 0.7
		breath.pitch_scale = 1.0 + k * 0.5
		ring.volume_db = lerpf(-40.0, -12.0, k)
		ui.set_damage(k * 0.55)
		player.view_offset = Transform3D(Basis.from_euler(Vector3(sin(t * 3.1) * 0.03 * k, sin(t * 2.3) * 0.04 * k,
			sin(t * 1.7) * 0.06 * k)), Vector3(0, -0.02 * k, 0))
	# падает из коляски на пол
	mom.set_sit(false)
	mom.set_hands(null, null, 0.0)
	mom.play("idle_loop", 0.2)
	snd("body_fall", null, 4.0, 0.85)
	var fall := create_tween()
	fall.tween_property(player, "view_offset", Transform3D(Basis.from_euler(Vector3(0.3, 0.4, 1.2)), Vector3(0.35, -0.9, 0.35)), 0.6).set_ease(Tween.EASE_IN)
	await wait(0.3)
	ui.say("mom", "Доктор! Доктора сюда, быстро!", 3.0)
	await fall.finished
	shake(0.6, 0.3)
	await wait(1.2)
	await GameState.fade_to(1.0, 1.4)
	ui.set_damage(0.0)
	# темнота: слышно, что вокруг
	var tw := create_tween()
	tw.tween_property(ring, "volume_db", -24.0, 2.0)
	snd("run_steps", Vector3(8.8, 4.6, -8.0), 2.0, 1.1, 30.0)
	await wait(0.8)
	ui.say("voice", "Что с ним?!", 1.8)
	snd("door_burst", Vector3(8.8, 5.6, -6.6), -6.0, 1.2, 30.0)
	await wait(1.6)
	ui.say("voice", "Врача! Быстро!", 1.8)
	snd("gurney_roll", Vector3(9.5, 4.6, -8.0), -2.0, 1.0, 30.0)
	await wait(2.0)
	ui.say("voice", "Мальчик, ты меня слышишь? Дыши. Дыши…", 3.0)
	await wait(3.0)
	var quiet := create_tween()
	quiet.tween_property(heart, "volume_db", -60.0, 3.0)
	quiet.parallel().tween_property(breath, "volume_db", -60.0, 3.0)
	quiet.parallel().tween_property(ring, "volume_db", -60.0, 3.0)
	await quiet.finished
	AudioServer.set_bus_mute(0, true)
	await wait(2.5)
	AudioServer.set_bus_mute(0, false)
	GameState.go(GameState.EPILOGUE)


## Чистый тон (звон в ушах) — синтез, без файла.
func _tone(hz: float, sec: float) -> AudioStreamWAV:
	var rate := 44100
	var n := int(rate * sec)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var v: float = sin(TAU * hz * float(i) / rate) * 0.25 * (1.0 + 0.15 * sin(TAU * 0.7 * float(i) / rate))
		data.encode_s16(i * 2, int(v * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_end = n
	return w


func _on_skip() -> void:
	_skip = true


# ================================================================================ кадр
func _physics_process(dt: float) -> void:
	if game == null:
		return
	if chase == "run" or chase == "safe":
		_update_chase(dt)
	if faceless_state == "run" or faceless_state == "door":
		_update_faceless(dt)


func _process(dt: float) -> void:
	if game == null:
		return
	if _track != null and not get_tree().paused:
		player.aim_at((_track as Callable).call(), clampf(dt * 3.5, 0.0, 1.0))
	if _mom_ride:
		mom.global_position.y = lift.cabin_floor_y()     # мама едет в кабине
	if _hold_lift:
		lift.idle_t = 0.0                                # двери не закрываются сами
	if _tied:
		_tied_msg_t -= dt
		var tries: bool = Input.is_action_pressed("drive_forward") or Input.is_action_pressed("drive_back") \
				or Input.is_action_pressed("turn_left") or Input.is_action_pressed("turn_right")
		if tries and _tied_msg_t <= 0.0 and not get_tree().paused:
			_tied_msg_t = 2.4
			ui.alert("Руки привязаны — коляска не двигается", 2.0)
			snd("metal_creak", ppos() + Vector3(0, 0.6, 0), -12.0, 1.7, 8.0)
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
