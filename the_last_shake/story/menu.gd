extends Control
## Главное меню «The Last Shake».
## Фон — кадр из самой игры: тёмный коридор 3-го этажа, вдали одна холодная лампа, на переднем плане пустая
## коляска, под лампой стоит мама. Лампа время от времени мигает — и с каждым миганием мама то исчезает, то
## оказывается ближе (story/menu/menu_bg_a, b, c — tests/shots.gd, case menubg). Картинка медленно наплывает.
## Слева — название и пункты: Продолжить (если игра уже начата) · Новая игра · Главы · Управление · Настройки ·
## Выход. Справа — содержимое пункта. Мышью или клавишами (↑/↓, Enter, Esc — назад).

const UI = preload("res://story/ui_kit.gd")
const FRAMES := ["res://story/menu/menu_bg_a.jpg", "res://story/menu/menu_bg_b.jpg", "res://story/menu/menu_bg_c.jpg"]
## порядок кадров на миганиях: далеко → нет → ближе → нет → далеко …
const SEQ := [0, 1, 2, 1]
const WHISPERS := ["Ты уверен, что проснулся?", "Здесь кто-то есть.", "Мама ждёт тебя.", "Не оглядывайся."]

var _bg: TextureRect
var _bg_holder: Control
var _tex: Array = []
var _seq_i := 0
var _flick_t := 7.0
var _flicker: Array = []             # [время, яркость] — текущее мигание
var _items: VBoxContainer
var _side: VBoxContainer
var _first: Button
var _sub := ""
var _title: Label
var _whisper: Label
var _whisper_t := 9.0
var _drone: AudioStreamPlayer
var _tick: AudioStreamPlayer
var _sfx: AudioStreamPlayer
var _sfx_t := 18.0
var _t := 0.0
var _started := false


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var black := ColorRect.new()
	black.color = Color(0, 0, 0)
	black.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(black)
	for f in FRAMES:
		_tex.append(load(f) if ResourceLoader.exists(f) else null)
	_bg_holder = Control.new()
	_bg_holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg_holder)
	_bg = TextureRect.new()
	_bg.texture = _tex[0]
	_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg_holder.add_child(_bg)
	_add_gradient(Vector2(0, 0), Vector2(1, 0), Color(0, 0, 0, 0.92), Color(0, 0, 0, 0.0), Control.PRESET_LEFT_WIDE, Vector2(980, 0))
	_add_gradient(Vector2(0, 1), Vector2(0, 0), Color(0, 0, 0, 0.8), Color(0, 0, 0, 0.0), Control.PRESET_BOTTOM_WIDE, Vector2(0, 260))
	# название и пункты — слева
	var left := VBoxContainer.new()
	left.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	left.offset_left = 96
	left.offset_right = 640
	left.alignment = BoxContainer.ALIGNMENT_CENTER
	left.add_theme_constant_override("separation", 4)
	add_child(left)
	_title = UI.label("THE LAST SHAKE", 92, Color(0.94, 0.91, 0.85), 600)
	left.add_child(_title)
	var sub_title: Label = UI.label("П О С Л Е Д Н И Й   С К А Ч О К", 22, Color(0.72, 0.68, 0.62), 300)
	left.add_child(sub_title)
	# по-английски название уже крупно сверху — подзаголовок не нужен
	var lang_vis := func(): sub_title.visible = GameState.language != "en"
	lang_vis.call()
	GameState.language_changed.connect(lang_vis)
	tree_exiting.connect(func(): GameState.language_changed.disconnect(lang_vis))
	var line := ColorRect.new()
	line.color = Color(UI.ACCENT.r, UI.ACCENT.g, UI.ACCENT.b, 0.8)
	line.custom_minimum_size = Vector2(120, 2)
	line.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	left.add_child(line)
	left.add_child(UI.label("Санаторий «Оромгох», Ташкент, 1975", 20, UI.DIM, 300))
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 44)
	left.add_child(gap)
	_items = VBoxContainer.new()
	_items.add_theme_constant_override("separation", 2)
	left.add_child(_items)
	var saved: Array = GameState.saved_progress()
	if not saved.is_empty():
		_first = _add("Продолжить", func(): _start(saved[0], saved[1]))
		var where := UI.label("        " + GameState.chapter_name(saved[0], saved[1]), 18, UI.DIM, 300)
		_items.add_child(where)
	var ng := _add("Новая игра", func(): _start(GameState.PROLOGUE, "start"))
	if _first == null:
		_first = ng
	_add("Главы", func(): _show("chapters"))
	_add("Управление", func(): _show("controls"))
	_add("Настройки", func(): _show("settings"))
	_add("Выход", func(): get_tree().quit())
	# справа — содержимое пункта
	_side = VBoxContainer.new()
	_side.set_anchors_preset(Control.PRESET_FULL_RECT)
	_side.offset_left = 760
	_side.offset_right = -90
	_side.alignment = BoxContainer.ALIGNMENT_CENTER
	_side.add_theme_constant_override("separation", 16)
	add_child(_side)
	# низ: версия, автор, тихая фраза
	var ver := UI.label(GameState.version_text(), 17, Color(UI.DIM.r, UI.DIM.g, UI.DIM.b, 0.75), 300)
	var ver_upd := func(): ver.text = GameState.version_text()
	GameState.language_changed.connect(ver_upd)
	tree_exiting.connect(func(): GameState.language_changed.disconnect(ver_upd))
	ver.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	ver.offset_left = 96
	ver.offset_top = -56
	ver.offset_right = 700
	ver.offset_bottom = -28
	add_child(ver)
	var author := UI.label("Игра и сценарий — Саман", 17, Color(UI.DIM.r, UI.DIM.g, UI.DIM.b, 0.75), 300, HORIZONTAL_ALIGNMENT_RIGHT)
	author.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	author.offset_left = -600
	author.offset_top = -56
	author.offset_right = -60
	author.offset_bottom = -28
	add_child(author)
	_whisper = UI.label("", 24, Color(0.82, 0.78, 0.74), 200, HORIZONTAL_ALIGNMENT_RIGHT)
	_whisper.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_whisper.offset_left = -900
	_whisper.offset_top = -120
	_whisper.offset_right = -60
	_whisper.offset_bottom = -80
	_whisper.modulate.a = 0.0
	add_child(_whisper)
	# звук: низкий гул, редкие далёкие звуки, щелчок наведения
	_drone = _player("res://story/sfx/drone_low.wav", -15.0, true)
	_drone.play()
	_tick = _player("res://story/sfx/ui_tick.wav", -14.0)
	_sfx = _player("", -20.0)
	var hum := _player("res://sanatorium/assets/sfx/fluo_buzz_loop.wav", -30.0, true)
	hum.play()
	_slow_zoom()
	_first.grab_focus.call_deferred()
	GameState.fade_to(0.0, 1.2)


