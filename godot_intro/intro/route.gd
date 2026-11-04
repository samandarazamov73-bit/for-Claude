extends RefCounted
## Маршрут автобуса: прямые участки и дуги (точная длина и кривизна), события (остановки, светофор),
## план скорости и подбор длины маршрута под нужную длительность поездки.

const C = preload("res://intro/cfg.gd")
const Driver = preload("res://intro/driver.gd")

const PLAN_STEP: float = 1.0

var pieces: Array = []          # участки: {arc, s0, len, k, x0, z0, th0}
var length: float = 0.0
var events: Array = []          # {id, kind: stop|light|final, s}
var by_id: Dictionary = {}
var turns: Array = []           # {s0, s1} — повороты (там нельзя ставить дома)
var start_s: float = 392.0
var expected_seconds: float = 0.0
var plan: PackedFloat32Array = PackedFloat32Array()


func _init(scale: float = 1.0) -> void:
	build(scale)


## Остановки по пути и конечная (id → тексты в story.gd).
const STOP_IDS: Array = ["camp", "spring"]
const FINAL_ID: String = "sanatorium"

var final_id: String = FINAL_ID           # то же, но доступно через экземпляр
var stop_ids: Array = STOP_IDS


## Собирает маршрут через лес. scale растягивает прямые участки — так подгоняется длительность.
func build(scale: float) -> void:
	# ["S", длина] — прямая; ["A", радиус, градусы] — дуга (плюс — направо, минус — налево).
	var defs: Array = [
		["S", 400.0],                   # 0  дорога «за спиной» в начале
		["S", 160.0 * scale],           # 1
		["A", 140.0, 28.0],             # 2  плавно направо
		["S", 230.0 * scale],           # 3  остановка «Пионерлагерь»
		["A", 110.0, -40.0],            # 4  налево
		["S", 260.0 * scale],           # 5
		["A", 200.0, 22.0],             # 6  плавно направо
		["S", 170.0 * scale],           # 7
		["A", 160.0, -26.0],            # 8  плавно налево
		["S", 300.0 * scale],           # 9  остановка «Родник»
		["A", 130.0, 34.0],             # 10 направо
		["S", 240.0 * scale + 160.0],   # 11 до санатория
		["A", 120.0, -38.0],            # 12 за остановкой поворот: автобус скрывается в лесу
		["S", 700.0],                   # 13 дальше автобус уезжает
	]
	pieces = []
	var s: float = 0.0
	var x: float = 0.0
	var z: float = 0.0
	var th: float = -PI / 2.0
	for d in defs:
		var arc: bool = d[0] == "A"
		var ln: float = float(d[1])
		var k: float = 0.0
		if arc:
			var radius: float = float(d[1])
			var deg: float = float(d[2])
			ln = absf(deg_to_rad(deg)) * radius
			k = signf(deg) / radius
		var piece: Dictionary = {"arc": arc, "s0": s, "len": ln, "k": k, "x0": x, "z0": z, "th0": th}
		pieces.append(piece)
		var e: Dictionary = _eval(piece, ln)
		x = e["x"]
		z = e["z"]
		th = e["th"]
		s += ln
	length = s

	events = [
		{"id": "camp", "kind": "stop", "s": float(pieces[3]["s0"]) + float(pieces[3]["len"]) * 0.55},
		{"id": "spring", "kind": "stop", "s": float(pieces[9]["s0"]) + float(pieces[9]["len"]) * 0.5},
		{"id": FINAL_ID, "kind": "final", "s": float(pieces[12]["s0"]) - 70.0},
	]
	by_id = {}
	for ev in events:
		by_id[ev["id"]] = ev
	turns = []
	for i in [2, 4, 6, 8, 10, 12]:
		turns.append({"s0": float(pieces[i]["s0"]), "s1": float(pieces[i]["s0"]) + float(pieces[i]["len"])})
	start_s = 392.0
	plan = make_plan()


