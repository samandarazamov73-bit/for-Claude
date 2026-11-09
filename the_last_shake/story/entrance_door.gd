extends Node3D
## Входная дверь санатория в прологе. В модели здания стеклянная стена вестибюля (Lobby_CurtainWall_Doors) —
## один неподвижный меш, поэтому створки двери «А» (напротив тамбура, z = 3,64…4,91) вырезаются из него:
## их стекло, нижняя планка, филёнка, притвор и ручки переносятся в отдельные меши, каждая створка —
## на своей петле, и открывается внутрь, в тамбур. Остальная стена остаётся как была.
## Координаты — здания (как в sanatorium/assets/level.json).

const HINGE_X := 27.5
const Z0 := 3.64          # петля первой створки
const ZM := 4.27          # притвор (середина двери)
const Z1 := 4.91          # петля второй створки
const TOP := 3.46         # верх створок (под импостом)
const PANEL := Vector2(3.59, 4.96)
const OPEN_DEG := 88.0
const CENTER := Vector3(27.55, 2.3, 4.27)

var pivots: Array = []    # Node3D на петлях: [z < ZM, z > ZM]
var amount := 0.0         # 0 — закрыта, 1 — открыта
var _snd_open: AudioStreamPlayer3D
var _snd_close: AudioStreamPlayer3D


## wall — MeshInstance3D «Lobby_CurtainWall_Doors» из здания. false — если такого меша нет.
func build(wall: MeshInstance3D) -> bool:
	var src: Mesh = wall.mesh
	if src == null:
		return false
	var keep := ArrayMesh.new()
	var leaf_meshes := [ArrayMesh.new(), ArrayMesh.new()]
	var hinges := [Vector3(HINGE_X, 0.0, Z0), Vector3(HINGE_X, 0.0, Z1)]
	for si in src.get_surface_count():
		var arr: Array = src.surface_get_arrays(si)
		var mat: Material = wall.get_active_material(si)
		var mname: String = (mat.resource_name if mat else "").to_lower()
		var kind := "glass" if mname.contains("glass") else ("frame" if mname.contains("frame") else "handle")
		var outs := [_Out.new(arr), _Out.new(arr), _Out.new(arr)]          # стена, створка 1, створка 2
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var nverts: int = (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var ntri: int = (idx.size() if idx.size() > 0 else nverts) / 3
		for t in ntri:
			var tri := []
			for k in 3:
				tri.append(_vertex(arr, idx[t * 3 + k] if idx.size() > 0 else t * 3 + k))
			_route(tri, kind, outs)
		for k in 3:
			var o: _Out = outs[k]
			if o.empty():
				continue
			if k > 0:
				o.shift(-hinges[k - 1])
			var m: ArrayMesh = keep if k == 0 else leaf_meshes[k - 1]
			m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, o.arrays())
			m.surface_set_material(m.get_surface_count() - 1, mat)
	wall.mesh = keep
	for i in 2:
		var pivot := Node3D.new()
		pivot.name = "EntranceLeaf%d" % i
		wall.add_child(pivot)
		pivot.position = hinges[i]
		var mi := MeshInstance3D.new()
		mi.mesh = leaf_meshes[i]
		pivot.add_child(mi)
		pivots.append(pivot)
	_snd_open = _player(wall, "res://sanatorium/assets/sfx/door_open_metal.wav")
	_snd_close = _player(wall, "res://sanatorium/assets/sfx/door_close_metal.wav")
	return true


func _player(parent: Node3D, path: String) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	if ResourceLoader.exists(path):
		p.stream = load(path)
	p.unit_size = 4.0
	p.max_distance = 40.0
	parent.add_child(p)
	p.position = CENTER
	return p


## 0 — закрыта, 1 — открыта (обе створки внутрь).
func set_amount(a: float) -> void:
	amount = clampf(a, 0.0, 1.0)
	if pivots.size() < 2:
		return
	var ang: float = deg_to_rad(OPEN_DEG) * amount
	(pivots[0] as Node3D).rotation.y = ang          # свободный край (+z) уходит в +x, внутрь
	(pivots[1] as Node3D).rotation.y = -ang


func open(seconds := 1.5) -> void:
	if _snd_open and _snd_open.stream:
		_snd_open.play()
	var tw := create_tween()
	tw.tween_method(set_amount, amount, 1.0, seconds).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tw.finished


func close(seconds := 1.1) -> void:
	var tw := create_tween()
	tw.tween_method(set_amount, amount, 0.0, seconds).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await tw.finished
	if _snd_close and _snd_close.stream:
		_snd_close.play()


