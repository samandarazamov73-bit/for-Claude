extends CharacterBody3D
## Electric wheelchair seen from the seat (first person).
## Drive model of a real mid-wheel-drive / rear-drive power chair controlled by a joystick:
## - five speed settings (4 .. 14 km/h), reverse at 45 % of the forward speed;
## - limited motor acceleration and stronger braking when the stick is released (electromagnetic brakes
##   click open when you start and engage when you stop; a stopped chair does not roll);
## - differential drive: turns on the spot, turns slower the faster it goes;
## - the front casters swing round when you change direction (a small heading wobble);
## - on slopes gravity speeds it up or slows it down a little;
## - it does not slide along walls: hitting something stops the chair with a bump.
## The collision shapes cover everything you can see of the chair (wheels, armrests, legs, footrest), and
## turning on the spot is refused when it would swing a part of the chair into a wall or a piece of furniture.

var game

const SPEEDS := [1.1, 1.75, 2.4, 3.1, 3.9]     # m/s: 4.0, 6.3, 8.6, 11.2, 14.0 km/h
const REVERSE := 0.45
const ACCEL := 0.8          # m/s² at the slowest setting; faster settings pull away harder
const BRAKE := 1.8
const YAW_MAX := 1.35
const YAW_ACC := 7.0
const YAW_STOP := 11.0
const RADIUS := 0.36
const FRONT := 0.75         # from the chair's centre to the front of the footrest
const EYE := 1.18
const HEAD_POS := Vector3(0, EYE, 0.06)
const MOUSE_SENS := 0.0024
const REACH := 1.5          # doors, switches, buttons: from the eyes, about an arm's length past the knees
const SEE_RANGE := 6.0      # farther than REACH: "too far" when you try
# collision boxes (local, metres): the chair with its wheels, and the legs with the footrest in front.
# They start 6 cm above the floor, like a real footrest: door sills roll under them.
const CLEAR := 0.06
const BODY_HALF_W := 0.36
const BODY_Z := Vector2(-0.30, 0.40)
const LEGS_HALF_W := 0.23
const LEGS_Z := Vector2(-FRONT, -0.30)

var speed_level := 2
var v := 0.0
var w := 0.0
var caster := 0.0
var caster_kick := 0.0
var last_dir := 1.0
var head: Node3D
var cam: Camera3D
var chair: Node3D
var stick: Node3D
var look_yaw := 0.0
var look_pitch := -0.08
var look_idle := 0.0
var shake := 0.0
var _lean := 0.0
var torch: SpotLight3D
var torch_on := false
var _torch_flick := 0.0
var _torch_next := 60.0
const TORCH_ENERGY := 4.2
const CHAIR_LAYER := 2       # visual layer of the chair's own meshes: they cast no shadow in the torch beam
var t := 0.0
var braked := true
var story_lock := false               # сюжетная сцена: мышь и E не слушаются (story/director.gd)
var view_offset := Transform3D.IDENTITY   # сюжет: смещение/наклон камеры (удар, падение на пол, тряска)
var input_override = null
var target = null
var far_target = null
var _boxes: Array[CollisionShape3D] = []
var motor: AudioStreamPlayer
var wheels: AudioStreamPlayer
var _ray_frame := 0
var _last_room := ""


func _ready() -> void:
	collision_layer = game.L_PLAYER
	collision_mask = game.L_WORLD | game.L_DOORS | game.L_LIFT
	floor_max_angle = deg_to_rad(20.0)
	floor_snap_length = 0.12
	floor_stop_on_slope = true
	floor_constant_speed = true
	safe_margin = 0.02
	platform_on_leave = CharacterBody3D.PLATFORM_ON_LEAVE_DO_NOTHING
	# floor contact: a capsule in the middle rolls over door sills like the wheels do
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.3
	cs.shape = cap
	cs.position = Vector3(0, 0.65, 0)
	add_child(cs)
	_boxes.append(_collision_box(BODY_HALF_W, BODY_Z, CLEAR, 1.3))
	_boxes.append(_collision_box(LEGS_HALF_W, LEGS_Z, CLEAR, 0.75))
	# The camera is not a child that moves with the physics ticks: it is placed every rendered frame from
	# the chair's interpolated position and the mouse look, so looking around stays smooth at any frame rate.
	head = Node3D.new()
	head.top_level = true
	head.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(head)
	cam = Camera3D.new()
	cam.fov = 74.0
	cam.near = 0.02
	cam.far = 400.0
	head.add_child(cam)
	cam.current = true
	_build_chair()
	_build_torch()
	motor = _loop_player("motor_loop", -80.0)
	wheels = _loop_player("wheels_loop", -80.0)
	if not ("--test" in OS.get_cmdline_user_args() or "--shots" in OS.get_cmdline_user_args()):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _collision_box(half_w: float, z: Vector2, y0: float, y1: float) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(half_w * 2.0, y1 - y0, z.y - z.x)
	cs.shape = bs
	cs.position = Vector3(0.0, (y0 + y1) * 0.5, (z.x + z.y) * 0.5)
	add_child(cs)
	return cs


