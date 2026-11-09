@tool
class_name RoadBuilder
extends Node3D
## Builds the single continuous road from the centreline baked by tools/world_gen.py.
##
## Cross-section (metres from the centreline, heights relative to it):
##   0 .. 4.10   asphalt, 2 % crown            (two 3.4 m lanes + 0.7 m paved strip)
##   4.10 .. 4.16  asphalt edge (4 cm drop)
##   4.16 .. 5.00  gravel shoulder
##   5.00 .. 5.02  skirt down into the terrain (hides the joint with the ditch)
## Sections are emitted adaptively: every ~5 m on straights, every ~1.5 m in curves / crests.
## UV.x = lateral offset (left +), UV.y = distance along the road; the road shader works in that space.

const COLS := [
	[-5.02, -0.62], [-5.0, -0.20], [-4.16, -0.12], [-4.10, -0.082], [-2.0, -0.04], [0.0, 0.0],
	[2.0, -0.04], [4.10, -0.082], [4.16, -0.12], [5.0, -0.20], [5.02, -0.62],
]

@export var material: ShaderMaterial
@export var max_step := 3.5
@export var min_step := 1.25

var points := PackedVector3Array()      # 1 m samples, closed loop
var length := 0.0
var lane_width := 3.4
var mesh_instance: MeshInstance3D
var triangles := 0
var sections := 0


func build(road: Dictionary, with_physics := true) -> void:
	for p in road["points"]:
		points.append(Vector3(p[0], p[1], p[2]))
	length = float(road["length"])
	lane_width = float(road.get("lane_width", 3.4))
	var keep := _adaptive_sections()
	sections = keep.size()
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var tangents := PackedFloat32Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var faces := PackedVector3Array()
	var nc := COLS.size()
	for k in keep.size() + 1:
		var i: int = keep[k % keep.size()]
		var s := float(i) if k < keep.size() else float(points.size())
		var c := points[i]
		var fwd := _tangent(i)
		var left := Vector3(-fwd.z, 0.0, fwd.x).normalized()
		for col in COLS:
			var o: float = col[0]
			var h: float = col[1]
			verts.append(c + left * o + Vector3(0.0, h, 0.0))
			# the skirt drops 0.4 m over 2 cm: spread its texture coordinate so the gravel is not stretched
			uvs.append(Vector2(signf(o) * 5.42 if absf(o) > 5.01 else o, s))
			# normals: up for the surface, outward for the skirts (refined below)
			normals.append(Vector3.UP)
			tangents.append_array([left.x, left.y, left.z, -1.0])
	var rows := keep.size() + 1
	for r in rows - 1:
		for j in nc - 1:
			var a := r * nc + j
			var b := a + 1
			var c2 := a + nc
			var d := c2 + 1
			# same winding as the terrain grid (Godot: clockwise = front face)
			idx.append_array([a, c2, b, b, c2, d])
			if j > 0 and j < nc - 2:
				faces.append_array([verts[a], verts[c2], verts[b], verts[b], verts[c2], verts[d]])
	# smooth normals from the surface
	var acc := PackedVector3Array()
	acc.resize(verts.size())
	acc.fill(Vector3.ZERO)
	for t in range(0, idx.size(), 3):
		var n := (verts[idx[t + 2]] - verts[idx[t]]).cross(verts[idx[t + 1]] - verts[idx[t]])
		for q in 3:
			acc[idx[t + q]] += n
	for v in verts.size():
		var n := acc[v]
		normals[v] = n.normalized() if n.length() > 1e-9 else Vector3.UP
		if normals[v].y < 0.0:
			normals[v] = -normals[v]
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_TANGENT] = tangents
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_material(0, material)
	mesh.resource_name = "road"
	triangles = idx.size() / 3
	mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "RoadMesh"
	mesh_instance.mesh = mesh
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh_instance)
	if not with_physics:
		return
	var body := StaticBody3D.new()
	body.name = "RoadCollision"
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	shape.backface_collision = true
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	add_child(body)


func _tangent(i: int) -> Vector3:
	var n := points.size()
	var t := points[(i + 1) % n] - points[(i - 1 + n) % n]
	t.y = 0.0
	return t.normalized()


func _adaptive_sections() -> PackedInt32Array:
	var keep := PackedInt32Array([0])
	var n := points.size()
	var last := 0
	for i in range(1, n):
		var span := float(i - last)
		var turn := _tangent(last).angle_to(_tangent(i))
		var g0 := points[(last + 1) % n].y - points[last].y
		var g1 := points[(i + 1) % n].y - points[i].y
		var vert := absf(g1 - g0)
		if span >= max_step or (span >= min_step and (turn > deg_to_rad(1.1) or vert > 0.006)):
			keep.append(i)
			last = i
	return keep


## Position on the road at distance s, with lateral offset (left +) and the road heading.
func sample(s: float, lateral := 0.0) -> Transform3D:
	var n := points.size()
	s = fposmod(s, float(n))
	var i := int(s)
	var f := s - i
	var p := points[i].lerp(points[(i + 1) % n], f)
	var fwd := _tangent(i).lerp(_tangent((i + 1) % n), f).normalized()
	var left := Vector3(-fwd.z, 0.0, fwd.x)
	var pos := p + left * lateral + Vector3(0, -0.02 * minf(absf(lateral), 4.1), 0)
	var slope := (points[(i + 2) % n].y - points[(i - 1 + n) % n].y) / 3.0
	var forward := Vector3(fwd.x, slope, fwd.z).normalized()
	return Transform3D(Basis.looking_at(forward, Vector3.UP), pos)


## Nearest road distance s for a world position (coarse search, used for respawn / autopilot).
func nearest_s(pos: Vector3) -> float:
	var best := INF
	var bi := 0
	for i in range(0, points.size(), 4):
		var d := Vector2(points[i].x - pos.x, points[i].z - pos.z).length_squared()
		if d < best:
			best = d
			bi = i
	for i in range(bi - 4, bi + 5):
		var j := posmod(i, points.size())
		var d := Vector2(points[j].x - pos.x, points[j].z - pos.z).length_squared()
		if d < best:
			best = d
			bi = j
	return float(bi)


## Signed lateral distance of a point from the centreline (left +).
func lateral_offset(pos: Vector3) -> float:
	var s := nearest_s(pos)
	var i := int(s)
	var fwd := _tangent(i)
	var left := Vector3(-fwd.z, 0.0, fwd.x)
	var rel := pos - points[i]
	return rel.x * left.x + rel.z * left.z
