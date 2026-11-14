extends Node3D
## Второй этаж в разные моменты сюжета:
##   void — «сон»: настоящий этаж прячется, вместо него огромная пустая тёмная комната с одной дверью —
##          палатой деда №204 (акт 3);
##   real — снова настоящий 2-й этаж здания (после 3-го этажа, акты 5–6): все комнаты на месте, но свет почти
##          везде погас, в коридоре скачет напряжение; палата 204 заперта, ключ — в процедурной 213.

const Y0 := 4.5          # пол 2-го этажа
const Y1 := 7.6          # под перекрытием 3-го
const NORTH := -0.3
const SOUTH := -15.8
const WEST := 0.3
const B_STAIR2 := [3.0, -15.8, 9.0, -9.6]
const B_204 := [6.0, -6.6, 12.0, -0.3]
const B_STAIR1 := [30.0, -6.6, 39.0, -0.3]
const B_STAIR3 := [66.0, -15.8, 72.0, -9.6]
const B_213 := [30.0, -15.8, 33.0, -9.6]
const HOLE_204 := [8.15, 9.5]       # дверь палаты 204 (стена z = -6.6)
const HOLE_LIFT := [36.75, 38.6]    # двери лифта и кнопка вызова (z = -6.6)
const HOLE_STAIR := [30.15, 31.7]   # дверь лестницы №1 (z = -6.6), открывается в землетрясение
const HOLE_213 := [30.85, 32.15]    # дверь процедурной 213 (z = -9.6)
const KEEP_ALWAYS := ["Lift_Landing_Floor2", "Lift_Signs_Floor2", "LiftDoor_F2_L", "LiftDoor_F2_R",
	"WindowReveals_L1", "WindowSills_L1", "Room_204_Doubleroomwithbathroom", "Room_F2b_En-suitebathroom"]
const DOOR_204 := 91
const DOOR_204_BATH := 92
const DOOR_213 := 119
const DOOR_STAIR1_F2 := 22
const DOOR_STAIR1_HALL_F2 := 232

var game
var mode := "normal"
var root_set: Node3D
var _surge_t := 3.0                 # «real»: когда в коридоре снова мигнёт свет
var quaking := false
var stair_panel: StaticBody3D
var lamps: Array = []               # OmniLight3D
var door_map := {}
var _m_wall: Material
var _m_floor: Material
var _m_ceil: Material
var _lamp_t := 0.0


func setup(g) -> void:
	game = g
	for dg in game.door_groups:
		if dg.leaves.is_empty():
			continue
		var nm: String = str(dg.leaves[0]["body"].name)
		if nm.begins_with("Door_DoorLeaf_"):
			door_map[int(nm.substr(14, 3))] = dg
	_m_wall = _material("M_Paint_WallBeige", Color(0.55, 0.52, 0.45))
	_m_floor = _material("M_Linoleum_Brown", Color(0.25, 0.2, 0.16))
	_m_ceil = _material("M_Ceiling_Paint", Color(0.6, 0.6, 0.57))


func door(id: int):
	return door_map.get(id)


## Материал из здания (с грязью, как у настоящих стен), с мировой проекцией текстуры — коробки любого размера.
func _material(mat_name: String, fallback: Color) -> Material:
	for key in game.nodes:
		var mi = game.nodes[key]
		if not (mi is MeshInstance3D) or mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var m = mi.mesh.surface_get_material(i)
			if m is BaseMaterial3D and m.resource_name == mat_name:
				var d: BaseMaterial3D = m.duplicate()
				d.uv1_triplanar = true
				d.uv1_world_triplanar = true
				d.uv1_scale = Vector3(0.5, 0.5, 0.5)
				d.cull_mode = BaseMaterial3D.CULL_DISABLED
				return d
	var s := StandardMaterial3D.new()
	s.albedo_color = fallback
	s.roughness = 0.9
	return s


# ------------------------------------------------------------------------------ прятать настоящий этаж
func _set_active(n: Node, on: bool) -> void:
	if n == null:
		return
	if n is Node3D:
		(n as Node3D).visible = on
	for b in n.find_children("*", "CollisionObject3D", true, false):
		var co: CollisionObject3D = b
		if on:
			co.collision_layer = int(co.get_meta("layer0", co.collision_layer))
		else:
			if not co.has_meta("layer0"):
				co.set_meta("layer0", co.collision_layer)
			co.collision_layer = 0


func set_door_active(id: int, on: bool) -> void:
	var dg = door(id)
	if dg == null:
		return
	for b in dg.leaf_bodies():
		(b as Node3D).visible = on
		(b as CollisionObject3D).collision_layer = game.L_DOORS if on else 0


