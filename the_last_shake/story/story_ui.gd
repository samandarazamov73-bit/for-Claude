extends CanvasLayer
## Сюжетный интерфейс: субтитры (кто говорит + реплика), задание, подсказка у прицела, красная пелена
## от ударов, вспышки, крупные надписи (названия глав, логотип). Затемнение экрана — GameState.fade_to().

signal line_skipped

const SPEAKERS := {
	"hero": ["Саман", Color(0.62, 0.82, 1.0)],
	"mom": ["Барно", Color(1.0, 0.72, 0.42)],
	"grandpa": ["Дед Анвар", Color(0.75, 0.95, 0.7)],
	"psycho": ["Мужчина в белом", Color(1.0, 0.45, 0.4)],
	"man": ["Человек в коляске", Color(0.85, 0.85, 0.8)],
	"younger": ["Младший брат", Color(1.0, 0.62, 0.35)],
	"elder": ["Старший брат", Color(1.0, 0.42, 0.38)],
	"radio": ["Радио", Color(0.75, 0.75, 0.75)],
	"doctor": ["Доктор", Color(0.9, 0.92, 1.0)],
	"driver": ["Водитель", Color(0.9, 0.9, 0.75)],
	"thought": ["Саман (про себя)", Color(0.62, 0.82, 1.0)],
	"": ["", Color(0.9, 0.9, 0.9)],
}

var _sub_box: PanelContainer
var _sub_name: Label
var _sub_text: Label
var _objective: Label
var _prompt: Label
var _hint: Label
var _title: Label
var _subtitle2: Label
var _damage: ColorRect
var _flash: ColorRect
var _dot: ColorRect
var _sub_t := 0.0
var _sub_next: Label
var _sub_wait := false
var _sub_shown_ms := 0
var _line_done := false
var _alert: Label
var _alert_t := 0.0
var _obj_flash := 0.0
var _hint_t := 0.0
var _damage_v := 0.0
var marker_target: Variant = null      # Vector3, Node3D или null: куда ехать по заданию
var marker_offset := Vector3(0, 1.0, 0)
var _marker: Control
var _marker_icon: Polygon2D
var _marker_text: Label
var _marker_t := 0.0

const DAMAGE_SHADER := """
shader_type canvas_item;
uniform float amount = 0.0;
void fragment() {
	vec2 uv = UV - 0.5;
	float v = smoothstep(0.25, 0.75, length(uv * vec2(1.4, 1.0)));
	COLOR = vec4(0.45, 0.0, 0.0, clamp(v * amount * 1.4 + amount * 0.12, 0.0, 0.92));
}
"""


