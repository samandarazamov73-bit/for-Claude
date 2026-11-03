extends CanvasLayer
## Интерфейс начала игры: затемнение, субтитры, выбор ответа, подсказка, задание, шкала маршрута,
## заставка, пауза и финальная карточка. Всё строится кодом.

signal choice_made(index: int)
signal resume_pressed
signal menu_pressed
signal restart_pressed
signal pause_toggle

const Story = preload("res://intro/story.gd")

const ROUTE_W: float = 336.0
const CHOICE_TIMEOUT: float = 25.0

var _fade: ColorRect
var _subtitle: RichTextLabel
var _sub_bg: ColorRect
var _choices: RichTextLabel
var _choices_bg: ColorRect
var _prompt: Label
var _objective: Label
var _crosshair: ColorRect
var _title_a: Label
var _title_b: Label
var _hint: Label
var _route_box: Control
var _route_bus: ColorRect
var _route_stops: Control
var _pause: Control
var _pause_continue: Button
var _end: Control
var _end_title: Label
var _end_text: Label

var _choice_active: bool = false
var _choice_count: int = 0
var _choice_time: float = 0.0


func _ready() -> void:
	layer = 50
	process_mode = Node.PROCESS_MODE_ALWAYS
	var root: Control = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_objective = _label("", 20, HORIZONTAL_ALIGNMENT_LEFT)
	_objective.position = Vector2(24, 18)
	root.add_child(_objective)

	_crosshair = ColorRect.new()
	_crosshair.color = Color(1, 1, 1, 0.35)
	_crosshair.set_anchors_preset(Control.PRESET_CENTER)
	_crosshair.offset_left = -3.0
	_crosshair.offset_right = 3.0
	_crosshair.offset_top = -3.0
	_crosshair.offset_bottom = 3.0
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_crosshair)

	_prompt = _label("", 22, HORIZONTAL_ALIGNMENT_CENTER)
	_prompt.anchor_left = 0.25
	_prompt.anchor_right = 0.75
	_prompt.anchor_top = 0.58
	_prompt.anchor_bottom = 0.64
	_prompt.visible = false
	root.add_child(_prompt)

	_hint = _label("E — действие   ·   1 / 2 / 3 — выбрать ответ   ·   Enter — пропустить реплику   ·   Tab (держать) — перемотка   ·   Esc — пауза", 15, HORIZONTAL_ALIGNMENT_LEFT)
	_hint.position = Vector2(24, 0)
	_hint.anchor_top = 1.0
	_hint.anchor_bottom = 1.0
	_hint.offset_top = -34.0
	_hint.offset_bottom = -8.0
	_hint.modulate.a = 0.0
	root.add_child(_hint)

	_build_route_hud(root)

	_fade = ColorRect.new()
	_fade.color = Color(0, 0, 0, 1)
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_fade)

	# Субтитры, выбор и заставка — ПОВЕРХ затемнения: слова мамы слышны и видны в темноте.
	_sub_bg = ColorRect.new()
	_sub_bg.color = Color(0, 0, 0, 0.5)
	_set_box(_sub_bg, 0.12, 0.88, -150.0, -60.0)
	_sub_bg.visible = false
	root.add_child(_sub_bg)
	_subtitle = _rich(24)
	_set_box(_subtitle, 0.13, 0.87, -142.0, -66.0)
	_subtitle.visible = false
	root.add_child(_subtitle)

	_choices_bg = ColorRect.new()
	_choices_bg.color = Color(0, 0, 0, 0.55)
	_set_box(_choices_bg, 0.2, 0.8, -310.0, -166.0)
	_choices_bg.visible = false
	root.add_child(_choices_bg)
	_choices = _rich(22)
	_set_box(_choices, 0.21, 0.79, -302.0, -172.0)
	_choices.visible = false
	root.add_child(_choices)

	_title_a = _label("", 56, HORIZONTAL_ALIGNMENT_CENTER)
	_title_a.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_a.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_a.offset_top = -30.0
	_title_a.modulate.a = 0.0
	root.add_child(_title_a)
	_title_b = _label("", 22, HORIZONTAL_ALIGNMENT_CENTER)
	_title_b.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_b.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_b.offset_top = 50.0
	_title_b.modulate.a = 0.0
	root.add_child(_title_b)


	_build_pause(root)
	_build_end(root)


