class_name Hud
extends CanvasLayer
## On-screen help, performance counters and loading message.

var help: Label
var info: Label
var stats: Label
var loading: Label
var show_stats := true
var main_ref: Node


func _ready() -> void:
	var ls := LabelSettings.new()
	ls.font_size = 15
	ls.outline_size = 5
	ls.outline_color = Color(0, 0, 0, 0.85)
	ls.font_color = Color(1, 1, 1)
	help = Label.new()
	help.label_settings = ls
	help.position = Vector2(14, 12)
	help.text = """DOWNTOWN CITY  -  H: hide help
Mouse: LMB/RMB drag = rotate, Shift+drag / MMB = pan, wheel = zoom
WASD / arrows = move   Q/E = turn   Shift = faster
1 Orbit   2 Top view   3 Free fly (hold RMB to look, Space/C up/down)
4 Walk (character; Space jump, V first/third person)
R or Home = reset to the trailer shot
N = time of day (day / golden hour / dusk / night)
F2 = quality (low / medium / high)   F3 = stats   F4 = adaptive resolution
F12 = screenshot (user://screenshots)"""
	add_child(help)
	info = Label.new()
	info.label_settings = ls
	info.anchor_left = 1.0
	info.anchor_right = 1.0
	info.position = Vector2(-340, 12)
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	info.size = Vector2(326, 100)
	add_child(info)
	stats = Label.new()
	var ls2 := ls.duplicate() as LabelSettings
	ls2.font_size = 13
	stats.label_settings = ls2
	stats.anchor_top = 1.0
	stats.anchor_bottom = 1.0
	stats.position = Vector2(14, -110)
	add_child(stats)
	loading = Label.new()
	var ls3 := ls.duplicate() as LabelSettings
	ls3.font_size = 28
	loading.label_settings = ls3
	loading.set_anchors_preset(Control.PRESET_CENTER)
	loading.text = "Building the city..."
	add_child(loading)


func set_loading(t: String) -> void:
	loading.visible = t != ""
	loading.text = t


func _process(_delta: float) -> void:
	if main_ref == null:
		return
	info.text = main_ref.call("status_text")
	stats.visible = show_stats
	if show_stats:
		var fps := Engine.get_frames_per_second()
		var prims := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
		var draws := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		var objs := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)
		var vram := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / 1048576.0
		var vp := get_viewport()
		stats.text = "FPS %d   frame %.1f ms\ndraw calls %d   objects %d   triangles %.2fM\nrender scale %.2f   VRAM %.0f MB" % [
			fps, 1000.0 / maxf(fps, 1.0), draws, objs, prims / 1.0e6, vp.scaling_3d_scale, vram]
