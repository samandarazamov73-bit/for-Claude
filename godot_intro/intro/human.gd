extends Node3D
## Человечек из простых форм (заглушка). Настоящую модель можно подставить: см. README.md.
## Позы: "stand", "sit" (на сиденье), "wheelchair" (в коляске).

const POSES: Dictionary = {
	"stand": {"spine": 0.0, "hipL": 0.0, "hipR": 0.0, "kneeL": 0.0, "kneeR": 0.0,
		"shLx": 0.0, "shRx": 0.0, "shLz": -0.08, "shRz": 0.08, "elL": 0.12, "elR": 0.12},
	"sit": {"spine": -0.06, "hipL": 1.52, "hipR": 1.52, "kneeL": -1.5, "kneeR": -1.5,
		"shLx": 0.35, "shRx": 0.35, "shLz": -0.1, "shRz": 0.1, "elL": 0.95, "elR": 0.95},
	"wheelchair": {"spine": -0.04, "hipL": 1.45, "hipR": 1.45, "kneeL": -1.35, "kneeR": -1.35,
		"shLx": 0.3, "shRx": 0.45, "shLz": -0.12, "shRz": 0.14, "elL": 1.15, "elR": 1.25},
}

static var _materials: Dictionary = {}

var k: float = 1.0                  # масштаб по росту
var sit_height: float = 0.46        # высота сиденья
var hip_height: float = 0.9
var hips: Node3D
var spine: Node3D
var neck: Node3D
var head: Node3D
var arm_l_sh: Node3D
var arm_l_el: Node3D
var arm_r_sh: Node3D
var arm_r_el: Node3D
var leg_l_hip: Node3D
var leg_l_knee: Node3D
var leg_r_hip: Node3D
var leg_r_knee: Node3D
var head_meshes: Array = []

var turn_body: bool = false          # совместимость с person.gd
var height: float = 1.5
var anim = null                      # у человечка-заглушки анимаций нет
var look_target: Variant = null     # Vector3 (мировые координаты) или null
var talking: float = 0.0            # >0 — говорит: кивает головой
var _head_yaw: float = 0.0
var _head_pitch: float = 0.0
var _t: float = randf() * 6.0
var _pose_name: String = "stand"


static func _mat(color: Color) -> StandardMaterial3D:
	var key: String = color.to_html()
	if not _materials.has(key):
		var m: StandardMaterial3D = StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = 0.85
		_materials[key] = m
	return _materials[key]


func _part(parent: Node3D, mesh: Mesh, color: Color, pos: Vector3, scl: Vector3 = Vector3.ONE, cast: bool = true) -> MeshInstance3D:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat(color)
	mi.position = pos
	mi.scale = scl
	if not cast:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


func _capsule(r: float, h: float) -> CapsuleMesh:
	var m: CapsuleMesh = CapsuleMesh.new()
	m.radius = r
	m.height = maxf(h, r * 2.0 + 0.001)
	m.radial_segments = 8
	m.rings = 3
	return m


func _box(x: float, y: float, z: float) -> BoxMesh:
	var m: BoxMesh = BoxMesh.new()
	m.size = Vector3(x, y, z)
	return m


func _sphere(r: float) -> SphereMesh:
	var m: SphereMesh = SphereMesh.new()
	m.radius = r
	m.height = r * 2.0
	m.radial_segments = 12
	m.rings = 6
	return m


func _joint(parent: Node3D, pos: Vector3) -> Node3D:
	var n: Node3D = Node3D.new()
	n.position = pos
	parent.add_child(n)
	return n


