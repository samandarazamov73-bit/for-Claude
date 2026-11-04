extends Node3D
## Человек из GLB (intro/assets/models/people/*.glb).
## Если в модели есть узел «Head» — поворачивается голова; если нет (модели автора — цельные),
## стоящий человек (turn_body = true) поворачивается к цели целиком.
## Если есть узлы «LegL» / «LegR» (голени мамы ниже подола) — walk() двигает ими при ходьбе.
## Если в модели есть скелет и анимации (мама: hold_loop — держится за верхний поручень, idle_loop, walk_loop),
## позы берутся из анимаций, а голова поворачивается костями Neck / Head.

var look_target: Variant = null      # Vector3 в мировых координатах или null
var talking: float = 0.0
var glances: bool = false            # пассажир иногда смотрит по сторонам (только с узлом Head)
var turn_body: bool = false          # поворачиваться к цели всем телом
var head: Node3D
var model: Node3D
var legs: Array = []
var height: float = 1.5              # где «лицо» у моделей без узла Head
var anim: AnimationPlayer
var skel: Skeleton3D
var _neck_i: int = -1
var _head_i: int = -1
var _anim_name: String = ""

var _rest: Basis = Basis.IDENTITY
var _base_yaw: float = 0.0
var _body_yaw: float = 0.0
var _yaw: float = 0.0
var _pitch: float = 0.0
var _t: float = 0.0
var _glance_timer: float = 3.0
var _glance: Vector2 = Vector2.ZERO
var _walk_phase: float = 0.0


func setup(scene: PackedScene) -> void:
	model = scene.instantiate() as Node3D
	add_child(model)
	head = model.find_child("Head", true, false) as Node3D
	if head != null:
		_rest = head.transform.basis
	for leg_name in ["LegL", "LegR"]:
		var leg: Node3D = model.find_child(leg_name, true, false) as Node3D
		if leg != null:
			legs.append(leg)
	var players: Array = model.find_children("*", "AnimationPlayer", true, false)
	if not players.is_empty():
		anim = players[0]
	var skels: Array = model.find_children("*", "Skeleton3D", true, false)
	if not skels.is_empty():
		skel = skels[0]
		_neck_i = skel.find_bone("Neck")
		_head_i = skel.find_bone("Head")
	_base_yaw = rotation.y
	_t = randf() * 10.0
	_glance_timer = randf_range(2.0, 9.0)


## Поза уже «запечена» в модели — метод нужен для совместимости с человечками-заглушками.
func set_pose(_pose: String) -> void:
	pass


## Включить анимацию из модели (hold_loop, idle_loop, walk_loop). Без анимаций — ничего не делает.
func play_anim(anim_name: String, blend: float = 0.3) -> void:
	if anim == null or anim_name == _anim_name or not anim.has_animation(anim_name):
		return
	_anim_name = anim_name
	anim.play(anim_name, blend)


## Точка, на которую смотрят и в которую «целятся» клавишей E (лицо).
func focus_point() -> Vector3:
	if skel != null and _head_i >= 0:
		return skel.global_transform * (skel.get_bone_global_pose(_head_i).origin + Vector3(0, 0.08, 0))
	if head != null:
		return head.global_position + head.global_transform.basis.y * 0.08
	return global_position + global_transform.basis.y * height


## Шаг: голени качаются, тело чуть подпрыгивает. speed — м/с.
func walk(speed: float, delta: float) -> void:
	if anim != null and anim.has_animation("walk_loop"):
		play_anim("walk_loop" if speed > 0.15 else "idle_loop")
		anim.speed_scale = clampf(speed / 1.2, 0.5, 1.5) if speed > 0.15 else 1.0
		return
	var k: float = clampf(speed / 1.2, 0.0, 1.0)
	_walk_phase += speed * delta * 5.4
	var swing: float = sin(_walk_phase) * 0.34 * k
	if legs.size() == 2:
		(legs[0] as Node3D).rotation.x = swing
		(legs[1] as Node3D).rotation.x = -swing
	if model != null:
		model.position.y = absf(sin(_walk_phase)) * 0.022 * k
		model.rotation.z = sin(_walk_phase) * 0.02 * k


