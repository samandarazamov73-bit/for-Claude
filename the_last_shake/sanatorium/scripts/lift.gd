extends Node3D
## Passenger elevator: the cabin (AnimatableBody3D: floor, walls, ceiling, sliding doors) travels between
## the four floors; each landing has two sliding door leaves and a call button; the cabin panel has
## buttons 1-4 and "doors". Doors close before travelling, open on arrival, close by themselves after a
## while, and re-open if the wheelchair is in the doorway.

signal arrived(floor_idx: int)
signal departed(floor_idx: int)

var game
var locked := false              # сюжет: лифт работает только с ключом администратора
var lock_text := "Лифт заперт. Нужен ключ"
var forced_floor := -1           # сюжет: любая кнопка в кабине везёт на этот этаж (-1 — как нажали)
var on_locked: Callable          # сюжет: что сделать, когда нажали кнопку запертого лифта
var data: Dictionary
var cabin: AnimatableBody3D
var cab_doors := []        # {shape, mesh, base_x, dir, built_open}
var landings := []         # {body, doors: [{shape, mesh, base_x, dir, built_open}], button}
var levels := []
var floor_idx := 0
var y_off := 0.0
var vel := 0.0
var open_f := 1.0          # 0 closed .. 1 open (doors at the current floor)
var state := "open"        # open, closing, moving, opening, closed
var queue := []
var idle_t := 0.0
var half_w := 0.6
var door_x := 37.5
var front_z := -6.25
var motor: AudioStreamPlayer3D
var cab_light: OmniLight3D

const SPEED := 0.85
const ACC := 0.55
const DOOR_TIME := 1.5
const AUTO_CLOSE := 9.0
const ROPE_TOP := 13.95               # under the overhead pulley beam in the shaft
const ROPE_X := [37.44, 37.56]
const ROPE_Z := -5.15
var ropes := []
var roof0 := 0.0


func setup(g) -> void:
	game = g
	data = g.level["lift"]
	for z in data["levels"]:
		levels.append(float(z))
	half_w = float(data["door_w"]) * 0.5
	door_x = float(data["door_x"])
	front_z = float(data["front_y"])
	cabin = AnimatableBody3D.new()
	cabin.name = "LiftCabinBody"
	cabin.collision_layer = g.L_LIFT
	cabin.collision_mask = 0
	cabin.sync_to_physics = true
	add_child(cabin)
	var cm: Node3D = g.node(data["cabin"])
	if cm:
		cm.reparent(cabin, true)
	var inner: Dictionary = data["inner"]
	var mn: Vector3 = g._v3(inner["min"])
	var mx: Vector3 = g._v3(inner["max"])
	var t: float = 0.05
	# floor reaching the landing sill, ceiling, back and side walls, front panels and header
	g._box_shape(cabin, Vector3(mn.x - t, mn.y - 0.15, front_z - 0.19), Vector3(mx.x + t, mn.y, mx.z + t))
	g._box_shape(cabin, Vector3(mn.x - t, mx.y, mn.z - t), Vector3(mx.x + t, mx.y + 0.15, mx.z + t))
	g._box_shape(cabin, Vector3(mn.x - t, mn.y, mx.z), Vector3(mx.x + t, mx.y, mx.z + t))
	g._box_shape(cabin, Vector3(mn.x - t, mn.y, mn.z - t), Vector3(mn.x, mx.y, mx.z))
	g._box_shape(cabin, Vector3(mx.x, mn.y, mn.z - t), Vector3(mx.x + t, mx.y, mx.z))
	g._box_shape(cabin, Vector3(mn.x - t, mn.y, front_z - t), Vector3(door_x - half_w, mx.y, front_z))
	g._box_shape(cabin, Vector3(door_x + half_w, mn.y, front_z - t), Vector3(mx.x + t, mx.y, front_z))
	g._box_shape(cabin, Vector3(door_x - half_w, mn.y + float(data["door_h"]), front_z - t),
		Vector3(door_x + half_w, mx.y, front_z))
	for d in data["cab_doors"]:
		var shp: CollisionShape3D = g._box_shape(cabin, g._v3(d["min"]), g._v3(d["max"]))
		var m: Node3D = g.node(d["name"])
		if m:
			m.reparent(cabin, true)
		cab_doors.append({"shape": shp, "mesh": m, "base_x": shp.position.x, "mesh_x": m.position.x if m else 0.0,
			"dir": float(d["dir"]), "built_open": bool(d["open"])})
	roof0 = mx.y + 0.15
	_fix_ropes(g)
	cab_light = OmniLight3D.new()
	cab_light.light_color = Color(1.0, 0.84, 0.62)
	cab_light.light_energy = 0.42
	cab_light.omni_range = 3.2
	cab_light.shadow_enabled = false
	cabin.add_child(cab_light)
	cab_light.global_position = g._v3(data["light"])
	motor = AudioStreamPlayer3D.new()
	motor.stream = g.sfx("lift_motor_loop", true)
	motor.volume_db = -8.0
	motor.unit_size = 4.0
	motor.max_distance = 30.0
	motor.bus = "World"
	cabin.add_child(motor)
	motor.position = Vector3(door_x, mx.y + 0.3, (mn.z + mx.z) * 0.5)
	# cabin panel buttons (move with the cabin)
	for key in data["buttons"]:
		if key in ["1", "2", "3", "4", "open"]:
			var a := _button(g._v3(data["buttons"][key]), {"cab": key})
			a.reparent(cabin, true)
	for ld in data["landings"]:
		var body := AnimatableBody3D.new()
		body.collision_layer = g.L_DOORS
		body.collision_mask = 0
		body.sync_to_physics = false
		add_child(body)
		var dl := []
		for d in ld["doors"]:
			var shp: CollisionShape3D = g._box_shape(body, g._v3(d["min"]), g._v3(d["max"]))
			var m: Node3D = g.node(d["name"])
			dl.append({"shape": shp, "mesh": m, "base_x": shp.position.x, "mesh_x": m.position.x if m else 0.0,
				"dir": float(d["dir"]), "built_open": bool(d["open"])})
		var btn := _button(g._v3(ld["button"]), {"call": int(ld["level"])})
		landings.append({"body": body, "doors": dl, "button": btn})
	floor_idx = int(data["parked"])
	_apply_doors()
	g.stats["lift_floors"] = levels.size()


