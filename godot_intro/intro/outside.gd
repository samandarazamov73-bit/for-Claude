extends Node
## После автобуса: герой на коляске едет за мамой по лесной тропинке к санаторию.
## Солнце садится, темнеет (даже если стоять на месте), есть фонарь (F). У ворот санатория — конец пролога.
## W / S — вперёд / назад, A / D — поворот, Shift — быстрее, мышь — осмотреться.

signal finished

const C = preload("res://intro/cfg.gd")
const Story = preload("res://intro/story.gd")

var main                     # bus_intro.gd (диалоги: play / ask)
var forest
var daylight
var audio
var ui
var hero_rig: Node3D
var cam: Camera3D
var mom
var active: bool = false
var progress: float = 0.0    # пройдено по тропинке, м
var night: float = 0.0       # 0 — закат у остановки, 1 — ночь
var flashlight: SpotLight3D

var _speed: float = 0.0
var _mom_s: float = 1.5
var _mom_speed: float = 0.0
var _mom_face: float = 0.0
var _elapsed: float = 0.0
var _step_timer: float = 0.0
var _fired: Dictionary = {}
var _flash_on: bool = false
var _done: bool = false
var _time_value: float = 0.42


func start() -> void:
	active = true
	flashlight = SpotLight3D.new()
	flashlight.spot_range = 26.0
	flashlight.spot_angle = 24.0
	flashlight.spot_angle_attenuation = 0.8
	flashlight.light_color = Color(1.0, 0.93, 0.8)
	flashlight.light_energy = 0.0
	flashlight.shadow_enabled = true
	flashlight.position = Vector3(0.12, -0.12, 0.0)
	cam.add_child(flashlight)
	_mom_face = mom.rotation.y
	ui.set_hint(Story.WALK_HINT)


func toggle_flashlight() -> void:
	_flash_on = not _flash_on
	audio.play_sfx("click", 0.8)
	if _flash_on and not _fired.has("flash_done"):
		_fired["flash_done"] = true
		if _fired.has("flash_ask"):
			ui.set_objective(Story.OBJECTIVE_WALK)


func _process(delta: float) -> void:
	if not active or get_tree().paused:
		return
	_elapsed += delta
	_drive(delta)
	_walk_mom(delta)
	_update_light(delta)
	_events()


func _key(k: Key) -> bool:
	return Input.is_physical_key_pressed(k)


func _drive(delta: float) -> void:
	var fwd_in: float = (1.0 if _key(KEY_W) or _key(KEY_UP) else 0.0) - (1.0 if _key(KEY_S) or _key(KEY_DOWN) else 0.0)
	var turn_in: float = (1.0 if _key(KEY_A) or _key(KEY_LEFT) else 0.0) - (1.0 if _key(KEY_D) or _key(KEY_RIGHT) else 0.0)
	if main.is_talking_choice():
		fwd_in = 0.0
	var top: float = C.WALK_SPEED * (1.5 if _key(KEY_SHIFT) else 1.0)
	var want: float = fwd_in * (top if fwd_in > 0.0 else C.WALK_SPEED * 0.5)
	_speed = move_toward(_speed, want, (2.2 if absf(want) > absf(_speed) else 3.5) * delta)
	hero_rig.rotation.y += turn_in * C.WALK_TURN * delta
	var forward: Vector3 = -hero_rig.global_transform.basis.z
	forward.y = 0.0
	var p: Vector3 = hero_rig.global_position + forward.normalized() * _speed * delta
	p = forest.constrain(p, C.PATH_HALF)
	var mom_pos: Vector3 = mom.global_position
	if Vector2(p.x - mom_pos.x, p.z - mom_pos.z).length() < 0.8 and _speed > 0.0:
		_speed = 0.0                                   # не наезжаем на маму
	else:
		hero_rig.global_position = p
	progress = float(forest.path_nearest(hero_rig.global_position)["s"])
	audio.set_motor(absf(_speed) / C.WALK_SPEED)