func _ready() -> void:
	layer = 30
	process_mode = Node.PROCESS_MODE_ALWAYS
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_damage = ColorRect.new()
	_damage.set_anchors_preset(Control.PRESET_FULL_RECT)
	_damage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = DAMAGE_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	_damage.material = mat
	root.add_child(_damage)
	_flash = ColorRect.new()
	_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash.color = Color(1, 1, 1, 0)
	root.add_child(_flash)
	_dot = ColorRect.new()
	_dot.color = Color(1, 1, 1, 0.5)
	_dot.size = Vector2(4, 4)
	_dot.set_anchors_preset(Control.PRESET_CENTER)
	_dot.position = Vector2(-2, -2)
	_dot.visible = false
	root.add_child(_dot)
	# субтитры
	_sub_box = PanelContainer.new()
	var st := StyleBoxEmpty.new()                  # без тёмной плашки: текст с чёрной обводкой
	st.set_content_margin_all(10)
	_sub_box.add_theme_stylebox_override("panel", st)
	_sub_box.anchor_left = 0.5
	_sub_box.anchor_right = 0.5
	_sub_box.anchor_top = 1.0
	_sub_box.anchor_bottom = 1.0
	_sub_box.offset_left = -520
	_sub_box.offset_right = 520
	_sub_box.offset_top = -170
	_sub_box.offset_bottom = -60
	_sub_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sub_box.visible = false
	root.add_child(_sub_box)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	_sub_box.add_child(v)
	_sub_name = _label(20, Color.WHITE)
	_sub_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_sub_name)
	_sub_text = _label(26, Color(0.96, 0.95, 0.92))
	_sub_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sub_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sub_text.custom_minimum_size = Vector2(1000, 0)
	for l in [_sub_name, _sub_text]:
		(l as Label).add_theme_constant_override("outline_size", 8)
		(l as Label).add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
	v.add_child(_sub_text)
	_sub_next = _label(16, Color(0.85, 0.82, 0.75, 0.8))
	_sub_next.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sub_next.add_theme_constant_override("outline_size", 6)
	_sub_next.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_sub_next.text = "Пробел — далее"
	_sub_next.visible = false
	v.add_child(_sub_next)
	# задание
	_objective = _label(22, Color(1.0, 0.92, 0.7))
	_objective.position = Vector2(30, 70)
	_objective.size = Vector2(900, 40)
	root.add_child(_objective)
	# подсказка у прицела (E — ...)
	_prompt = _label(22, Color(1, 0.96, 0.88))
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.set_anchors_preset(Control.PRESET_CENTER)
	_prompt.position = Vector2(-400, 40)
	_prompt.size = Vector2(800, 40)
	root.add_child(_prompt)
	# подсказка по управлению (внизу слева)
	_hint = _label(18, Color(0.85, 0.85, 0.8))
	_hint.anchor_top = 1.0
	_hint.anchor_bottom = 1.0
	_hint.offset_left = 30
	_hint.offset_top = -105
	_hint.offset_right = 1200
	_hint.offset_bottom = -75
	root.add_child(_hint)
	# маркер задания: ромбик и расстояние; за краем экрана — прижимается к краю
	_marker = Control.new()
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker.visible = false
	root.add_child(_marker)
	_marker_icon = Polygon2D.new()
	_marker_icon.polygon = PackedVector2Array([Vector2(0, -11), Vector2(8, 0), Vector2(0, 11), Vector2(-8, 0)])
	_marker_icon.color = Color(1.0, 0.92, 0.7, 0.85)
	_marker.add_child(_marker_icon)
	_marker_text = _label(16, Color(1.0, 0.94, 0.8))
	_marker_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_marker_text.position = Vector2(-50, 12)
	_marker_text.size = Vector2(100, 22)
	_marker.add_child(_marker_text)
	# крупные надписи
	_title = _label(64, Color(0.95, 0.92, 0.85))
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title.offset_bottom = -60
	_title.modulate.a = 0.0
	root.add_child(_title)
	_subtitle2 = _label(26, Color(0.85, 0.82, 0.75))
	_subtitle2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle2.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_subtitle2.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_subtitle2.set_anchors_preset(Control.PRESET_FULL_RECT)
	_subtitle2.offset_top = 90
	_subtitle2.offset_left = 160
	_subtitle2.offset_right = -160
	_subtitle2.modulate.a = 0.0
	root.add_child(_subtitle2)


func _label(size: int, col: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("shadow_offset_x", 2)
	l.add_theme_constant_override("shadow_offset_y", 2)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## Надпись вверху по центру (крупно, на пару секунд): «Руки связаны…».
func alert(text: String, seconds := 2.0) -> void:
	if _alert == null:
		_alert = _label(30, Color(1.0, 0.78, 0.6))
		_alert.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_alert.add_theme_constant_override("outline_size", 8)
		_alert.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.95))
		_alert.set_anchors_preset(Control.PRESET_CENTER_TOP)
		_alert.position = Vector2(-500, 70)
		_alert.size = Vector2(1000, 50)
		add_child(_alert)
	_alert.text = text
	_alert.modulate.a = 1.0
	_alert_t = seconds


