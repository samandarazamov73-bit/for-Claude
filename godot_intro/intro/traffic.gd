extends RefCounted
## Машины (и пешеходы, если есть тротуары) вдоль маршрута. На лесной дороге — только редкие встречные машины.
## Светофор необязателен: если в маршруте нет события «light», машины его не ждут.

const C = preload("res://intro/cfg.gd")
const MeshKit = preload("res://intro/meshkit.gd")

# Приглушённые цвета советских машин: «Волги», «Жигули», «Москвичи», УАЗики.
const CAR_COLORS: Array = ["e8e2cf", "2f4f6f", "6d1f1f", "3b5b3b", "c9b27a", "1b1b1b", "8a8f88", "5a7b9a", "b06a2a", "d8d4c4"]

var route
var city
var root: Node3D
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var cars: Array = []
var cross: Array = []
var peds: Array = []

var _stop_fwd: float = 0.0
var _stop_back: float = 0.0
var _cross_timer: float = 0.0
var _has_light: bool = false
var _m_vc: StandardMaterial3D
var _car_meshes: Dictionary = {}


func build(parent: Node3D, rt, world) -> void:
	route = rt
	city = world
	rng.seed = 99
	root = Node3D.new()
	root.name = "Traffic"
	parent.add_child(root)
	_m_vc = StandardMaterial3D.new()
	_m_vc.vertex_color_use_as_albedo = true
	_m_vc.vertex_color_is_srgb = true
	_m_vc.roughness = 0.4
	_m_vc.metallic = 0.2
	_has_light = route.by_id.has("light")
	if _has_light:
		_stop_fwd = float(route.by_id["light"]["stop_line"])
		_stop_back = float(world.cross_s) + 9.0
	var start_s: float = route.start_s
	# Двухполосная дорога: только встречные, редко.
	for i in C.ONCOMING_CARS:
		_add_car(-C.LANE_OFFSET, -1, start_s + 120.0 + float(i) * 190.0 + rng.randf_range(-40.0, 40.0))


# --- Машины ----------------------------------------------------------------------

func _car_mesh(color_hex: String, type: String) -> ArrayMesh:
	var key: String = color_hex + "|" + type
	if _car_meshes.has(key):
		return _car_meshes[key]
	var kit: Object = MeshKit.new()
	var paint: Color = Color(color_hex)
	var glass: Color = Color(0.11, 0.16, 0.2)
	var tire: Color = Color(0.08, 0.08, 0.08)
	if type == "van" or type == "ambulance":
		kit.add_box(Vector3(0, 1.3, 0), Vector3(1.95, 1.75, 4.8), paint)
		kit.add_box(Vector3(0, 1.7, -1.75), Vector3(1.97, 0.55, 1.1), glass)
		if type == "ambulance":
			kit.add_box(Vector3(0, 1.05, 0), Vector3(1.98, 0.22, 4.82), Color(0.83, 0.18, 0.18))
			kit.add_box(Vector3(0, 2.24, -1.6), Vector3(0.9, 0.12, 0.3), Color(0.18, 0.36, 1.0))
	else:
		var ln: float = 3.9 if type == "hatch" else 4.4
		var zc: float = 0.35 if type == "hatch" else 0.15
		kit.add_box(Vector3(0, 0.62, 0), Vector3(1.8, 0.7, ln), paint)
		kit.add_box(Vector3(0, 1.25, zc), Vector3(1.62, 0.6, ln * 0.5), glass)
		kit.add_box(Vector3(0, 1.57, zc), Vector3(1.64, 0.06, ln * 0.48), paint)
	for x in [-0.82, 0.82]:
		for z in [-1.35, 1.35]:
			kit.add_cyl(Vector3(x, 0.33, z), 0.33, 0.33, 0.24, tire, Vector3(0, 0, PI / 2.0), 10)
	kit.add_box(Vector3(0, 0.72, -2.16), Vector3(1.5, 0.12, 0.05), Color(1.0, 0.96, 0.86))
	kit.add_box(Vector3(0, 0.78, 2.16), Vector3(1.5, 0.12, 0.05), Color(0.63, 0.09, 0.09))
	var mesh: ArrayMesh = kit.build_mesh()
	_car_meshes[key] = mesh
	return mesh