## Мама идёт за «точкой» на тропинке, которая держится на MOM_AHEAD метров впереди героя.
func _walk_mom(delta: float) -> void:
	var target: float = minf(progress + C.MOM_AHEAD, forest.path_len - 1.5)
	var hold: bool = _fired.has("stop_listen") and not _fired.has("go_on")   # остановилась и прислушивается
	if not hold and _mom_s < target:
		_mom_s = minf(target, _mom_s + 1.25 * delta)
	var side: Vector3 = forest.path_dir(_mom_s)
	var dp: Vector3 = forest.path_at(_mom_s) + Vector3(-side.z, 0, side.x) * 0.35   # чуть левее середины
	var cur: Vector3 = mom.global_position
	var to_p: Vector3 = Vector3(dp.x - cur.x, 0, dp.z - cur.z)
	var dist_p: float = to_p.length()
	var step: float = minf(dist_p, 1.3 * delta) if dist_p > 0.05 and not hold else 0.0
	var mp: Vector3 = cur
	if step > 0.0:
		mp = cur + to_p / dist_p * step
		mom.global_position = mp
	_mom_speed = lerpf(_mom_speed, step / maxf(delta, 0.0001), 1.0 - exp(-8.0 * delta))
	var face: float
	if _mom_speed > 0.2:
		face = atan2(-to_p.x, -to_p.z)
	else:
		var to: Vector3 = hero_rig.global_position - mp  # стоит — смотрит на сына
		face = atan2(-to.x, -to.z)
	_mom_face = lerp_angle(_mom_face, face, 1.0 - exp(-3.0 * delta))
	mom.rotation.y = _mom_face
	mom.walk(_mom_speed, delta)
	if _mom_speed > 0.4:
		_step_timer -= delta
		if _step_timer <= 0.0:
			_step_timer = 0.5
			var dist: float = mp.distance_to(hero_rig.global_position)
			audio.play_sfx("step", clampf(0.5 - dist * 0.04, 0.15, 0.5))


func _update_light(delta: float) -> void:
	var by_path: float = clampf(progress / maxf(forest.path_len, 1.0), 0.0, 1.0) * 1.05
	var by_time: float = _elapsed / C.NIGHT_AFTER
	var target: float = 0.42 + 0.58 * clampf(maxf(by_path, by_time), 0.0, 1.0)
	_time_value = maxf(_time_value, lerpf(_time_value, target, 1.0 - exp(-0.6 * delta)))
	daylight.set_time(_time_value)
	night = clampf((_time_value - 0.42) / 0.58, 0.0, 1.0)
	audio.set_forest(0.0, night)
	var flicker: float = 1.0 - 0.06 * sin(_elapsed * 23.0) * sin(_elapsed * 7.0)
	flashlight.light_energy = lerpf(flashlight.light_energy, C.FLASHLIGHT_ENERGY * flicker if _flash_on else 0.0, 1.0 - exp(-18.0 * delta))
	var dusk: float = clampf((night - 0.3) * 2.0, 0.0, 1.0)
	if forest.gate_lamp != null:
		forest.gate_lamp.light_energy = dusk * 1.6
	if forest.lit_window != null:
		forest.lit_window.light_energy = dusk * 1.2


func _events() -> void:
	var f: float = progress / maxf(forest.path_len, 1.0)
	if not _fired.has("start"):
		_fired["start"] = true
		main.play(Story.WALK_START)
		ui.set_objective(Story.OBJECTIVE_WALK)
	if f > 0.12 and not _fired.has("talk1"):
		_fired["talk1"] = true
		main.play(Story.WALK_TALK_1)
	if night > 0.42 and not _flash_on and not _fired.has("flash_ask"):
		_fired["flash_ask"] = true
		main.play(Story.WALK_FLASHLIGHT)
		ui.set_objective(Story.OBJECTIVE_FLASHLIGHT)
	if f > 0.36 and not _fired.has("crow"):
		_fired["crow"] = true
		audio.play_sfx("crow", 0.55)
	if f > 0.52 and not _fired.has("stop_listen"):
		_fired["stop_listen"] = true
		audio.play_sfx("snap", 0.8)
		_listen()
	if f > 0.84 and not _fired.has("building"):
		_fired["building"] = true
		main.play(Story.WALK_BUILDING)
	if not _done and hero_rig.global_position.distance_to(forest.gate_pos) < 4.5:
		_done = true
		active = false
		_speed = 0.0
		audio.set_motor(0.0)
		finished.emit()


func _listen() -> void:
	await main.play_and_wait(Story.WALK_LISTEN)
	_fired["go_on"] = true
