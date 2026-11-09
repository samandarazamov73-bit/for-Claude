extends Node3D
## Rats and cockroaches. Not many: 2-3 rats per floor (corridors, kitchen, stores, lounges) and small groups
## of cockroaches in kitchens and bathrooms. Rats wander between free floor points of their room, sniff,
## squeak now and then, and run away from the wheelchair (or a loud noise), then hide and come back later
## somewhere else. Cockroaches sit still, twitch, and scatter when you come close or switch the light on.

var game
var rats := []
var roaches := []
var room_boxes := {}
var rat_mesh := {}
var roach_mesh := {}
var rng := RandomNumberGenerator.new()
var _beam_t := 0.0


func setup(g) -> void:
	game = g
	rng.seed = 1986
	for b in g.level["boxes"]:
		var mn: Vector3 = g._v3(b["min"])
		var mx: Vector3 = g._v3(b["max"])
		if mn.y > float(g.rooms[b["room"]]["floor_y"]) + 0.25:
			continue
		if not room_boxes.has(b["room"]):
			room_boxes[b["room"]] = []
		room_boxes[b["room"]].append(Rect2(Vector2(mn.x, mn.z), Vector2(mx.x - mn.x, mx.z - mn.z)))
	_build_meshes()
	var areas: Array = g.level["critters"]["rats"]
	for lvl in 4:
		var mine := areas.filter(func(a): return int(a["level"]) == lvl)
		mine.shuffle()
		var corr := mine.filter(func(a): return String(a["room"]).ends_with(".C") or String(a["room"]).ends_with(".SC"))
		var pick := []
		if corr.size() > 0:
			pick.append(corr[0])
		for a in mine:
			if pick.size() >= 3:
				break
			if not (a in pick):
				pick.append(a)
		for a in pick:
			rats.append(_spawn_rat(a))
	var ra: Array = g.level["critters"]["roaches"]
	ra.shuffle()
	var used := 0
	for a in ra:
		if used >= 9:
			break
		used += 1
		for i in rng.randi_range(3, 6):
			roaches.append(_spawn_roach(a))
	g.stats["rats"] = rats.size()
	g.stats["roaches"] = roaches.size()


