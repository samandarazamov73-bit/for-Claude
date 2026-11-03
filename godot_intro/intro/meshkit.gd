extends RefCounted
## Копилка геометрии: складывает коробки, цилиндры, четырёхугольники в ОДИН меш.
## Цвет хранится в вершинах (материал с vertex_color_use_as_albedo). Мало мешей — мало нагрузки на видеокарту.

var verts: PackedVector3Array = PackedVector3Array()
var norms: PackedVector3Array = PackedVector3Array()
var uvs: PackedVector2Array = PackedVector2Array()
var cols: PackedColorArray = PackedColorArray()
var idx: PackedInt32Array = PackedInt32Array()


func is_empty() -> bool:
	return verts.size() == 0


## Четырёхугольник a-b-c-d. n — наружная нормаль; порядок вершин подбирается сам (в Godot лицевая сторона — по часовой стрелке).
func add_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, color: Color,
		ua: Vector2 = Vector2(0, 0), ub: Vector2 = Vector2(1, 0), uc: Vector2 = Vector2(1, 1), ud: Vector2 = Vector2(0, 1)) -> void:
	var base: int = verts.size()
	verts.append(a)
	verts.append(b)
	verts.append(c)
	verts.append(d)
	uvs.append(ua)
	uvs.append(ub)
	uvs.append(uc)
	uvs.append(ud)
	for i in 4:
		norms.append(n)
		cols.append(color)
	var cr: Vector3 = (b - a).cross(c - a)
	if cr.dot(n) > 0.0:
		idx.append_array(PackedInt32Array([base, base + 2, base + 1, base, base + 3, base + 2]))
	else:
		idx.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))


## Добавляет готовую примитивную форму (BoxMesh, CylinderMesh…) с трансформом и цветом.
func add_prim(mesh: PrimitiveMesh, xf: Transform3D, color: Color) -> void:
	var arr: Array = mesh.get_mesh_arrays()
	var pv: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var pn: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var pu: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
	var pi: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var base: int = verts.size()
	var nb: Basis = xf.basis.inverse().transposed()
	for i in pv.size():
		verts.append(xf * pv[i])
		norms.append((nb * pn[i]).normalized())
		if i < pu.size():
			uvs.append(pu[i])
		else:
			uvs.append(Vector2.ZERO)
		cols.append(color)
	for i in pi.size():
		idx.append(base + pi[i])


func add_box(center: Vector3, size: Vector3, color: Color, rot: Vector3 = Vector3.ZERO) -> void:
	var m: BoxMesh = BoxMesh.new()
	m.size = Vector3.ONE
	var xf: Transform3D = Transform3D(Basis.from_euler(rot) * Basis.from_scale(size), center)
	add_prim(m, xf, color)


## Цилиндр (ось вдоль Y до поворота rot). r_bottom/r_top — радиусы снизу/сверху.
func add_cyl(center: Vector3, r_bottom: float, r_top: float, height: float, color: Color,
		rot: Vector3 = Vector3.ZERO, segs: int = 10) -> void:
	var m: CylinderMesh = CylinderMesh.new()
	m.bottom_radius = r_bottom
	m.top_radius = r_top
	m.height = 1.0
	m.radial_segments = segs
	m.rings = 1
	var xf: Transform3D = Transform3D(Basis.from_euler(rot) * Basis.from_scale(Vector3(1.0, height, 1.0)), center)
	add_prim(m, xf, color)


func add_sphere(center: Vector3, radius: float, color: Color, scale: Vector3 = Vector3.ONE, segs: int = 12) -> void:
	var m: SphereMesh = SphereMesh.new()
	m.radius = radius
	m.height = radius * 2.0
	m.radial_segments = segs
	m.rings = maxi(segs / 2, 4)
	var xf: Transform3D = Transform3D(Basis.from_scale(scale), center)
	add_prim(m, xf, color)


func add_capsule(center: Vector3, radius: float, height: float, color: Color,
		rot: Vector3 = Vector3.ZERO, scale: Vector3 = Vector3.ONE, segs: int = 8) -> void:
	var m: CapsuleMesh = CapsuleMesh.new()
	m.radius = radius
	m.height = maxf(height, radius * 2.0 + 0.001)
	m.radial_segments = segs
	m.rings = 4
	var xf: Transform3D = Transform3D(Basis.from_euler(rot) * Basis.from_scale(scale), center)
	add_prim(m, xf, color)


func add_torus(center: Vector3, inner: float, outer: float, color: Color, rot: Vector3 = Vector3.ZERO) -> void:
	var m: TorusMesh = TorusMesh.new()
	m.inner_radius = inner
	m.outer_radius = outer
	m.rings = 14
	m.ring_segments = 8
	add_prim(m, Transform3D(Basis.from_euler(rot), center), color)


func build_mesh() -> ArrayMesh:
	var mesh: ArrayMesh = ArrayMesh.new()
	if verts.size() == 0:
		return mesh
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func build(material: Material, cast_shadow: bool = true) -> MeshInstance3D:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = build_mesh()
	mi.material_override = material
	if not cast_shadow:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi
