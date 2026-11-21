extends RefCounted
## Коляска с героем (intro/assets/models/wheelchair.glb) — одна и та же в автобусе, в лесу и в здании.
## Когда едешь, ручка джойстика наклоняется вокруг основания, а кисть Азиза, держащая её сверху, целиком
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
# пульт: корпус из модели (коробка с кнопками) заменяется подробным (_build_controller)
const HOUSING_BOX := AABB(Vector3(-0.315, 0.094, 0.065), Vector3(0.112, 0.069, 0.147))
const TOP_PARTS := AABB(Vector3(-0.32, 0.154, 0.135), Vector3(0.12, 0.03, 0.08))   # старые кнопки и лампочка
const HOUSING_C := Vector3(-0.259, 0.1265, 0.1385)
const HOUSING_S := Vector3(0.108, 0.067, 0.146)
const TOP_Y := 0.160

var root: Node3D
var stick: Node3D               # ручка: поворачивается вокруг основания
var hand: Node3D                # кисть: сдвигается за верхом ручки, не поворачиваясь
var leds: Array = []            # 5 лампочек скорости на пульте
var _led_on: StandardMaterial3D
var _led_off: StandardMaterial3D


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
	var drop := {}                                   # старый пульт: корпус и мелкие детали на крышке
	var housing_c: int = _match(boxes, HOUSING_BOX)
	if housing_c >= 0:
		drop[housing_c] = true
		for c in boxes:
			if c != knob_c and c != hand_c and TOP_PARTS.encloses(boxes[c]):
				drop[c] = true
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
		elif drop.has(tri_root[t]):
			continue
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
	if not drop.is_empty():
		_build_controller(mi)


