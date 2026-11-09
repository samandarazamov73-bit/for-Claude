extends Node
## Запускает tests/shots.gd отдельным узлом (чтобы он пережил смену сцен).


func _ready() -> void:
	var runner: Node = load("res://tests/shots.gd").new()
	runner.name = "ShotRunner"
	get_tree().root.add_child.call_deferred(runner)
