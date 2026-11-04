extends Node3D
## Человек из GLB (intro/assets/models/people/*.glb).
## Если в модели есть узел «Head» — поворачивается голова; если нет (модели автора — цельные),
## стоящий человек (turn_body = true) поворачивается к цели целиком.
## Если есть узлы «LegL» / «LegR» (голени мамы ниже подола) — walk() двигает ими при ходьбе.

var look_target: Variant = null      # Vector3 в мировых координатах или null
var talking: float = 0.0
var glances: bool = false            # пассажир иногда смотрит по сторонам (только с узлом Head)
var turn_body: bool = false          # поворачиваться к цели всем телом
var head: Node3D
var model: Node3D
var legs: Array = []
var height: float = 1.5              # где «лицо» у моделей без узла Head

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
	_base_yaw = rotation.y
	_t = randf() * 10.0
	_glance_timer = randf_range(2.0, 9.0)


## Поза уже «запечена» в модели — метод нужен для совместимости с человечками-заглушками.
func set_pose(_pose: String) -> void:
	pass


## Точка, на которую смотрят и в которую «целятся» клавишей E (лицо).
func focus_point() -> Vector3:
	if head != null:
		return head.global_position + head.global_transform.basis.y * 0.08
	return global_position + global_transform.basis.y * height


## Шаг: голени качаются, тело чуть подпрыгивает. speed — м/с.
func walk(speed: float, delta: float) -> void:
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