# ------------------------------------------------------------------ разрезка меша
## Куда идёт треугольник: целиком в стену, целиком в створку или по частям (разрез по z и по верху створок).
func _route(tri: Array, kind: String, outs: Array) -> void:
	var zmin := INF
	var zmax := -INF
	var ymax := -INF
	for v in tri:
		var p: Vector3 = v["p"]
		zmin = minf(zmin, p.z)
		zmax = maxf(zmax, p.z)
		ymax = maxf(ymax, p.y)
	if zmax <= Z0 + 0.001 or zmin >= Z1 - 0.001:
		(outs[0] as _Out).add(tri)
		return
	match kind:
		"handle":
			if zmin >= PANEL.x and zmax <= PANEL.y:
				(outs[1 if (zmin + zmax) * 0.5 < ZM else 2] as _Out).add(tri)
			else:
				(outs[0] as _Out).add(tri)
			return
		"frame":
			if ymax > TOP + 0.02:                    # стойки, импост, верхняя рама — неподвижны
				(outs[0] as _Out).add(tri)
				return
		"glass":
			if zmin < PANEL.x or zmax > PANEL.y:     # стекло соседних секций
				(outs[0] as _Out).add(tri)
				return
	var upper: Array = _clip(tri, 1, TOP, true)
	_emit(upper, outs[0])
	var lower: Array = _clip(tri, 1, TOP, false)
	_emit(_clip(lower, 2, Z0, false), outs[0])
	var rest: Array = _clip(lower, 2, Z0, true)
	_emit(_clip(rest, 2, ZM, false), outs[1])
	var rest2: Array = _clip(rest, 2, ZM, true)
	_emit(_clip(rest2, 2, Z1, false), outs[2])
	_emit(_clip(rest2, 2, Z1, true), outs[0])


## Многоугольник по одну сторону плоскости (ось axis = c): keep_greater — сторона, где координата больше.
func _clip(poly: Array, axis: int, c: float, keep_greater: bool) -> Array:
	var out := []
	var n: int = poly.size()
	if n < 3:
		return out
	var sgn: float = 1.0 if keep_greater else -1.0
	for i in n:
		var a: Dictionary = poly[i]
		var b: Dictionary = poly[(i + 1) % n]
		var da: float = ((a["p"] as Vector3)[axis] - c) * sgn
		var db: float = ((b["p"] as Vector3)[axis] - c) * sgn
		if da >= 0.0:
			out.append(a)
		if (da >= 0.0) != (db >= 0.0):
			out.append(_lerp_vertex(a, b, da / (da - db)))
	return out


## Многоугольник → треугольники веером (вырожденные — пропустить).
func _emit(poly: Array, o: _Out) -> void:
	if poly.size() < 3:
		return
	for i in range(1, poly.size() - 1):
		var tri := [poly[0], poly[i], poly[i + 1]]
		var area: float = ((tri[1]["p"] as Vector3) - (tri[0]["p"] as Vector3)).cross((tri[2]["p"] as Vector3) - (tri[0]["p"] as Vector3)).length()
		if area > 1e-7:
			o.add(tri)


func _vertex(arr: Array, i: int) -> Dictionary:
	var v := {"p": (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array)[i]}
	if arr[Mesh.ARRAY_NORMAL] != null:
		v["n"] = (arr[Mesh.ARRAY_NORMAL] as PackedVector3Array)[i]
	if arr[Mesh.ARRAY_TANGENT] != null:
		var t: PackedFloat32Array = arr[Mesh.ARRAY_TANGENT]
		v["t"] = Color(t[i * 4], t[i * 4 + 1], t[i * 4 + 2], t[i * 4 + 3])
	if arr[Mesh.ARRAY_COLOR] != null:
		v["c"] = (arr[Mesh.ARRAY_COLOR] as PackedColorArray)[i]
	if arr[Mesh.ARRAY_TEX_UV] != null:
		v["uv"] = (arr[Mesh.ARRAY_TEX_UV] as PackedVector2Array)[i]
	if arr[Mesh.ARRAY_TEX_UV2] != null:
		v["uv2"] = (arr[Mesh.ARRAY_TEX_UV2] as PackedVector2Array)[i]
	return v


func _lerp_vertex(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var v := {}
	for k in a:
		match k:
			"n":
				v[k] = (a[k] as Vector3).lerp(b[k], t).normalized()
			_:
				v[k] = lerp(a[k], b[k], t)
	return v


class _Out:
	var p := PackedVector3Array()
	var n := PackedVector3Array()
	var t := PackedFloat32Array()
	var c := PackedColorArray()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var has := {}

	func _init(src: Array) -> void:
		has = {"n": src[Mesh.ARRAY_NORMAL] != null, "t": src[Mesh.ARRAY_TANGENT] != null,
			"c": src[Mesh.ARRAY_COLOR] != null, "uv": src[Mesh.ARRAY_TEX_UV] != null,
			"uv2": src[Mesh.ARRAY_TEX_UV2] != null}

	func empty() -> bool:
		return p.is_empty()

	func add(tri: Array) -> void:
		for v in tri:
			p.append(v["p"])
			if has["n"]:
				n.append(v["n"])
			if has["t"]:
				var tc: Color = v["t"]
				t.append_array(PackedFloat32Array([tc.r, tc.g, tc.b, 1.0 if tc.a >= 0.0 else -1.0]))
			if has["c"]:
				c.append(v["c"])
			if has["uv"]:
				uv.append(v["uv"])
			if has["uv2"]:
				uv2.append(v["uv2"])

	func shift(d: Vector3) -> void:
		for i in p.size():
			p[i] += d

	func arrays() -> Array:
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = p
		if has["n"]:
			a[Mesh.ARRAY_NORMAL] = n
		if has["t"]:
			a[Mesh.ARRAY_TANGENT] = t
		if has["c"]:
			a[Mesh.ARRAY_COLOR] = c
		if has["uv"]:
			a[Mesh.ARRAY_TEX_UV] = uv
		if has["uv2"]:
			a[Mesh.ARRAY_TEX_UV2] = uv2
		return a