## Спрятать 2-й этаж, кроме узлов keep (имена детей узла Floor2), дверей keep_doors, комнат keep_rooms.
func hide_floor2(keep: Array, keep_doors: Array, keep_rooms: Array) -> void:
	var f2: Node = game.node("Floor2")
	if f2:
		for c in f2.get_children():
			_set_active(c, str(c.name) in keep)
	for id in door_map:
		var dg = door_map[id]
		if dg.center.y > 4.0 and dg.center.y < 7.0:
			set_door_active(id, id in keep_doors)
	var fc: Node = game.get_node_or_null("FurnitureColliders")
	if fc:
		var specs: Array = game.level["boxes"] + game.level["rot_boxes"]
		var shapes: Array = fc.get_children()
		for i in mini(shapes.size(), specs.size()):
			var room: String = str(specs[i].get("room", ""))
			if room.begins_with("L1."):
				(shapes[i] as CollisionShape3D).disabled = not (room in keep_rooms)
	for c in game.get_children():
		if c is Area3D and "room" in c:
			var room: String = str(c.room)
			if room.begins_with("L1."):
				(c as Area3D).collision_layer = game.L_INTERACT if room in keep_rooms else 0
	for room in game.lights.groups.keys():
		var rs: String = str(room)
		if rs.begins_with("L1.") and not (rs in keep_rooms):
			game.lights.set_room(rs, false)
	if game.critters:
		game.critters.visible = false


# ------------------------------------------------------------------------------ геометрия
func _box(parent: Node3D, center: Vector3, size: Vector3, mat: Material, collide := true) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = game.L_WORLD if collide else 0
	body.collision_mask = 0
	parent.add_child(body)
	body.position = center
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	body.add_child(cs)
	return body


## Стена по отрезку (x0,z0)-(x1,z1) — вдоль X или вдоль Z; side: с какой стороны проход (-1/1), 0 — по центру;
## holes — проёмы [[a, b], ...] вдоль стены. Возвращает тела кусков.
func _wall(parent: Node3D, x0: float, z0: float, x1: float, z1: float, side: int, holes: Array) -> Array:
	var along_x: bool = absf(z1 - z0) < 0.001
	# концы стены заходят за угол на 0,4 м: соседние стены (они сдвинуты от линии блока) перекрываются,
	# и в углах нет щелей, сквозь которые видны лестницы и пустота здания
	var a0: float = (minf(x0, x1) if along_x else minf(z0, z1)) - 0.4
	var a1: float = (maxf(x0, x1) if along_x else maxf(z0, z1)) + 0.4
	var c: float = z0 if along_x else x0
	var th: float = 0.2 if side == 0 else 0.16
	var off: float = 0.0 if side == 0 else float(side) * 0.16
	var pieces: Array = [[a0, a1]]
	for h in holes:
		var nxt: Array = []
		for p in pieces:
			if h[1] <= p[0] or h[0] >= p[1]:
				nxt.append(p)
				continue
			if h[0] > p[0]:
				nxt.append([p[0], h[0]])
			if h[1] < p[1]:
				nxt.append([h[1], p[1]])
		pieces = nxt
	var out: Array = []
	for p in pieces:
		var ln: float = p[1] - p[0]
		if ln < 0.05:
			continue
		var mid: float = (p[0] + p[1]) * 0.5
		var h: float = Y1 - Y0
		var center := Vector3(mid, Y0 + h * 0.5, c + off) if along_x else Vector3(c + off, Y0 + h * 0.5, mid)
		var size := Vector3(ln + (th if side == 0 else 0.0), h, th) if along_x else Vector3(th, h, ln + (th if side == 0 else 0.0))
		out.append(_box(parent, center, size, _m_wall))
	return out


## Пол и потолок: прямоугольник без блоков (там свои полы — комнаты, лестницы).
func _slabs(parent: Node3D, x_max: float, blocks: Array) -> void:
	var xs: Array = [WEST, x_max]
	var zs: Array = [SOUTH, NORTH]
	for b in blocks:
		for x in [b[0], b[2]]:
			if x > WEST and x < x_max and not (x in xs):
				xs.append(x)
		for z in [b[1], b[3]]:
			if z > SOUTH and z < NORTH and not (z in zs):
				zs.append(z)
	xs.sort()
	zs.sort()
	for i in xs.size() - 1:
		for j in zs.size() - 1:
			var cx: float = (xs[i] + xs[i + 1]) * 0.5
			var cz: float = (zs[j] + zs[j + 1]) * 0.5
			var inside := false
			for b in blocks:
				if cx > b[0] and cx < b[2] and cz > b[1] and cz < b[3]:
					inside = true
			if inside:
				continue
			var sx: float = xs[i + 1] - xs[i]
			var sz: float = zs[j + 1] - zs[j]
			_box(parent, Vector3(cx, Y0 - 0.1, cz), Vector3(sx, 0.2, sz), _m_floor)
			_box(parent, Vector3(cx, Y1 + 0.05, cz), Vector3(sx, 0.1, sz), _m_ceil, false)