## Пульт электроколяски (координаты модели, она мельче настоящей в 1,2 раза): скруглённый корпус из тёмного
## пластика, мягкая панель спереди с кнопками (питание с зелёной подсветкой, звонок, «−» и «+» скорости),
## полоска из пяти лампочек — сколько горит, такая скорость; у основания ручки — резиновый чехол.
func _build_controller(mi: MeshInstance3D) -> void:
	var ctl := Node3D.new()
	ctl.name = "Controller"
	mi.add_child(ctl)
	var plastic := _mat(Color(0.055, 0.058, 0.063), 0.42, 0.0, 0.45)
	var panel := _mat(Color(0.11, 0.115, 0.12), 0.68)
	var rubber := _mat(Color(0.03, 0.03, 0.032), 0.85)
	var metal := _mat(Color(0.55, 0.56, 0.58), 0.3, 0.9)
	var white := _mat(Color(0.82, 0.82, 0.8), 0.6)
	_add(ctl, _rounded_box(HOUSING_S, 0.011), HOUSING_C, plastic)
	# тонкий шов между верхом и низом корпуса
	_add(ctl, _rounded_box(HOUSING_S + Vector3(0.0015, -0.062, 0.0015), 0.004), HOUSING_C + Vector3(0, -0.006, 0), rubber)
	# мягкая панель с кнопками (передняя часть крышки)
	var pz := 0.176
	_add(ctl, _rounded_box(Vector3(0.094, 0.0016, 0.06), 0.0008), Vector3(HOUSING_C.x, TOP_Y + 0.0008, pz), panel)
	# кнопки: питание, «−», «+», звонок
	var bx := [-0.292, -0.272, -0.246, -0.226]
	for i in bx.size():
		var b := CylinderMesh.new()
		b.top_radius = 0.0062
		b.bottom_radius = 0.0068
		b.height = 0.0032
		b.radial_segments = 20
		b.rings = 1
		_add(ctl, b, Vector3(bx[i], TOP_Y + 0.0026, 0.164), rubber)
	# значки на кнопках
	var marks := ["ВКЛ", "-", "+", "СИГН"]
	for i in marks.size():
		var lb := Label3D.new()
		lb.text = marks[i]
		lb.font_size = 32
		lb.pixel_size = 0.00018 if marks[i].length() == 1 else 0.00008
		lb.modulate = Color(0.85, 0.85, 0.82)
		lb.outline_size = 0
		lb.rotation = Vector3(-PI * 0.5, PI, 0)
		lb.position = Vector3(bx[i], TOP_Y + 0.0043, 0.164)
		ctl.add_child(lb)
	# кольцо подсветки вокруг кнопки питания
	var ring := TorusMesh.new()
	ring.inner_radius = 0.0068
	ring.outer_radius = 0.0078
	ring.rings = 24
	ring.ring_segments = 6
	_led_on = StandardMaterial3D.new()
	_led_on.albedo_color = Color(0.25, 1.0, 0.35)
	_led_on.emission_enabled = true
	_led_on.emission = Color(0.25, 1.0, 0.35)
	_led_on.emission_energy_multiplier = 2.2
	_led_off = _mat(Color(0.05, 0.09, 0.06), 0.3)
	_add(ctl, ring, Vector3(bx[0], TOP_Y + 0.0018, 0.164), _led_on)
	# пять лампочек скорости
	for i in 5:
		var led := _add(ctl, _rounded_box(Vector3(0.011, 0.002, 0.0045), 0.0008),
			Vector3(-0.287 + i * 0.0135, TOP_Y + 0.0019, 0.192), _led_off)
		leds.append(led)
	var tag := Label3D.new()
	tag.text = "СКОРОСТЬ"
	tag.font_size = 24
	tag.pixel_size = 0.00012
	tag.modulate = Color(0.7, 0.7, 0.68)
	tag.rotation = Vector3(-PI * 0.5, PI, 0)
	tag.position = Vector3(HOUSING_C.x, TOP_Y + 0.0018, 0.2005)
	ctl.add_child(tag)
	# хромированное кольцо и резиновый чехол у основания ручки (наклоняется вместе с ней)
	var collar := TorusMesh.new()
	collar.inner_radius = 0.0125
	collar.outer_radius = 0.016
	collar.rings = 24
	collar.ring_segments = 8
	_add(ctl, collar, Vector3(KNOB_BASE.x, TOP_Y + 0.0012, KNOB_BASE.z), metal)
	var boot := CylinderMesh.new()
	boot.top_radius = 0.006
	boot.bottom_radius = 0.0135
	boot.height = 0.013
	boot.radial_segments = 20
	boot.rings = 3
	if stick:
		_add(stick, boot, Vector3(0, 0.0055, 0), rubber)
	# винты крепления к кронштейну по бокам
	for sx in [-1.0, 1.0]:
		var sc := CylinderMesh.new()
		sc.top_radius = 0.0035
		sc.bottom_radius = 0.0035
		sc.height = 0.003
		sc.radial_segments = 12
		var screw := _add(ctl, sc, HOUSING_C + Vector3(sx * (HOUSING_S.x * 0.5 + 0.001), -0.012, -0.03), metal)
		screw.rotation.z = PI * 0.5
	set_speed(2)
	for gi in ctl.find_children("*", "GeometryInstance3D", true, false):
		(gi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		(gi as GeometryInstance3D).layers = mi.layers


## Лампочки скорости: горит level + 1 из пяти.
func set_speed(level: int) -> void:
	for i in leds.size():
		(leds[i] as MeshInstance3D).material_override = _led_on if i <= level else _led_off


func _mat(c: Color, rough: float, metal := 0.0, spec := 0.5) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	m.metallic_specular = spec
	return m


func _add(parent: Node3D, mesh: Mesh, pos: Vector3, m: Material) -> MeshInstance3D:
	var x := MeshInstance3D.new()
	x.mesh = mesh
	x.material_override = m
	x.position = pos
	parent.add_child(x)
	return x


## Коробка со скруглёнными рёбрами радиуса r (сетка куба, точки рёбер переносятся на скругление).
static func _rounded_box(size: Vector3, r: float, seg := 4) -> ArrayMesh:
	var H: Vector3 = size * 0.5
	r = minf(r, minf(H.x, minf(H.y, H.z)) * 0.95)
	var h: Vector3 = H - Vector3(r, r, r)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var coords := []
	for ax in 3:
		var c := []
		for k in seg + 1:
			c.append(-H[ax] + r * float(k) / seg)
		for k in seg + 1:
			c.append(h[ax] + r * float(k) / seg)
		coords.append(c)
	for ax in 3:
		for sgn in [-1.0, 1.0]:
			var u: int = (ax + 1) % 3
			var v: int = (ax + 2) % 3
			var cu: Array = coords[u]
			var cv: Array = coords[v]
			var grid := []
			for iu in cu.size():
				var row := []
				for iv in cv.size():
					var q := Vector3.ZERO
					q[ax] = sgn * H[ax]
					q[u] = cu[iu]
					q[v] = cv[iv]
					var inner := Vector3(clampf(q.x, -h.x, h.x), clampf(q.y, -h.y, h.y), clampf(q.z, -h.z, h.z))
					var d: Vector3 = q - inner
					var n: Vector3 = d.normalized() if d.length() > 1e-6 else Vector3.ZERO
					row.append([inner + n * r, n])
				grid.append(row)
			for iu in cu.size() - 1:
				for iv in cv.size() - 1:
					var a: Array = grid[iu][iv]
					var b: Array = grid[iu + 1][iv]
					var c2: Array = grid[iu + 1][iv + 1]
					var d2: Array = grid[iu][iv + 1]
					var face_n: Vector3 = (a[1] + b[1] + c2[1] + d2[1]).normalized()
					var tri1 := [a, b, c2]
					var tri2 := [a, c2, d2]
					for tri in [tri1, tri2]:
						var p0: Vector3 = tri[0][0]
						var p1: Vector3 = tri[1][0]
						var p2: Vector3 = tri[2][0]
						if (p1 - p0).cross(p2 - p0).length() < 1e-10:
							continue
						# Godot: лицевая сторона — по часовой стрелке, если смотреть снаружи
						var order := [0, 1, 2] if (p1 - p0).cross(p2 - p0).dot(face_n) < 0.0 else [0, 2, 1]
						for k in order:
							st.set_normal(tri[k][1])
							st.add_vertex(tri[k][0])
	return st.commit()


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
