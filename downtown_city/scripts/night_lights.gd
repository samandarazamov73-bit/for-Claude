class_name NightLights
extends Node3D
## Street lamps are emissive meshes; real lights would be far too expensive for hundreds of
## lamps, so a small pool of OmniLight3D follows the camera and sits on the nearest lamp heads
## at dusk / night.

var positions: Array[Vector3] = []
var env_ctrl: EnvironmentController
var pool: Array[OmniLight3D] = []
var pool_size := 14
var _timer := 0.0


func setup(lamps: Array[Vector3], size: int) -> void:
	positions = lamps
	pool_size = size
	for l in pool:
		l.queue_free()
	pool.clear()
	for i in pool_size:
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.8, 0.55)
		l.omni_range = 16.0
		l.omni_attenuation = 1.4
		l.shadow_enabled = false
		l.light_specular = 0.3
		l.visible = false
		add_child(l)
		pool.append(l)


func _process(delta: float) -> void:
	_timer -= delta
	var night: float = env_ctrl.night_factor if env_ctrl else 0.0
	var energy := smoothstep(0.35, 0.8, night) * 2.2
	if energy <= 0.01:
		for l in pool:
			l.visible = false
		return
	if _timer > 0.0:
		for l in pool:
			l.light_energy = energy
		return
	_timer = 0.3
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var cp := cam.global_position
	var fwd := -cam.global_transform.basis.z
	var scored: Array = []
	for p in positions:
		var d := p - cp
		var dist := d.length()
		if dist > 140.0:
			continue
		# prefer lamps in front of the camera
		var score := dist - maxf(fwd.dot(d / maxf(dist, 0.01)), 0.0) * 25.0
		scored.append([score, p])
	scored.sort_custom(func(a, b): return a[0] < b[0])
	for i in pool.size():
		var l := pool[i]
		if i < scored.size():
			l.global_position = scored[i][1] - Vector3(0, 0.4, 0)
			l.light_energy = energy
			l.visible = true
		else:
			l.visible = false