## Машина-заглушка. type: sedan | hatch | van | ambulance. Перед — −Z.
func make_car(color_hex: String, type: String = "sedan") -> MeshInstance3D:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = _car_mesh(color_hex, type)
	mi.material_override = _m_vc
	return mi


func _add_car(lane: float, dir: int, s: float) -> void:
	var roll: float = rng.randf()
	var type: String = "van" if roll < 0.15 else ("hatch" if roll < 0.4 else "sedan")
	var node: MeshInstance3D = make_car(CAR_COLORS[rng.randi_range(0, CAR_COLORS.size() - 1)], type)
	root.add_child(node)
	var vmax: float = rng.randf_range(10.0, 14.0)
	cars.append({"node": node, "lane": lane, "dir": dir, "s": s, "v": vmax * 0.8, "max": vmax,
		"len": 5.0 if type == "van" else 4.6})


func _respawn(car: Dictionary, s_new: float) -> void:
	var s: float = s_new
	for tries in 6:
		var clash: bool = false
		for other in cars:
			if other != car and float(other["lane"]) == float(car["lane"]) and absf(float(other["s"]) - s) < 14.0:
				clash = true
		if not clash:
			break
		s += 16.0 * (1.0 if int(car["dir"]) < 0 else -1.0)
	car["s"] = s
	car["v"] = float(car["max"]) * 0.9


func _spawn_cross_car() -> void:
	var dir: float = 1.0 if rng.randf() < 0.5 else -1.0
	var type: String = "van" if rng.randf() < 0.2 else "sedan"
	var node: MeshInstance3D = make_car(CAR_COLORS[rng.randi_range(0, CAR_COLORS.size() - 1)], type)
	root.add_child(node)
	# Правостороннее движение: едущие «вправо» держатся ближней к автобусу полосы.
	cross.append({"node": node, "dir": dir, "lane": -2.75 if dir > 0.0 else 2.75, "t": 0.0, "v": rng.randf_range(9.0, 12.0)})


# --- Пешеходы ----------------------------------------------------------------------

func _add_ped(s: float) -> void:
	var side: float = 1.0 if rng.randf() < 0.5 else -1.0
	var h: float = rng.randf_range(0.92, 1.08)
	var shirts: Array = ["a03e3e", "3e6aa0", "4f8a4f", "c9a227", "6b4f8a", "cccccc", "333333"]
	var pants: Array = ["2b2b33", "3a4a66", "5a4632"]
	var skins: Array = ["e2b28f", "c68e64", "8d5a3b", "f0c9a8"]
	var g: Node3D = Node3D.new()
	var upper: Object = MeshKit.new()
	upper.add_capsule(Vector3(0, 1.2 * h, 0), 0.17, 0.74, Color(shirts[rng.randi_range(0, shirts.size() - 1)]))
	upper.add_sphere(Vector3(0, 1.62 * h, 0), 0.11, Color(skins[rng.randi_range(0, skins.size() - 1)]), Vector3.ONE, 10)
	g.add_child(upper.build(_m_vc))
	var pc: Color = Color(pants[rng.randi_range(0, pants.size() - 1)])
	var legs: Array = []
	for x in [-0.09, 0.09]:
		var pivot: Node3D = Node3D.new()
		pivot.position = Vector3(float(x), 0.88 * h, 0)
		var lk: Object = MeshKit.new()
		lk.add_capsule(Vector3(0, -0.44 * h, 0), 0.065, 0.88 * h, pc, Vector3.ZERO, Vector3.ONE, 6)
		pivot.add_child(lk.build(_m_vc))
		g.add_child(pivot)
		legs.append(pivot)
	root.add_child(g)
	peds.append({"node": g, "legs": legs, "s": s, "lat": side * rng.randf_range(8.1, 10.2),
		"dir": 1.0 if rng.randf() < 0.5 else -1.0, "v": rng.randf_range(1.0, 1.5), "phase": rng.randf() * 6.0})


# --- Каждый кадр ---------------------------------------------------------------------

