extends Node3D
## Персонаж сюжета (дед Анвар, мама Барно, мужчина в белом) из GLB со скелетом и анимациями
## (characters/*.glb: idle_loop, talk_loop, walk_loop, run_loop, ... — склеены tools/godot_assets/merge_chars.py).
## Узел смотрит в −Z (как все в Godot); модель внутри развёрнута (Mixamo смотрит в +Z).
## Ходит по точкам (с высотой — можно по лестнице), поворачивается по ходу, поворачивает голову к цели.

signal arrived

const BoneLook = preload("res://story/bone_look.gd")

var model: Node3D
var anim: AnimationPlayer
var skel: Skeleton3D
var look: Node                         # BoneLook
var natural := {"walk_loop": 1.24, "run_loop": 3.4, "sprint_loop": 2.13}   # м/с, при которых анимация не скользит
var idle_anim := "idle_loop"
var turn_rate := 7.0
var current := ""

var _path: Array = []                  # Vector3
var _speed := 0.0
var _move_anim := ""
var _moving := false
var _face_dir: Variant = null          # Vector3 или null
var _yaw := 0.0
var step_volume := -8.0                 # громкость шагов (дБ); псих топает громче
var _step_left := 0.0
var _steps: AudioStreamPlayer3D


func setup(path: String, scale_k := 1.0) -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF     # ходит в _process, а не в физике
	var res: Resource = load(path)
	if not (res is PackedScene):
		push_warning("нет модели " + path)
		return
	model = (res as PackedScene).instantiate() as Node3D
	model.rotation.y = PI
	model.scale = Vector3.ONE * scale_k
	add_child(model)
	var players: Array = model.find_children("*", "AnimationPlayer", true, false)
	if not players.is_empty():
		anim = players[0]
	var skels: Array = model.find_children("*", "Skeleton3D", true, false)
	if not skels.is_empty():
		skel = skels[0]
		look = BoneLook.new()
		skel.add_child(look)
		look.find_bones(skel)
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).extra_cull_margin = 1.5     # анимация уводит руки за рамки покоя — не пропадать
	_yaw = rotation.y
	play(idle_anim)
	_steps = AudioStreamPlayer3D.new()
	_steps.stream = load("res://story/sfx/footstep_slow.wav")
	_steps.unit_size = 2.5
	_steps.max_distance = 30.0
	_steps.bus = "World" if AudioServer.get_bus_index("World") >= 0 else "Master"
	add_child(_steps)


## Имя анимации в плеере. Godot при импорте отрезает окончание «_loop» (walk_loop → walk) и делает такую
## анимацию циклической, поэтому ищем оба варианта.
func anim_name(n: String) -> String:
	if anim == null:
		return ""
	if anim.has_animation(n):
		return n
	var base: String = n.trim_suffix("_loop")
	if anim.has_animation(base):
		return base
	if anim.has_animation(n + "_loop"):
		return n + "_loop"
	return ""


func has_anim(n: String) -> bool:
	return anim_name(n) != ""


func play(n: String, blend := 0.25, spd := 1.0) -> void:
	var real: String = anim_name(n)
	if real == "":
		return
	anim.speed_scale = spd
	if current == n and anim.is_playing():
		return
	current = n
	anim.play(real, blend)


## Проиграть один раз и дождаться конца (или часть: until — секунда, на которой вернуть управление).
func play_once(n: String, blend := 0.15, spd := 1.0, until := -1.0) -> void:
	var real: String = anim_name(n)
	if real == "":
		return
	current = n
	anim.speed_scale = spd
	anim.play(real, blend)
	if anim.current_animation == real:
		anim.seek(0.0, true)
	var length: float = anim.get_animation(real).length
	var t: float = (until if until > 0.0 else length) / maxf(spd, 0.05)
	await get_tree().create_timer(t, false).timeout


func set_look(target: Variant) -> void:
	if look:
		look.look_target = target


func set_arm(target: Variant) -> void:
	if look:
		look.arm_target = target


func set_lean(a: float) -> void:
	if look:
		look.lean = a


## Обе руки к точкам (мировые), weight — насколько (0..1).
func set_hands(right: Variant, left: Variant, weight := 1.0) -> void:
	if look:
		look.arm_target = right
		look.arm_target_left = left
		look.arm_weight = weight


## Голова (для «навести взгляд и нажать E» и камер).
func head_pos() -> Vector3:
	if skel and look and look._head >= 0:
		return skel.global_transform * skel.get_bone_global_pose(look._head).origin + Vector3(0, 0.08, 0)
	return global_position + Vector3(0, 1.6, 0)


## Идти по точкам (мировые координаты, с высотой). anim — какой цикл играть.
func go(points: Array, speed := 1.2, anim_name := "walk_loop") -> void:
	_path = points.duplicate()
	_speed = speed
	_move_anim = anim_name
	_moving = not _path.is_empty()
	if _moving:
		var nat: float = float(natural.get(anim_name, speed))
		play(anim_name, 0.25, clampf(speed / maxf(nat, 0.05), 0.55, 1.8))


## Идти и дождаться прихода.
func go_and_wait(points: Array, speed := 1.2, anim_name := "walk_loop") -> void:
	go(points, speed, anim_name)
	if _moving:
		await arrived


func stop(anim_name := "") -> void:
	_path.clear()
	_moving = false
	play(anim_name if anim_name != "" else idle_anim, 0.3)


func is_moving() -> bool:
	return _moving


## Повернуться лицом к точке (плавно; instant — сразу).
func face(p: Vector3, instant := false) -> void:
	var d: Vector3 = p - global_position
	d.y = 0.0
	if d.length() < 0.01:
		return
	if instant:
		_yaw = atan2(-d.x, -d.z)
		rotation.y = _yaw
		_face_dir = null
	else:
		_face_dir = d.normalized()


## Шаги: примерно через каждые 0,7 м (на бегу — чаще и громче).
func _footstep(dist: float) -> void:
	if _steps == null or not visible:
		return
	_step_left -= dist
	if _step_left > 0.0:
		return
	var running: bool = _speed > 2.0
	_step_left = 1.1 if running else 0.68
	_steps.volume_db = step_volume + (4.0 if running else 0.0) + randf_range(-2.0, 1.0)
	_steps.pitch_scale = randf_range(0.85, 1.1) * (1.15 if running else 1.0)
	_steps.play()


## Шаги, когда персонаж двигается не сам (по команде извне, например в погоне).
func step_moved(dist: float) -> void:
	_footstep(dist)


func set_yaw(y: float) -> void:
	_yaw = y
	rotation.y = y
	_face_dir = null


func _process(dt: float) -> void:
	if _moving and not _path.is_empty():
		var target: Vector3 = _path[0]
		var to: Vector3 = target - global_position
		var flat := Vector3(to.x, 0.0, to.z)
		var step: float = _speed * dt
		if to.length() <= step + 0.02:
			global_position = target
			_path.pop_front()
			if _path.is_empty():
				_moving = false
				play(idle_anim, 0.3)
				arrived.emit()
		else:
			global_position += to.normalized() * step
			if flat.length() > 0.05:
				_face_dir = flat.normalized()
		_footstep(step)
	if _face_dir != null:
		var fd: Vector3 = _face_dir
		var want: float = atan2(-fd.x, -fd.z)
		_yaw = lerp_angle(_yaw, want, 1.0 - exp(-turn_rate * dt))
		rotation.y = _yaw
		if absf(angle_difference(_yaw, want)) < 0.01 and not _moving:
			_face_dir = null
