class_name ForestCar
extends VehicleBody3D
## A simple rear-wheel-drive saloon to drive along the forest road (Jolt physics + VehicleBody3D).
## The body is a procedural extrusion so the project has no external car asset.

@export var max_engine_force := 5200.0
@export var max_brake := 45.0
@export var max_steer := 0.48
@export var top_speed_kmh := 150.0
@export var paint := Color(0.09, 0.12, 0.10)

var wheels: Array[VehicleWheel3D] = []
var speed_kmh := 0.0
var input_enabled := true
var _steer := 0.0


func _ready() -> void:
	mass = 1350.0
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0, 0.45, 0.1)
	physics_material_override = PhysicsMaterial.new()
	physics_material_override.friction = 0.6
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.78, 0.75, 4.4)
	col.shape = box
	col.position = Vector3(0, 0.78, 0)
	add_child(col)
	var cabin := CollisionShape3D.new()
	var cb := BoxShape3D.new()
	cb.size = Vector3(1.5, 0.55, 2.2)
	cabin.shape = cb
	cabin.position = Vector3(0, 1.35, 0.15)
	add_child(cabin)
	_build_body()
	for spec in [[-0.78, -1.36, true], [0.78, -1.36, true], [-0.78, 1.34, false], [0.78, 1.34, false]]:
		var w := VehicleWheel3D.new()
		w.position = Vector3(spec[0], 0.42, spec[1])
		w.use_as_steering = spec[2]
		w.use_as_traction = not spec[2]
		w.wheel_radius = 0.33
		w.wheel_rest_length = 0.16
		w.suspension_travel = 0.18
		w.suspension_stiffness = 46.0
		w.suspension_max_force = 9000.0
		w.damping_compression = 0.9
		w.damping_relaxation = 1.3
		w.wheel_friction_slip = 2.8
		w.wheel_roll_influence = 0.12
		w.add_child(_wheel_mesh())
		add_child(w)
		wheels.append(w)


func _physics_process(_delta: float) -> void:
	speed_kmh = linear_velocity.dot(-global_transform.basis.z) * 3.6
	var throttle := 0.0
	var braking := 0.0
	var steer_in := 0.0
	if input_enabled:
		throttle = Input.get_action_strength("accelerate")
		braking = Input.get_action_strength("brake")
		steer_in = Input.get_action_strength("steer_left") - Input.get_action_strength("steer_right")
	var fwd_speed := speed_kmh
	var force := 0.0
	var brk := 0.0
	if throttle > 0.0 and fwd_speed < top_speed_kmh:
		force = throttle * max_engine_force * clampf(1.15 - fwd_speed / top_speed_kmh, 0.25, 1.0)
	if braking > 0.0:
		if fwd_speed > 2.0:
			brk = braking * max_brake
		else:
			force = -braking * max_engine_force * 0.45     # reverse
	if Input.is_action_pressed("handbrake") and input_enabled:
		brk = max_brake * 1.4
	if throttle == 0.0 and braking == 0.0:
		brk = maxf(brk, 1.2)                               # engine braking / rolling resistance
	# VehicleBody3D: forward is +Z of the body, our model faces -Z
	engine_force = -force
	brake = brk
	var steer_limit := max_steer * clampf(1.0 - absf(fwd_speed) / 230.0, 0.3, 1.0)
	_steer = move_toward(_steer, steer_in * steer_limit, _delta * 2.2)
	steering = _steer


func reset_to(xf: Transform3D) -> void:
	global_transform = xf
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	reset_physics_interpolation()


func _build_body() -> void:
	# side profile (z forward = -Z, y up), extruded across the width
	var prof := PackedVector2Array([
		Vector2(-2.22, 0.42), Vector2(-2.28, 0.62), Vector2(-2.22, 0.92), Vector2(-1.25, 1.02),
		Vector2(-0.72, 1.48), Vector2(0.62, 1.50), Vector2(1.35, 1.06), Vector2(2.18, 0.98),
		Vector2(2.24, 0.70), Vector2(2.18, 0.42),
	])
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hw := 0.88
	var n := prof.size()
	for i in n:
		var a := prof[i]
		var b := prof[(i + 1) % n]
		var t := 0.06 if (a.y > 1.3 and b.y > 1.3) else 0.0
		var p0 := Vector3(-hw + t, a.y, -a.x)
		var p1 := Vector3(hw - t, a.y, -a.x)
		var p2 := Vector3(hw - t, b.y, -b.x)
		var p3 := Vector3(-hw + t, b.y, -b.x)
		var nrm := (p1 - p0).cross(p3 - p0).normalized()
		for p in [p0, p2, p1, p0, p3, p2]:
			st.set_normal(-nrm)
			st.add_vertex(p)
	for side in [-1.0, 1.0]:
		var c := Vector3(side * hw, 0.85, 0.0)
		for i in n:
			var a := prof[i]
			var b := prof[(i + 1) % n]
			var pa := Vector3(side * hw, a.y, -a.x)
			var pb := Vector3(side * hw, b.y, -b.x)
			st.set_normal(Vector3(side, 0, 0))
			if side > 0:
				st.add_vertex(c); st.add_vertex(pb); st.add_vertex(pa)
			else:
				st.add_vertex(c); st.add_vertex(pa); st.add_vertex(pb)
	var body := MeshInstance3D.new()
	body.mesh = st.commit()
	var m := StandardMaterial3D.new()
	m.albedo_color = paint
	m.metallic = 0.25
	m.roughness = 0.38
	m.clearcoat_enabled = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	body.material_override = m
	add_child(body)
	# glasshouse
	var glass := MeshInstance3D.new()
	var gm := BoxMesh.new()
	gm.size = Vector3(1.62, 0.36, 1.7)
	glass.mesh = gm
	glass.position = Vector3(0, 1.27, 0.0)
	var g := StandardMaterial3D.new()
	g.albedo_color = Color(0.03, 0.04, 0.05)
	g.metallic = 0.2
	g.roughness = 0.05
	glass.material_override = g
	add_child(glass)
	for x in [-0.62, 0.62]:
		var lamp := MeshInstance3D.new()
		var lm := BoxMesh.new()
		lm.size = Vector3(0.36, 0.1, 0.05)
		lamp.mesh = lm
		lamp.position = Vector3(x, 0.82, 2.27)
		var l := StandardMaterial3D.new()
		l.albedo_color = Color(0.5, 0.02, 0.02)
		l.emission_enabled = true
		l.emission = Color(0.6, 0.02, 0.02)
		lamp.material_override = l
		add_child(lamp)


func _wheel_mesh() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.33
	cm.bottom_radius = 0.33
	cm.height = 0.22
	cm.radial_segments = 20
	mi.mesh = cm
	mi.rotation_degrees = Vector3(0, 0, 90)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.05, 0.05, 0.05)
	m.roughness = 0.85
	mi.material_override = m
	var rim := MeshInstance3D.new()
	var rm := CylinderMesh.new()
	rm.top_radius = 0.2
	rm.bottom_radius = 0.2
	rm.height = 0.24
	rm.radial_segments = 14
	rim.mesh = rm
	var r := StandardMaterial3D.new()
	r.albedo_color = Color(0.55, 0.56, 0.58)
	r.metallic = 0.9
	r.roughness = 0.35
	rim.material_override = r
	mi.add_child(rim)
	return mi
