extends RefCounted
## Электроколяска-заглушка (средний привод). Начало координат — на земле под осью ведущих колёс, «перед» — −Z.
## Своя модель: положи intro/assets/models/wheelchair.glb (см. README.md).

const MeshKit = preload("res://intro/meshkit.gd")

const FRAME: Color = Color(0.18, 0.19, 0.21)
const SEAT: Color = Color(0.12, 0.31, 0.55)
const BLACK: Color = Color(0.05, 0.05, 0.05)
const TIRE: Color = Color(0.08, 0.08, 0.08)
const RIM: Color = Color(0.6, 0.64, 0.67)
const ACCENT: Color = Color(0.31, 0.64, 1.0)

const SEAT_HEIGHT: float = 0.52


static func build() -> Node3D:
	var root: Node3D = Node3D.new()
	root.name = "Wheelchair"
	var kit: Object = MeshKit.new()
	kit.add_box(Vector3(0, 0.22, 0), Vector3(0.5, 0.18, 0.78), FRAME)                      # база
	kit.add_box(Vector3(0, 0.36, 0.05), Vector3(0.34, 0.14, 0.4), BLACK)                    # аккумулятор
	kit.add_cyl(Vector3(0, 0.44, 0.04), 0.05, 0.05, 0.12, FRAME, Vector3.ZERO, 10)          # стойка сиденья
	kit.add_box(Vector3(0, SEAT_HEIGHT - 0.04, 0.03), Vector3(0.47, 0.09, 0.47), SEAT)      # сиденье
	kit.add_box(Vector3(0, 0.84, 0.29), Vector3(0.46, 0.56, 0.08), SEAT)                    # спинка
	kit.add_box(Vector3(0, 1.24, 0.31), Vector3(0.28, 0.17, 0.08), SEAT)                    # подголовник
	kit.add_cyl(Vector3(0, 1.12, 0.33), 0.015, 0.015, 0.2, FRAME, Vector3.ZERO, 6)
	for side in [-1.0, 1.0]:
		kit.add_box(Vector3(side * 0.27, 0.72, 0.0), Vector3(0.07, 0.05, 0.4), BLACK)       # подлокотник
		kit.add_box(Vector3(side * 0.27, 0.6, 0.15), Vector3(0.03, 0.22, 0.03), FRAME)
		# Ведущее колесо: покрышка (тор), диск, спица-акцент.
		kit.add_torus(Vector3(side * 0.29, 0.17, 0.0), 0.115, 0.185, TIRE, Vector3(0, 0, PI / 2.0))
		kit.add_cyl(Vector3(side * 0.29, 0.17, 0.0), 0.11, 0.11, 0.05, RIM, Vector3(0, 0, PI / 2.0), 14)
		# Поворотные колёсики спереди и сзади.
		for z in [-0.36, 0.38]:
			kit.add_cyl(Vector3(side * 0.2, 0.065, z), 0.065, 0.065, 0.04, TIRE, Vector3(0, 0, PI / 2.0), 10)
	# Подножка, кронштейн, пульт и джойстик справа.
	kit.add_box(Vector3(0, 0.12, -0.44), Vector3(0.4, 0.03, 0.22), FRAME, Vector3(0.15, 0, 0))
	kit.add_box(Vector3(0, 0.32, -0.36), Vector3(0.03, 0.4, 0.03), FRAME, Vector3(-0.35, 0, 0))
	kit.add_box(Vector3(0.3, 0.74, -0.18), Vector3(0.08, 0.05, 0.12), BLACK)
	kit.add_cyl(Vector3(0.3, 0.8, -0.2), 0.012, 0.012, 0.07, FRAME, Vector3.ZERO, 6)
	kit.add_sphere(Vector3(0.3, 0.84, -0.2), 0.022, ACCENT, Vector3.ONE, 8)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	mat.roughness = 0.55
	root.add_child(kit.build(mat))
	# Зелёный индикатор заряда на пульте.
	var led: MeshInstance3D = MeshInstance3D.new()
	var bm: BoxMesh = BoxMesh.new()
	bm.size = Vector3(0.16, 0.02, 0.01)
	led.mesh = bm
	var lm: StandardMaterial3D = StandardMaterial3D.new()
	lm.albedo_color = Color(0.06, 0.19, 0.06)
	lm.emission_enabled = true
	lm.emission = Color(0.19, 1.0, 0.38)
	lm.emission_energy_multiplier = 1.2
	led.material_override = lm
	led.position = Vector3(0.3, 0.768, -0.24)
	root.add_child(led)
	return root