func _eval(p: Dictionary, t: float) -> Dictionary:
	var k: float = p["k"]
	var th0: float = p["th0"]
	var x0: float = p["x0"]
	var z0: float = p["z0"]
	if k == 0.0:
		return {"x": x0 + cos(th0) * t, "z": z0 + sin(th0) * t, "th": th0}
	var th: float = th0 + k * t
	return {"x": x0 + (sin(th) - sin(th0)) / k, "z": z0 + (cos(th0) - cos(th)) / k, "th": th}


func piece_at(s: float) -> Dictionary:
	if s <= 0.0:
		return pieces[0]
	for p in pieces:
		if s < float(p["s0"]) + float(p["len"]):
			return p
	return pieces[pieces.size() - 1]


## Точка на оси дороги: x, z, направление вперёд (dx, dz), вправо (rx, rz), кривизна k.
func sample(s: float) -> Dictionary:
	var cs: float = clampf(s, 0.0, length)
	var p: Dictionary = piece_at(cs)
	var e: Dictionary = _eval(p, cs - float(p["s0"]))
	var extra: float = s - cs     # за краями маршрута продолжаем по прямой
	var th: float = e["th"]
	var dx: float = cos(th)
	var dz: float = sin(th)
	var k: float = float(p["k"])
	if extra != 0.0:
		k = 0.0
	return {"x": float(e["x"]) + dx * extra, "z": float(e["z"]) + dz * extra,
		"dx": dx, "dz": dz, "rx": -dz, "rz": dx, "k": k}


## Точка рядом с дорогой: lateral > 0 — вправо от оси.
func point(s: float, lateral: float = 0.0, y: float = 0.0) -> Vector3:
	var q: Dictionary = sample(s)
	return Vector3(float(q["x"]) + float(q["rx"]) * lateral, y, float(q["z"]) + float(q["rz"]) * lateral)


## Поворот объекта (rotation.y), чтобы его «перед» (−Z) смотрел вдоль маршрута.
func yaw(s: float) -> float:
	var q: Dictionary = sample(s)
	return atan2(-float(q["dx"]), -float(q["dz"]))


func curvature(s: float) -> float:
	return float(piece_at(s)["k"])


# --- Скорость -------------------------------------------------------------

## Допустимая скорость в каждой точке: по кривизне и с заблаговременным торможением перед поворотом.
func make_plan() -> PackedFloat32Array:
	var n: int = int(ceil(length / PLAN_STEP)) + 3
	var lim: PackedFloat32Array = PackedFloat32Array()
	lim.resize(n)
	for i in n:
		var k: float = absf(curvature(float(i) * PLAN_STEP))
		if k > 0.0:
			lim[i] = minf(C.BUS_CRUISE, sqrt(C.BUS_LAT_ACCEL / k))
		else:
			lim[i] = C.BUS_CRUISE
	for i in range(n - 2, -1, -1):
		lim[i] = minf(lim[i], sqrt(lim[i + 1] * lim[i + 1] + 2.0 * C.BUS_DECEL * PLAN_STEP))
	return lim


func plan_at(s: float) -> float:
	var i: int = clampi(int(round(s / PLAN_STEP)), 0, plan.size() - 1)
	return plan[i]


# --- Подбор длины под нужное время ----------------------------------------

## Сколько секунд длится поездка от старта до больницы (с остановками и светофором).
func simulate_trip() -> float:
	var d: RefCounted = Driver.new(self)
	var t: float = 0.0
	var dt: float = 0.1
	while t < 7200.0:
		d.update(dt)
		t += dt
		if d.stopped:
			var ev: Dictionary = events[d.index]
			if ev["kind"] == "final":
				return t
			if ev["kind"] == "light":
				t += C.BUS_RED_LIGHT
			else:
				t += C.BUS_DWELL + C.DOOR_EXTRA
			d.release()
	return t


## Растягивает прямые участки, пока поездка не станет длиться target_seconds.
func fit_to_duration(target_seconds: float) -> void:
	var lo: float = 0.35
	var hi: float = 4.0
	for i in 14:
		var mid: float = (lo + hi) / 2.0
		build(mid)
		if simulate_trip() < target_seconds:
			lo = mid
		else:
			hi = mid
	build((lo + hi) / 2.0)
	expected_seconds = simulate_trip()