func _label(text: String, size: int, align: HorizontalAlignment) -> Label:
	var l: Label = Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(1, 1, 1))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 6)
	l.horizontal_alignment = align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _rich(size: int) -> RichTextLabel:
	var r: RichTextLabel = RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = false
	r.scroll_active = false
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.add_theme_font_size_override("normal_font_size", size)
	r.add_theme_font_size_override("bold_font_size", size)
	r.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	r.add_theme_constant_override("outline_size", 5)
	return r


## Прямоугольник по низу экрана: доли ширины и отступы от нижнего края.
func _set_box(c: Control, left: float, right: float, top_off: float, bottom_off: float) -> void:
	c.anchor_left = left
	c.anchor_right = right
	c.anchor_top = 1.0
	c.anchor_bottom = 1.0
	c.offset_top = top_off
	c.offset_bottom = bottom_off
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _build_route_hud(root: Control) -> void:
	_route_box = Control.new()
	_route_box.anchor_left = 1.0
	_route_box.anchor_right = 1.0
	_route_box.offset_left = -(ROUTE_W + 24.0)
	_route_box.offset_right = -24.0
	_route_box.offset_top = 20.0
	_route_box.offset_bottom = 70.0
	_route_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_route_box)
	var line: ColorRect = ColorRect.new()
	line.color = Color(1, 1, 1, 0.3)
	line.position = Vector2(0, 10)
	line.size = Vector2(ROUTE_W, 4)
	_route_box.add_child(line)
	_route_stops = Control.new()
	_route_box.add_child(_route_stops)
	_route_bus = ColorRect.new()
	_route_bus.color = Color(0.25, 0.75, 0.42)
	_route_bus.size = Vector2(20, 20)
	_route_bus.position = Vector2(-10, 2)
	_route_box.add_child(_route_bus)


## stops: [{name: String, at: float 0…1, final: bool}]
func setup_route(stops: Array) -> void:
	for ch in _route_stops.get_children():
		ch.queue_free()
	for st in stops:
		var dot: ColorRect = ColorRect.new()
		dot.color = Color(0.85, 0.2, 0.25) if bool(st["final"]) else Color(0.9, 0.9, 0.9)
		dot.size = Vector2(12, 12)
		dot.position = Vector2(float(st["at"]) * ROUTE_W - 6.0, 6.0)
		_route_stops.add_child(dot)
		var lab: Label = _label(str(st["name"]), 12, HORIZONTAL_ALIGNMENT_CENTER)
		lab.custom_minimum_size = Vector2(120, 0)
		lab.position = Vector2(float(st["at"]) * ROUTE_W - 60.0, 20.0)
		lab.add_theme_constant_override("outline_size", 4)
		_route_stops.add_child(lab)


func set_route_progress(f: float) -> void:
	_route_bus.position.x = clampf(f, 0.0, 1.0) * ROUTE_W - 10.0


func show_route(v: bool) -> void:
	_route_box.visible = v