# ----------------------------------------------------------------------------- meshes
func _mat(c: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m


func _sphere(r: float, segs := 10) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = segs
	s.rings = 6
	return s


func _build_meshes() -> void:
	rat_mesh["fur"] = _mat(Color(0.16, 0.135, 0.115), 0.85)
	rat_mesh["skin"] = _mat(Color(0.55, 0.38, 0.36), 0.6)
	rat_mesh["eye"] = _mat(Color(0.01, 0.01, 0.01), 0.1)
	rat_mesh["body"] = _sphere(0.05)
	rat_mesh["head"] = _sphere(0.028)
	rat_mesh["ear"] = _sphere(0.011, 6)
	rat_mesh["eyeball"] = _sphere(0.005, 6)
	var tail := CylinderMesh.new()
	tail.top_radius = 0.007
	tail.bottom_radius = 0.0015
	tail.height = 0.2
	tail.radial_segments = 5
	tail.rings = 1
	rat_mesh["tail"] = tail
	roach_mesh["mat"] = _mat(Color(0.24, 0.11, 0.05), 0.25)
	roach_mesh["body"] = _sphere(0.01, 8)
	var ant := BoxMesh.new()
	ant.size = Vector3(0.0012, 0.0012, 0.03)
	roach_mesh["ant"] = ant


## Every move of a shadow-casting mesh makes Godot redraw the shadows of all lamps around it, and the
## critters move almost every frame. So only the rat's body casts a shadow: the head, ears, eyes and
## tail that sway while it sniffs, and the centimetre-sized cockroaches, do not.
func _mi(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3, scl := Vector3.ONE, shadow := false) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.mesh = mesh
	m.material_override = mat
	m.position = pos
	m.scale = scl
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	m.visibility_range_end = 22.0
	parent.add_child(m)
	return m


func _spawn_rat(area: Dictionary) -> Dictionary:
	var n := Node3D.new()
	add_child(n)
	var body := _mi(n, rat_mesh["body"], rat_mesh["fur"], Vector3(0, 0.042, 0), Vector3(1.0, 0.8, 2.2), true)
	var head := Node3D.new()
	head.position = Vector3(0, 0.048, -0.12)
	n.add_child(head)
	_mi(head, rat_mesh["head"], rat_mesh["fur"], Vector3.ZERO, Vector3(1.0, 0.9, 1.6))
	_mi(head, rat_mesh["head"], rat_mesh["skin"], Vector3(0, -0.004, -0.045), Vector3(0.25, 0.25, 0.25))
	for sx in [-1.0, 1.0]:
		_mi(head, rat_mesh["ear"], rat_mesh["skin"], Vector3(0.018 * sx, 0.02, 0.012), Vector3(1.0, 1.0, 0.4))
		_mi(head, rat_mesh["eyeball"], rat_mesh["eye"], Vector3(0.015 * sx, 0.01, -0.022))
	var tail := Node3D.new()
	tail.position = Vector3(0, 0.035, 0.1)
	n.add_child(tail)
	var tm := _mi(tail, rat_mesh["tail"], rat_mesh["skin"], Vector3(0, 0, 0.1))
	tm.rotation.x = PI / 2
	var r := {"node": n, "body": body, "head": head, "tail": tail, "area": area, "state": "wait",
		"timer": rng.randf_range(0.5, 4.0), "target": Vector3.ZERO, "speed": 0.0, "t": rng.randf() * 10.0,
		"squeak": rng.randf_range(15.0, 60.0)}
	_place_random(r, area)
	return r


func _spawn_roach(area: Dictionary) -> Dictionary:
	var n := Node3D.new()
	add_child(n)
	_mi(n, roach_mesh["body"], roach_mesh["mat"], Vector3(0, 0.004, 0), Vector3(1.0, 0.35, 1.9))
	_mi(n, roach_mesh["body"], roach_mesh["mat"], Vector3(0, 0.004, -0.018), Vector3(0.55, 0.3, 0.5))
	for sx in [-1.0, 1.0]:
		var a := _mi(n, roach_mesh["ant"], roach_mesh["mat"], Vector3(0.004 * sx, 0.005, -0.035))
		a.rotation = Vector3(0.25, 0.35 * sx, 0)
	n.scale = Vector3.ONE * rng.randf_range(0.8, 1.25)
	var r := {"node": n, "area": area, "state": "wait", "timer": rng.randf_range(1.0, 8.0), "target": Vector3.ZERO,
		"speed": 0.0, "hidden": 0.0}
	_place_random(r, area)
	return r


func _pt(area: Dictionary, p) -> Vector3:
	return Vector3(float(p[0]), float(area["floor_y"]) + 0.003, float(p[1]))


func _place_random(c: Dictionary, area: Dictionary, away_from = null) -> void:
	var pts: Array = area["points"]
	var best: Vector3 = _pt(area, pts[rng.randi() % pts.size()])
	if away_from != null:
		for i in 12:
			var q := _pt(area, pts[rng.randi() % pts.size()])
			if q.distance_to(away_from) > best.distance_to(away_from):
				best = q
	c["node"].position = best
	c["node"].rotation.y = rng.randf() * TAU


func _clear(room: String, a: Vector3, b: Vector3) -> bool:
	var boxes: Array = room_boxes.get(room, [])
	var d: float = a.distance_to(b)
	var n := int(d / 0.12) + 1
	for i in n + 1:
		var p := a.lerp(b, float(i) / n)
		var q := Vector2(p.x, p.z)
		for r in boxes:
			if r.grow(0.06).has_point(q):
				return false
	return true


func _pick_target(c: Dictionary, max_d: float, flee_from = null) -> bool:
	var area: Dictionary = c["area"]
	var pts: Array = area["points"]
	var here: Vector3 = c["node"].position
	var best = null
	var best_score := -1e9
	for i in 18:
		var q := _pt(area, pts[rng.randi() % pts.size()])
		var d: float = q.distance_to(here)
		if d > max_d or d < 0.3 or not _clear(area["room"], here, q):
			continue
		var score: float = rng.randf() if flee_from == null else q.distance_to(flee_from) - here.distance_to(flee_from)
		if score > best_score:
			best_score = score
			best = q
	if best == null:
		return false
	c["target"] = best
	return true


# ----------------------------------------------------------------------------- events
func scare(pos: Vector3, radius: float) -> void:
	for r in rats:
		if r["state"] != "hidden" and r["node"].position.distance_to(pos) < radius:
			_flee_rat(r, pos)
	for r in roaches:
		if r["state"] != "hidden" and r["node"].position.distance_to(pos) < radius * 0.6:
			_scatter(r, pos)


## The torch: rats and roaches caught in its beam run away.
func scare_beam(beam: Transform3D, reach: float) -> void:
	var fwd: Vector3 = -beam.basis.z.normalized()
	for is_rat in [true, false]:
		for r in (rats if is_rat else roaches):
			if r["state"] == "hidden":
				continue
			var to: Vector3 = r["node"].global_position - beam.origin
			var d: float = to.length()
			if d < reach and d > 0.01 and fwd.dot(to / d) > 0.96:
				if is_rat:
					_flee_rat(r, beam.origin)
				else:
					_scatter(r, beam.origin)


func light_on(room: String) -> void:
	for r in rats:
		if r["state"] != "hidden" and r["area"]["room"] == room:
			_flee_rat(r, game.player.global_position)
	for r in roaches:
		if r["state"] != "hidden" and r["area"]["room"] == room:
			_scatter(r, game.player.global_position)


func _flee_rat(r: Dictionary, from: Vector3) -> void:
	if r["state"] == "flee":
		return
	if _pick_target(r, 6.0, from):
		r["state"] = "flee"
		r["speed"] = rng.randf_range(1.8, 2.5)
		if rng.randf() < 0.7:
			game.play_at("rat_squeak_%d" % rng.randi_range(1, 3), r["node"].global_position, -6.0, rng.randf_range(0.9, 1.2), 14.0)
		game.play_at("rat_scurry", r["node"].global_position, -10.0, rng.randf_range(0.9, 1.15), 10.0)


func _scatter(r: Dictionary, from: Vector3) -> void:
	if r["state"] == "scatter":
		return
	if _pick_target(r, 2.2, from):
		r["state"] = "scatter"
		r["speed"] = rng.randf_range(0.7, 1.1)
		if rng.randf() < 0.3:
			game.play_at("roach_skitter", r["node"].global_position, -16.0, 1.0, 5.0)


# ----------------------------------------------------------------------------- update
func _move(c: Dictionary, dt: float) -> bool:
	var n: Node3D = c["node"]
	var to: Vector3 = c["target"] - n.position
	to.y = 0.0
	var d: float = to.length()
	if d < 0.03:
		return true
	var step: float = min(d, c["speed"] * dt)
	var want: float = atan2(-to.x, -to.z)
	n.rotation.y = lerp_angle(n.rotation.y, want, clamp(dt * 14.0, 0.0, 1.0))
	n.position += to / d * step
	return false


func _process(dt: float) -> void:
	if game.player == null:
		return
	var pp: Vector3 = game.player.global_position
	_beam_t -= dt
	if _beam_t <= 0.0:
		_beam_t = 0.25
		if game.player.torch_on:
			scare_beam(game.player.torch.global_transform, 8.0)
	for r in rats:
		_rat(r, dt, pp)
	for r in roaches:
		_roach(r, dt, pp)


func _rat(r: Dictionary, dt: float, pp: Vector3) -> void:
	var n: Node3D = r["node"]
	if r["state"] == "hidden":
		r["timer"] -= dt
		if r["timer"] <= 0.0:
			_place_random(r, r["area"], pp)
			if n.position.distance_to(pp) > 7.0:
				n.visible = true
				r["state"] = "wait"
				r["timer"] = rng.randf_range(1.0, 4.0)
			else:
				r["timer"] = 5.0
		return
	if abs(n.position.y - pp.y) > 2.0 or n.position.distance_to(pp) > 30.0:
		return
	r["t"] += dt
	var dist: float = n.position.distance_to(pp)
	if dist < 2.8 and r["state"] != "flee":
		_flee_rat(r, pp)
	match r["state"]:
		"wait":
			r["timer"] -= dt
			r["head"].rotation.y = sin(r["t"] * 3.0) * 0.4
			r["head"].position.y = 0.048 + abs(sin(r["t"] * 9.0)) * 0.004
			if r["timer"] <= 0.0 and _pick_target(r, 3.0):
				r["state"] = "walk"
				r["speed"] = rng.randf_range(0.25, 0.45)
		"walk", "flee":
			r["body"].position.y = 0.042 + abs(sin(r["t"] * (24.0 if r["state"] == "flee" else 12.0))) * 0.006
			r["head"].rotation.y = 0.0
			if _move(r, dt):
				if r["state"] == "flee" and dist < 5.0:
					n.visible = false
					r["state"] = "hidden"
					r["timer"] = rng.randf_range(25.0, 60.0)
				else:
					r["state"] = "wait"
					r["timer"] = rng.randf_range(1.0, 6.0)
	r["tail"].rotation.y = sin(r["t"] * (6.0 if r["state"] != "wait" else 2.0)) * 0.35
	r["squeak"] -= dt
	if r["squeak"] <= 0.0:
		r["squeak"] = rng.randf_range(20.0, 70.0)
		if dist < 12.0:
			game.play_at("rat_squeak_%d" % rng.randi_range(1, 3), n.global_position, -14.0, rng.randf_range(0.9, 1.15), 14.0)


func _roach(r: Dictionary, dt: float, pp: Vector3) -> void:
	var n: Node3D = r["node"]
	if r["state"] == "hidden":
		r["timer"] -= dt
		if r["timer"] <= 0.0:
			if game.lights.is_on(r["area"]["room"]) or n.position.distance_to(pp) < 6.0:
				r["timer"] = 10.0
				return
			_place_random(r, r["area"], pp)
			n.visible = true
			r["state"] = "wait"
			r["timer"] = rng.randf_range(2.0, 8.0)
		return
	if abs(n.position.y - pp.y) > 2.0 or n.position.distance_to(pp) > 15.0:
		return
	if n.position.distance_to(pp) < 1.4 and r["state"] != "scatter":
		_scatter(r, pp)
	match r["state"]:
		"wait":
			r["timer"] -= dt
			if r["timer"] <= 0.0:
				if _pick_target(r, 0.6):
					r["state"] = "walk"
					r["speed"] = rng.randf_range(0.15, 0.35)
				r["timer"] = rng.randf_range(2.0, 10.0)
		"walk":
			if _move(r, dt):
				r["state"] = "wait"
		"scatter":
			if _move(r, dt):
				n.visible = false
				r["state"] = "hidden"
				r["timer"] = rng.randf_range(40.0, 90.0)
