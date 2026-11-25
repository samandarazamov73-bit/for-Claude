extends Node3D
## Наклейки грязи (Decal) по всему зданию: протечки на потолке и потёки со стены от потолка, облупленная
## краска, трещины в штукатурке, затёртая полоса у пола (в коридорах — чаще), пятна на полу. Текстуры — из
## коллажей автора игры (tools/godot_assets/make_decals.py → sanatorium/assets/decals/): каждая затемняет
## стену её же цветом, поэтому подходит к любой краске и обоям.
## Места — случайные, но каждый раз одни и те же (зерно — номер комнаты). Место на стене проверяется лучами:
## под всей наклейкой — сплошная стена (не дверной проём, не окно, не угол), на потолке и полу — тоже.
## В мокрых комнатах (санузлы, ванные, кухня) протечек больше; в коридорах и холле — больше затёртых полос и
## пятен на полу. Каждая наклейка ложится только на свой этаж (слой отрисовки этажа).

const DIR := "res://sanatorium/assets/decals/"
const SKIP_KINDS := ["shaft", "stair_main", "stair_end", "machine_room", "fridge"]
## имя → [ширина от, до (м), насколько видна]
const KINDS := {
	"ceiling_leak": [1.0, 1.9, 0.85],
	"wall_leak": [0.9, 1.5, 0.8],
	"peeling": [0.55, 1.05, 0.9],
	"cracks": [0.6, 1.2, 0.85],
	"scuffs": [1.6, 3.0, 0.8],
	"floor": [0.8, 1.4, 0.7],
}

var game
var decals: Array = []                   # [Decal, базовая видимость]
var _tex := {}                           # имя → [[цвет, нормали], …]
var _strength := 1.0


func place(g) -> void:
	game = g
	for nm in KINDS:
		var vs: Array = []
		for v in ["a", "b"]:
			var p: String = DIR + "%s_%s.png" % [nm, v]
			if ResourceLoader.exists(p):
				var np: String = DIR + "%s_%s_n.png" % [nm, v]
				vs.append([load(p), load(np) if ResourceLoader.exists(np) else null])
		if not vs.is_empty():
			_tex[nm] = vs
	if _tex.is_empty():
		return
	await get_tree().physics_frame                 # стены, пол и потолок уже в физике
	await get_tree().physics_frame
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	for r in game.room_list:
		_room(r, space)
	set_strength(_strength)
	print("grime decals: %d" % decals.size())


## Насколько видна грязь (1 — как есть; утром в настоящей больнице — слабее).
func set_strength(k: float) -> void:
	_strength = k
	for d in decals:
		var dc: Decal = d[0]
		dc.modulate.a = float(d[1]) * k


func _room(r: Dictionary, space: PhysicsDirectSpaceState3D) -> void:
	var kind: String = r["kind"]
	if kind in SKIP_KINDS:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(String(r["id"]) + "grime")
	var area := 0.0
	for q in r["rects"]:
		area += (float(q[1]) - float(q[0])) * (float(q[3]) - float(q[2]))
	var corridor: bool = kind.contains("corridor") or kind in ["hall", "foyer", "vestibule", "lounge", "registration"]
	var wet: bool = kind.contains("wc") or kind.contains("bath") or kind.contains("shower") \
			or kind in ["hydro", "dishwash", "plumbing", "kitchen", "veg_prep", "janitor", "cleaning_store"]
	var k: float = clampf(area / 18.0, 0.4, 5.0)
	var want := {
		"ceiling_leak": (0.3 + (0.45 if wet else 0.0)) * k,
		"wall_leak": (0.2 + (0.4 if wet else 0.0)) * k,
		"peeling": (0.35 + (0.2 if wet else 0.0)) * k,
		"cracks": 0.3 * k,
		"scuffs": (0.9 if corridor else 0.3) * k,
		"floor": (0.45 if corridor else 0.12) * k,
	}
	var storey: int = clampi(roundi((float(r["floor_y"]) - game.FIRST_FLOOR) / game.STOREY), 0, 3)
	var mask: int = 1 << (game.STOREY_BIT0 + storey)
	for nm in want:
		if not _tex.has(nm):
			continue
		var n: int = int(want[nm]) + (1 if rng.randf() < fmod(want[nm], 1.0) else 0)
		for i in n:
			for attempt in 8:
				if _try(nm, r, mask, rng, space):
					break


