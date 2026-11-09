extends RefCounted
## Простые предметы для сюжета, собранные из примитивов: каталка, тумбочка, бетонная балка, обломки,
## кулак Самана (вид от первого лица), пыль. Модели ключей и фонаря — из props/*.glb.

static func mat(col: Color, rough := 0.85, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	return m


static func box(parent: Node3D, center: Vector3, size: Vector3, m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = m
	mi.position = center
	parent.add_child(mi)
	return mi


static func cyl(parent: Node3D, center: Vector3, r: float, h: float, m: Material, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = h
	cm.radial_segments = 10
	cm.rings = 1
	mi.mesh = cm
	mi.material_override = m
	mi.position = center
	mi.rotation = rot
	parent.add_child(mi)
	return mi


## Ржавая больничная каталка: 0,62 × 1,9 м, длинная сторона вдоль Z. Начало координат — на полу, посередине.
static func gurney() -> Node3D:
	var root := Node3D.new()
	root.name = "Gurney"
	var rust := mat(Color(0.36, 0.22, 0.14), 0.75, 0.45)
	var steel := mat(Color(0.42, 0.4, 0.37), 0.5, 0.7)
	var mattress := mat(Color(0.55, 0.52, 0.42), 0.95)
	var stain := mat(Color(0.3, 0.18, 0.12), 0.95)
	box(root, Vector3(0, 0.78, 0), Vector3(0.62, 0.05, 1.9), rust)
	box(root, Vector3(0, 0.86, 0.02), Vector3(0.58, 0.12, 1.82), mattress)
	box(root, Vector3(0.08, 0.925, 0.3), Vector3(0.3, 0.01, 0.45), stain)
	for sx in [-0.27, 0.27]:
		for sz in [-0.85, 0.85]:
			cyl(root, Vector3(sx, 0.43, sz), 0.018, 0.72, steel)
			cyl(root, Vector3(sx, 0.07, sz), 0.06, 0.04, mat(Color(0.08, 0.08, 0.08), 0.9), Vector3(0, 0, PI / 2))
		cyl(root, Vector3(sx, 1.0, 0), 0.012, 1.6, steel, Vector3(PI / 2, 0, 0))
		for sz in [-0.8, 0.8]:
			cyl(root, Vector3(sx, 0.92, sz), 0.012, 0.25, steel)
	box(root, Vector3(0, 0.25, 0), Vector3(0.5, 0.03, 1.7), rust)
	return root


## Тумбочка 0,45 × 0,62 × 0,48 м, дверца/ящик смотрит в −Z. Возвращает {root, drawer}.
static func nightstand() -> Dictionary:
	var root := Node3D.new()
	root.name = "Nightstand"
	var wood := mat(Color(0.33, 0.22, 0.14), 0.7)
	var dark := mat(Color(0.18, 0.12, 0.08), 0.8)
	box(root, Vector3(0, 0.31, 0), Vector3(0.45, 0.62, 0.48), wood)
	box(root, Vector3(0, 0.63, 0), Vector3(0.48, 0.03, 0.5), dark)
	var drawer := Node3D.new()
	drawer.position = Vector3(0, 0.5, -0.24)
	root.add_child(drawer)
	box(drawer, Vector3(0, 0, 0.0), Vector3(0.4, 0.13, 0.02), dark)
	box(drawer, Vector3(0, -0.04, 0.2), Vector3(0.38, 0.06, 0.38), wood)
	box(drawer, Vector3(0, 0.0, -0.02), Vector3(0.1, 0.02, 0.02), mat(Color(0.6, 0.55, 0.4), 0.4, 0.8))
	return {"root": root, "drawer": drawer}


static func concrete() -> StandardMaterial3D:
	return mat(Color(0.48, 0.47, 0.44), 0.95)


## Бетонная балка с торчащей арматурой.
static func beam(length := 4.0) -> Node3D:
	var root := Node3D.new()
	var c := concrete()
	box(root, Vector3.ZERO, Vector3(0.45, 0.5, length), c)
	var rebar := mat(Color(0.3, 0.2, 0.15), 0.6, 0.6)
	for i in 4:
		cyl(root, Vector3(-0.12 + 0.08 * i, 0.1, length * 0.5 + 0.15), 0.012, 0.35, rebar, Vector3(PI / 2, 0, 0))
	return root


static func chunk(size: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(size, size * randf_range(0.4, 0.8), size * randf_range(0.6, 1.2))
	mi.mesh = bm
	mi.material_override = concrete()
	return mi


## Рука Самана для удара (вид от первого лица): рукав и кулак. Начало — у плеча, вытянута в −Z.
static func fist_arm() -> Node3D:
	var root := Node3D.new()
	var sleeve := mat(Color(0.18, 0.24, 0.36), 0.9)
	var skin := mat(Color(0.78, 0.6, 0.48), 0.7)
	cyl(root, Vector3(0, 0, -0.22), 0.045, 0.44, sleeve, Vector3(PI / 2, 0, 0))
	var f := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.055
	sm.height = 0.1
	f.mesh = sm
	f.material_override = skin
	f.position = Vector3(0, 0, -0.47)
	f.scale = Vector3(1.0, 0.85, 1.25)
	root.add_child(f)
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return root


## Пыль и мелкая крошка с потолка вокруг точки (включается emitting).
static func dust(extent: Vector3) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 220
	p.lifetime = 2.2
	p.emitting = false
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = extent
	pm.direction = Vector3(0, -1, 0)
	pm.spread = 12.0
	pm.initial_velocity_min = 0.2
	pm.initial_velocity_max = 1.2
	pm.gravity = Vector3(0, -3.5, 0)
	pm.scale_min = 0.4
	pm.scale_max = 1.6
	p.process_material = pm
	var qm := QuadMesh.new()
	qm.size = Vector2(0.03, 0.03)
	var dm := StandardMaterial3D.new()
	dm.albedo_color = Color(0.7, 0.68, 0.62, 0.8)
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.material = dm
	p.draw_pass_1 = qm
	p.visibility_aabb = AABB(-extent - Vector3(1, 4, 1), extent * 2.0 + Vector3(2, 8, 2))
	return p


## Модель из GLB с масштабом; поднимает так, чтобы низ стоял на y = 0 (для моделей с центром посередине).
static func glb(path: String, scale_k: float, lift_half := 0.0) -> Node3D:
	var holder := Node3D.new()
	var res: Resource = load(path)
	if res is PackedScene:
		var m: Node3D = (res as PackedScene).instantiate() as Node3D
		m.scale = Vector3.ONE * scale_k
		m.position.y = lift_half * scale_k
		holder.add_child(m)
	return holder