## Записка на весь экран (лист бумаги). Ждёт пробел / E / Esc.
func note(title: String, text: String) -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	var paper := PanelContainer.new()
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.86, 0.82, 0.72)
	st.set_content_margin_all(34)
	st.shadow_color = Color(0, 0, 0, 0.6)
	st.shadow_size = 14
	paper.add_theme_stylebox_override("panel", st)
	paper.set_anchors_preset(Control.PRESET_CENTER)
	paper.custom_minimum_size = Vector2(760, 0)
	paper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(paper)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	paper.add_child(v)
	var h := Label.new()
	h.text = title
	h.add_theme_font_size_override("font_size", 24)
	h.add_theme_color_override("font_color", Color(0.2, 0.15, 0.1))
	h.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	h.custom_minimum_size = Vector2(690, 0)
	v.add_child(h)
	var body := Label.new()
	body.text = text
	body.add_theme_font_size_override("font_size", 19)
	body.add_theme_color_override("font_color", Color(0.16, 0.13, 0.1))
	body.add_theme_constant_override("line_spacing", 4)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(690, 0)
	v.add_child(body)
	var foot := Label.new()
	foot.text = "Пробел — отложить"
	foot.add_theme_font_size_override("font_size", 15)
	foot.add_theme_color_override("font_color", Color(0.35, 0.3, 0.25))
	foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.add_child(foot)
	await get_tree().process_frame
	paper.position = (get_viewport().get_visible_rect().size - paper.size) * 0.5
	await get_tree().create_timer(0.4).timeout
	if GameState.auto_lines:
		await get_tree().create_timer(1.0).timeout
	else:
		while not (Input.is_action_just_pressed("skip_line") or Input.is_action_just_pressed("interact")):
			await get_tree().process_frame
	paper.queue_free()
	dim.queue_free()


## Реплика диалога: висит, пока не нажмёшь пробел / Enter (автотест — по времени: GameState.auto_lines).
func line(who: String, text: String, seconds := 0.0) -> void:
	var t: float = say(who, text, seconds, not GameState.auto_lines)
	_line_done = false
	while not _line_done:
		await get_tree().process_frame
		if GameState.auto_lines and not get_tree().paused:
			t -= get_process_delta_time()
			if t <= 0.0:
				break
	hide_line()


## Показать реплику. seconds = 0 — по длине текста; wait — не убирать сама, ждать пробел (line()).
## Без wait — короткий выкрик во время действия: пропадает сам.
func say(who: String, text: String, seconds := 0.0, wait := false) -> float:
	var sp: Array = SPEAKERS.get(who, ["", Color.WHITE])
	_sub_name.text = sp[0]
	_sub_name.add_theme_color_override("font_color", sp[1])
	_sub_name.visible = sp[0] != ""
	_sub_text.text = text
	_sub_box.visible = true
	_sub_wait = wait
	_sub_next.visible = wait
	_sub_shown_ms = Time.get_ticks_msec()
	var t: float = seconds if seconds > 0.0 else clampf(1.6 + text.length() * 0.055, 2.2, 7.5)
	_sub_t = 0.0 if wait else t
	return t


func hide_line() -> void:
	_sub_t = 0.0
	_sub_wait = false
	_sub_next.visible = false
	_sub_box.visible = false
	_line_done = true


func line_visible() -> bool:
	return _sub_box.visible


func set_objective(text: String, target: Variant = null, offset := Vector3(0, 1.0, 0)) -> void:
	_objective.text = ("Задание: " + text) if text != "" else ""
	_obj_flash = 2.0 if text != "" else 0.0
	set_marker(target, offset)


## Маркер цели (ромбик с расстоянием): точка или узел (тогда следует за ним), null — убрать.
func set_marker(target: Variant, offset := Vector3(0, 1.0, 0)) -> void:
	marker_target = target
	marker_offset = offset
	_marker_t = 0.0


func set_prompt(text: String) -> void:
	_prompt.text = text


func set_crosshair(on: bool) -> void:
	_dot.visible = on


func hint(text: String, seconds := 6.0) -> void:
	_hint.text = text
	_hint.modulate.a = 1.0
	_hint_t = seconds


func set_damage(v: float) -> void:
	_damage_v = clampf(v, 0.0, 1.0)
	(_damage.material as ShaderMaterial).set_shader_parameter("amount", _damage_v)


func flash(col: Color, seconds := 0.35) -> void:
	_flash.color = col
	var tw := create_tween()
	tw.tween_property(_flash, "color:a", 0.0, seconds)