func _try(nm: String, r: Dictionary, mask: int, rng: RandomNumberGenerator, space: PhysicsDirectSpaceState3D) -> bool:
	var fy: float = r["floor_y"]
	var cy: float = r["ceil_y"]
	var rects: Array = r["rects"]
	var q: Array = rects[rng.randi() % rects.size()]
	var x0: float = q[0]
	var x1: float = q[1]
	var z0: float = q[2]
	var z1: float = q[3]
	var var_i: int = rng.randi() % (_tex[nm] as Array).size()
	var tex: Texture2D = _tex[nm][var_i][0]
	var aspect: float = float(tex.get_height()) / float(tex.get_width())
	var w: float = rng.randf_range(KINDS[nm][0], KINDS[nm][1])
	var h: float = w * aspect
	if nm == "ceiling_leak" or nm == "floor":
		var m: float = w * 0.5 + 0.1
		if x1 - x0 < 2.0 * m or z1 - z0 < 2.0 * m:
			return false
		var p := Vector3(rng.randf_range(x0 + m, x1 - m), 0.0, rng.randf_range(z0 + m, z1 - m))
		var yaw: float = rng.randf() * TAU
		var tx := Vector3(cos(yaw), 0.0, sin(yaw))
		var tz := Vector3(-tx.z, 0.0, tx.x)
		var up: bool = nm == "ceiling_leak"
		var surf_y: float = cy if up else fy
		for c in [Vector2.ZERO, Vector2(-0.45, -0.45), Vector2(0.45, -0.45), Vector2(-0.45, 0.45), Vector2(0.45, 0.45)]:
			var s: Vector3 = p + tx * (c.x * w) + tz * (c.y * h)
			var hit: Dictionary = _ray(space, Vector3(s.x, fy + 1.3, s.z), Vector3(s.x, surf_y + (0.25 if up else -0.25), s.z))
			if hit.is_empty() or absf((hit["position"] as Vector3).y - surf_y) > 0.12:
				return false
		var yb := Vector3.DOWN if up else Vector3.UP
		_add(nm, var_i, Basis(tx, yb, tx.cross(yb)), Vector3(p.x, surf_y, p.z), Vector3(w, 0.12, h), mask)
		return true
	# стена: случайная сторона прямоугольника комнаты, точка вдоль неё
	var side: int = rng.randi() % 4
	var a: Vector3
	var b: Vector3
	var inward: Vector3
	match side:
		0:
			a = Vector3(x0, 0, z0); b = Vector3(x1, 0, z0); inward = Vector3(0, 0, 1)
		1:
			a = Vector3(x0, 0, z1); b = Vector3(x1, 0, z1); inward = Vector3(0, 0, -1)
		2:
			a = Vector3(x0, 0, z0); b = Vector3(x0, 0, z1); inward = Vector3(1, 0, 0)
		_:
			a = Vector3(x1, 0, z0); b = Vector3(x1, 0, z1); inward = Vector3(-1, 0, 0)
	var L: float = a.distance_to(b)
	if L < w + 0.3:
		return false
	var t: float = rng.randf_range(w * 0.5 + 0.15, L - w * 0.5 - 0.15)
	var along: Vector3 = (b - a).normalized()
	var base: Vector3 = a + along * t
	var yc: float
	match nm:
		"wall_leak":
			yc = cy - 0.01 - h * 0.5
		"scuffs":
			yc = fy + 0.02 + h * 0.5
		"peeling":
			yc = fy + rng.randf_range(1.1, 2.3)
		_:
			yc = fy + rng.randf_range(1.4, 2.6)
	if yc + h * 0.5 > cy - 0.005 or yc - h * 0.5 < fy:
		return false
	# сплошная стена под всей наклейкой: 6 лучей из комнаты к стене — все на одном расстоянии
	var d0 := -1.0
	var nrm := Vector3.ZERO
	for c in [Vector2.ZERO, Vector2(-0.45, -0.4), Vector2(0.45, -0.4), Vector2(-0.45, 0.4), Vector2(0.45, 0.4), Vector2(0, 0.4)]:
		var s: Vector3 = base + along * (c.x * w) + Vector3(0, yc + c.y * h, 0) + inward * 0.3
		var hit: Dictionary = _ray(space, s, s - inward * 0.6)
		if hit.is_empty():
			return false
		var n: Vector3 = hit["normal"]
		if n.dot(inward) < 0.9:
			return false
		var d: float = s.distance_to(hit["position"])
		if d0 < 0.0:
			d0 = d
			nrm = n
		elif absf(d - d0) > 0.04:
			return false
	var pos: Vector3 = base + Vector3(0, yc, 0) + inward * (0.3 - d0)
	_add(nm, var_i, Basis(Vector3.UP.cross(nrm), nrm, Vector3.DOWN), pos, Vector3(w, 0.1, h), mask)
	return true


func _ray(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> Dictionary:
	var pq := PhysicsRayQueryParameters3D.create(from, to, game.L_WORLD)
	return space.intersect_ray(pq)


func _add(nm: String, var_i: int, basis: Basis, pos: Vector3, size: Vector3, mask: int) -> void:
	var d := Decal.new()
	d.texture_albedo = _tex[nm][var_i][0]
	if _tex[nm][var_i][1]:
		d.texture_normal = _tex[nm][var_i][1]
	d.size = size
	d.cull_mask = mask
	d.normal_fade = 0.5                       # не тянуть на перпендикулярные поверхности (угол, бок шкафа)
	d.upper_fade = 0.2
	d.lower_fade = 0.2
	d.distance_fade_enabled = true
	d.distance_fade_begin = 16.0
	d.distance_fade_length = 6.0
	add_child(d)
	d.global_transform = Transform3D(basis.orthonormalized(), pos)
	decals.append([d, float(KINDS[nm][2])])
