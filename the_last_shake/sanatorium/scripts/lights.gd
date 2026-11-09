extends Node3D
## Lamps per room: one OmniLight3D per working fixture (from level.json), the fixture's glowing glass
## switched with it, table lamps, floor lamps and wall sconces of the room. Broken lamps never light;
## failing lamps flicker (with a crackle). Guest rooms and offices are dark when you arrive, corridors
## and stairs are lit. Only the nearest lights cast shadows (updated a few times a second).

var game
var groups := {}          # room -> {on, lights: [], fixtures: [], glows: [], flick: []}
var flickers := []        # {light, mesh, room, next, phase, n}
var shadowed := []
var all_lights := []
var off_mat: StandardMaterial3D
var buzz_players := []
var fluo := []            # {pos, room, light}
var _t := 0.0
var _shadow_t := 0.0

const ON_KINDS := ["corridor", "corridor_patient", "service_corridor", "hall", "vestibule", "stair_main", "stair_end",
	"nurse_post", "foyer", "phytobar"]
const SHADOWS := 8
var max_shadows := SHADOWS   # set by quality.gd
const SHADOW_DIST := 15.0
const DIM := 0.5              # the whole building darker than the fixtures' nominal output (horror)
const LIGHT_PER_M2 := 0.2     # light_energy per square metre of an average room (per storey)
const SHADOW_FADE := 2.5      # shadow opacity per second when a lamp starts or stops casting shadows
var _fade := {}               # light -> target shadow opacity while it fades in or out


func _group(room: String) -> Dictionary:
	if not groups.has(room):
		groups[room] = {"on": false, "lights": [], "fixtures": [], "glows": [], "has_switch": false}
	return groups[room]


