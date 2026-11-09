extends CanvasLayer
## Interface: crosshair, interaction prompt, short messages, room name, joystick speed setting,
## intro with controls, pause menu (Esc), and a light vignette with film grain over the picture.

var prompt_label: Label
var msg_label: Label
var room_label: Label
var debug_label: Label
var speed_bars := []
var intro: Control
var menu: Control
var _msg_t := 0.0
var _room_t := 0.0
var _intro_t := 0.0
var _focused := true

const GRAIN_SHADER := """
shader_type canvas_item;
uniform float vignette = 0.66;
uniform float grain = 0.055;
float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
void fragment() {
	vec2 uv = UV - 0.5;
	uv.x *= 1.6;
	float v = smoothstep(0.35, 0.95, length(uv)) * vignette;
	float n = hash(floor(FRAGCOORD.xy * 0.75) + floor(TIME * 24.0) * vec2(1.7, 3.1));
	float g = (n - 0.5) * 2.0 * grain;
	float ag = abs(g) * (1.0 - v);
	float a = v + ag;
	vec3 c = g > 0.0 ? vec3(1.0) : vec3(0.0);
	COLOR = vec4(c * ag / max(a, 0.0001), a);
}
"""

# Medium and High: the picture as seen through an old film lens: a slight barrel distortion (straight lines
# bow out a little towards the edges), chromatic aberration growing towards the corners, vignette and grain
# (costs one copy of the screen per frame).
const LENS_SHADER := """
shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;
uniform float vignette = 0.66;
uniform float grain = 0.055;
uniform float aberration = 0.0015;      // about 5 px in the corners of a 2K picture
uniform float barrel = 0.035;           // corners stay where they are, the middle is 3.5 % larger
float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
void fragment() {
	vec2 d = SCREEN_UV - 0.5;
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	vec2 p = d * vec2(aspect, 1.0);
	float r2 = dot(p, p) / (0.25 * aspect * aspect + 0.25);
	vec2 uv0 = 0.5 + d * (1.0 + barrel * r2) / (1.0 + barrel);
	vec2 off = d * aberration * r2 * 4.0;
	vec3 col = vec3(texture(screen_tex, uv0 + off).r, texture(screen_tex, uv0).g,
		texture(screen_tex, uv0 - off).b);
	vec2 uv = UV - 0.5;
	uv.x *= 1.6;
	float v = smoothstep(0.35, 0.95, length(uv)) * vignette;
	float n = hash(floor(FRAGCOORD.xy * 0.75) + floor(TIME * 24.0) * vec2(1.7, 3.1));
	col += (n - 0.5) * 2.0 * grain * (1.0 - v);
	COLOR = vec4(col * (1.0 - v), 1.0);
}
"""
var _fx: ColorRect
var _overlay_mat: ShaderMaterial
var _lens_mat: ShaderMaterial


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	var fx := ColorRect.new()
	fx.set_anchors_preset(Control.PRESET_FULL_RECT)
	fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = GRAIN_SHADER
	_overlay_mat = ShaderMaterial.new()
	_overlay_mat.shader = sh
	var lsh := Shader.new()
	lsh.code = LENS_SHADER
	_lens_mat = ShaderMaterial.new()
	_lens_mat.shader = lsh
	fx.material = _overlay_mat
	add_child(fx)
	_fx = fx
	var dot := ColorRect.new()
	dot.color = Color(1, 1, 1, 0.55)
	dot.size = Vector2(4, 4)
	dot.set_anchors_preset(Control.PRESET_CENTER)
	dot.position = Vector2(-2, -2)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dot)
	prompt_label = _label(22, Color(1, 0.96, 0.88))
	prompt_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	prompt_label.position = Vector2(-300, -150)
	prompt_label.size = Vector2(600, 40)
	msg_label = _label(26, Color(1, 0.9, 0.8))
	msg_label.set_anchors_preset(Control.PRESET_CENTER)
	msg_label.position = Vector2(-300, 60)
	msg_label.size = Vector2(600, 40)
	room_label = _label(20, Color(0.92, 0.88, 0.78))
	room_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	room_label.position = Vector2(28, 22)
	room_label.size = Vector2(700, 60)
	var sp := HBoxContainer.new()
	sp.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	sp.position = Vector2(28, -52)
	sp.add_theme_constant_override("separation", 5)
	add_child(sp)
	var l := Label.new()
	l.text = "Скорость "
	l.add_theme_font_size_override("font_size", 18)
	l.add_theme_color_override("font_color", Color(0.85, 0.82, 0.74, 0.85))
	sp.add_child(l)
	for i in 5:
		var b := ColorRect.new()
		b.custom_minimum_size = Vector2(16, 14 + i * 3)
		b.size_flags_vertical = Control.SIZE_SHRINK_END
		sp.add_child(b)
		speed_bars.append(b)
	set_speed(2, 5)
	# F3: where you are (room, coordinates, frame rate), for screenshots of anything that looks wrong
	debug_label = _label(15, Color(0.8, 1.0, 0.8))
	debug_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	debug_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	debug_label.position = Vector2(-620, 16)
	debug_label.size = Vector2(600, 60)
	debug_label.visible = false
	_build_menu()


func _label(size: int, col: Color) -> Label:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("shadow_offset_x", 2)
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l


const CONTROLS := "W / S — вперёд / назад     A / D — поворот\nМышь — смотреть по сторонам     E — открыть, нажать, поговорить     ЛКМ — удар     F — фонарик\nКолесо мыши или Q / R — скорость коляски (1–5)     H — гудок     F3 — где я\nF11 (Mac: Ctrl+Cmd+F) — полный экран     G — качество графики     L — не больше 30 кадров/с     Esc — пауза"


