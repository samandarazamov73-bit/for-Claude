class_name CameraRig
extends Node3D
## Camera modes: CHASE (behind the car), HOOD (driver's eye), CINEMATIC (autopilot along the
## right-hand lane — also used for screenshots and benchmarks) and FREE (fly anywhere).

enum Mode { CHASE, HOOD, CINEMATIC, FREE }
const MODE_NAMES := ["Chase camera", "Driver view", "Autopilot drive", "Free camera"]

@export var mode: Mode = Mode.CHASE
@export var cinematic_speed := 19.0         # m/s (~70 km/h)
@export var cinematic_height := 1.25

var car: ForestCar
var road: RoadBuilder
var terrain: TerrainSystem
var camera: Camera3D
var cine_s := 0.0
var _yaw := 0.0
var _pitch := 0.0
var _look := Vector3.ZERO
var _vel := Vector3.ZERO


func _ready() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 68.0
	camera.near = 0.08
	camera.far = 1200.0
	# the rig moves the camera every rendered frame itself (the chase view follows the car's
	# interpolated transform), so the camera must not be physics-interpolated
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(camera)
	camera.current = true


func set_mode(m: int) -> void:
	mode = m as Mode
	if car:
		car.input_enabled = mode == Mode.CHASE or mode == Mode.HOOD
		car.visible = mode == Mode.CHASE or mode == Mode.FREE
	if mode == Mode.FREE:
		var e := camera.global_transform.basis.get_euler()
		_pitch = e.x
		_yaw = e.y
	if mode == Mode.CINEMATIC and car and road:
		cine_s = road.nearest_s(car.global_position)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if mode == Mode.FREE else Input.MOUSE_MODE_VISIBLE


func next_mode() -> void:
	set_mode((int(mode) + 1) % 4)


func _unhandled_input(event: InputEvent) -> void:
	if mode == Mode.FREE and event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * 0.0025
		_pitch = clampf(_pitch - event.relative.y * 0.0025, -1.5, 1.5)
	if mode == Mode.CINEMATIC and event is InputEventKey and event.pressed:
		if event.keycode == KEY_EQUAL or event.keycode == KEY_KP_ADD:
			cinematic_speed = minf(cinematic_speed + 3.0, 45.0)
		elif event.keycode == KEY_MINUS or event.keycode == KEY_KP_SUBTRACT:
			cinematic_speed = maxf(cinematic_speed - 3.0, 0.0)


func _process(delta: float) -> void:
	match mode:
		Mode.CHASE:
			_chase(delta)
		Mode.HOOD:
			_hood()
		Mode.CINEMATIC:
			advance_cinematic(delta)
		Mode.FREE:
			_free(delta)


func _chase(delta: float) -> void:
	if car == null:
		return
	var xf := car.get_global_transform_interpolated()
	var back := xf.basis.z
	back.y = 0.0
	back = back.normalized()
	var target := xf.origin + back * 7.2 + Vector3.UP * 2.6
	var k := 1.0 - exp(-delta * 6.0)
	camera.global_position = camera.global_position.lerp(target, k) if camera.global_position.distance_to(target) < 30.0 else target
	if terrain:
		var g := terrain.height_at(camera.global_position.x, camera.global_position.z) + 0.6
		camera.global_position.y = maxf(camera.global_position.y, g)
	_look = _look.lerp(xf.origin + Vector3.UP * 1.2 - back * 4.0, k) if _look.distance_to(xf.origin) < 30.0 else xf.origin
	camera.look_at(_look, Vector3.UP)


func _hood() -> void:
	if car == null:
		return
	var xf := car.get_global_transform_interpolated()
	camera.global_transform = Transform3D(xf.basis, xf.origin + xf.basis * Vector3(-0.36, 1.22, -0.05))
	camera.rotate_object_local(Vector3.RIGHT, deg_to_rad(-2.0))


## Moves the camera along the right lane. Public so tests/benchmarks can step it deterministically.
func advance_cinematic(delta: float) -> void:
	if road == null:
		return
	cine_s += cinematic_speed * delta
	var lane := -road.lane_width * 0.5
	var here := road.sample(cine_s, lane)
	var ahead := road.sample(cine_s + 22.0, lane)
	var pos := here.origin + Vector3.UP * cinematic_height
	var look := ahead.origin + Vector3.UP * (cinematic_height * 0.85)
	camera.global_position = pos
	camera.look_at(look, Vector3.UP)


func place_cinematic(s: float) -> void:
	cine_s = s
	advance_cinematic(0.0)


func _free(delta: float) -> void:
	var basis := Basis.from_euler(Vector3(_pitch, _yaw, 0.0))
	var dir := Vector3.ZERO
	dir += -basis.z * (Input.get_action_strength("accelerate") - Input.get_action_strength("brake"))
	dir += basis.x * (Input.get_action_strength("steer_right") - Input.get_action_strength("steer_left"))
	dir += Vector3.UP * (Input.get_action_strength("free_up") - Input.get_action_strength("free_down"))
	var speed := 60.0 if Input.is_action_pressed("free_fast") else 14.0
	_vel = _vel.lerp(dir * speed, 1.0 - exp(-delta * 8.0))
	camera.global_basis = basis
	camera.global_position += _vel * delta
	if terrain:
		var g := terrain.height_at(camera.global_position.x, camera.global_position.z) + 0.4
		camera.global_position.y = maxf(camera.global_position.y, g)
