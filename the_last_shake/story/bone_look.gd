extends SkeletonModifier3D
## Поверх анимации: голова и шея поворачиваются к точке (look_target), правая рука тянется к точке
## (arm_target — например, держится за верхний поручень в автобусе). Работает после AnimationPlayer,
## поэтому анимация (ходьба, разговор) не перебивает поворот головы.
## Модели Mixamo смотрят в +Z своего скелета.

var look_target: Variant = null      # Vector3 (мировые координаты) или null
var arm_target: Variant = null       # Vector3 (мировые) или null — правая рука
var arm_target_left: Variant = null  # левая рука
var arm_weight := 1.0                # 0..1: насколько рука тянется к цели (плавно взяться/отпустить)
var lean := 0.0                      # рад: наклон корпуса вперёд от поясницы (бьёт сверху, тянется вниз)
var max_yaw := 1.2
var max_pitch := 0.5
var follow_rate := 4.0

var _neck := -1
var _head := -1
var _arm := -1
var _fore := -1
var _hand := -1
var _larm := -1
var _lfore := -1
var _lhand := -1
var _spine := -1
var _yaw := 0.0
var _pitch := 0.0
var _last_us := 0


func find_bones(sk: Skeleton3D) -> void:
	for i in sk.get_bone_count():
		# Godot при импорте меняет «mixamorig:Neck» на «mixamorig_Neck» — отрезаем приставку в любом виде
		var short: String = sk.get_bone_name(i)
		for prefix in ["mixamorig:", "mixamorig_", "mixamorig"]:
			if short.begins_with(prefix):
				short = short.substr(prefix.length())
				break
		match short:
			"Neck": _neck = i
			"Head": _head = i
			"RightArm": _arm = i
			"RightForeArm": _fore = i
			"RightHand": _hand = i
			"LeftArm": _larm = i
			"LeftForeArm": _lfore = i
			"LeftHand": _lhand = i
			"Spine": _spine = i


func _process_modification() -> void:
	var sk: Skeleton3D = get_skeleton()
	if sk == null:
		return
	var now: int = Time.get_ticks_usec()
	var dt: float = clampf(float(now - _last_us) / 1000000.0, 0.0, 0.1) if _last_us > 0 else 0.016
	_last_us = now
	var inv: Transform3D = sk.global_transform.affine_inverse()
	if absf(lean) > 0.001 and _spine >= 0:
		# поворот вокруг оси «вправо» скелета у поясницы: всё, что выше, наклоняется вперёд (+Z — лицо)
		var sg: Transform3D = sk.get_bone_global_pose(_spine)
		var par: int = sk.get_bone_parent(_spine)
		var pb: Basis = sk.get_bone_global_pose(par).basis if par >= 0 else Basis.IDENTITY
		var bent: Basis = Basis(Vector3.RIGHT, lean) * sg.basis
		sk.set_bone_pose_rotation(_spine, (pb.inverse() * bent).get_rotation_quaternion())
	if arm_target != null and _arm >= 0 and _fore >= 0 and _hand >= 0:
		_reach(sk, inv * (arm_target as Vector3), _arm, _fore, _hand, Vector3(-0.6, -1.0, -0.3))
	if arm_target_left != null and _larm >= 0 and _lfore >= 0 and _lhand >= 0:
		_reach(sk, inv * (arm_target_left as Vector3), _larm, _lfore, _lhand, Vector3(0.6, -1.0, -0.3))
	if _neck >= 0 and _head >= 0:
		_look(sk, inv, dt)


func _look(sk: Skeleton3D, inv: Transform3D, dt: float) -> void:
	var yaw := 0.0
	var pitch := 0.0
	var head_g: Transform3D = sk.get_bone_global_pose(_head)
	if look_target != null:
		var d: Vector3 = inv * (look_target as Vector3) - head_g.origin
		yaw = clampf(atan2(d.x, d.z), -max_yaw, max_yaw)
		pitch = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -max_pitch, max_pitch)
	var k: float = 1.0 - exp(-follow_rate * dt)
	_yaw = lerpf(_yaw, yaw, k)
	_pitch = lerpf(_pitch, pitch, k)
	if absf(_yaw) < 0.002 and absf(_pitch) < 0.002:
		return
	var neck_g: Transform3D = sk.get_bone_global_pose(_neck)
	var parent: int = sk.get_bone_parent(_neck)
	var parent_b: Basis = sk.get_bone_global_pose(parent).basis if parent >= 0 else Basis.IDENTITY
	var r40: Basis = Basis(Vector3.UP, _yaw * 0.4) * Basis(Vector3.RIGHT, -_pitch * 0.4)
	var r100: Basis = Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, -_pitch)
	var neck_new: Basis = r40 * neck_g.basis
	var head_new: Basis = r100 * head_g.basis
	sk.set_bone_pose_rotation(_neck, (parent_b.inverse() * neck_new).get_rotation_quaternion())
	sk.set_bone_pose_rotation(_head, (neck_new.inverse() * head_new).get_rotation_quaternion())


## Две кости (плечо — предплечье): кисть в точку t (координаты скелета), локоть вниз и наружу.
func _reach(sk: Skeleton3D, t_full: Vector3, arm: int, fore: int, hand: int, pole0: Vector3) -> void:
	var arm_g: Transform3D = sk.get_bone_global_pose(arm)
	var fore_g: Transform3D = sk.get_bone_global_pose(fore)
	var hand_g: Transform3D = sk.get_bone_global_pose(hand)
	var t: Vector3 = hand_g.origin.lerp(t_full, clampf(arm_weight, 0.0, 1.0))
	var s: Vector3 = arm_g.origin
	var a: float = s.distance_to(fore_g.origin)
	var b: float = fore_g.origin.distance_to(hand_g.origin)
	if a < 0.01 or b < 0.01:
		return
	var to: Vector3 = t - s
	var d: float = clampf(to.length(), absf(a - b) + 0.01, a + b - 0.01)
	var u: Vector3 = to.normalized()
	var pole: Vector3 = pole0                             # локоть: вниз, наружу, чуть назад
	pole = (pole - u * pole.dot(u)).normalized()
	var cos_a: float = clampf((a * a + d * d - b * b) / (2.0 * a * d), -1.0, 1.0)
	var elbow: Vector3 = s + (u * cos_a + pole * sqrt(1.0 - cos_a * cos_a)) * a
	var wrist: Vector3 = s + u * d
	var q1 := Quaternion((fore_g.origin - s).normalized(), (elbow - s).normalized())
	var arm_new: Basis = Basis(q1) * arm_g.basis
	var fore_dir: Vector3 = Basis(q1) * (hand_g.origin - fore_g.origin)
	var q2 := Quaternion(fore_dir.normalized(), (wrist - elbow).normalized())
	var fore_new: Basis = Basis(q2) * Basis(q1) * fore_g.basis
	var parent: int = sk.get_bone_parent(arm)
	var parent_b: Basis = sk.get_bone_global_pose(parent).basis if parent >= 0 else Basis.IDENTITY
	sk.set_bone_pose_rotation(arm, (parent_b.inverse() * arm_new).get_rotation_quaternion())
	sk.set_bone_pose_rotation(fore, (arm_new.inverse() * fore_new).get_rotation_quaternion())