## Контур блока (стены снаружи него), кроме сторон, лежащих на наружных стенах здания.
func _block_walls(parent: Node3D, b: Array, x_max: float, holes_south: Array, holes_north: Array) -> void:
	if b[1] > SOUTH + 0.01:
		_wall(parent, b[0], b[1], b[2], b[1], -1, holes_south)
	if b[3] < NORTH - 0.01:
		_wall(parent, b[0], b[3], b[2], b[3], 1, holes_north)
	if b[0] > WEST + 0.01:
		_wall(parent, b[0], b[1], b[0], b[3], -1, [])
	if b[2] < x_max - 0.01:
		_wall(parent, b[2], b[1], b[2], b[3], 1, [])


func _perimeter(parent: Node3D, x_max: float, blocks: Array) -> void:
	var north_holes: Array = []
	var south_holes: Array = []
	for b in blocks:
		if b[3] >= NORTH - 0.01:
			north_holes.append([b[0], b[2]])
		if b[1] <= SOUTH + 0.01:
			south_holes.append([b[0], b[2]])
	_wall(parent, WEST, NORTH, x_max, NORTH, -1, north_holes)
	_wall(parent, WEST, SOUTH, x_max, SOUTH, 1, south_holes)
	_wall(parent, WEST, SOUTH, WEST, NORTH, 1, [])
	_wall(parent, x_max, SOUTH, x_max, NORTH, -1, [])


func _stair_door_panel(parent: Node3D) -> void:
	var w: float = HOLE_STAIR[1] - HOLE_STAIR[0]
	stair_panel = _box(parent, Vector3((HOLE_STAIR[0] + HOLE_STAIR[1]) * 0.5, (Y0 + Y1) * 0.5, -6.6 - 0.16),
		Vector3(w, Y1 - Y0, 0.12), _m_wall)


func lamp(parent: Node3D, pos: Vector3, energy := 0.7, rng := 5.5, col := Color(1.0, 0.86, 0.6)) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.light_color = col
	l.light_energy = energy
	l.omni_range = rng
	l.omni_attenuation = 1.4
	l.shadow_enabled = false
	l.set_meta("base", energy)
	parent.add_child(l)
	l.global_position = pos
	var bulb := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.06
	sm.height = 0.12
	bulb.mesh = sm
	var bm := StandardMaterial3D.new()
	bm.emission_enabled = true
	bm.emission = col
	bm.emission_energy_multiplier = 3.0
	bm.albedo_color = col
	bulb.material_override = bm
	l.add_child(bulb)
	var cord := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.006
	cm.bottom_radius = 0.006
	cm.height = maxf(Y1 - pos.y, 0.05)
	cord.mesh = cm
	cord.position.y = cm.height * 0.5 + 0.05
	var cmat := StandardMaterial3D.new()
	cmat.albedo_color = Color(0.05, 0.05, 0.05)
	cord.material_override = cmat
	l.add_child(cord)
	lamps.append(l)
	return l


func _clear() -> void:
	if root_set:
		root_set.queue_free()
	root_set = Node3D.new()
	root_set.name = "DreamSet"
	root_set.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(root_set)
	lamps.clear()
	stair_panel = null


# ------------------------------------------------------------------------------ акт 3: пустая комната
func build_void() -> void:
	mode = "void"
	hide_floor2(KEEP_ALWAYS, [DOOR_204, DOOR_204_BATH, DOOR_STAIR1_F2, DOOR_STAIR1_HALL_F2], ["L1.F2", "L1.F2b"])
	_clear()
	var x_max := 74.7
	var blocks: Array = [B_STAIR2, B_204, B_STAIR1, B_STAIR3]
	_slabs(root_set, x_max, blocks)
	_perimeter(root_set, x_max, blocks)
	_block_walls(root_set, B_STAIR2, x_max, [], [])
	_block_walls(root_set, B_STAIR3, x_max, [], [])
	_block_walls(root_set, B_204, x_max, [HOLE_204], [])
	_block_walls(root_set, B_STAIR1, x_max, [HOLE_LIFT, HOLE_STAIR], [])
	_stair_door_panel(root_set)
	# одна лампа над дверью деда — как маяк в темноте; в палате горит свет
	lamp(root_set, Vector3(8.8, 6.9, -7.3), 1.1, 7.0)
	lamp(root_set, Vector3(37.5, 6.9, -7.6), 0.25, 3.5, Color(0.7, 0.8, 1.0))
	game.lights.set_room("L1.F2", true)
	game.hud.hidden_level = 1                     # в пустоте нет комнат — подписи не нужны (кроме палаты деда)
	game.hud.hidden_except = ["L1.F2", "L1.F2b"]
	var d = door(DOOR_204)
	if d:
		d.locked = false
		d.set_angle(0.0)


