extends Control
## Главное меню «The Last Shake»: новая игра, выбор главы, графика, выход.

var _main: VBoxContainer
var _chapters: VBoxContainer
var _drone: AudioStreamPlayer
var _t := 0.0
var _title: Label


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().paused = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.022, 0.025)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 18)
	box.custom_minimum_size = Vector2(700, 0)
	box.position = Vector2(-350, -280)
	add_child(box)
	_title = _label("THE LAST SHAKE", 84, Color(0.92, 0.88, 0.8))
	box.add_child(_title)
	box.add_child(_label("Последний Скачок · Soʻnggi Silkiniş", 26, Color(0.7, 0.66, 0.6)))
	box.add_child(_label("Санаторий «Оромгох», 1975", 20, Color(0.55, 0.52, 0.48)))
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 30)
	box.add_child(gap)
	_main = VBoxContainer.new()
	_main.add_theme_constant_override("separation", 10)
	box.add_child(_main)
	_button(_main, "Новая игра", func(): GameState.go(GameState.PROLOGUE, "start"))
	_button(_main, "Главы", _show_chapters.bind(true))
	_button(_main, "Графика: " + str(GraphicsSettings.settings.get("name", "")), _cycle_graphics)
	_button(_main, "Выход", func(): get_tree().quit())
	_chapters = VBoxContainer.new()
	_chapters.add_theme_constant_override("separation", 8)
	_chapters.visible = false
	box.add_child(_chapters)
	for ch in GameState.CHAPTERS:
		_button(_chapters, ch[0], GameState.go.bind(ch[1], ch[2]))
	_button(_chapters, "← Назад", _show_chapters.bind(false))
	var foot := _label("Автор игры и сценария: Саман", 18, Color(0.5, 0.48, 0.45))
	foot.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	foot.position = Vector2(-350, -60)
	foot.size = Vector2(700, 30)
	add_child(foot)
	var ver := _label(GameState.VERSION, 18, Color(0.62, 0.58, 0.5))
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	ver.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	ver.position = Vector2(24, -46)
	ver.size = Vector2(420, 30)
	add_child(ver)
	_drone = AudioStreamPlayer.new()
	var s: AudioStream = load("res://story/sfx/drone_low.wav")
	if s is AudioStreamWAV:
		var w: AudioStreamWAV = (s as AudioStreamWAV).duplicate()
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_end = int(w.get_length() * w.mix_rate)
		s = w
	_drone.stream = s
	_drone.volume_db = -14.0
	add_child(_drone)
	_drone.play()
	GameState.fade_to(0.0, 1.0)


func _label(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l


func _button(parent: Control, text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(420, 46)
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	b.add_theme_font_size_override("font_size", 22)
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.08, 0.075, 0.07, 0.9)
	st.border_color = Color(0.45, 0.38, 0.28, 0.7)
	st.set_border_width_all(1)
	st.set_content_margin_all(8)
	var hv: StyleBoxFlat = st.duplicate()
	hv.bg_color = Color(0.2, 0.15, 0.1, 0.95)
	b.add_theme_stylebox_override("normal", st)
	b.add_theme_stylebox_override("hover", hv)
	b.add_theme_stylebox_override("focus", hv)
	b.add_theme_stylebox_override("pressed", hv)
	b.pressed.connect(action)
	parent.add_child(b)
	return b


func _show_chapters(on: bool) -> void:
	_main.visible = not on
	_chapters.visible = on


func _cycle_graphics() -> void:
	GraphicsSettings.cycle()
	for b in _main.get_children():
		if b is Button and (b as Button).text.begins_with("Графика"):
			(b as Button).text = "Графика: " + str(GraphicsSettings.settings.get("name", ""))


func _process(dt: float) -> void:
	_t += dt
	# название иногда «дрожит» — как от толчка
	var k: float = maxf(0.0, sin(_t * 0.6) - 0.97) * 30.0
	_title.position.x = randf_range(-1.0, 1.0) * k * 4.0