## opts: height, shirt, pants, skin, hair, shoes, hair_style ("short"|"long"|"bun"), sit_height, shadows
func setup(opts: Dictionary) -> void:
	var height: float = float(opts.get("height", 1.7))
	k = height / 1.7
	sit_height = float(opts.get("sit_height", 0.46))
	hip_height = 0.9 * k
	var shirt: Color = Color(str(opts.get("shirt", "#3a6ea5")))
	var pants: Color = Color(str(opts.get("pants", "#2f3e5c")))
	var skin: Color = Color(str(opts.get("skin", "#e2b28f")))
	var hair: Color = Color(str(opts.get("hair", "#2b1d14")))
	var shoes: Color = Color(str(opts.get("shoes", "#f0f0f0")))
	var style: String = str(opts.get("hair_style", "short"))
	var shadows: bool = bool(opts.get("shadows", true))

	hips = _joint(self, Vector3(0, hip_height, 0))
	_part(hips, _box(0.32 * k, 0.17 * k, 0.21 * k), pants, Vector3(0, -0.03 * k, 0), Vector3.ONE, shadows)
	spine = _joint(hips, Vector3.ZERO)
	_part(spine, _capsule(0.15 * k, 0.52 * k), shirt, Vector3(0, 0.27 * k, 0), Vector3(1.15, 1.0, 0.72), shadows)
	var neck_mesh: CylinderMesh = CylinderMesh.new()
	neck_mesh.top_radius = 0.05 * k
	neck_mesh.bottom_radius = 0.055 * k
	neck_mesh.height = 0.09 * k
	neck_mesh.radial_segments = 8
	_part(spine, neck_mesh, skin, Vector3(0, 0.53 * k, 0), Vector3.ONE, shadows)
	neck = _joint(spine, Vector3(0, 0.5 * k, 0))
	head = _joint(neck, Vector3(0, 0.16 * k, 0))
	head_meshes = []
	head_meshes.append(_part(head, _sphere(0.11 * k), skin, Vector3.ZERO, Vector3(0.9, 1.06, 1.0), shadows))
	var cap: SphereMesh = _sphere(0.115 * k)
	cap.height = 0.115 * k
	cap.is_hemisphere = true
	head_meshes.append(_part(head, cap, hair, Vector3(0, 0.012 * k, 0.008 * k), Vector3(0.94, 1.06, 1.04), shadows))
	for sx in [-0.035, 0.035]:
		head_meshes.append(_part(head, _sphere(0.014 * k), Color(0.1, 0.1, 0.1), Vector3(sx * k, 0.015 * k, -0.095 * k), Vector3.ONE, false))
	head_meshes.append(_part(head, _box(0.02 * k, 0.035 * k, 0.03 * k), skin, Vector3(0, -0.012 * k, -0.105 * k), Vector3.ONE, false))
	if style == "long":
		head_meshes.append(_part(head, _box(0.2 * k, 0.26 * k, 0.07 * k), hair, Vector3(0, -0.1 * k, 0.07 * k), Vector3.ONE, shadows))
	elif style == "bun":
		head_meshes.append(_part(head, _sphere(0.06 * k), hair, Vector3(0, 0.06 * k, 0.1 * k), Vector3.ONE, shadows))

	# Руки: плечо → локоть → кисть.
	var parts_l: Array = _make_arm(-1.0, shirt, skin, shadows)
	arm_l_sh = parts_l[0]
	arm_l_el = parts_l[1]
	var parts_r: Array = _make_arm(1.0, shirt, skin, shadows)
	arm_r_sh = parts_r[0]
	arm_r_el = parts_r[1]
	# Ноги: бедро → колено → ботинок.
	var legs_l: Array = _make_leg(-1.0, pants, shoes, shadows)
	leg_l_hip = legs_l[0]
	leg_l_knee = legs_l[1]
	var legs_r: Array = _make_leg(1.0, pants, shoes, shadows)
	leg_r_hip = legs_r[0]
	leg_r_knee = legs_r[1]
	set_pose("stand")


func _make_arm(side: float, shirt: Color, skin: Color, cast: bool) -> Array:
	var sh: Node3D = _joint(spine, Vector3(side * 0.19 * k, 0.45 * k, 0))
	_part(sh, _capsule(0.047 * k, 0.29 * k), shirt, Vector3(0, -0.145 * k, 0), Vector3.ONE, cast)
	var el: Node3D = _joint(sh, Vector3(0, -0.29 * k, 0))
	_part(el, _capsule(0.04 * k, 0.26 * k), shirt, Vector3(0, -0.125 * k, 0), Vector3.ONE, cast)
	_part(el, _sphere(0.045 * k), skin, Vector3(0, -0.27 * k, 0), Vector3(0.8, 1.1, 0.9), cast)
	return [sh, el]