func _add_gradient(from: Vector2, to: Vector2, c0: Color, c1: Color, preset: int, sz: Vector2) -> void:
	var tr := TextureRect.new()
	var gt := GradientTexture2D.new()
	var g := Gradient.new()
	g.set_color(0, c0)
	g.set_color(1, c1)
	gt.gradient = g
	gt.fill_from = from
	gt.fill_to = to
	tr.texture = gt
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.set_anchors_preset(preset)
	if sz.x > 0:
		tr.offset_right = sz.x
	if sz.y > 0:
		tr.offset_top = -sz.y
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(tr)


func _player(path: String, db: float, loop := false) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	if path != "" and ResourceLoader.exists(path):
		var s: AudioStream = load(path)
		if loop and s is AudioStreamWAV:
			var w: AudioStreamWAV = (s as AudioStreamWAV).duplicate()
			w.loop_mode = AudioStreamWAV.LOOP_FORWARD
			w.loop_begin = 0
			w.loop_end = int(w.get_length() * w.mix_rate)
			s = w
		p.stream = s
	p.volume_db = db
	add_child(p)
	return p


func _add(text: String, cb: Callable) -> Button:
	var b: Button = UI.item(text, 34, cb, func(): _hover())
	_items.add_child(b)
	return b


func _hover() -> void:
	if _tick.stream:
		_tick.pitch_scale = randf_range(0.95, 1.08)
		_tick.play()


