class_name CameraController
extends Camera3D
## Camera modes:
##   ORBIT  - orbit around a pivot (RMB/LMB drag rotate, MMB or Shift+drag pan, wheel zoom, WASD/QE move)
##   TOP    - top-down map view (drag/WASD pan, wheel zoom)
##   FLY    - free flight (hold RMB to look, WASD + Space/C, Shift = fast)
##   WALK   - third-person character (V toggles first person)
## Home / R resets to the hero shot reproduced from the trailer.

signal mode_changed(mode: String)

enum Mode { ORBIT, TOP, FLY, WALK }

## Hero shot: standing on the south-west corner of the hero intersection looking up at The Jade Garden
const HERO_POS := Vector3(-5.0, 1.7, 15.5)
const HERO_TARGET := Vector3(11.0, 11.2, -10.7)
const HERO_FOV := 59.0

var mode: Mode = Mode.ORBIT
var pivot := HERO_TARGET
var yaw := 0.0
var pitch := 0.0
var distance := 30.0
var top_height := 260.0
var fly_speed := 14.0
var player: Player
var first_person := false
var walk_yaw := 0.0
var walk_pitch := -0.12
var walk_dist := 4.2
var _dragging := false
var _panning := false
var _looking := false
var _smooth_pivot := Vector3.ZERO
var _orbit_target := {}


func _ready() -> void:
	near = 0.08
	far = 2600.0
	fov = HERO_FOV
	reset_view()


func reset_view() -> void:
	set_mode(Mode.ORBIT)
	_set_orbit_from(HERO_POS, HERO_TARGET)
	fov = HERO_FOV


func _set_orbit_from(pos: Vector3, target: Vector3) -> void:
	pivot = target
	var d := pos - target
	distance = d.length()
	yaw = atan2(d.x, d.z)
	pitch = asin(clampf(d.y / distance, -1.0, 1.0))
	_apply_orbit()


func set_mode(m: Mode) -> void:
	if m == Mode.WALK and player == null:
		return
	var prev := mode
	mode = m
	projection = PROJECTION_PERSPECTIVE
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if player:
		player.active = m == Mode.WALK
		player.visible = m == Mode.WALK and not first_person
	match m:
		Mode.ORBIT:
			fov = 55.0
			if prev == Mode.TOP:
				pitch = deg_to_rad(35.0)
				distance = 120.0
			_apply_orbit()
		Mode.TOP:
			projection = PROJECTION_ORTHOGONAL
			size = top_height
			pivot.y = 0.0
			_apply_top()
		Mode.FLY:
			fov = 65.0
		Mode.WALK:
			fov = 62.0
			if prev != Mode.WALK:
				var spawn := global_position
				spawn.y = 0.5
				# drop the walker onto the street below the current view
				var fwd := -global_transform.basis.z
				fwd.y = 0.0
				if prev == Mode.ORBIT or prev == Mode.TOP:
					spawn = Vector3(pivot.x, 0.5, pivot.z)
				player.teleport(spawn)
				walk_yaw = atan2(-fwd.x, -fwd.z) if fwd.length() > 0.1 else 0.0
	mode_changed.emit(mode_name())


