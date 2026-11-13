extends Control
## Мини-игра «поймай зелёную зону»: по кругу бежит стрелка, на круге — зелёный участок.
## E (или ЛКМ), когда стрелка в зелёном, — удача (сигнал hit(true)), мимо — промах (hit(false)).
## После каждого нажатия зелёный участок прыгает в другое место; can_shrink — с каждой удачей он уже,
## а стрелка быстрее. run() ждёт, пока не наберётся need удач (промах отнимает одну, если lose_on_miss).
## Директор сюжета (story/director.gd) решает, что происходит на каждую удачу (толчок двери, щелчок замка).

signal hit(ok: bool)

const R := 92.0                 # радиус круга, пиксели
const W := 12.0                 # толщина
var title := ""
var need := 3
var got := 0
var speed := 200.0              # град/с
var zone_deg := 52.0            # ширина зелёного участка
var zone_at := 0.0              # середина зелёного участка, град
var angle := 0.0                # стрелка, град
var dir := 1.0
var shrink := false
var lose_on_miss := false
var reverse_on_hit := false
var running := false
var cheat := false              # автотест: любое нажатие — удача
var _flash := 0.0
var _flash_col := Color.WHITE
var _cool := 0.0                # после нажатия — короткая пауза (толчок)
var _font: Font


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_font = ThemeDB.fallback_font


## Запустить и дождаться need удач.
func run(caption: String, need_hits: int, spd: float, zone: float, opts := {}) -> void:
	title = caption
	need = need_hits
	got = 0
	speed = spd
	zone_deg = zone
	shrink = bool(opts.get("shrink", false))
	lose_on_miss = bool(opts.get("lose_on_miss", false))
	reverse_on_hit = bool(opts.get("reverse", false))
	angle = randf_range(0.0, 360.0)
	_new_zone()
	visible = true
	running = true
	_cool = 0.4
	while got < need:
		await get_tree().process_frame
	running = false
	await get_tree().create_timer(0.35, false).timeout
	visible = false


func press() -> void:
	if not running or _cool > 0.0:
		return
	var ok: bool = cheat or absf(angle_difference(deg_to_rad(angle), deg_to_rad(zone_at))) <= deg_to_rad(zone_deg * 0.5)
	if ok:
		got += 1
		_flash_col = Color(0.35, 1.0, 0.45)
		if shrink:
			zone_deg = maxf(zone_deg * 0.8, 18.0)
			speed *= 1.12
		if reverse_on_hit:
			dir = -dir
	else:
		_flash_col = Color(1.0, 0.25, 0.2)
		if lose_on_miss:
			got = maxi(got - 1, 0)
	_flash = 0.35
	_cool = 0.45 if ok else 0.3
	_new_zone()
	hit.emit(ok)


func _new_zone() -> void:
	# зелёный участок — подальше от стрелки, чтобы не попасть случайно
	zone_at = fposmod(angle + dir * randf_range(110.0, 250.0), 360.0)


func _process(dt: float) -> void:
	if not visible:
		return
	if running:
		angle = fposmod(angle + dir * speed * dt, 360.0)
	_flash = maxf(_flash - dt, 0.0)
	_cool = maxf(_cool - dt, 0.0)
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if not running:
		return
	if event.is_action_pressed("interact") or event.is_action_pressed("attack"):
		press()
		get_viewport().set_input_as_handled()


func _draw() -> void:
	var c: Vector2 = get_viewport_rect().size * 0.5 + Vector2(0, 40)
	draw_circle(c, R + W, Color(0, 0, 0, 0.45))
	draw_arc(c, R, 0.0, TAU, 72, Color(0.75, 0.72, 0.66, 0.55), W, true)
	var a0: float = deg_to_rad(zone_at - zone_deg * 0.5) - PI * 0.5
	var a1: float = deg_to_rad(zone_at + zone_deg * 0.5) - PI * 0.5
	draw_arc(c, R, a0, a1, 24, Color(0.25, 0.95, 0.4, 0.95), W + 2.0, true)
	var a: float = deg_to_rad(angle) - PI * 0.5
	var tip: Vector2 = c + Vector2(cos(a), sin(a)) * (R + W)
	draw_line(c + Vector2(cos(a), sin(a)) * (R - W * 1.6), tip, Color(1, 1, 1), 4.0, true)
	if _flash > 0.0:
		var col := _flash_col
		col.a = _flash / 0.35
		draw_arc(c, R + W + 6.0, 0.0, TAU, 72, col, 6.0, true)
	# прогресс: кружки
	for i in need:
		var p: Vector2 = c + Vector2((i - (need - 1) * 0.5) * 26.0, R + W + 34.0)
		draw_circle(p, 8.0, Color(0.3, 0.95, 0.45) if i < got else Color(0.3, 0.3, 0.3, 0.8))
	var ts: Vector2 = _font.get_string_size(title, HORIZONTAL_ALIGNMENT_CENTER, -1, 22)
	draw_string(_font, c + Vector2(-ts.x * 0.5, -R - W - 22.0), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(0.95, 0.92, 0.85))
	var hint := "E или ЛКМ — когда стрелка в зелёном"
	var hs: Vector2 = _font.get_string_size(hint, HORIZONTAL_ALIGNMENT_CENTER, -1, 16)
	draw_string(_font, c + Vector2(-hs.x * 0.5, R + W + 70.0), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.8, 0.78, 0.72))