func setup(g) -> void:
	game = g
	off_mat = StandardMaterial3D.new()
	off_mat.albedo_color = Color(0.58, 0.57, 0.54)
	off_mat.roughness = 0.3
	var rng := RandomNumberGenerator.new()
	rng.seed = 1982
	var rng_flick := RandomNumberGenerator.new()
	rng_flick.seed = 1983
	var rng_dead := RandomNumberGenerator.new()
	rng_dead.seed = 1984
	var dead := 0
	for f in game.level["fixtures"]:
		var grp: Dictionary = _group(f["room"])
		var mesh: Node = game.node(f["name"])
		var kind: String = f["kind"]
		if mesh != null:
			grp["fixtures" if kind != "lamp" else "glows"].append(mesh)
			# The shade sits around the bulb, so its own shadow is never seen, but every flicker swaps its
			# material, and a shadow caster that changes makes the nearby lamps redraw their shadow cubes.
			if mesh is GeometryInstance3D and kind != "lamp":
				mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if f["state"] == "broken":
			continue
		# many more dead lamps than the plan had: about a quarter of the ceiling lights in rooms, a fifth in
		# corridors and stairs (they stay walkable), a third of the chandeliers; their glass stays dark
		var room_kind: String = game.rooms.get(f["room"], {}).get("kind", "")
		var p_dead: float = 0.33 if kind == "pendant" else (0.2 if room_kind in ON_KINDS else 0.25)
		if kind != "lamp" and rng_dead.randf() < p_dead:
			if mesh is GeometryInstance3D:
				grp["fixtures"].erase(mesh)
				mesh.material_override = off_mat
			dead += 1
			continue
		var l := OmniLight3D.new()
		var col: Array = f["color"]
		l.light_color = Color(col[0], col[1], col[2])
		var e: float = f["energy"]
		match kind:
			"pendant":
				l.light_energy = minf(e / 40.0, 3.2)     # the hall chandeliers were blinding
				l.omni_range = 11.0
			"bulb":
				l.light_energy = e / 40.0
				l.omni_range = 5.0
			"lamp":
				l.light_energy = e / 26.0
				l.omni_range = 4.0
			_:
				l.light_energy = e / 44.0
				l.omni_range = 7.0
		# old tubes give a sickly greenish white, old ceiling lights a dirty yellow
		if kind == "fluo":
			l.light_color = Color(col[0], col[1], col[2]).lerp(Color(0.84, 1.0, 0.8), 0.35)
		elif kind == "plafond":
			l.light_color = Color(col[0], col[1], col[2]).lerp(Color(1.0, 0.85, 0.6), 0.18)
		l.light_energy *= DIM
		l.omni_attenuation = 1.0
		l.light_specular = 0.35
		l.light_volumetric_fog_energy = 0.5
		l.shadow_enabled = false
		l.omni_shadow_mode = OmniLight3D.SHADOW_CUBE
		l.shadow_bias = 0.08
		l.distance_fade_enabled = true
		l.distance_fade_begin = 30.0       # far lamps fade out slowly over 12 m instead of popping
		l.distance_fade_length = 12.0
		l.distance_fade_shadow = 14.0
		add_child(l)
		l.global_position = game._v3(f["pos"])
		l.set_meta("base_energy", l.light_energy)
		# table lamps, floor lamps and sconces never get a shadow: inside their shade it only cut sharp
		# wedges and stray lines of light on the walls and ceiling (and beams in the fog)
		l.set_meta("no_shadow", kind == "lamp")
		grp["lights"].append(l)
		all_lights.append({"light": l, "room": f["room"]})
		var flicker: bool = f["state"] == "flicker"
		if not flicker and kind in ["fluo", "plafond"] and rng_flick.randf() < 0.05:
			flicker = true            # a few more failing lamps than the plan had
		if flicker:
			flickers.append({"light": l, "mesh": mesh, "room": f["room"], "next": rng.randf_range(0.5, 6.0),
				"phase": 0, "n": 0})
		if kind == "fluo":
			fluo.append({"pos": l.global_position, "room": f["room"], "light": l})
	_balance_rooms()
	var unlit := {}
	for room in groups:
		if groups[room]["lights"].is_empty():
			unlit[room] = true
	var desk_lamps := 0
	for gl in game.level["glows"]:
		var m: Node = game.node(gl["name"])
		if m != null:
			_group(gl["room"])["glows"].append(m)
		# A desk lamp in a room whose ceiling lights are all dead glowed with nothing lit around it, a bright
		# patch hanging in the dark. In those rooms the desk lamps really light: a small warm lamp at the shade.
		if m is VisualInstance3D and unlit.has(gl["room"]):
			var box: AABB = m.get_aabb()
			var l := OmniLight3D.new()
			l.light_color = Color(1.0, 0.78, 0.5)
			l.light_energy = 0.55
			l.omni_range = 3.5
			l.omni_attenuation = 1.2
			l.light_specular = 0.3
			l.light_volumetric_fog_energy = 0.3
			l.distance_fade_enabled = true
			l.distance_fade_begin = 30.0
			l.distance_fade_length = 12.0
			add_child(l)
			l.global_position = m.global_transform * (box.position + box.size * Vector3(0.5, 0.75, 0.5))
			l.set_meta("base_energy", l.light_energy)
			l.set_meta("no_shadow", true)
			_group(gl["room"])["lights"].append(l)
			all_lights.append({"light": l, "room": gl["room"]})
			desk_lamps += 1
	game.stats["desk_lamps_in_dark_rooms"] = desk_lamps
	for s in game.level["switches"]:
		_group(s["room"])["has_switch"] = true
	for room in groups:
		var r: Dictionary = game.rooms.get(room, {})
		var on: bool = r.get("kind", "") in ON_KINDS
		if not groups[room]["has_switch"] and not on:
			on = r.get("kind", "") in ["lift", "shaft"]
		# someone left the light on in a few guest rooms
		if r.get("kind", "") in ["suite_double", "suite_single"] and rng.randf() < 0.07:
			on = true
		set_room(room, on, false)
	for i in 4:
		var p := AudioStreamPlayer3D.new()
		p.stream = game.sfx("fluo_buzz_loop", true)
		p.volume_db = -22.0
		p.unit_size = 1.5
		p.max_distance = 9.0
		p.bus = "World"
		add_child(p)
		buzz_players.append(p)
	game.stats["lights"] = all_lights.size()
	game.stats["dead_lamps"] = dead
	game.stats["flickering"] = flickers.size()


## Small rooms (bathrooms, WCs) had one ceiling light as strong as a ward's: 2 to 2.5 times more light per
## square metre than an average room, and with a 7 m reach it shone through the walls too. Rooms brighter
## than average are toned down, and in small rooms the light's reach is kept to about the room.
func _balance_rooms() -> void:
	for room in groups:
		var r: Dictionary = game.rooms.get(room, {})
		var lights_in: Array = groups[room]["lights"]
		if lights_in.is_empty():
			continue
		var area := 0.0
		var diag := 0.0
		for q in r.get("rects", []):
			area += (q[1] - q[0]) * (q[3] - q[2])
			diag = maxf(diag, Vector2(q[1] - q[0], q[3] - q[2]).length())
		var storeys: float = maxf(1.0, roundf((float(r.get("ceil_y", 4.2)) - float(r.get("floor_y", 1.2))) / 3.3))
		if area <= 0.0:
			continue
		var total := 0.0
		for l in lights_in:
			total += l.light_energy
		var k: float = clampf(sqrt(LIGHT_PER_M2 * DIM * area * storeys / total), 0.6, 1.0)
		for l in lights_in:
			l.light_energy *= k
			if storeys < 1.5:
				# still reaching the floor 3 m below and the corners, but not far into the next rooms
				l.omni_range = minf(l.omni_range, maxf(4.8, diag))
			l.set_meta("base_energy", l.light_energy)


