extends Node
## «The Last Shake»: общее для всей игры (автозагрузка GameState).
## Управление (все клавиши задаются здесь), глава/контрольная точка, переходы между сценами с затемнением.

## Номер сборки — виден в главном меню слева внизу (чтобы сразу видно, какая версия запущена).
const VERSION := "версия 11.3 · 27 ноября 2026"

const MENU := "res://story/menu.tscn"
const PROLOGUE := "res://story/prologue.tscn"
const SANATORIUM := "res://sanatorium/main.tscn"
const EPILOGUE := "res://story/epilogue.tscn"

## Главы для меню: [название, сцена, контрольная точка]
const CHAPTERS := [
	["Пролог. Дорога в никуда", PROLOGUE, "start"],
	["Глава 1. Санаторий «Оромгох»", SANATORIUM, "start"],
	["Глава 2. Ключ администратора", SANATORIUM, "key"],
	["Глава 3. Второй этаж", SANATORIUM, "void"],
	["Глава 4. Третий этаж", SANATORIUM, "floor3"],
	["Глава 5. Таблетка", SANATORIUM, "pharmacy"],
	["Глава 6. Настоящая больница", SANATORIUM, "real"],
	["Эпилог", EPILOGUE, ""],
]

## где начать: start, key, chase, void, floor3, floor3b, pharmacy, pharmacy_out (лес), real. Каждая смена
## запоминается на диске — «Продолжить» в главном меню начнёт с этого места.
var checkpoint := "start":
	set(v):
		checkpoint = v
		_save_progress()
var current_scene := ""          # какая сцена игры сейчас (для «Начать главу заново» и «Продолжить»)
## Настройки (меню «Настройки» — в главном меню и в паузе): громкость 0..1, чувствительность мыши (множитель).
var volume := 0.85
var mouse_sens := 1.0
var fullscreen := false
const SETTINGS_PATH := "user://the_last_shake_settings.cfg"
const PROGRESS_PATH := "user://the_last_shake_progress.cfg"
var deaths := 0
var auto_lines := false          # автотест: записки закрываются сами (реплики и так идут по времени)
var entry := {}                  # откуда заехали в здание (пролог → санаторий): pos, yaw, mom — координаты здания
var _fade: ColorRect
var _layer: CanvasLayer
var _loading: Label
var _busy := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	setup_input()
	_load_settings()
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
	if scene != MENU:
		current_scene = scene
	if cp != "":
		checkpoint = cp
	else:
		_save_progress()
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


# ------------------------------------------------------------------------------ настройки и прогресс
func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		volume = clampf(float(cfg.get_value("settings", "volume", volume)), 0.0, 1.0)
		mouse_sens = clampf(float(cfg.get_value("settings", "mouse_sens", mouse_sens)), 0.3, 2.5)
		fullscreen = bool(cfg.get_value("settings", "fullscreen", fullscreen))
	apply_settings()


func apply_settings() -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(volume, 0.0001)))
	AudioServer.set_bus_mute(0, volume <= 0.001)
	var fs: bool = DisplayServer.window_get_mode() in [DisplayServer.WINDOW_MODE_FULLSCREEN, DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN]
	if fs != fullscreen and not DisplayServer.get_name().contains("headless"):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED)


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("settings", "volume", volume)
	cfg.set_value("settings", "mouse_sens", mouse_sens)
	cfg.set_value("settings", "fullscreen", fullscreen)
	cfg.save(SETTINGS_PATH)
	apply_settings()


func _save_progress() -> void:
	if current_scene == "" or current_scene == MENU or current_scene == EPILOGUE:
		return
	var cfg := ConfigFile.new()
	cfg.set_value("progress", "scene", current_scene)
	cfg.set_value("progress", "checkpoint", checkpoint)
	cfg.save(PROGRESS_PATH)


## Сохранённое место: [сцена, контрольная точка] или [] — если игру ещё не начинали.
func saved_progress() -> Array:
	var cfg := ConfigFile.new()
	if cfg.load(PROGRESS_PATH) != OK:
		return []
	var sc: String = cfg.get_value("progress", "scene", "")
	if sc == "" or not ResourceLoader.exists(sc):
		return []
	return [sc, String(cfg.get_value("progress", "checkpoint", "start"))]


## Название главы по сцене и контрольной точке (для паузы и «Продолжить»).
func chapter_name(scene := "", cp := "") -> String:
	var sc: String = scene if scene != "" else current_scene
	var c: String = cp if cp != "" else checkpoint
	if sc == PROLOGUE:
		return "Глава 5. Таблетка" if c == "pharmacy_out" else "Пролог. Дорога в никуда"
	if sc == EPILOGUE:
		return "Эпилог"
	var by_cp := {"start": 1, "key": 2, "chase": 2, "void": 3, "floor3": 4, "floor3b": 4, "pharmacy": 5, "real": 6}
	var i: int = int(by_cp.get(c, 1))
	return String(CHAPTERS[i][0])


func restart_chapter() -> void:
	if current_scene == "":
		to_menu()
		return
	go(current_scene, checkpoint)