## Whether the chair's boxes would overlap the world (walls, furniture, doors, the lift) at transform xf.
func _overlaps(xf: Transform3D) -> bool:
	var space := get_world_3d().direct_space_state
	for cs in _boxes:
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = cs.shape
		q.transform = xf * cs.transform
		q.collision_mask = collision_mask
		q.exclude = [get_rid()]
		if not space.intersect_shape(q, 1).is_empty():
			return true
	return false


func _loop_player(name: String, vol: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = game.sfx(name, true)
	p.volume_db = vol
	add_child(p)
	p.play()
	return p


func _mat(c: Color, rough := 0.7, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m


func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


func _plaid() -> StandardMaterial3D:
	var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
	for y in 64:
		for x in 64:
			var a := (x / 8) % 2
			var b := (y / 8) % 2
			var c := Color(0.2, 0.24, 0.18).lerp(Color(0.46, 0.4, 0.3), (a + b) * 0.5)
			if x % 16 == 0 or y % 16 == 0:
				c = Color(0.42, 0.14, 0.1)
			img.set_pixel(x, y, c)
	var m := StandardMaterial3D.new()
	m.albedo_texture = ImageTexture.create_from_image(img)
	m.uv1_scale = Vector3(2, 2, 2)
	m.roughness = 0.95
	return m


func _build_chair() -> void:
	chair = Node3D.new()
	add_child(chair)
	var leather := _mat(Color(0.06, 0.055, 0.05), 0.55)
	var steel := _mat(Color(0.18, 0.19, 0.2), 0.4, 0.8)
	var rubber := _mat(Color(0.03, 0.03, 0.03), 0.9)
	var blanket := _plaid()
	for sx in [-1.0, 1.0]:
		_box(chair, Vector3(0.075, 0.05, 0.42), Vector3(0.275 * sx, 0.74, -0.06), leather)
		_box(chair, Vector3(0.025, 0.25, 0.025), Vector3(0.275 * sx, 0.6, -0.24), steel)
		var wheel := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.3
		cm.bottom_radius = 0.3
		cm.height = 0.04
		cm.radial_segments = 24
		wheel.mesh = cm
		wheel.material_override = rubber
		wheel.rotation.z = PI / 2
		wheel.position = Vector3(0.31 * sx, 0.3, 0.08)     # rims inside BODY_HALF_W: 0.72 m over the rims
		# like the rest of the chair: a shadow caster that moves with the player would make every
		# nearby lamp redraw its shadow cube on every frame of driving
		wheel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		chair.add_child(wheel)
		var rim := MeshInstance3D.new()
		var rm := TorusMesh.new()
		rm.inner_radius = 0.25
		rm.outer_radius = 0.27
		rim.mesh = rm
		rim.material_override = _mat(Color(0.7, 0.72, 0.74), 0.25, 1.0)
		rim.rotation.z = PI / 2
		rim.position = Vector3(0.345 * sx, 0.3, 0.08)
		rim.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		chair.add_child(rim)
		_box(chair, Vector3(0.1, 0.08, 0.25), Vector3(0.09 * sx, 0.12, -0.6), _mat(Color(0.16, 0.1, 0.06), 0.6))
	# legs under a plaid blanket: two rounded thighs and the blanket hanging over the knees
	for sx in [-1.0, 1.0]:
		var thigh := MeshInstance3D.new()
		var cp := CapsuleMesh.new()
		cp.radius = 0.085
		cp.height = 0.5
		cp.radial_segments = 12
		cp.rings = 4
		thigh.mesh = cp
		thigh.material_override = blanket
		thigh.rotation.x = PI / 2
		thigh.position = Vector3(0.105 * sx, 0.6, -0.27)
		thigh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		chair.add_child(thigh)
		var shin := MeshInstance3D.new()
		var cs2 := CapsuleMesh.new()
		cs2.radius = 0.06
		cs2.height = 0.46
		shin.mesh = cs2
		shin.material_override = _mat(Color(0.12, 0.1, 0.09), 0.9)
		shin.position = Vector3(0.1 * sx, 0.35, -0.52)
		shin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		chair.add_child(shin)
	_box(chair, Vector3(0.44, 0.3, 0.02), Vector3(0, 0.46, -0.59), blanket)
	_box(chair, Vector3(0.44, 0.02, 0.24), Vector3(0, 0.07, -0.6), steel)
	_box(chair, Vector3(0.08, 0.05, 0.13), Vector3(0.275, 0.785, -0.22), _mat(Color(0.05, 0.05, 0.05), 0.4))
	stick = Node3D.new()
	stick.position = Vector3(0.275, 0.81, -0.23)
	chair.add_child(stick)
	_box(stick, Vector3(0.012, 0.06, 0.012), Vector3(0, 0.03, 0), steel)
	var knob := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.018
	sm.height = 0.036
	knob.mesh = sm
	knob.material_override = _mat(Color(0.04, 0.04, 0.04), 0.3)
	knob.position = Vector3(0, 0.065, 0)
	knob.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	stick.add_child(knob)
	var led := _box(chair, Vector3(0.012, 0.004, 0.012), Vector3(0.255, 0.811, -0.19), StandardMaterial3D.new())
	var lm: StandardMaterial3D = led.material_override
	lm.emission_enabled = true
	lm.emission = Color(0.2, 1.0, 0.3)
	lm.emission_energy_multiplier = 2.0


func _unhandled_input(event: InputEvent) -> void:
	if get_tree().paused:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not story_lock:
		look_yaw = clamp(look_yaw - event.relative.x * MOUSE_SENS, -2.1, 2.1)
		look_pitch = clamp(look_pitch - event.relative.y * MOUSE_SENS, -1.25, 1.0)
		look_idle = 0.0
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED \
			and not game.hud.menu_open():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if event.is_action_pressed("speed_up"):
		speed_level = min(speed_level + 1, SPEEDS.size() - 1)
		game.hud.set_speed(speed_level, SPEEDS.size())
		game.play_at("button", global_position + Vector3(0.27, 0.8, 0), -14.0, 1.4, 4.0)
	elif event.is_action_pressed("speed_down"):
		speed_level = max(speed_level - 1, 0)
		game.hud.set_speed(speed_level, SPEEDS.size())
		game.play_at("button", global_position + Vector3(0.27, 0.8, 0), -14.0, 1.2, 4.0)
	elif event.is_action_pressed("horn"):
		game.play_at("horn", global_position + Vector3(0, 0.8, 0), -6.0, 1.0, 30.0)
		game.critters.scare(global_position, 8.0)
	elif event.is_action_pressed("flashlight") and not (event is InputEventKey and (event.ctrl_pressed or event.meta_pressed)):
		set_torch(not torch_on)
	elif event.is_action_pressed("interact") and not story_lock:
		if target != null and is_instance_valid(target):
			target.interact(self)
		elif far_target != null and is_instance_valid(far_target):
			game.hud.message("Слишком далеко — подъедьте ближе")


func joystick() -> Vector2:
	if input_override != null:
		return input_override
	var thr: float = Input.get_action_strength("drive_forward") - Input.get_action_strength("drive_back")
	var st: float = Input.get_action_strength("turn_right") - Input.get_action_strength("turn_left")
	var right := Vector2(Input.get_joy_axis(0, JOY_AXIS_RIGHT_X), Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y))
	if right.length() > 0.2:
		look_yaw = clamp(look_yaw - right.x * 0.04, -2.1, 2.1)
		look_pitch = clamp(look_pitch - right.y * 0.03, -1.25, 1.0)
		look_idle = 0.0
	return Vector2(thr, st)


func _physics_process(dt: float) -> void:
	t += dt
	var j := joystick()
	var vmax: float = SPEEDS[speed_level]
	var vt: float = j.x * vmax * (REVERSE if j.x < 0.0 else 1.0)
	# motor torque: accelerate gently, brake harder (and when the stick goes the other way); the faster
	# settings pull away and stop harder, so speed 5 reaches 14 km/h in about 2 s and stops in about 1 s
	var acc: float = maxf(ACCEL, vmax * 0.55)
	var brk: float = maxf(BRAKE, vmax * 1.1)
	var a: float = acc if (absf(vt) > absf(v) and signf(vt) == signf(v)) or absf(v) < 0.02 else brk
	if abs(j.x) < 0.05:
		a = brk
	v = move_toward(v, vt, a * dt)
	var turn_scale: float = 1.0 - 0.55 * clamp(abs(v) / SPEEDS[-1], 0.0, 1.0)
	var wt: float = -j.y * YAW_MAX * turn_scale * (0.75 if speed_level < 1 else 1.0)
	# turning answers the keys quickly and stops as soon as they are released
	w = move_toward(w, wt, (YAW_ACC if absf(wt) > absf(w) and signf(wt) == signf(w) else YAW_STOP) * dt)
	# casters swing round when the direction of travel reverses
	var dir: float = signf(v) if absf(v) > 0.05 else last_dir
	if dir != last_dir:
		caster_kick = randf_range(-1.0, 1.0) * 0.5
		last_dir = dir
	caster = lerp(caster, caster_kick, 6.0 * dt)
	caster_kick = move_toward(caster_kick, 0.0, 1.5 * dt)
	var yaw_rate: float = w + caster * 0.35 * clampf(absf(v) * 2.0, 0.0, 1.0)
	var turn: float = yaw_rate * dt
	if absf(turn) > 0.00001:
		# do not swing the footrest or a wheel into a wall or a piece of furniture
		var turned := global_transform.rotated_local(Vector3.UP, turn)
		if not _overlaps(turned) or _overlaps(global_transform):
			global_transform = turned
		else:
			w = 0.0
			caster = 0.0
			caster_kick = 0.0
	# brakes
	var moving: bool = abs(v) > 0.02 or abs(w) > 0.02 or j.length() > 0.05
	if moving and braked:
		braked = false
		game.play_at("brake_release", global_position + Vector3(0, 0.3, 0), -12.0, 1.0, 6.0)
	elif not moving and not braked:
		braked = true
		game.play_at("brake_engage", global_position + Vector3(0, 0.3, 0), -14.0, 1.0, 6.0)
	var fwd := -global_transform.basis.z
	# slope: gravity along the floor speeds the chair up downhill (only while driving; the brakes hold it otherwise)
	if is_on_floor() and not braked:
		var n := get_floor_normal()
		v += 9.81 * n.dot(fwd) * 0.3 * dt
	var vel := fwd * v
	if is_on_floor():
		velocity = Vector3(vel.x, min(velocity.y, 0.0), vel.z)
	else:
		velocity = Vector3(vel.x, velocity.y - 9.81 * dt, vel.z)
	var before := global_position
	move_and_slide()
	# hitting something: stop with a bump instead of gliding along it
	for i in get_slide_collision_count():
		var c: KinematicCollision3D = get_slide_collision(i)
		var nrm := c.get_normal()
		if abs(nrm.y) > 0.6:
			continue
		var into: float = -nrm.dot(fwd * signf(v))
		if into > 0.45 and abs(v) > 0.25:
			var hit: float = abs(v)
			v *= 0.1
			shake = clamp(hit * 0.025, 0.004, 0.05)
			game.play_at("bump", global_position + fwd * (FRONT if v > 0.0 else RADIUS) + Vector3(0, 0.4, 0), linear_to_db(clamp(hit / 1.6, 0.15, 1.0)), randf_range(0.9, 1.1), 18.0)
			game.critters.scare(global_position, 4.0)
			break
		elif into > 0.2:
			v *= 0.85
	var moved: Vector3 = (global_position - before) / maxf(dt, 0.0001)
	_update_sound(moved.length())
	_update_view(dt)
	_update_target()
	_update_room()


func _update_sound(spd: float) -> void:
	var load_f: float = clamp(abs(v) / SPEEDS[-1] + abs(w) * 0.25, 0.0, 1.2)
	motor.volume_db = lerp(motor.volume_db, -60.0 if load_f < 0.02 else linear_to_db(0.16 + 0.5 * load_f) - 6.0, 0.2)
	motor.pitch_scale = 0.75 + 0.55 * clamp(abs(v) / SPEEDS[-1], 0.0, 1.0) + 0.15 * abs(w)
	var roll: float = clamp(spd / SPEEDS[-1], 0.0, 1.0)
	wheels.volume_db = lerp(wheels.volume_db, -60.0 if roll < 0.02 else linear_to_db(0.1 + 0.6 * roll) - 4.0, 0.2)
	wheels.pitch_scale = 0.8 + 0.4 * roll


func _update_view(dt: float) -> void:
	look_idle += dt
	if look_idle > 2.5 and abs(v) > 0.3:
		look_yaw = lerp(look_yaw, 0.0, 1.2 * dt)
	var vib: float = clamp(abs(v) / SPEEDS[-1], 0.0, 1.0)
	shake = move_toward(shake, 0.0, 0.12 * dt)
	chair.rotation.z = sin(t * 17.0) * 0.002 * vib
	stick.rotation = Vector3(-joystick().x * 0.35, 0, -joystick().y * 0.35)


## Torch (F): an old hand torch held at chest height on the right. A warm beam with a hot centre, a ring
## from the reflector and a yellower spill, that follows the view with a slight lag like a hand, lights up the
## dust in the air and throws shadows (not on Low). The chair's own parts cast no shadow in it.
func _build_torch() -> void:
	for n in chair.find_children("*", "GeometryInstance3D", true, false):
		n.layers = CHAIR_LAYER
	torch = SpotLight3D.new()
	torch.top_level = true
	torch.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	torch.light_color = Color(1.0, 0.9, 0.74)
	torch.light_energy = TORCH_ENERGY
	torch.light_specular = 0.6
	torch.light_volumetric_fog_energy = 1.6
	torch.spot_range = 17.0
	torch.spot_attenuation = 1.1
	torch.spot_angle = 31.0
	torch.spot_angle_attenuation = 0.9
	torch.light_projector = _torch_pattern()
	torch.shadow_enabled = true
	torch.shadow_bias = 0.05
	torch.shadow_normal_bias = 1.2
	torch.shadow_blur = 1.4
	torch.shadow_caster_mask = 0xFFFFF & ~CHAIR_LAYER
	torch.light_cull_mask = 0xFFFFF
	torch.visible = false
	add_child(torch)


## The beam's light pattern: a hot centre, the reflector's brighter ring, a dimmer yellowish spill, and faint
## smudges of a dirty lens.
func _torch_pattern() -> ImageTexture:
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	var noise := FastNoiseLite.new()
	noise.seed = 7
	noise.frequency = 0.06
	for y in n:
		for x in n:
			var r: float = Vector2(x + 0.5 - n * 0.5, y + 0.5 - n * 0.5).length() / (n * 0.5)
			var core: float = 1.0 - smoothstep(0.0, 0.34, r) * 0.38
			var ring: float = exp(-pow((r - 0.36) / 0.035, 2.0)) * 0.22
			var spill: float = 1.0 - smoothstep(0.42, 0.98, r)
			var v: float = clampf((core + ring) * (0.35 + 0.65 * (1.0 - smoothstep(0.3, 0.5, r))) * spill, 0.0, 1.0)
			v *= 0.9 + 0.1 * noise.get_noise_2d(x, y)
			var warm: float = smoothstep(0.3, 0.8, r)
			img.set_pixel(x, y, Color(v, v * (1.0 - 0.08 * warm), v * (1.0 - 0.22 * warm)))
	return ImageTexture.create_from_image(img)


func set_torch(on: bool) -> void:
	torch_on = on
	torch.visible = on
	if game.quality:
		game.quality.shadow_budget()
	game.play_at("switch", cam.global_position + cam.global_basis * Vector3(0.16, -0.25, -0.1), -16.0, 1.5, 4.0)
	if on:
		_update_torch(1.0)
		game.critters.scare_beam(torch.global_transform, 8.0)


func _update_torch(dt: float) -> void:
	var eye: Transform3D = cam.global_transform
	var hand: Vector3 = eye * Vector3(0.17, -0.24, -0.12)
	var aim: Vector3 = eye * Vector3(0.0, 0.0, -7.0)
	var want := Transform3D(Basis.looking_at(aim - hand, eye.basis.y), hand)
	# the hand follows the view a little late, so the beam swings a bit when you look around
	var k: float = 1.0 - exp(-dt * 13.0)
	var b: Basis = torch.global_basis.orthonormalized().slerp(want.basis, k) if dt < 0.5 else want.basis
	torch.global_transform = Transform3D(b, hand)
	# an old battery: now and then the bulb dims and stutters for a moment
	_torch_next -= dt
	if _torch_next <= 0.0:
		_torch_flick = randf_range(0.25, 0.7)
		_torch_next = randf_range(50.0, 140.0)
	if _torch_flick > 0.0:
		_torch_flick -= dt
		torch.light_energy = TORCH_ENERGY * (randf_range(0.15, 0.9) if _torch_flick > 0.0 else 1.0)


## The eyes for a given chair transform (mouse look included).
func _eye(xf: Transform3D) -> Transform3D:
	return xf * Transform3D(Basis.from_euler(Vector3(look_pitch, look_yaw, 0.0)), HEAD_POS)


func _process(dt: float) -> void:
	# every rendered frame: the latest mouse look and the chair's position interpolated between physics ticks
	head.global_transform = _eye(get_global_transform_interpolated()) * view_offset
	var vib: float = clamp(abs(v) / SPEEDS[-1], 0.0, 1.0)
	cam.position = Vector3(randf_range(-1, 1) * shake, sin(t * 23.0) * 0.0018 * vib + randf_range(-1, 1) * shake, 0.0)
	# a person, not a tripod: slow breathing and a slight lean of the head into turns (well under a degree)
	_lean = lerpf(_lean, -w * 0.011, minf(1.0, dt * 4.0))
	cam.rotation = Vector3(sin(t * 1.45) * 0.0022 + sin(t * 0.37) * 0.0012, sin(t * 0.61) * 0.0015, _lean)
	if torch_on:
		_update_torch(dt)


func _update_target() -> void:
	_ray_frame += 1
	if _ray_frame % 3 != 0:
		return
	var eye := _eye(global_transform)
	var from := eye.origin
	var dir := -eye.basis.z
	var q: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, from + dir * SEE_RANGE,
		game.L_WORLD | game.L_DOORS | game.L_INTERACT | game.L_LIFT, [get_rid()])
	q.collide_with_areas = true
	var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(q)
	var found = null
	if not hit.is_empty():
		var col: Object = hit["collider"]
		if col.has_meta("interact"):
			found = col.get_meta("interact")
	# within reach: show what E does; farther: pressing E says to come closer
	var near: bool = found != null and from.distance_to(hit["position"]) <= REACH
	target = found if near else null
	far_target = found if not near else null
	game.hud.set_prompt(target.prompt(self) if target != null else "")


func _update_room() -> void:
	if _ray_frame % 15 != 0:
		return
	var r: Dictionary = game.room_at(global_position + Vector3(0, 0.3, 0))
	var id: String = r.get("id", "")
	if id != _last_room and id != "":
		_last_room = id
		game.hud.show_room(r)


## Сюжет: плавно повернуть взгляд к точке (k — доля за вызов, 1 — сразу).
func aim_at(p: Vector3, k := 1.0) -> void:
	var eye: Vector3 = global_transform * HEAD_POS
	var d: Vector3 = global_transform.basis.inverse() * (p - eye)
	if d.length() < 0.01:
		return
	var yaw: float = clampf(atan2(-d.x, -d.z), -2.1, 2.1)
	var pitch: float = clampf(atan2(d.y, Vector2(d.x, d.z).length()), -1.25, 1.0)
	look_yaw = lerp_angle(look_yaw, yaw, clampf(k, 0.0, 1.0))
	look_pitch = lerpf(look_pitch, pitch, clampf(k, 0.0, 1.0))
	look_idle = 0.0


## Сюжет: куда смотрит камера (для «навёл на человека — нажал E»).
func view_dir() -> Vector3:
	return -cam.global_transform.basis.z