func update(dt: float, bus_s: float, bus_v: float) -> void:
	var red: bool = _has_light and (city.light_state == "red" or city.light_state == "yellow")
	for car in cars:
		var cs: float = float(car["s"])
		var dir: float = float(car["dir"])
		var target: float = float(car["max"])
		# Машина впереди в той же полосе.
		var gap: float = INF
		for other in cars:
			if other == car or float(other["lane"]) != float(car["lane"]):
				continue
			var d: float = (float(other["s"]) - cs) * dir
			if d > 0.0 and d < gap:
				gap = d - (float(car["len"]) + float(other["len"])) / 2.0
		if gap < INF:
			target = minf(target, sqrt(2.0 * 3.5 * maxf(0.0, gap - 2.5)))
		# Красный свет: стоим у своей стоп-линии.
		if red:
			var front: float = cs + dir * float(car["len"]) / 2.0
			var line: float = _stop_fwd if dir > 0.0 else _stop_back
			var dist: float = (line - front) * dir
			if dist > -0.5 and dist < 70.0:
				target = minf(target, sqrt(2.0 * 3.5 * maxf(0.0, dist - 0.6)))
		var v: float = float(car["v"])
		v += (2.2 if target > v else -6.0) * dt
		v = clampf(v, 0.0, maxf(target, 0.0))
		car["v"] = v
		cs += v * dir * dt
		car["s"] = cs
		# Уехавшие машины переносим вперёд/назад, чтобы трафик всегда был рядом.
		if dir < 0.0 and cs < bus_s - 170.0:
			_respawn(car, bus_s + rng.randf_range(260.0, 460.0))
			cs = float(car["s"])
		elif dir > 0.0 and cs > bus_s + 480.0 and bus_v > 2.0:
			_respawn(car, bus_s - rng.randf_range(120.0, 220.0))
			cs = float(car["s"])
		var node: Node3D = car["node"]
		node.position = route.point(cs, float(car["lane"]), 0.0)
		node.rotation.y = route.yaw(cs) + (PI if dir < 0.0 else 0.0)

	# Поперечный поток, пока у нас красный.
	if not _has_light:
		_update_peds(dt, bus_s, bus_v)
		return
	_cross_timer -= dt
	if city.light_state == "red" and _cross_timer <= 0.0 and absf(bus_s - city.cross_s) < 200.0:
		_spawn_cross_car()
		_cross_timer = rng.randf_range(2.2, 3.8)
	var q: Dictionary = route.sample(city.cross_s)
	var i: int = cross.size() - 1
	while i >= 0:
		var c: Dictionary = cross[i]
		c["t"] = float(c["t"]) + float(c["v"]) * dt
		var along: float = float(c["t"]) - 70.0
		var cdir: float = float(c["dir"])
		var lane: float = float(c["lane"])
		var node2: Node3D = c["node"]
		node2.position = Vector3(float(q["x"]) + float(q["rx"]) * along * cdir + float(q["dx"]) * lane, 0.0,
			float(q["z"]) + float(q["rz"]) * along * cdir + float(q["dz"]) * lane)
		node2.rotation.y = atan2(-float(q["rx"]) * cdir, -float(q["rz"]) * cdir)
		if float(c["t"]) > 140.0:
			node2.queue_free()
			cross.remove_at(i)
		i -= 1

	_update_peds(dt, bus_s, bus_v)


func _update_peds(dt: float, bus_s: float, bus_v: float) -> void:
	for p in peds:
		var ps: float = float(p["s"])
		var pdir: float = float(p["dir"])
		ps += float(p["v"]) * pdir * dt
		p["phase"] = float(p["phase"]) + dt * float(p["v"]) * 5.5
		if ps < bus_s - 140.0 or ps > bus_s + 300.0:
			ps = bus_s + (rng.randf_range(120.0, 280.0) if bus_v > 1.0 else rng.randf_range(-60.0, 160.0))
			p["dir"] = 1.0 if rng.randf() < 0.5 else -1.0
			pdir = float(p["dir"])
		p["s"] = ps
		var pn: Node3D = p["node"]
		pn.position = route.point(ps, float(p["lat"]), 0.0)
		pn.rotation.y = route.yaw(ps) + (PI if pdir < 0.0 else 0.0)
		var swing: float = sin(float(p["phase"])) * 0.45
		(p["legs"][0] as Node3D).rotation.x = swing
		(p["legs"][1] as Node3D).rotation.x = -swing