func _panel(title: String, body: String) -> PanelContainer:
	var p := PanelContainer.new()
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.04, 0.035, 0.03, 0.82)
	st.border_color = Color(0.55, 0.45, 0.3, 0.6)
	st.set_border_width_all(1)
	st.set_content_margin_all(28)
	p.add_theme_stylebox_override("panel", st)
	p.set_anchors_preset(Control.PRESET_CENTER)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	p.add_child(v)
	var t := Label.new()
	t.text = title
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.add_theme_font_size_override("font_size", 40)
	t.add_theme_color_override("font_color", Color(0.93, 0.86, 0.72))
	v.add_child(t)
	var b := Label.new()
	b.text = body
	b.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.add_theme_font_size_override("font_size", 18)
	b.add_theme_color_override("font_color", Color(0.85, 0.82, 0.75))
	v.add_child(b)
	add_child(p)
	return p


func _build_menu() -> void:
	menu = _panel("Пауза", CONTROLS)
	var v: VBoxContainer = menu.get_child(0)
	var h := HBoxContainer.new()
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_theme_constant_override("separation", 20)
	v.add_child(h)
	var cont := Button.new()
	cont.text = "Продолжить"
	cont.pressed.connect(func(): toggle_menu())
	h.add_child(cont)
	var m := Button.new()
	m.text = "В главное меню"
	m.pressed.connect(func(): GameState.to_menu())
	h.add_child(m)
	var q := Button.new()
	q.text = "Выйти"
	q.pressed.connect(func(): get_tree().quit())
	h.add_child(q)
	menu.visible = false
	_center(menu)


func _center(c: Control) -> void:
	await get_tree().process_frame
	c.reset_size()
	c.position = (c.get_parent_area_size() - c.size) * 0.5      # position is measured from the top-left corner


func show_intro() -> void:
	intro = _panel("Санаторий", "Электроколяска. Ночь. Здание давно никто не убирал.\nСвет в комнатах включается у двери, " +
		"на этажи можно подняться только на лифте.\n\n" + CONTROLS + "\n\nНажмите любую клавишу")
	_center(intro)
	_intro_t = 14.0


## quality.gd: the lens look on Medium and High, the plain overlay on Low.
func set_lens(on: bool) -> void:
	if _fx:
		_fx.material = _lens_mat if on else _overlay_mat


func menu_open() -> bool:
	return menu.visible


func toggle_menu() -> void:
	menu.visible = not menu.visible
	get_tree().paused = menu.visible
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if menu.visible else Input.MOUSE_MODE_CAPTURED
	if menu.visible:
		_center(menu)
	update_fps_cap()


## The paused game and a game left in the background still draw every frame: cap the frame rate there,
## so a fanless MacBook does not heat up while nobody plays. 30 fps behind the pause menu looks the same,
## because the picture stands still (the film grain changes 24 times a second anyway). In play, the
## limit from quality.gd (L key) applies.
func update_fps_cap() -> void:
	var args := OS.get_cmdline_user_args()
	if "--bench" in args or "--shots" in args or "--test" in args:
		return
	var q = get_parent().get("quality")
	var play: int = q.fps_cap() if q else 0
	if not _focused:
		Engine.max_fps = 10
	elif menu and menu.visible:
		Engine.max_fps = 30 if play == 0 else mini(play, 30)
	else:
		Engine.max_fps = play


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_focused = what == NOTIFICATION_APPLICATION_FOCUS_IN
		update_fps_cap()


func _unhandled_input(event: InputEvent) -> void:
	if intro and intro.visible and (event is InputEventKey or event is InputEventMouseButton) and event.is_pressed():
		intro.visible = false
	if event.is_action_pressed("pause"):
		toggle_menu()
	elif event.is_action_pressed("debug_info"):
		debug_label.visible = not debug_label.visible


func set_prompt(s: String) -> void:
	prompt_label.text = s


func message(s: String, t := 2.2) -> void:
	msg_label.text = s
	msg_label.modulate.a = 1.0
	_msg_t = t


func show_room(r: Dictionary) -> void:
	var num: String = r.get("num", "")
	room_label.text = (num + "  " if num != "" else "") + String(r.get("name", ""))
	room_label.modulate.a = 1.0
	_room_t = 3.5


func set_speed(level: int, n: int) -> void:
	for i in speed_bars.size():
		speed_bars[i].color = Color(0.95, 0.75, 0.3, 0.9) if i <= level else Color(0.4, 0.38, 0.34, 0.5)


func _process(dt: float) -> void:
	if debug_label.visible:
		var g = get_parent()
		if g.player:
			var p: Vector3 = g.player.global_position
			var r: Dictionary = g.room_at(p + Vector3(0, 0.3, 0))
			debug_label.text = "%s  %s\nx %.1f  y %.1f  z %.1f   %d fps" % [r.get("id", "?"), r.get("name", ""), p.x, p.y, p.z,
				Engine.get_frames_per_second()]
	if _msg_t > 0.0:
		_msg_t -= dt
		msg_label.modulate.a = clamp(_msg_t / 0.6, 0.0, 1.0)
	if _room_t > 0.0:
		_room_t -= dt
		room_label.modulate.a = clamp(_room_t / 0.8, 0.0, 1.0)
	if intro and intro.visible:
		_intro_t -= dt
		if _intro_t <= 0.0:
			intro.visible = false