func _build_pause(root: Control) -> void:
	_pause = ColorRect.new()
	(_pause as ColorRect).color = Color(0, 0, 0, 0.65)
	_pause.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause.visible = false
	root.add_child(_pause)
	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause.add_child(center)
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	center.add_child(box)
	var title: Label = _label("Пауза", 40, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(title)
	_pause_continue = Button.new()
	_pause_continue.text = "Продолжить"
	_pause_continue.custom_minimum_size = Vector2(300, 46)
	_pause_continue.pressed.connect(func() -> void: resume_pressed.emit())
	box.add_child(_pause_continue)
	var menu_b: Button = Button.new()
	menu_b.text = "В меню"
	menu_b.custom_minimum_size = Vector2(300, 46)
	menu_b.pressed.connect(func() -> void: menu_pressed.emit())
	box.add_child(menu_b)


func _build_end(root: Control) -> void:
	_end = ColorRect.new()
	(_end as ColorRect).color = Color(0, 0, 0, 1)
	_end.set_anchors_preset(Control.PRESET_FULL_RECT)
	_end.visible = false
	root.add_child(_end)
	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_end.add_child(center)
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	center.add_child(box)
	_end_title = _label(Story.END_TITLE, 44, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(_end_title)
	_end_text = _label(Story.END_TEXT, 22, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(_end_text)
	var again: Button = Button.new()
	again.text = "Начать заново"
	again.custom_minimum_size = Vector2(300, 46)
	again.pressed.connect(func() -> void: restart_pressed.emit())
	box.add_child(again)
	var menu_b: Button = Button.new()
	menu_b.text = "В меню"
	menu_b.custom_minimum_size = Vector2(300, 46)
	menu_b.pressed.connect(func() -> void: menu_pressed.emit())
	box.add_child(menu_b)


# --- Управление интерфейсом ----------------------------------------------------------

func set_fade(v: float) -> void:
	_fade.color.a = clampf(v, 0.0, 1.0)


func get_fade() -> float:
	return _fade.color.a


func set_objective(text: String) -> void:
	_objective.text = text


func set_prompt(text: String) -> void:
	_prompt.text = text
	_prompt.visible = text != ""
	_crosshair.color.a = 0.9 if text != "" else 0.35


func set_crosshair(v: bool) -> void:
	_crosshair.visible = v


func set_hint_alpha(a: float) -> void:
	_hint.modulate.a = a


func set_title(a: String, b: String, alpha: float) -> void:
	_title_a.text = a
	_title_b.text = b
	_title_a.modulate.a = alpha
	_title_b.modulate.a = alpha


func show_line(who: String, text: String) -> void:
	var sp: Dictionary = Story.SPEAKERS.get(who, {"name": who, "color": "#ffffff"})
	_subtitle.text = "[center][color=%s][b]%s:[/b][/color]  %s[/center]" % [sp["color"], sp["name"], text]
	_subtitle.visible = true
	_sub_bg.visible = true


func hide_line() -> void:
	_subtitle.visible = false
	_sub_bg.visible = false


## Варианты ответа. Выбор — клавишами 1/2/3. Нет ответа 25 с — герой промолчал (−1).
func choose(options: Array) -> int:
	var t: String = ""
	for i in options.size():
		t += "[color=#9fd3ff][b]%d[/b][/color]   %s\n" % [i + 1, str(options[i])]
	_choices.text = t
	_choices.visible = true
	_choices_bg.visible = true
	_choice_active = true
	_choice_count = options.size()
	_choice_time = CHOICE_TIMEOUT
	var idx: int = await choice_made
	_choice_active = false
	_choices.visible = false
	_choices_bg.visible = false
	return idx


func is_choosing() -> bool:
	return _choice_active


func pick(i: int) -> void:
	if _choice_active and i >= 0 and i < _choice_count:
		choice_made.emit(i)


func cancel_choice() -> void:
	if _choice_active:
		choice_made.emit(-1)


func show_pause(on: bool) -> void:
	_pause.visible = on
	if on:
		_pause_continue.grab_focus()


func show_end() -> void:
	_end.visible = true


## Esc: пауза / продолжить. Обрабатывается здесь, потому что интерфейс работает и на паузе (главный узел — нет).
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		pause_toggle.emit()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _choice_active and not get_tree().paused:
		_choice_time -= delta
		if _choice_time <= 0.0:
			choice_made.emit(-1)