func _make_leg(side: float, pants: Color, shoes: Color, cast: bool) -> Array:
	var hip: Node3D = _joint(hips, Vector3(side * 0.09 * k, 0, 0))
	_part(hip, _capsule(0.068 * k, 0.43 * k), pants, Vector3(0, -0.215 * k, 0), Vector3.ONE, cast)
	var knee: Node3D = _joint(hip, Vector3(0, -0.43 * k, 0))
	_part(knee, _capsule(0.052 * k, 0.41 * k), pants, Vector3(0, -0.205 * k, 0), Vector3.ONE, cast)
	_part(knee, _box(0.1 * k, 0.07 * k, 0.25 * k), shoes, Vector3(0, -0.43 * k, -0.05 * k), Vector3.ONE, cast)
	return [hip, knee]


func set_pose(pose: String) -> void:
	_pose_name = pose if POSES.has(pose) else "stand"
	var p: Dictionary = POSES[_pose_name]
	spine.rotation.x = float(p["spine"])
	leg_l_hip.rotation.x = float(p["hipL"])
	leg_r_hip.rotation.x = float(p["hipR"])
	leg_l_knee.rotation.x = float(p["kneeL"])
	leg_r_knee.rotation.x = float(p["kneeR"])
	arm_l_sh.rotation = Vector3(float(p["shLx"]), 0.0, float(p["shLz"]))
	arm_r_sh.rotation = Vector3(float(p["shRx"]), 0.0, float(p["shRz"]))
	arm_l_el.rotation.x = float(p["elL"])
	arm_r_el.rotation.x = float(p["elR"])
	# Сидя таз опускается на высоту сиденья.
	hips.position.y = hip_height if _pose_name == "stand" else sit_height + 0.06


func focus_point() -> Vector3:
	return head.global_position


func set_head_visible(v: bool) -> void:
	for m in head_meshes:
		(m as MeshInstance3D).visible = v


func _process(delta: float) -> void:
	_t += delta
	spine.rotation.x = float(POSES[_pose_name]["spine"]) + sin(_t * 1.6) * 0.012   # дыхание
	var yaw: float = 0.0
	var pitch: float = 0.0
	if look_target != null and neck.is_inside_tree():
		var local: Vector3 = neck.to_local(look_target as Vector3)
		yaw = clampf(atan2(-local.x, -local.z), -1.2, 1.2)
		pitch = clampf(atan2(local.y - 0.16 * k, Vector2(local.x, local.z).length()), -0.5, 0.45)
	_head_yaw = lerpf(_head_yaw, yaw, 1.0 - exp(-5.0 * delta))
	_head_pitch = lerpf(_head_pitch, pitch, 1.0 - exp(-5.0 * delta))
	talking = maxf(0.0, talking - delta)
	var nod: float = sin(_t * 9.0) * 0.03 if talking > 0.0 else 0.0
	head.basis = Basis.from_euler(Vector3(_head_pitch + nod, _head_yaw, 0.0), EULER_ORDER_YXZ)


## Шаг (для заглушки, когда нет модели мамы): ноги качаются от бедра.
func walk(speed: float, delta: float) -> void:
	if _pose_name != "stand":
		set_pose("stand")
	_t += speed * delta * 5.4
	var k: float = clampf(speed / 1.2, 0.0, 1.0)
	leg_l_hip.rotation.x = sin(_t) * 0.45 * k
	leg_r_hip.rotation.x = -sin(_t) * 0.45 * k
	leg_l_knee.rotation.x = -maxf(0.0, -sin(_t)) * 0.5 * k
	leg_r_knee.rotation.x = -maxf(0.0, sin(_t)) * 0.5 * k


## Совместимость с person.gd: анимаций нет — поза задаётся set_pose().
func play_anim(anim_name: String, _blend: float = 0.3) -> void:
	set_pose("stand" if anim_name != "sit" else "sit")