func is_on(room: String) -> bool:
	return groups.has(room) and groups[room]["on"]


func working_count(room: String) -> int:
	return groups[room]["lights"].size() if groups.has(room) else 0


func set_room(room: String, on: bool, _sound := true) -> void:
	var grp := _group(room)
	grp["on"] = on
	for l in grp["lights"]:
		l.visible = on
		if not on and l.shadow_enabled:
			l.shadow_enabled = false
			_fade.erase(l)
	for m in grp["fixtures"]:
		if m is GeometryInstance3D:
			m.material_override = null if on else off_mat
	for m in grp["glows"]:
		if m is GeometryInstance3D:
			m.material_override = null if on else off_mat
	# broken fixtures keep their dark glass (baked into the mesh)


func _process(dt: float) -> void:
	_t += dt
	var pp: Vector3 = game.player.global_position if game.player else Vector3.ZERO
	for f in flickers:
		var l: OmniLight3D = f["light"]
		if not is_on(f["room"]):
			continue
		f["next"] -= dt
		if f["next"] > 0.0:
			continue
		var base: float = l.get_meta("base_energy")
		if f["phase"] == 0:
			# start a burst of 1..5 short drop-outs
			f["n"] = randi_range(1, 5)
			f["phase"] = 1
		if f["phase"] == 1:
			l.light_energy = base * randf_range(0.0, 0.15)
			if f["mesh"] is GeometryInstance3D:
				f["mesh"].material_override = off_mat
			f["phase"] = 2
			f["next"] = randf_range(0.03, 0.14)
			if pp.distance_to(l.global_position) < 14.0 and randf() < 0.6:
				game.play_at("flicker", l.global_position, -10.0, randf_range(0.8, 1.3), 14.0)
		else:
			l.light_energy = base
			if f["mesh"] is GeometryInstance3D:
				f["mesh"].material_override = null
			f["n"] -= 1
			if f["n"] > 0:
				f["phase"] = 1
				f["next"] = randf_range(0.04, 0.25)
			else:
				f["phase"] = 0
				f["next"] = randf_range(1.5, 9.0)
	for l in _fade.keys():
		if not is_instance_valid(l):
			_fade.erase(l)
			continue
		var goal: float = _fade[l]
		l.shadow_opacity = move_toward(l.shadow_opacity, goal, dt * SHADOW_FADE)
		if l.shadow_opacity == goal:
			if goal == 0.0:
				l.shadow_enabled = false
			_fade.erase(l)
	_shadow_t -= dt
	if _shadow_t <= 0.0:
		_shadow_t = 0.25
		_update_shadows(pp)
		_update_buzz(pp)


func _update_shadows(pp: Vector3) -> void:
	var cand := []
	for e in all_lights:
		var l: OmniLight3D = e["light"]
		if not l.visible or l.get_meta("no_shadow", false):
			continue
		var d: float = pp.distance_to(l.global_position)
		if d < SHADOW_DIST and abs(l.global_position.y - pp.y) < 4.5:
			cand.append([d, l])
	cand.sort_custom(func(a, b): return a[0] < b[0])
	var want := {}
	for i in min(max_shadows, cand.size()):
		want[cand[i][1]] = true
	# Only touch lights whose shadow actually switches: setting shadow_enabled, even to the value it
	# already has, makes Godot redraw the light's whole shadow cube (6 views of the building).
	# Shadows fade in and out (shadow_opacity costs no redraw) instead of popping when the set changes.
	for l in shadowed:
		if is_instance_valid(l) and not want.has(l) and l.shadow_enabled:
			_fade[l] = 0.0
	shadowed = []
	for l in want:
		if not l.shadow_enabled:
			l.shadow_opacity = 0.0
			l.shadow_enabled = true
		if l.shadow_opacity < 1.0:
			_fade[l] = 1.0
		shadowed.append(l)


func _update_buzz(pp: Vector3) -> void:
	var cand := []
	for f in fluo:
		if not is_on(f["room"]):
			continue
		var d: float = pp.distance_to(f["pos"])
		if d < 9.0:
			cand.append([d, f["pos"]])
	cand.sort_custom(func(a, b): return a[0] < b[0])
	for i in buzz_players.size():
		var p: AudioStreamPlayer3D = buzz_players[i]
		if i < cand.size():
			p.global_position = cand[i][1]
			if not p.playing:
				p.play(randf() * 0.9)
		elif p.playing:
			p.stop()
