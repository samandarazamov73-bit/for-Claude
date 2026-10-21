class_name Player
extends CharacterBody3D
## Walkable character (the Meshy "Friendly Cartoon Explorer" model, models/characters/explorer.glb).
## The model has no skeleton, so walking is animated procedurally (bob, sway, lean).

const HEIGHT := 1.75
const WALK_SPEED := 2.2
const RUN_SPEED := 6.0
const JUMP_VELOCITY := 4.6

var active := false
var cam_yaw := 0.0
var model: Node3D
var _phase := 0.0
var _speed_blend := 0.0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)


func _ready() -> void:
	var shape := CapsuleShape3D.new()
	shape.radius = 0.32
	shape.height = HEIGHT
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position.y = HEIGHT * 0.5
	add_child(cs)
	floor_snap_length = 0.3
	floor_max_angle = deg_to_rad(50.0)
	var scene: PackedScene = load("res://models/characters/explorer.glb")
	model = Node3D.new()
	add_child(model)
	if scene:
		var inst: Node3D = scene.instantiate()
		model.add_child(inst)
		# the source model is 0.95 m tall and centred on the origin
		var s := HEIGHT / 0.95
		inst.scale = Vector3.ONE * s
		inst.position.y = 0.4753 * s
		for mi in inst.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	visible = false


func teleport(p: Vector3) -> void:
	global_position = p
	velocity = Vector3.ZERO


func _physics_process(delta: float) -> void:
	if not active:
		return
	var input := Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP): input.y -= 1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN): input.y += 1
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT): input.x -= 1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): input.x += 1
	var running := Input.is_key_pressed(KEY_SHIFT)
	var dir := (Basis(Vector3.UP, cam_yaw) * Vector3(input.x, 0, input.y))
	if dir.length() > 1.0:
		dir = dir.normalized()
	var target_speed := RUN_SPEED if running else WALK_SPEED
	var hv := Vector3(velocity.x, 0, velocity.z)
	hv = hv.lerp(dir * target_speed, clampf(delta * 10.0, 0.0, 1.0))
	velocity.x = hv.x
	velocity.z = hv.z
	if not is_on_floor():
		velocity.y -= _gravity * delta
	elif Input.is_key_pressed(KEY_SPACE):
		velocity.y = JUMP_VELOCITY
	move_and_slide()
	if global_position.y < -20.0:
		teleport(Vector3(0, 2, 8))
	_animate(delta, hv)


func _animate(delta: float, hv: Vector3) -> void:
	var spd := hv.length()
	_speed_blend = lerpf(_speed_blend, clampf(spd / RUN_SPEED, 0.0, 1.0), clampf(delta * 8.0, 0.0, 1.0))
	if spd > 0.2:
		var target := atan2(hv.x, hv.z)
		model.rotation.y = lerp_angle(model.rotation.y, target, clampf(delta * 10.0, 0.0, 1.0))
		_phase += delta * (5.5 + spd * 1.6)
	else:
		_phase = lerpf(_phase, roundf(_phase / PI) * PI, clampf(delta * 6.0, 0.0, 1.0))
	var bob := absf(sin(_phase)) * (0.035 + 0.06 * _speed_blend)
	model.position.y = bob
	model.rotation.z = sin(_phase) * 0.05 * minf(spd, 1.0)
	model.rotation.x = 0.12 * _speed_blend
	var squash := 1.0 + (absf(sin(_phase)) - 0.5) * 0.04 * minf(spd, 1.0)
	model.scale = Vector3(1.0 / sqrt(squash), squash, 1.0 / sqrt(squash))
