extends RefCounted
## Общий вид меню (главное меню и пауза): шрифт Oswald (узкий, без засечек — заголовки и пункты), Noto Sans
## для мелкого текста; пункты меню — текст без рамок, при наведении — светлее, с чертой слева; ползунки
## и переключатели настроек; таблица клавиш.

const OSWALD := "res://story/fonts/Oswald.ttf"
const TEXT := Color(0.86, 0.83, 0.77)
const DIM := Color(0.56, 0.53, 0.49)
const ACCENT := Color(0.78, 0.16, 0.12)

static var _fonts := {}


## Oswald нужной насыщенности (200 — тонкий, 400 — обычный, 600 — жирный).
static func font(weight := 400) -> Font:
	if _fonts.has(weight):
		return _fonts[weight]
	var base: Font = load(OSWALD) if ResourceLoader.exists(OSWALD) else ThemeDB.fallback_font
	var fv := FontVariation.new()
	fv.base_font = base
	fv.variation_opentype = {"wght": weight}
	_fonts[weight] = fv
	return fv


static func label(text: String, size: int, col := TEXT, weight := 400, align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align
	l.add_theme_font_override("font", font(weight))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_x", 2)
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## Пункт меню: крупный текст, при наведении/фокусе — ярче, с красной чертой слева. Звук наведения — hover.
static func item(text: String, size := 30, on_press: Callable = Callable(), hover: Callable = Callable()) -> Button:
	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.flat = false
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_font_override("font", font(400))
	b.add_theme_font_size_override("font_size", size)
	b.add_theme_color_override("font_color", Color(TEXT.r, TEXT.g, TEXT.b, 0.78))
	b.add_theme_color_override("font_hover_color", Color(1.0, 0.97, 0.92))
	b.add_theme_color_override("font_focus_color", Color(1.0, 0.97, 0.92))
	b.add_theme_color_override("font_pressed_color", ACCENT.lightened(0.3))
	b.add_theme_color_override("font_disabled_color", Color(DIM.r, DIM.g, DIM.b, 0.45))
	var empty := StyleBoxEmpty.new()
	empty.content_margin_left = 22
	empty.content_margin_top = 2
	empty.content_margin_bottom = 2
	var mark := StyleBoxFlat.new()
	mark.bg_color = Color(0, 0, 0, 0)
	mark.border_color = ACCENT
	mark.border_width_left = 3
	mark.content_margin_left = 22
	mark.content_margin_top = 2
	mark.content_margin_bottom = 2
	b.add_theme_stylebox_override("normal", empty)
	b.add_theme_stylebox_override("disabled", empty)
	b.add_theme_stylebox_override("hover", mark)
	b.add_theme_stylebox_override("focus", mark)
	b.add_theme_stylebox_override("pressed", mark)
	if on_press.is_valid():
		b.pressed.connect(on_press)
	if hover.is_valid():
		b.mouse_entered.connect(func(): b.grab_focus())
		b.focus_entered.connect(hover)
	else:
		b.mouse_entered.connect(func(): b.grab_focus())
	return b


## Строка «название — ползунок — значение».
static func slider(text: String, value: float, lo: float, hi: float, step: float, fmt: Callable, on_change: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	var l := label(text, 22, TEXT, 400)
	l.custom_minimum_size = Vector2(250, 0)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	s.custom_minimum_size = Vector2(280, 28)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.focus_mode = Control.FOCUS_ALL
	var track := StyleBoxFlat.new()
	track.bg_color = Color(1, 1, 1, 0.14)
	track.content_margin_top = 2
	track.content_margin_bottom = 2
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.85)
	fill.content_margin_top = 2
	fill.content_margin_bottom = 2
	s.add_theme_stylebox_override("slider", track)
	s.add_theme_stylebox_override("grabber_area", fill)
	s.add_theme_stylebox_override("grabber_area_highlight", fill)
	row.add_child(s)
	var v := label(fmt.call(value), 22, DIM, 300)
	v.custom_minimum_size = Vector2(70, 0)
	row.add_child(v)
	s.value_changed.connect(func(x):
		v.text = fmt.call(x)
		on_change.call(x))
	return row


static func toggle(text: String, on: bool, on_change: Callable) -> CheckButton:
	var c := CheckButton.new()
	c.text = text
	c.button_pressed = on
	c.focus_mode = Control.FOCUS_ALL
	c.add_theme_font_override("font", font(400))
	c.add_theme_font_size_override("font_size", 22)
	c.add_theme_color_override("font_color", TEXT)
	c.add_theme_color_override("font_hover_color", Color(1, 0.97, 0.92))
	c.add_theme_color_override("font_focus_color", Color(1, 0.97, 0.92))
	c.add_theme_color_override("font_pressed_color", TEXT)
	c.toggled.connect(on_change)
	return c


## Управление: клавиша — действие, в две колонки.
const CONTROLS := [
	["W / S", "вперёд / назад"], ["A / D", "поворот коляски"], ["Мышь", "смотреть по сторонам"],
	["E", "открыть, нажать, поговорить"], ["E (держать)", "перегрызть бинты"], ["ЛКМ", "удар"],
	["F", "фонарик"], ["Q / R, колесо", "скорость коляски 1–5"], ["H", "гудок"],
	["Пробел / Enter", "пропустить реплику"], ["Tab (держать)", "перемотать поездку в автобусе"],
	["L", "не больше 30 кадров/с"], ["F11", "полный экран (Mac: Ctrl+Cmd+F)"], ["F3", "где я (для скриншота)"],
	["Esc", "пауза"],
]


static func controls_grid() -> GridContainer:
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 28)
	g.add_theme_constant_override("v_separation", 6)
	for row in CONTROLS:
		var k := label(String(row[0]), 21, Color(1.0, 0.92, 0.8), 500, HORIZONTAL_ALIGNMENT_RIGHT)
		k.custom_minimum_size = Vector2(190, 0)
		g.add_child(k)
		g.add_child(label(String(row[1]), 21, TEXT, 300))
	return g


## Настройки: громкость, чувствительность мыши, полный экран — сразу сохраняются.
static func settings_box() -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 16)
	v.add_child(slider("Громкость", GameState.volume, 0.0, 1.0, 0.05, func(x): return "%d %%" % roundi(x * 100.0),
		func(x):
			GameState.volume = x
			GameState.save_settings()))
	v.add_child(slider("Чувствительность мыши", GameState.mouse_sens, 0.3, 2.5, 0.05, func(x): return "%.2f" % x,
		func(x):
			GameState.mouse_sens = x
			GameState.save_settings()))
	v.add_child(toggle("Полный экран", GameState.fullscreen, func(on):
		GameState.fullscreen = on
		GameState.save_settings()))
	v.add_child(label("Графика одна — «Средняя»: реалистичный свет без тяжёлых эффектов.", 18, DIM, 300))
	return v