func _process(delta: float) -> void:
	_t += delta
	talking = maxf(0.0, talking - delta)
	if skel != null and _neck_i >= 0 and _head_i >= 0:
		_bone_look(delta)
		return
	if head == null:
		if turn_body and look_target != null:
			var lp: Vector3 = get_parent_node_3d().to_local(look_target as Vector3) - position
			var want: float = atan2(-lp.x, -lp.z)
			var off: float = clampf(wrapf(want - _base_yaw, -PI, PI), -1.1, 1.1)
			_body_yaw = lerpf(_body_yaw, off, 1.0 - exp(-2.5 * delta))
			rotation.y = _base_yaw + _body_yaw
		return
	var yaw: float = 0.0
	var pitch: float = 0.0
	if look_target != null:
		var parent: Node3D = head.get_parent() as Node3D
		var hp: Vector3 = parent.to_local(look_target as Vector3) - head.position
		yaw = clampf(atan2(-hp.x, -hp.z), -1.25, 1.25)
		pitch = clampf(atan2(hp.y - 0.08, Vector2(hp.x, hp.z).length()), -0.5, 0.4)
	elif glances:
		_glance_timer -= delta
		if _glance_timer <= 0.0:
			if _glance == Vector2.ZERO:
				_glance = Vector2(randf_range(-1.0, 1.0), randf_range(-0.15, 0.1))
				_glance_timer = randf_range(1.5, 4.0)
			else:
				_glance = Vector2.ZERO
				_glance_timer = randf_range(5.0, 14.0)
		yaw = _glance.x
		pitch = _glance.y
	_yaw = lerpf(_yaw, yaw, 1.0 - exp(-4.0 * delta))
	_pitch = lerpf(_pitch, pitch, 1.0 - exp(-4.0 * delta))
	var nod: float = sin(_t * 9.0) * 0.035 if talking > 0.0 else 0.0
	var breathe: float = sin(_t * 1.7) * 0.01
	head.transform.basis = _rest * Basis.from_euler(Vector3(_pitch + nod + breathe, _yaw, 0.0), EULER_ORDER_YXZ)


## Голова костями: Neck берёт 40% поворота, Head — 60%. Цель — look_target (или прямо, если null).
func _bone_look(delta: float) -> void:
	var yaw: float = 0.0
	var pitch: float = 0.0
	if look_target != null:
		var hp: Vector3 = focus_point()
		var lp: Vector3 = global_transform.basis.inverse() * ((look_target as Vector3) - hp)
		yaw = clampf(atan2(-lp.x, -lp.z), -1.15, 1.15)
		pitch = clampf(atan2(lp.y, Vector2(lp.x, lp.z).length()), -0.45, 0.35)
	_yaw = lerpf(_yaw, yaw, 1.0 - exp(-3.0 * delta))
	_pitch = lerpf(_pitch, pitch, 1.0 - exp(-3.0 * delta))
	var to_skel: Basis = skel.global_transform.basis.inverse() * global_transform.basis
	var up_s: Vector3 = (to_skel * Vector3.UP).normalized()
	var right_s: Vector3 = (to_skel * Vector3.RIGHT).normalized()
	var nod: float = sin(_t * 8.0) * 0.03 if talking > 0.0 else 0.0
	var r_neck: Basis = Basis(right_s.rotated(up_s, _yaw * 0.4), (_pitch + nod) * 0.4) * Basis(up_s, _yaw * 0.4)
	var r_head: Basis = Basis(right_s.rotated(up_s, _yaw), _pitch + nod) * Basis(up_s, _yaw)
	var neck_rest: Basis = skel.get_bone_global_rest(_neck_i).basis
	var head_rest: Basis = skel.get_bone_global_rest(_head_i).basis
	var parent_rest: Basis = skel.get_bone_global_rest(skel.get_bone_parent(_neck_i)).basis
	var neck_g: Basis = r_neck * neck_rest
	skel.set_bone_pose_rotation(_neck_i, (parent_rest.inverse() * neck_g).get_rotation_quaternion())
	skel.set_bone_pose_rotation(_head_i, (neck_g.inverse() * (r_head * head_rest)).get_rotation_quaternion())
