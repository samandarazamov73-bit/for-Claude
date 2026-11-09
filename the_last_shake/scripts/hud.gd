class_name ForestHUD
extends CanvasLayer
## On-screen help, speed, FPS / preset line and the F3 profiling overlay.

var world: Node
var _help: Label
var _line: Label
var _stats: Label
var _toast: Label
var _toast_t := 0.0
var _stats_on := false
var _acc := 0.0

const HELP := """W/S or ↑/↓  throttle / brake (reverse)    A/D or ←/→  steer    Space  handbrake    R  back on the road
C  camera: chase → driver → autopilot → free    (free camera: mouse + WASD, Q/E down/up, Shift fast)
G  graphics preset    L  30 fps cap    [ ]  road wetness    F3  profiler    F4  LOD view    F1  hide help    F11  fullscreen"""


func _ready() -> void:
	layer = 10
	_help = _label(Vector2(16, 12), 14, Color(1, 1, 1, 0.9))
	_help.text = HELP
	_line = _label(Vector2(16, 0), 15, Color(1, 1, 1, 0.95))
	_line.anchor_top = 1.0
	_line.anchor_bottom = 1.0
	_line.offset_top = -34
	_stats = _label(Vector2(16, 84), 13, Color(0.85, 1.0, 0.85))
	_stats.visible = false
	_toast = _label(Vector2(0, 0), 22, Color(1, 1, 1))
	_toast.anchor_left = 0.5
	_toast.anchor_right = 0.5
	_toast.offset_left = -300
	_toast.offset_right = 300
	_toast.offset_top = 60
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


func _label(pos: Vector2, size: int, col: Color) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	add_child(l)
	return l


func toast(text: String) -> void:
	_toast.text = text
	_toast.modulate.a = 1.0
	_toast_t = 2.2


func toggle_help() -> void:
	_help.visible = not _help.visible


func toggle_stats() -> void:
	_stats_on = not _stats_on
	_stats.visible = _stats_on


func _process(delta: float) -> void:
	_toast_t -= delta
	_toast.modulate.a = clampf(_toast_t, 0.0, 1.0)
	_acc += delta
	if _acc < 0.25:
		return
	_acc = 0.0
	if world == null or not world.has_method("hud_line"):
		return
	_line.text = world.hud_line()
	if _stats_on:
		_stats.text = world.stats_text()