## Картинка медленно наплывает и отплывает (почти незаметно — как будто коридор «дышит»).
func _slow_zoom() -> void:
	await get_tree().process_frame
	_bg_holder.pivot_offset = _bg_holder.size * Vector2(0.52, 0.48)
	var tw := create_tween().set_loops()
	tw.tween_property(_bg_holder, "scale", Vector2.ONE * 1.07, 38.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(_bg_holder, "scale", Vector2.ONE * 1.0, 38.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _start(scene: String, cp: String) -> void:
	if _started:
		return
	_started = true
	var sel := _player("res://story/sfx/ui_select.wav", -6.0)
	sel.play()
	var tw := create_tween()
	tw.tween_property(_drone, "volume_db", -40.0, 0.8)
	GameState.go(scene, cp)


func _clear_side() -> void:
	for c in _side.get_children():
		c.queue_free()


func _show(what: String) -> void:
	_sub = what
	_clear_side()
	match what:
		"chapters":
			_side.add_child(UI.label("Главы", 40, Color(0.95, 0.92, 0.86), 500))
			var list := VBoxContainer.new()
			list.add_theme_constant_override("separation", 0)
			_side.add_child(list)
			var first_ch: Button = null
			for ch in GameState.CHAPTERS:
				var b: Button = UI.item(String(ch[0]), 26, _start.bind(ch[1], ch[2]), func(): _hover())
				list.add_child(b)
				if first_ch == null:
					first_ch = b
			first_ch.grab_focus.call_deferred()
		"controls":
			_side.add_child(UI.label("Управление", 40, Color(0.95, 0.92, 0.86), 500))
			_side.add_child(UI.controls_grid())
		"settings":
			_side.add_child(UI.label("Настройки", 40, Color(0.95, 0.92, 0.86), 500))
			var box: VBoxContainer = UI.settings_box()
			_side.add_child(box)
			(box.get_child(0).get_child(1) as Control).grab_focus.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if (event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel")) and _sub != "":
		get_viewport().set_input_as_handled()
		_show("")
		_first.grab_focus.call_deferred()


## Лампа мигает: несколько быстрых провалов яркости; в самой тёмной точке кадр меняется на следующий
## (мама исчезает — появляется ближе — снова исчезает…).
func _process(dt: float) -> void:
	_t += dt
	_flick_t -= dt
	if _flick_t <= 0.0 and _flicker.is_empty():
		var n: int = randi_range(3, 6)
		var tt := 0.0
		for i in n:
			tt += randf_range(0.04, 0.12)
			_flicker.append([tt, randf_range(0.15, 0.55)])
			tt += randf_range(0.03, 0.1)
			_flicker.append([tt, 1.0])
		_flicker.insert(n, [_flicker[n - 1][0] + 0.01, 0.0])          # посередине — полная темнота: смена кадра
		_flicker.append([tt + 0.01, -1.0])
		_flick_t = randf_range(7.0, 13.0)
		_flick_clock = 0.0
		var buzz := _player("res://sanatorium/assets/sfx/flicker.wav", -18.0)
		buzz.play()
		buzz.finished.connect(buzz.queue_free)
	if not _flicker.is_empty():
		_flick_clock += dt
		while not _flicker.is_empty() and _flick_clock >= float(_flicker[0][0]):
			var k: float = _flicker[0][1]
			_flicker.pop_front()
			if k < 0.0:
				_bg.modulate = Color(1, 1, 1)
			elif k == 0.0:
				_bg.modulate = Color(0.02, 0.02, 0.02)
				_seq_i = (_seq_i + 1) % SEQ.size()
				if _tex[SEQ[_seq_i]]:
					_bg.texture = _tex[SEQ[_seq_i]]
			else:
				_bg.modulate = Color(k, k, k * 1.05)
	# тихая фраза внизу справа: появляется и тает
	_whisper_t -= dt
	if _whisper_t <= 0.0:
		_whisper.text = WHISPERS[randi() % WHISPERS.size()]
		var tw := create_tween()
		tw.tween_property(_whisper, "modulate:a", 0.55, 2.5)
		tw.tween_interval(3.0)
		tw.tween_property(_whisper, "modulate:a", 0.0, 3.0)
		_whisper_t = randf_range(16.0, 26.0)
	# редкие далёкие звуки: стук, шёпот, сердце
	_sfx_t -= dt
	if _sfx_t <= 0.0:
		var pick: String = ["knock", "whisper_name", "heartbeat", "door_creak_slow", "metal_creak"][randi() % 5]
		_sfx.stream = load("res://story/sfx/%s.wav" % pick)
		_sfx.volume_db = -24.0 if pick != "heartbeat" else -18.0
		_sfx.play()
		_sfx_t = randf_range(20.0, 40.0)
	# название иногда чуть «дрожит» — как от толчка
	var kk: float = maxf(0.0, sin(_t * 0.6) - 0.97) * 30.0
	_title.position.x = randf_range(-1.0, 1.0) * kk * 3.0


var _flick_clock := 0.0