# ------------------------------------------------------------------------------ акт 5–6: настоящий 2-й этаж
## Вернуть 2-й этаж как в здании (после «пустой комнаты» акта 3).
func restore_floor2() -> void:
	var f2: Node = game.node("Floor2")
	if f2:
		for c in f2.get_children():
			_set_active(c, true)
	for id in door_map:
		var dg = door_map[id]
		if dg.center.y > 4.0 and dg.center.y < 7.0:
			set_door_active(id, true)
	var fc: Node = game.get_node_or_null("FurnitureColliders")
	if fc:
		var specs: Array = game.level["boxes"] + game.level["rot_boxes"]
		var shapes: Array = fc.get_children()
		for i in mini(shapes.size(), specs.size()):
			if str(specs[i].get("room", "")).begins_with("L1."):
				(shapes[i] as CollisionShape3D).disabled = false
	for c in game.get_children():
		if c is Area3D and "room" in c and str(c.room).begins_with("L1."):
			(c as Area3D).collision_layer = game.L_INTERACT


func build_real2() -> void:
	mode = "real"
	game.hud.hidden_level = -1
	_clear()
	restore_floor2()
	# свет: в комнатах темно, в коридоре горит, но то и дело гаснет; в процедурной 213 горит (там ключ)
	for room in game.lights.groups.keys():
		var rs: String = str(room)
		if rs.begins_with("L1."):
			game.lights.set_room(rs, rs == "L1.C" or rs == "L1.R10")
	_surge_t = 4.0
	var d = door(DOOR_204)
	if d:
		d.set_angle(0.0)
		d.locked = true
		d.locked_text = "Заперто. Нужен ключ от палаты"
	var k = door(DOOR_213)
	if k:
		k.locked = false
		k.set_angle(0.0)
	var st = door(DOOR_STAIR1_F2)                # на лестницу — заклинило (откроет землетрясение)
	if st:
		st.set_angle(0.0)
		st.locked = true
		st.locked_text = "Дверь на лестницу заклинило"


## Землетрясение на настоящем этаже: свет в коридоре скачет, двери палат бьются и распахиваются.
func quake_open_route() -> void:
	quaking = true
	var k := 0
	for id in door_map:
		var dg = door_map[id]
		if dg.center.y < 4.0 or dg.center.y > 7.0 or id in [DOOR_204, DOOR_204_BATH]:
			continue
		if dg.center.z > -11.0 and dg.center.z < -5.0 and randf() < 0.5:
			dg.locked = false
			var tw := create_tween()
			tw.tween_interval(0.15 * k + randf_range(0.0, 0.4))
			tw.tween_callback(func(): dg.swing_to(randf_range(40.0, 95.0), 0.35))
			k += 1
	var st = door(DOOR_STAIR1_F2)
	if st:
		st.locked = false


func set_lamps(f: float) -> void:
	for l in lamps:
		if is_instance_valid(l):
			l.light_energy = float(l.get_meta("base")) * f


func _process(dt: float) -> void:
	if mode == "real":
		# скачет напряжение: коридор гаснет на миг (иногда — на пару секунд), в землетрясение — постоянно
		_surge_t -= dt
		if _surge_t <= 0.0:
			var on: bool = not game.lights.is_on("L1.C")
			game.lights.set_room("L1.C", on)
			if not on and not quaking and game.player and game.player.global_position.y > 4.0:
				game.play_at("flicker", game.player.global_position + Vector3(0, 2.6, 0), -10.0, randf_range(0.8, 1.2), 15.0)
			if quaking:
				_surge_t = randf_range(0.05, 0.35)
			elif on:
				_surge_t = randf_range(3.0, 9.0)
			else:
				_surge_t = randf_range(1.6, 3.0) if randf() < 0.25 else randf_range(0.06, 0.35)
	if lamps.is_empty():
		return
	_lamp_t -= dt
	if _lamp_t > 0.0:
		return
	_lamp_t = randf_range(0.05, 0.4)
	var l: OmniLight3D = lamps[randi() % lamps.size()]
	if is_instance_valid(l):
		l.light_energy = float(l.get_meta("base")) * (randf_range(0.0, 0.4) if randf() < 0.35 else 1.0)