func mode_name() -> String:
	match mode:
		Mode.ORBIT: return "Orbit"
		Mode.TOP: return "Top view"
		Mode.FLY: return "Free fly"
		Mode.WALK: return "Walk (1st person)" if first_person else "Walk (3rd person)"
	return ""


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					var f := 0.88 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 0.88
					match mode:
						Mode.ORBIT: distance = clampf(distance * f, 2.0, 900.0)
						Mode.TOP: top_height = clampf(top_height * f, 20.0, 1400.0)
						Mode.FLY: fly_speed = clampf(fly_speed / f, 2.0, 200.0)
						Mode.WALK: walk_dist = clampf(walk_dist * f, 1.6, 14.0)
			MOUSE_BUTTON_LEFT:
				_dragging = mb.pressed
				_panning = mb.pressed and (mb.shift_pressed or mode == Mode.TOP)
			MOUSE_BUTTON_RIGHT:
				_looking = mb.pressed
				_dragging = mb.pressed
				_panning = false
				if mode in [Mode.FLY, Mode.WALK]:
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if mb.pressed else Input.MOUSE_MODE_VISIBLE
			MOUSE_BUTTON_MIDDLE:
				_dragging = mb.pressed
				_panning = mb.pressed
	elif event is InputEventMouseMotion and (_dragging or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED):
		var rel := (event as InputEventMouseMotion).relative
		match mode:
			Mode.ORBIT:
				if _panning:
					_pan(rel * distance * 0.0016)
				else:
					yaw -= rel.x * 0.005
					pitch = clampf(pitch + rel.y * 0.004, deg_to_rad(-30.0), deg_to_rad(88.0))
			Mode.TOP:
				_pan(rel * top_height / get_viewport().get_visible_rect().size.y)
			Mode.FLY:
				rotation.y -= rel.x * 0.003
				rotation.x = clampf(rotation.x - rel.y * 0.003, -1.5, 1.5)
			Mode.WALK:
				walk_yaw -= rel.x * 0.004
				walk_pitch = clampf(walk_pitch - rel.y * 0.003, -1.2, 1.0)
	elif event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).keycode:
			KEY_V:
				if mode == Mode.WALK:
					first_person = not first_person
					player.visible = not first_person
					mode_changed.emit(mode_name())


func _pan(rel: Vector2) -> void:
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	if mode == Mode.TOP:
		right = Vector3.RIGHT
		fwd = Vector3.FORWARD
	pivot += -right * rel.x + fwd * rel.y


func _process(delta: float) -> void:
	var mv := Vector3.ZERO
	if not Input.is_key_pressed(KEY_CTRL) and not Input.is_key_pressed(KEY_META):
		if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP): mv.z -= 1
		if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN): mv.z += 1
		if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT): mv.x -= 1
		if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): mv.x += 1
	var fast := 3.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0
	match mode:
		Mode.ORBIT:
			if Input.is_key_pressed(KEY_Q): yaw += delta * 1.2
			if Input.is_key_pressed(KEY_E): yaw -= delta * 1.2
			if mv != Vector3.ZERO:
				var b := Basis(Vector3.UP, yaw)
				pivot += b * mv.normalized() * maxf(distance, 15.0) * 0.7 * delta * fast
			_apply_orbit()
		Mode.TOP:
			if mv != Vector3.ZERO:
				pivot += mv.normalized() * top_height * 0.6 * delta * fast
			_apply_top()
		Mode.FLY:
			if Input.is_key_pressed(KEY_SPACE): mv.y += 1
			if Input.is_key_pressed(KEY_C): mv.y -= 1
			if mv != Vector3.ZERO:
				global_position += global_transform.basis * mv.normalized() * fly_speed * fast * delta
			global_position.y = maxf(global_position.y, 0.4)
		Mode.WALK:
			_follow_player(delta)


func _apply_orbit() -> void:
	var off := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
	var pos := pivot + off
	pos.y = maxf(pos.y, 0.5)
	global_position = pos
	look_at(pivot, Vector3.UP)


func _apply_top() -> void:
	size = top_height
	global_position = Vector3(pivot.x, 900.0, pivot.z)
	rotation = Vector3(-PI * 0.5, 0, 0)


func _follow_player(delta: float) -> void:
	if player == null:
		return
	player.cam_yaw = walk_yaw
	var head := player.global_position + Vector3(0, 1.62, 0)
	if first_person:
		global_position = head
		rotation = Vector3(walk_pitch, walk_yaw, 0)
		return
	var dir := Vector3(sin(walk_yaw) * cos(walk_pitch), -sin(walk_pitch), cos(walk_yaw) * cos(walk_pitch))
	var desired := head + Vector3(0, 0.2, 0) + dir * walk_dist
	# keep the camera out of walls
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(head, desired)
	q.exclude = [player.get_rid()]
	var hit := space.intersect_ray(q)
	if hit:
		desired = (hit.position as Vector3) + (hit.normal as Vector3) * 0.25
	global_position = global_position.lerp(desired, clampf(delta * 12.0, 0.0, 1.0))
	look_at(head + Vector3(0, 0.15, 0), Vector3.UP)
