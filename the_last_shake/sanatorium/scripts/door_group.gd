extends Node
## A hinged door (one leaf, or both leaves of a double door). Each leaf mesh from the building GLB is moved
## under an AnimatableBody3D whose origin is the hinge, so opening is a rotation about the hinge.
## The swing stops if the leaf would hit the wheelchair. Steel doors of technical rooms and the exterior
## exits are locked.

var game
var leaves := []          # [{body, closed: Transform3D, sign, box_center, box_size}]
var angle := 0.0
var target := 0.0
var max_angle := 100.0
var locked := false
var locked_text := ""        # сюжет: своё сообщение для запертой двери («Нужен ключ…»)
var ext := false
var style := "wood"
var kind := "std"
var center := Vector3.ZERO
var _sound_cd := 0.0
var _shape_q: PhysicsShapeQueryParameters3D


func add_leaf(d: Dictionary, mesh: Node3D) -> void:
	if mesh == null:
		push_warning("door leaf missing: " + str(d["name"]))
		return
	locked = locked or bool(d["locked"])
	ext = ext or bool(d["ext"])
	style = d["style"]
	kind = d["kind"]
	max_angle = float(d["max_angle"])
	var body := AnimatableBody3D.new()
	body.name = "Door_" + str(d["name"])
	body.collision_layer = game.L_DOORS
	body.collision_mask = 0
	body.sync_to_physics = false
	add_child(body)
	body.global_transform = mesh.global_transform
	mesh.reparent(body, true)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = game._v3(d["box_size"])
	cs.shape = bs
	cs.position = game._v3(d["box_center"])
	body.add_child(cs)
	body.set_meta("interact", self)
	leaves.append({"body": body, "closed": body.global_transform, "sign": float(d["open_sign"]), "center": cs.position,
		"shape": bs})


func finish_setup() -> void:
	var c := Vector3.ZERO
	for lf in leaves:
		c += lf["body"].global_transform * lf["center"]
	if leaves.size() > 0:
		center = c / leaves.size()
	_shape_q = PhysicsShapeQueryParameters3D.new()
	_shape_q.collision_mask = game.L_PLAYER
	_shape_q.collide_with_bodies = true
	set_physics_process(false)


func prompt(_by) -> String:
	if locked and locked_text != "":
		return "Заперто"
	if locked:
		return "Дверь заперта" if not ext else "Выход заперт"
	return "[E] Закрыть дверь" if target > 1.0 else "[E] Открыть дверь"


func interact(_by) -> void:
	if locked:
		game.play_at("door_locked", center, -4.0, randf_range(0.95, 1.05), 20.0)
		game.hud.message(locked_text if locked_text != "" else ("Заперто" if not ext else "Заперто снаружи"), 2.6)
		return
	if target > 1.0:
		target = 0.0
	else:
		target = max_angle
		var s: String = "door_open_metal" if style.begins_with("metal") else ("door_open_wood" if randf() < 0.6 else "door_open_wood2")
		game.play_at(s, center, -3.0, randf_range(0.92, 1.06), 25.0)
	set_physics_process(true)


func set_angle(a: float) -> void:
	angle = a
	target = a
	_apply(a)


func _leaf_xf(lf: Dictionary, a: float) -> Transform3D:
	var c: Transform3D = lf["closed"]
	return c * Transform3D(Basis(Vector3.UP, deg_to_rad(a) * float(lf["sign"])), Vector3.ZERO)


func _apply(a: float) -> void:
	for lf in leaves:
		lf["body"].global_transform = _leaf_xf(lf, a)


func _blocked(a: float) -> bool:
	var space: PhysicsDirectSpaceState3D = game.get_world_3d().direct_space_state
	for lf in leaves:
		var bs: BoxShape3D = lf["shape"]
		_shape_q.shape = bs
		_shape_q.transform = _leaf_xf(lf, a) * Transform3D(Basis(), lf["center"])
		if space.intersect_shape(_shape_q, 1).size() > 0:
			return true
	return false


func _physics_process(dt: float) -> void:
	var spd: float = 95.0 if target > angle else 130.0
	var nxt: float = move_toward(angle, target, spd * dt)
	if _blocked(nxt):
		target = angle
		game.hud.message("Мешает коляска")
		set_physics_process(false)
		return
	angle = nxt
	_apply(angle)
	if is_equal_approx(angle, target):
		set_physics_process(false)
		if target <= 0.01:
			var s: String = "door_close_metal" if style.begins_with("metal") else "door_close_wood"
			game.play_at(s, center, -2.0, randf_range(0.95, 1.05), 28.0)
			game.critters.scare(center, 5.0)


## Сюжет: дверь резко захлопывается (сама), с громким ударом.
func slam() -> void:
	set_physics_process(false)
	var from: float = angle
	var tw := create_tween()
	tw.tween_method(_set_now, from, 0.0, 0.18).set_ease(Tween.EASE_IN)
	await tw.finished
	game.play_at("door_close_wood", center, 4.0, 0.8, 40.0)


## Сюжет: открыть до угла a (плавно за seconds).
func swing_to(a: float, seconds := 0.8) -> void:
	set_physics_process(false)
	var tw := create_tween()
	tw.tween_method(_set_now, angle, a, seconds).set_ease(Tween.EASE_OUT)
	await tw.finished


## Сюжет: дверь дрожит от ударов с той стороны.
func rattle(strength := 3.0) -> void:
	var base: float = angle
	var tw := create_tween()
	for i in 4:
		tw.tween_method(_apply, base, base + strength * (1.0 if i % 2 == 0 else 0.4), 0.04)
		tw.tween_method(_apply, base + strength, base, 0.06)


func _set_now(a: float) -> void:
	angle = a
	target = a
	_apply(a)


func leaf_bodies() -> Array:
	var out := []
	for lf in leaves:
		out.append(lf["body"])
	return out
