extends CanvasLayer
## Пауза (Esc) — одна и та же во всей игре: игра замирает и темнеет, слева — «ПАУЗА», глава и пункты:
## Продолжить · Начать главу заново · Управление · Настройки · Главное меню · Выйти из игры.
## Справа — содержимое пункта (клавиши, ползунки) или вопрос «Точно?» перед выходом и перезапуском.
## Мышью или клавишами: ↑/↓ — выбрать, Enter — нажать, Esc — назад / продолжить игру.

const UI = preload("res://story/ui_kit.gd")

signal closed

var capture_mouse := true            # после паузы мышь снова захвачена (в игре — да, в эпилоге — нет)
var _root: Control
var _items: VBoxContainer
var _side: VBoxContainer
var _chapter: Label
var _first: Button
var _sub := ""                       # что открыто справа: "", "controls", "settings", "confirm"
var _click: AudioStreamPlayer


func _ready() -> void:
	layer = 110                                   # поверх затемнения (GameState — слой 100)
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)
	var grad := TextureRect.new()                 # слева темнее: текст читается на любой картинке
	var gt := GradientTexture2D.new()
	var gr := Gradient.new()
	gr.set_color(0, Color(0, 0, 0, 0.85))
	gr.set_color(1, Color(0, 0, 0, 0.0))
	gt.gradient = gr
	gt.fill_to = Vector2(1, 0)
	grad.texture = gt
	grad.stretch_mode = TextureRect.STRETCH_SCALE
	grad.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	grad.size = Vector2(900, 0)
	grad.custom_minimum_size = Vector2(900, 0)
	grad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(grad)
	var left := VBoxContainer.new()
	left.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	left.offset_left = 90
	left.offset_right = 560
	left.alignment = BoxContainer.ALIGNMENT_CENTER
	left.add_theme_constant_override("separation", 6)
	_root.add_child(left)
	left.add_child(UI.label("ПАУЗА", 76, Color(0.95, 0.92, 0.86), 600))
	_chapter = UI.label("", 22, UI.DIM, 300)
	left.add_child(_chapter)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 26)
	left.add_child(gap)
	_items = VBoxContainer.new()
	_items.add_theme_constant_override("separation", 4)
	left.add_child(_items)
	_first = _add("Продолжить", close)
	_add("Начать главу заново", func(): _confirm("Начать главу заново?", "Всё, что сделано в этой главе, придётся пройти снова.", "Начать заново", GameState.restart_chapter))
	_add("Управление", func(): _show("controls"))
	_add("Настройки", func(): _show("settings"))
	_add("Главное меню", func(): _confirm("Выйти в главное меню?", "Продолжить потом можно с начала этой главы.", "Выйти в меню", GameState.to_menu))
	_add("Выйти из игры", func(): _confirm("Выйти из игры?", "Продолжить потом можно с начала этой главы.", "Выйти", func(): get_tree().quit()))
	_side = VBoxContainer.new()
	_side.set_anchors_preset(Control.PRESET_FULL_RECT)
	_side.offset_left = 640
	_side.offset_right = -80
	_side.alignment = BoxContainer.ALIGNMENT_CENTER
	_side.add_theme_constant_override("separation", 18)
	_root.add_child(_side)
	var hint := UI.label("↑ ↓ — выбрать     Enter — нажать     Esc — назад / продолжить", 18, Color(UI.DIM.r, UI.DIM.g, UI.DIM.b, 0.8), 300)
	hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	hint.offset_left = 90
	hint.offset_top = -64
	hint.offset_right = 1200
	hint.offset_bottom = -30
	_root.add_child(hint)
	_click = AudioStreamPlayer.new()
	if ResourceLoader.exists("res://story/sfx/ui_tick.wav"):
		_click.stream = load("res://story/sfx/ui_tick.wav")
	_click.volume_db = -14.0
	add_child(_click)


func _add(text: String, cb: Callable) -> Button:
	var b: Button = UI.item(text, 32, cb, func(): _tick())
	_items.add_child(b)
	return b


func _tick() -> void:
	if visible and _click.stream:
		_click.pitch_scale = randf_range(0.95, 1.08)
		_click.play()


func is_open() -> bool:
	return visible


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func open() -> void:
	if visible:
		return
	_chapter.text = GameState.chapter_name() if GameState.current_scene != "" else ""
	_show("")
	visible = true
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_first.grab_focus.call_deferred()


func close() -> void:
	if not visible:
		return
	visible = false
	_show("")
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if capture_mouse else Input.MOUSE_MODE_VISIBLE
	closed.emit()


func _clear_side() -> void:
	for c in _side.get_children():
		c.queue_free()


func _show(what: String) -> void:
	_sub = what
	_clear_side()
	_items.modulate.a = 1.0
	match what:
		"controls":
			_side.add_child(UI.label("Управление", 40, Color(0.95, 0.92, 0.86), 500))
			_side.add_child(UI.controls_grid())
		"settings":
			_side.add_child(UI.label("Настройки", 40, Color(0.95, 0.92, 0.86), 500))
			var box: VBoxContainer = UI.settings_box()
			_side.add_child(box)
			var first_slider: Control = box.get_child(0).get_child(1)
			first_slider.grab_focus.call_deferred()


## «Точно?» справа: две кнопки, по умолчанию выбрана «Нет» (случайный Enter ничего не ломает).
func _confirm(title: String, text: String, yes_text: String, yes: Callable) -> void:
	_show("confirm")
	_sub = "confirm"
	_items.modulate.a = 0.45
	_side.add_child(UI.label(title, 40, Color(0.95, 0.92, 0.86), 500))
	_side.add_child(UI.label(text, 22, UI.TEXT, 300))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 30)
	_side.add_child(row)
	var yes_b: Button = UI.item(yes_text, 30, func():
		visible = false
		get_tree().paused = false
		yes.call(), func(): _tick())
	var no_b: Button = UI.item("Нет", 30, func(): _show(""), func(): _tick())
	row.add_child(no_b)
	row.add_child(yes_b)
	no_b.grab_focus.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("pause"):
		return
	get_viewport().set_input_as_handled()
	if not visible:
		open()
	elif _sub != "":
		_show("")
		_first.grab_focus.call_deferred()
	else:
		close()