func _button(pos: Vector3, what: Dictionary) -> Area3D:
	var a := Area3D.new()
	a.collision_layer = game.L_INTERACT
	a.collision_mask = 0
	a.monitoring = false
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(0.14, 0.12, 0.14)
	cs.shape = bs
	a.add_child(cs)
	var b := LiftButton.new()
	b.lift = self
	b.what = what
	a.set_meta("interact", b)
	a.set_meta("button", b)
	add_child(a)
	a.global_position = pos
	return a


class LiftButton:
	extends RefCounted
	var lift
	var what: Dictionary

	func prompt(_by) -> String:
		if lift.locked:
			return "[E] Вызвать лифт" if what.has("call") else "[E] Нажать кнопку"
		if what.has("call"):
			return "[E] Вызвать лифт"
		if what["cab"] == "open":
			return "[E] Открыть двери"
		return "[E] Этаж " + what["cab"]

	func interact(_by) -> void:
		var pos: Vector3 = _by.global_position + Vector3(0, 1.0, 0)
		lift.game.play_at("button", pos, -8.0, 1.0, 8.0)
		if lift.locked:
			lift.game.hud.message(lift.lock_text, 3.0)
			if lift.on_locked.is_valid():
				lift.on_locked.call()
			return
		if what.has("cab") and what["cab"] != "open" and lift.forced_floor >= 0:
			lift.request(lift.forced_floor)
		elif what.has("call"):
			lift.request(int(what["call"]))
		elif what["cab"] == "open":
			lift.open_here()
		else:
			lift.request(int(what["cab"]) - 1)


func request(f: int) -> void:
	if f == floor_idx and state in ["open", "opening", "closed", "closing"]:
		open_here()
		return
	if not (f in queue):
		queue.append(f)
	if state == "open" or state == "opening":
		state = "closing"
		_door_sound()


func open_here() -> void:
	if state in ["closed", "closing"]:
		state = "opening"
		idle_t = 0.0
		_door_sound()
	elif state == "open":
		idle_t = 0.0


func _door_sound() -> void:
	var p: Vector3 = Vector3(door_x, float(levels[floor_idx]) + 1.0, front_z - 0.3)
	game.play_at("lift_doors", p, -4.0, 1.0, 22.0)


func _player_in_doorway() -> bool:
	var p: Vector3 = game.player.global_position
	return abs(p.x - door_x) < half_w + 0.35 and p.z < front_z + 0.5 and p.z > front_z - 0.9 \
		and abs(p.y - levels[floor_idx]) < 0.6


func player_in_cabin() -> bool:
	var p: Vector3 = game.player.global_position
	var inner: Dictionary = data["inner"]
	var mn: Vector3 = game._v3(inner["min"])
	var mx: Vector3 = game._v3(inner["max"])
	return p.x > mn.x and p.x < mx.x and p.z > front_z - 0.1 and p.z < mx.z and abs(p.y - (levels[0] + y_off)) < 0.8


