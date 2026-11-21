extends Node
## Загружает все .gd проекта с автозагрузками и печатает, какие не компилируются.
func _ready() -> void:
	var bad := 0
	var n := 0
	for dir in ["res://story", "res://sanatorium/scripts"]:
		for f in _list(dir):
			n += 1
			var s = ResourceLoader.load(f, "", ResourceLoader.CACHE_MODE_IGNORE)
			if s == null or not (s as Script).can_instantiate():
				print("BAD ", f)
				bad += 1
	print("COMPILE CHECK: %d scripts, %d bad" % [n, bad])
	get_tree().quit()

func _list(dir: String) -> Array:
	var out := []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir + "/" + f)
	for sub in d.get_directories():
		out += _list(dir + "/" + sub)
	return out
