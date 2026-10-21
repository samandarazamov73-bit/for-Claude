class_name GeoBatch
extends RefCounted
## Accumulates procedural geometry per material and commits it as one ArrayMesh
## (one surface per material). Used for roads, sidewalks, roofs, signs and LOD shells,
## so a whole city block costs only a handful of draw calls.

class Surface:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var tangents := PackedFloat32Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var colors := PackedColorArray()
	var custom0 := PackedFloat32Array()
	var indices := PackedInt32Array()
	var use_uv2 := false
	var use_custom0 := false

var surfaces := {}  # Material -> Surface
var _cur: Surface
var _cur_mat: Material
var color := Color(1, 1, 1, 1)
var uv2 := Vector2.ZERO
var custom := Color(0, 0, 0, 0)


func set_material(mat: Material, with_uv2 := false, with_custom0 := false) -> void:
	_cur_mat = mat
	if not surfaces.has(mat):
		var s := Surface.new()
		s.use_uv2 = with_uv2
		s.use_custom0 = with_custom0
		surfaces[mat] = s
	_cur = surfaces[mat]


func is_empty() -> bool:
	for s in surfaces.values():
		if s.verts.size() > 0:
			return false
	return true


func vertex_count() -> int:
	var n := 0
	for s in surfaces.values():
		n += s.verts.size()
	return n


func _push(p: Vector3, n: Vector3, uv: Vector2, t: Vector3) -> void:
	var s := _cur
	s.verts.append(p)
	s.normals.append(n)
	s.uvs.append(uv)
	s.tangents.append(t.x)
	s.tangents.append(t.y)
	s.tangents.append(t.z)
	s.tangents.append(1.0)
	s.colors.append(color)
	if s.use_uv2:
		s.uv2s.append(uv2)
	if s.use_custom0:
		s.custom0.append(custom.r)
		s.custom0.append(custom.g)
		s.custom0.append(custom.b)
		s.custom0.append(custom.a)


## Quad p0..p3 counter-clockwise when seen from the front (normal side).
func add_quad(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
		uv0: Vector2, uv1: Vector2, uv2_: Vector2, uv3: Vector2) -> void:
	var n := (p1 - p0).cross(p3 - p0).normalized()
	if n == Vector3.ZERO:
		return
	# tangent = direction of +u
	var du1 := uv1.x - uv0.x
	var du3 := uv3.x - uv0.x
	var dv1 := uv1.y - uv0.y
	var dv3 := uv3.y - uv0.y
	var det := du1 * dv3 - du3 * dv1
	var t: Vector3
	if absf(det) > 1e-8:
		t = ((p1 - p0) * dv3 - (p3 - p0) * dv1) / det
	else:
		t = p1 - p0
	t = (t - n * n.dot(t)).normalized()
	if t == Vector3.ZERO:
		t = n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
	var base := _cur.verts.size()
	_push(p0, n, uv0, t)
	_push(p1, n, uv1, t)
	_push(p2, n, uv2_, t)
	_push(p3, n, uv3, t)
	_cur.indices.append_array([base, base + 2, base + 1, base, base + 3, base + 2])


## Quad whose front side is chosen by `facing` (vertex order does not matter as long as it is a loop).
func add_quad_facing(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, facing: Vector3,
		uv0 := Vector2.ZERO, uv1 := Vector2.ZERO, uv2_ := Vector2.ZERO, uv3 := Vector2.ZERO) -> void:
	if (p1 - p0).cross(p3 - p0).dot(facing) < 0.0:
		add_quad(p3, p2, p1, p0, uv3, uv2_, uv1, uv0)
	else:
		add_quad(p0, p1, p2, p3, uv0, uv1, uv2_, uv3)


func add_tri_facing(p0: Vector3, p1: Vector3, p2: Vector3, facing: Vector3,
		uv0 := Vector2.ZERO, uv1 := Vector2.ZERO, uv2_ := Vector2.ZERO) -> void:
	if (p1 - p0).cross(p2 - p0).dot(facing) < 0.0:
		add_tri(p0, p2, p1, uv0, uv2_, uv1)
	else:
		add_tri(p0, p1, p2, uv0, uv1, uv2_)


## Triangle (CCW seen from the front).
func add_tri(p0: Vector3, p1: Vector3, p2: Vector3, uv0: Vector2, uv1: Vector2, uv2_: Vector2) -> void:
	var n := (p1 - p0).cross(p2 - p0).normalized()
	if n == Vector3.ZERO:
		return
	var t := (p1 - p0).normalized()
	var base := _cur.verts.size()
	_push(p0, n, uv0, t)
	_push(p1, n, uv1, t)
	_push(p2, n, uv2_, t)
	_cur.indices.append_array([base, base + 2, base + 1])


