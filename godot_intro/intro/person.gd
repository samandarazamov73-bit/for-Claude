extends Node3D
## Человек из GLB (intro/assets/models/people/*.glb): тело в готовой позе + голова отдельным узлом «Head».
## Голова плавно поворачивается к цели (look_target), кивает, когда человек говорит (talking > 0),
## а пассажиры (glances = true) время от времени смотрят по сторонам и в окно.

var look_target: Variant = null      # Vector3 в мировых координатах или null
var talking: float = 0.0
var glances: bool = false
var head: Node3D

var _rest: Basis = Basis.IDENTITY
var _yaw: float = 0.0
var _pitch: float = 0.0
var _t: float = 0.0
var _glance_timer: float = 3.0
var _glance: Vector2 = Vector2.ZERO


func setup(scene: PackedScene) -> void:
	var inst: Node = scene.instantiate()
	add_child(inst)
	head = inst.find_child("Head", true, false) as Node3D
	if head != null:
		_rest = head.transform.basis
	_t = randf() * 10.0
	_glance_timer = randf_range(2.0, 9.0)


## Поза уже «запечена» в модели — метод нужен для совместимости с человечками-заглушками.
func set_pose(_pose: String) -> void:
	pass


## Точка, на которую смотрят и в которую «целятся» клавишей E (голова).
func focus_point() -> Vector3:
	if head != null:
		return head.global_position + head.global_transform.basis.y * 0.08
	return global_position + Vector3(0, 1.2, 0)


func _process(delta: float) -> void:
	if head == null:
		return
	_t += delta
	var yaw: float = 0.0
	var pitch: float = 0.0
	if look_target != null:
		var parent: Node3D = head.get_parent() as Node3D
		var lp: Vector3 = parent.to_local(look_target as Vector3) - head.position
		yaw = clampf(atan2(-lp.x, -lp.z), -1.25, 1.25)
		pitch = clampf(atan2(lp.y - 0.08, Vector2(lp.x, lp.z).length()), -0.5, 0.4)
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
	talking = maxf(0.0, talking - delta)
	var nod: float = sin(_t * 9.0) * 0.035 if talking > 0.0 else 0.0
	var breathe: float = sin(_t * 1.7) * 0.01
	head.transform.basis = _rest * Basis.from_euler(Vector3(_pitch + nod + breathe, _yaw, 0.0), EULER_ORDER_YXZ)