## Крупная надпись по центру (название главы, логотип). Плавно появляется и исчезает.
func title(text: String, sub := "", hold := 3.0, size := 64) -> void:
	_title.text = text
	_title.add_theme_font_size_override("font_size", size)
	_subtitle2.text = sub
	var tw := create_tween()
	tw.tween_property(_title, "modulate:a", 1.0, 1.2)
	tw.parallel().tween_property(_subtitle2, "modulate:a", 1.0 if sub != "" else 0.0, 1.6)
	tw.tween_interval(hold)
	tw.tween_property(_title, "modulate:a", 0.0, 1.2)
	tw.parallel().tween_property(_subtitle2, "modulate:a", 0.0, 1.2)
	await tw.finished


## Надпись, которая остаётся на экране (финальные титры); clear_title() убирает.
func show_title(text: String, sub: String, size := 64, fade := 2.0) -> void:
	_title.text = text
	_title.add_theme_font_size_override("font_size", size)
	_subtitle2.text = sub
	var tw := create_tween()
	tw.tween_property(_title, "modulate:a", 1.0, fade)
	tw.parallel().tween_property(_subtitle2, "modulate:a", 1.0, fade * 1.5)
	await tw.finished


func clear_title(fade := 1.0) -> void:
	var tw := create_tween()
	tw.tween_property(_title, "modulate:a", 0.0, fade)
	tw.parallel().tween_property(_subtitle2, "modulate:a", 0.0, fade)
	await tw.finished


func _update_marker(dt: float) -> void:
	var cam: Camera3D = get_viewport().get_camera_3d()
	var tp: Vector3
	if marker_target is Node3D and is_instance_valid(marker_target):
		tp = (marker_target as Node3D).global_position + marker_offset
	elif marker_target is Vector3:
		tp = (marker_target as Vector3) + marker_offset
	else:
		_marker.visible = false
		return
	if cam == null:
		_marker.visible = false
		return
	_marker_t += dt
	var dist: float = cam.global_position.distance_to(tp)
	var vs: Vector2 = get_viewport().get_visible_rect().size
	var p: Vector2
	var behind: bool = cam.is_position_behind(tp)
	if behind:
		var local: Vector3 = cam.global_transform.affine_inverse() * tp
		p = vs * 0.5 + Vector2(local.x, -local.y).normalized() * vs.length()
	else:
		p = cam.unproject_position(tp)
	var margin := 40.0
	var inside: bool = not behind and p.x > margin and p.x < vs.x - margin and p.y > margin and p.y < vs.y - margin
	if not inside:
		var c: Vector2 = vs * 0.5
		var d: Vector2 = p - c
		if d.length() < 0.001:
			d = Vector2(0, 1)
		var k: float = minf((c.x - margin) / maxf(absf(d.x), 0.001), (c.y - margin) / maxf(absf(d.y), 0.001))
		p = c + d * minf(k, 1.0)
	_marker.position = p
	_marker_text.text = "%d м" % int(round(dist))
	# близко — почти пропадает; только что выдано — мигает
	var a: float = clampf((dist - 1.5) / 3.0, 0.15, 0.85)
	if _marker_t < 2.0:
		a = maxf(a, 0.5 + 0.5 * sin(_marker_t * 12.0))
	_marker.modulate.a = a
	_marker.visible = true


func _process(dt: float) -> void:
	_update_marker(dt)
	if _sub_t > 0.0:
		_sub_t -= dt
		if _sub_t <= 0.0:
			_sub_box.visible = false
	if _obj_flash > 0.0:
		_obj_flash -= dt
		var k: float = 0.5 + 0.5 * cos(_obj_flash * 9.0)
		_objective.modulate = Color(1, 1, 1).lerp(Color(1.0, 0.75, 0.3), k * minf(_obj_flash, 1.0))
	if _alert_t > 0.0 and _alert:
		_alert_t -= dt
		_alert.modulate.a = clampf(_alert_t / 0.5, 0.0, 1.0)
	if _hint_t > 0.0:
		_hint_t -= dt
		_hint.modulate.a = clampf(_hint_t, 0.0, 1.0)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("skip_line") and _sub_box.visible:
		if _sub_wait and Time.get_ticks_msec() - _sub_shown_ms < 250:
			return                                  # нажатие для прошлой реплики — не проскочить эту
		_line_done = true
		line_skipped.emit()