## Axis-aligned (in `xf` space) box. uv_mode: 0 = world-metre UVs per face, 1 = unit 0..1 per face.
func add_box(xf: Transform3D, size: Vector3, uv_mode := 0, faces := 0x3F) -> void:
	var h := size * 0.5
	var c := [
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z),
		Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z)]
	for i in 8:
		c[i] = xf * c[i]
	# faces: +Z, -Z, +X, -X, +Y, -Y  (each listed CCW seen from outside, bottom-left first)
	var f := [
		[4, 5, 6, 7, size.x, size.y], [1, 0, 3, 2, size.x, size.y],
		[5, 1, 2, 6, size.z, size.y], [0, 4, 7, 3, size.z, size.y],
		[7, 6, 2, 3, size.x, size.z], [0, 1, 5, 4, size.x, size.z]]
	for i in 6:
		if (faces >> i) & 1 == 0:
			continue
		var q: Array = f[i]
		var w: float = q[4] if uv_mode == 0 else 1.0
		var hh: float = q[5] if uv_mode == 0 else 1.0
		add_quad(c[q[0]], c[q[1]], c[q[2]], c[q[3]], Vector2(0, hh), Vector2(w, hh), Vector2(w, 0), Vector2(0, 0))


## Vertical cylinder / cone frustum along +Y from `base`.
func add_cylinder(base: Vector3, r0: float, r1: float, height: float, sides := 8, caps := true, uv_scale := Vector2(1, 1)) -> void:
	var circ := TAU * maxf(r0, r1)
	for i in sides:
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		var d0 := Vector3(cos(a0), 0, sin(a0))
		var d1 := Vector3(cos(a1), 0, sin(a1))
		var u0 := float(i) / sides * circ * uv_scale.x
		var u1 := float(i + 1) / sides * circ * uv_scale.x
		add_quad(base + d1 * r0, base + d0 * r0, base + d0 * r1 + Vector3(0, height, 0), base + d1 * r1 + Vector3(0, height, 0),
			Vector2(u1, height * uv_scale.y), Vector2(u0, height * uv_scale.y), Vector2(u0, 0), Vector2(u1, 0))
		if caps:
			var top := base + Vector3(0, height, 0)
			add_tri(top, top + d1 * r1, top + d0 * r1, Vector2(0.5, 0.5), Vector2(0.5 + d1.x * 0.5, 0.5 + d1.z * 0.5), Vector2(0.5 + d0.x * 0.5, 0.5 + d0.z * 0.5))


## Cylinder between two arbitrary points (pipes, rails, branches).
func add_tube(a: Vector3, b: Vector3, r0: float, r1: float, sides := 6) -> void:
	var axis := b - a
	var len := axis.length()
	if len < 1e-4:
		return
	var y := axis / len
	var x := y.cross(Vector3.UP if absf(y.y) < 0.95 else Vector3.RIGHT).normalized()
	var z := x.cross(y)
	var basis := Basis(x, y, z)
	for i in sides:
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		var d0 := basis * Vector3(cos(a0), 0, sin(a0))
		var d1 := basis * Vector3(cos(a1), 0, sin(a1))
		add_quad(a + d1 * r0, a + d0 * r0, b + d0 * r1, b + d1 * r1,
			Vector2(float(i + 1) / sides, len), Vector2(float(i) / sides, len), Vector2(float(i) / sides, 0), Vector2(float(i + 1) / sides, 0))


func commit(mesh: ArrayMesh = null) -> ArrayMesh:
	if mesh == null:
		mesh = ArrayMesh.new()
	for mat in surfaces:
		var s: Surface = surfaces[mat]
		if s.verts.is_empty():
			continue
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = s.verts
		arr[Mesh.ARRAY_NORMAL] = s.normals
		arr[Mesh.ARRAY_TANGENT] = s.tangents
		arr[Mesh.ARRAY_TEX_UV] = s.uvs
		arr[Mesh.ARRAY_COLOR] = s.colors
		arr[Mesh.ARRAY_INDEX] = s.indices
		var flags := 0
		if s.use_uv2:
			arr[Mesh.ARRAY_TEX_UV2] = s.uv2s
		if s.use_custom0:
			arr[Mesh.ARRAY_CUSTOM0] = s.custom0
			flags |= Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {}, flags)
		mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
	return mesh