## The shaft model has the two hoist ropes baked in from the parked cabin's roof up to the pulleys, so
## once the cabin went up they ran right through it. They are cut out of the shaft mesh here and replaced
## by two ropes that start on the cabin roof and follow it.
func _fix_ropes(g) -> void:
	var shaft = g.node("Lift_Shaft_Equipment")
	if shaft is MeshInstance3D and shaft.mesh:
		var src: Mesh = shaft.mesh
		var out := ArrayMesh.new()
		var cut := 0
		for si in src.get_surface_count():
			var arr: Array = src.surface_get_arrays(si)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			var keep := PackedInt32Array()
			for i in range(0, idx.size(), 3):
				var rope := true
				for k in 3:
					var p: Vector3 = shaft.global_transform * verts[idx[i + k]]
					if absf(p.z - ROPE_Z) > 0.03 or p.y < roof0 - 0.05 \
							or (absf(p.x - ROPE_X[0]) > 0.03 and absf(p.x - ROPE_X[1]) > 0.03):
						rope = false
						break
				if rope:
					cut += 1
				else:
					keep.append_array([idx[i], idx[i + 1], idx[i + 2]])
			arr[Mesh.ARRAY_INDEX] = keep
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			out.surface_set_material(si, src.surface_get_material(si))
		shaft.mesh = out
		g.stats["lift_rope_tris_cut"] = cut
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.07, 0.065, 0.06)
	mat.metallic = 0.6
	mat.roughness = 0.45
	for x in ROPE_X:
		var mi := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.008
		cm.bottom_radius = 0.008
		cm.height = 1.0
		cm.radial_segments = 6
		cm.rings = 1
		mi.mesh = cm
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		ropes.append({"mesh": mi, "x": float(x)})
	_update_ropes()


func _update_ropes() -> void:
	var roof: float = roof0 + y_off
	var length: float = maxf(ROPE_TOP - roof, 0.01)
	for r in ropes:
		r["mesh"].position = Vector3(r["x"], roof + length * 0.5, ROPE_Z)
		r["mesh"].scale = Vector3(1.0, length, 1.0)


func _physics_process(dt: float) -> void:
	match state:
		"open":
			idle_t += dt
			if (queue.size() > 0 or idle_t > AUTO_CLOSE) and not _player_in_doorway():
				state = "closing"
				_door_sound()
		"closing":
			if _player_in_doorway() and open_f > 0.15:
				state = "opening"
			open_f = move_toward(open_f, 0.0, dt / DOOR_TIME)
			_apply_doors()
			if open_f <= 0.0:
				state = "closed"
				idle_t = 0.0
		"closed":
			if queue.size() > 0:
				var f: int = queue[0]
				if f == floor_idx:
					queue.pop_front()
					state = "opening"
					_door_sound()
				else:
					state = "moving"
					vel = 0.0
					departed.emit(floor_idx)
					game.play_at("lift_start", Vector3(door_x, levels[floor_idx] + 2.4, front_z + 1.0), -6.0, 1.0, 20.0)
					motor.play()
		"moving":
			var f: int = queue[0]
			var goal: float = levels[f] - levels[0]
			var dist: float = goal - y_off
			var dir: float = signf(dist)
			var stop_d: float = vel * vel / (2.0 * ACC)
			if abs(dist) <= stop_d + 0.01:
				vel = move_toward(vel, 0.08, ACC * dt)
			else:
				vel = move_toward(vel, SPEED, ACC * dt)
			var step: float = min(abs(dist), vel * dt)
			y_off += dir * step
			cabin.global_position = Vector3(0, y_off, 0)
			_update_ropes()
			motor.pitch_scale = 0.8 + 0.3 * vel / SPEED
			if abs(goal - y_off) < 0.002:
				y_off = goal
				cabin.global_position = Vector3(0, y_off, 0)
				_update_ropes()
				floor_idx = f
				queue.pop_front()
				motor.stop()
				game.play_at("lift_arrive", Vector3(door_x, levels[f] + 2.3, front_z), -4.0, 1.0, 25.0)
				state = "opening"
				_door_sound()
				if player_in_cabin():
					game.hud.message("Этаж %d" % (f + 1))
				arrived.emit(f)
		"opening":
			open_f = move_toward(open_f, 1.0, dt / DOOR_TIME)
			_apply_doors()
			if open_f >= 1.0:
				state = "open"
				idle_t = 0.0


func _apply_doors() -> void:
	# cabin doors and the landing doors of the floor the cabin is at slide together; other floors stay shut
	for d in cab_doors:
		_slide(d, open_f)
	for i in landings.size():
		for d in landings[i]["doors"]:
			_slide(d, open_f if i == floor_idx else 0.0)


func _slide(d: Dictionary, f: float) -> void:
	var off: float = d["dir"] * half_w * (f - (1.0 if d["built_open"] else 0.0))
	d["shape"].position.x = d["base_x"] + off
	if d["mesh"]:
		d["mesh"].position.x = d["mesh_x"] + off


## Сюжет: двери закрыты, кабина стоит на этаже f (без звука и движения).
func park_closed(f: int) -> void:
	queue.clear()
	floor_idx = f
	y_off = levels[f] - levels[0]
	cabin.global_position = Vector3(0, y_off, 0)
	_update_ropes()
	open_f = 0.0
	state = "closed"
	idle_t = 0.0
	motor.stop()
	_apply_doors()


## Сюжет: кабина на этаже f с открытыми дверями.
func park_open(f: int) -> void:
	park_closed(f)
	open_f = 1.0
	state = "open"
	_apply_doors()


func cabin_floor_y() -> float:
	return levels[0] + y_off
