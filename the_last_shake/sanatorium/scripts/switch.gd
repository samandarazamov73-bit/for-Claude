extends Area3D
## Wall light switch of a room: toggles all working lamps of the room.

var game
var room := ""


func _ready() -> void:
	collision_layer = game.L_INTERACT
	collision_mask = 0
	monitoring = false
	monitorable = true
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(0.16, 0.2, 0.16)
	cs.shape = bs
	add_child(cs)
	set_meta("interact", self)


func prompt(_by) -> String:
	return "[E] Выключить свет" if game.lights.is_on(room) else "[E] Включить свет"


func interact(_by) -> void:
	game.play_at("switch", global_position, -6.0, randf_range(0.95, 1.05), 12.0)
	var on: bool = not game.lights.is_on(room)
	game.lights.set_room(room, on)
	if on:
		if game.lights.working_count(room) == 0:
			game.hud.message("Лампа не работает")
		game.critters.light_on(room)
