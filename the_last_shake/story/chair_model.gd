extends RefCounted
## Коляска с героем (intro/assets/models/wheelchair.glb) — одна и та же в автобусе, в лесу и в здании.
## Когда едешь, ручка джойстика наклоняется вокруг основания, а кисть Самана, держащая её сверху, целиком
## сдвигается вслед за верхом ручки (как рука на настоящем джойстике). Ручку и кисть находим как отдельные куски
## модели (связные части меша), поэтому кисть никогда не рвётся (set_input).
## Модель смотрит в +Z и мельче настоящей: разворот на 180°, ×1,2, колёса на пол.

const MODEL := "res://intro/assets/models/wheelchair.glb"
const SCALE := 1.2
const LIFT := 0.552
# джойстик в координатах модели (м): границы кусков «кисть» и «ручка», основание ручки и точка хвата
const HAND_BOX := AABB(Vector3(-0.313, 0.178, 0.0), Vector3(0.113, 0.090, 0.125))
const KNOB_BOX := AABB(Vector3(-0.286, 0.160, 0.079), Vector3(0.061, 0.029, 0.059))
const KNOB_BASE := Vector3(-0.2555, 0.160, 0.1085)
const GRIP := Vector3(-0.2555, 0.189, 0.1085)
const TILT := 0.26              # рад — наклон ручки до упора (кисть сдвигается на ~8 мм)

var root: Node3D
var stick: Node3D               # ручка: поворачивается вокруг основания
var hand: Node3D                # кисть: сдвигается за верхом ручки, не поворачиваясь


## Строит коляску под parent. Возвращает false, если модели нет.
func build(parent: Node3D) -> bool:
	var res: Resource = load(MODEL) if ResourceLoader.exists(MODEL) else null
	if not (res is PackedScene):
		return false
	root = Node3D.new()
	root.name = "WheelchairModel"
	root.position.y = LIFT
	root.rotation.y = PI
	root.scale = Vector3.ONE * SCALE
	parent.add_child(root)
	var inst: Node = (res as PackedScene).instantiate()
	root.add_child(inst)
	for gi in root.find_children("*", "GeometryInstance3D", true, false):
		(gi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var meshes: Array = inst.find_children("*", "MeshInstance3D", true, false)
	if not meshes.is_empty():
		_split_stick(meshes[0])
	return true


func _split_stick(mi: MeshInstance3D) -> void:
	var src: Mesh = mi.mesh
	if src == null or src.get_surface_count() != 1:
		return
	var arr: Array = src.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	if idx.is_empty():
		return
	# связные части: вершины с одинаковой позицией — одна точка; треугольник связывает свои точки
	var weld := {}
	var wid := PackedInt32Array()
	wid.resize(verts.size())
	for i in verts.size():
		var v: Vector3 = verts[i]
		var key := Vector3i(roundi(v.x * 100000.0), roundi(v.y * 100000.0), roundi(v.z * 100000.0))
		var w: int = weld.get(key, -1)
		if w < 0:
			w = weld.size()
			weld[key] = w
		wid[i] = w
	var par := PackedInt32Array()
	par.resize(weld.size())
	for i in par.size():
		par[i] = i
	for t in range(0, idx.size(), 3):
		var roots := []
		for k in 3:
			var x: int = wid[idx[t + k]]
			while par[x] != x:
				par[x] = par[par[x]]
				x = par[x]
			roots.append(x)
		par[roots[1]] = roots[0]
		par[roots[2]] = roots[0]
	var tri_root := PackedInt32Array()
	tri_root.resize(idx.size() / 3)
	var boxes := {}
	for t in tri_root.size():
		var x: int = wid[idx[t * 3]]
		while par[x] != x:
			x = par[x]
		tri_root[t] = x
		for k in 3:
			var p: Vector3 = verts[idx[t * 3 + k]]
			if boxes.has(x):
				boxes[x] = (boxes[x] as AABB).expand(p)
			else:
				boxes[x] = AABB(p, Vector3.ZERO)
	var hand_c: int = _match(boxes, HAND_BOX)
	var knob_c: int = _match(boxes, KNOB_BOX)
	if hand_c < 0 or knob_c < 0:
		push_warning("коляска: не нашла кисть или ручку джойстика — джойстик будет неподвижным")
		return
	var body_idx := PackedInt32Array()
	var knob_idx := PackedInt32Array()
	var hand_idx := PackedInt32Array()
	for t in tri_root.size():
		var tri := PackedInt32Array([idx[t * 3], idx[t * 3 + 1], idx[t * 3 + 2]])
		if tri_root[t] == hand_c:
			hand_idx.append_array(tri)
		elif tri_root[t] == knob_c:
			knob_idx.append_array(tri)
		else:
			body_idx.append_array(tri)
	var mat: Material = src.surface_get_material(0)
	if mat == null:
		mat = mi.get_active_material(0)
	mi.mesh = _part(arr, body_idx, Vector3.ZERO, mat)
	stick = Node3D.new()
	stick.name = "JoystickKnob"
	stick.position = KNOB_BASE
	mi.add_child(stick)
	stick.add_child(_part_instance(_part(arr, knob_idx, KNOB_BASE, mat), mi))
	hand = Node3D.new()
	hand.name = "JoystickHand"
	hand.position = GRIP
	mi.add_child(hand)
	hand.add_child(_part_instance(_part(arr, hand_idx, GRIP, mat), mi))


## Связная часть, у которой границы совпадают с ожидаемыми (±5 мм), или −1.
func _match(boxes: Dictionary, want: AABB) -> int:
	for c in boxes:
		var b: AABB = boxes[c]
		if b.position.distance_to(want.position) < 0.005 and b.end.distance_to(want.end) < 0.005:
			return c
	return -1


func _part(arr: Array, part_idx: PackedInt32Array, origin: Vector3, mat: Material) -> ArrayMesh:
	var a: Array = arr.duplicate()
	if origin != Vector3.ZERO:
		var src: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var moved := PackedVector3Array()
		moved.resize(src.size())
		for i in src.size():
			moved[i] = src[i] - origin
		a[Mesh.ARRAY_VERTEX] = moved
	a[Mesh.ARRAY_INDEX] = part_idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	m.surface_set_material(0, mat)
	return m


func _part_instance(m: ArrayMesh, like: MeshInstance3D) -> MeshInstance3D:
	var smi := MeshInstance3D.new()
	smi.mesh = m
	smi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	smi.layers = like.layers
	return smi


## Ручка джойстика: forward −1..1 (вперёд / назад), turn −1..1 (влево / вправо). Плавно.
## Ручка наклоняется вокруг основания, кисть сдвигается ровно туда, куда ушёл верх ручки.
func set_input(forward: float, turn: float, dt: float) -> void:
	if stick == null:
		return
	var k: float = 1.0 - exp(-14.0 * dt)
	var want := Vector3(clampf(forward, -1.0, 1.0) * TILT, 0.0, clampf(turn, -1.0, 1.0) * TILT)
	stick.rotation = stick.rotation.lerp(want, k)
	if hand:
		hand.position = KNOB_BASE + Basis.from_euler(stick.rotation) * (GRIP - KNOB_BASE)
