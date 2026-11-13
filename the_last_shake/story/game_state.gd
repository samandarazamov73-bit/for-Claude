extends Node
## «The Last Shake»: общее для всей игры (автозагрузка GameState).
## Управление (все клавиши задаются здесь), глава/контрольная точка, переходы между сценами с затемнением.

## Номер сборки — виден в главном меню слева внизу (чтобы сразу видно, какая версия запущена).
const VERSION := "версия 5 · 13 ноября 2026"

const MENU := "res://story/menu.tscn"
const PROLOGUE := "res://story/prologue.tscn"
const SANATORIUM := "res://sanatorium/main.tscn"
const EPILOGUE := "res://story/epilogue.tscn"

## Главы для меню: [название, сцена, контрольная точка]
const CHAPTERS := [
	["Пролог. Дорога в никуда", PROLOGUE, ""],
	["Глава 1. Санаторий «Оромгох»", SANATORIUM, "start"],
	["Глава 2. Ключ администратора", SANATORIUM, "key"],
	["Глава 3. Второй этаж", SANATORIUM, "void"],
	["Глава 4. Третий этаж", SANATORIUM, "floor3"],
	["Глава 5. Палата №204", SANATORIUM, "maze"],
	["Эпилог. 1980", EPILOGUE, ""],
]

var checkpoint := "start"       # где начать санаторий: start, key, chase, void, floor3, maze
var deaths := 0
var entry := {}                  # откуда заехали в здание (пролог → санаторий): pos, yaw, mom — координаты здания
var _fade: ColorRect
var _layer: CanvasLayer
var _loading: Label
var _busy := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	setup_input()
	_layer = CanvasLayer.new()
	_layer.layer = 100
	add_child(_layer)
	_fade = ColorRect.new()
	_fade.color = Color(0, 0, 0, 0)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_layer.add_child(_fade)
	_loading = Label.new()
	_loading.text = "Загрузка…"
	_loading.add_theme_font_size_override("font_size", 26)
	_loading.add_theme_color_override("font_color", Color(0.75, 0.72, 0.66))
	_loading.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_loading.position = Vector2(-260, -70)
	_loading.size = Vector2(220, 40)
	_loading.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_loading.visible = false
	_layer.add_child(_loading)


## Все действия игры. Свои клавиши можно поменять здесь (physical_keycode — место клавиши, раскладка не важна).
func setup_input() -> void:
	var keys := {
		"drive_forward": [KEY_W, KEY_UP], "drive_back": [KEY_S, KEY_DOWN], "turn_left": [KEY_A, KEY_LEFT],
		"turn_right": [KEY_D, KEY_RIGHT], "interact": [KEY_E], "flashlight": [KEY_F], "horn": [KEY_H],
		"speed_up": [KEY_EQUAL, KEY_KP_ADD, KEY_R], "speed_down": [KEY_MINUS, KEY_KP_SUBTRACT, KEY_Q],
		"pause": [KEY_ESCAPE], "fullscreen": [KEY_F11], "quality": [KEY_G, KEY_F2], "fps_limit": [KEY_L],
		"debug_info": [KEY_F3], "skip_line": [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE], "fast_forward": [KEY_TAB],
	}
	for a in keys:
		if not InputMap.has_action(a):
			InputMap.add_action(a, 0.2)
		for k in keys[a]:
			var ev := InputEventKey.new()
			ev.physical_keycode = k
			if not InputMap.action_has_event(a, ev):
				InputMap.action_add_event(a, ev)
	if not InputMap.has_action("attack"):
		InputMap.add_action("attack", 0.2)
		var lmb := InputEventMouseButton.new()
		lmb.button_index = MOUSE_BUTTON_LEFT
		InputMap.action_add_event("attack", lmb)


func set_fade(a: float) -> void:
	_fade.color.a = clampf(a, 0.0, 1.0)
	if a < 0.5:
		_loading.visible = false


## Надпись «Загрузка…» поверх чёрного экрана (сама пропадает, когда экран светлеет).
func set_loading(on: bool, text := "Загрузка…") -> void:
	_loading.text = text
	_loading.visible = on


func fade_target() -> float:
	return _fade.color.a


func fade_to(a: float, seconds: float) -> void:
	if a < 0.5:
		_loading.visible = false
	var tw := create_tween()
	tw.tween_property(_fade, "color:a", clampf(a, 0.0, 1.0), maxf(seconds, 0.01))
	await tw.finished


## Сменить сцену: затемнить, загрузить, (новая сцена сама решает, когда светлеть — fade_to(0, ...)).
## threaded — сцена уже грузится в фоне (ResourceLoader.load_threaded_request): забрать её оттуда.
func go(scene: String, cp := "", threaded := false) -> void:
	if _busy:
		return
	_busy = true
	if cp != "":
		checkpoint = cp
	await fade_to(1.0, 0.8)
	set_loading(true)
	await get_tree().process_frame
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var packed: Resource = ResourceLoader.load_threaded_get(scene) if threaded else null
	if packed is PackedScene:
		get_tree().change_scene_to_packed(packed)
	else:
		get_tree().change_scene_to_file(scene)
	_busy = false


func to_menu() -> void:
	go(MENU)
