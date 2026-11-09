extends RefCounted
## Коляска с героем (intro/assets/models/wheelchair.glb) — одна и та же в автобусе, в лесу и в здании.
## Ручка джойстика вместе с ладонью вырезается из модели на лету и наклоняется, когда едешь (set_input).
## Модель смотрит в +Z и мельче настоящей: разворот на 180°, ×1,2, колёса на пол.

const MODEL := "res://intro/assets/models/wheelchair.glb"
const SCALE := 1.2
const LIFT := 0.552
# джойстик в координатах модели: ручка над пультом и ладонь на ней
const STICK_MIN := Vector3(-0.31, 0.164, 0.02)
const STICK_MAX := Vector3(-0.195, 0.27, 0.16)
const PIVOT := Vector3(-0.262, 0.163, 0.11)
const TILT := 0.26              # рад — наклон ручки до упора

var root: Node3D
var stick: Node3D               # поворачивается вокруг основания ручки


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
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	if idx.is_empty():
		return
	var body_idx := PackedInt32Array()
	var stick_idx := PackedInt32Array()
	for i in range(0, idx.size(), 3):
		var inside := true
		for k in 3:
			var p: Vector3 = verts[idx[i + k]]
			if p.x < STICK_MIN.x or p.x > STICK_MAX.x or p.y < STICK_MIN.y or p.y > STICK_MAX.y \
					or p.z < STICK_MIN.z or p.z > STICK_MAX.z:
				inside = false
				break
		if inside:
			stick_idx.append_array([idx[i], idx[i + 1], idx[i + 2]])
		else:
			body_idx.append_array([idx[i], idx[i + 1], idx[i + 2]])
	if stick_idx.size() < 30:
		return
	var mat: Material = src.surface_get_material(0)
	if mat == null:
		mat = mi.get_active_material(0)
	var body := ArrayMesh.new()
	var a1: Array = arr.duplicate()
	a1[Mesh.ARRAY_INDEX] = body_idx
	body.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a1)
	body.surface_set_material(0, mat)
	var moved := PackedVector3Array()
	moved.resize(verts.size())
	for i in verts.size():
		moved[i] = verts[i] - PIVOT
	var a2: Array = arr.duplicate()
	a2[Mesh.ARRAY_VERTEX] = moved
	a2[Mesh.ARRAY_INDEX] = stick_idx
	var stick_mesh := ArrayMesh.new()
	stick_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a2)
	stick_mesh.surface_set_material(0, mat)
	mi.mesh = body
	stick = Node3D.new()
	stick.name = "Joystick"
	stick.position = PIVOT
	mi.add_child(stick)
	var smi := MeshInstance3D.new()
	smi.mesh = stick_mesh
	smi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	smi.layers = mi.layers
	stick.add_child(smi)


## Ручка джойстика: forward −1..1 (вперёд / назад), turn −1..1 (влево / вправо). Плавно.
func set_input(forward: float, turn: float, dt: float) -> void:
	if stick == null:
		return
	var k: float = 1.0 - exp(-14.0 * dt)
	var want := Vector3(clampf(forward, -1.0, 1.0) * TILT, 0.0, clampf(turn, -1.0, 1.0) * TILT)
	stick.rotation = stick.rotation.lerp(want, k)
