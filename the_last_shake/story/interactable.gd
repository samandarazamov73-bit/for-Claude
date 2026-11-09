extends Area3D
## Предмет, на который можно навести взгляд и нажать E (коляска из санатория ищет у тел мету «interact»).

var text := "[E]"
var action: Callable
var enabled := true


func setup(size: Vector3, prompt_text: String, on_use: Callable, layer := 8) -> void:
	text = prompt_text
	action = on_use
	collision_layer = layer
	collision_mask = 0
	monitoring = false
	monitorable = true
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	add_child(cs)
	set_meta("interact", self)


func prompt(_by) -> String:
	return text if enabled else ""


func interact(_by) -> void:
	if enabled and action.is_valid():
		action.call()
