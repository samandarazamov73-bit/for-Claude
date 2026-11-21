extends SceneTree
# Renders every .glb in a folder from front (+Z), right (+X), back (-Z) and top, glTF axes, orthographic.
var files: Array = []
var src := ""
var out := ""
var idx := -1
var stage := 0
var frames := 0
var holder: Node3D
var cam: Camera3D
var shots: Array = []
var aabb := AABB()

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--src="): src = a.substr(6)
		if a.begins_with("--out="): out = a.substr(6)
	for f in DirAccess.get_files_at(src):
		if f.to_lower().ends_with(".glb"): files.append(f)
	files.sort()
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.32, 0.34, 0.37)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.55, 0.58)
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 30, 0)
	sun.light_energy = 1.6
	root.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, 200, 0)
	fill.light_energy = 0.5
	root.add_child(fill)
	cam = Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	root.add_child(cam)
	cam.current = true
	# floor grid reference at y = 0 is not drawn: models are centred, a grid would cut them

func _calc_aabb(n: Node) -> void:
	if n is MeshInstance3D and n.mesh:
		var b: AABB = (n as MeshInstance3D).global_transform * n.mesh.get_aabb()
		aabb = b if aabb.size == Vector3.ZERO else aabb.merge(b)
	for c in n.get_children():
		_calc_aabb(c)

func _process(_d: float) -> bool:
	frames += 1
	if idx < 0 or stage >= 4:
		if idx >= 0:
			_save()
		idx += 1
		if idx >= files.size():
			return true
		if holder: holder.queue_free()
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		if doc.append_from_file(src.path_join(files[idx]), st) != OK:
			print("FAIL ", files[idx]); stage = 4; return false
		holder = doc.generate_scene(st)
		root.add_child(holder)
		aabb = AABB(); _calc_aabb(holder)
		stage = 0; frames = 0; shots = []
		_place()
		return false
	if frames >= 3:
		shots.append(root.get_viewport().get_texture().get_image())
		stage += 1; frames = 0
		if stage < 4: _place()
	return false

func _place() -> void:
	var c := aabb.get_center()
	var r := aabb.size.length() * 0.5 + 0.01
	cam.size = r * 2.1
	var dirs := [Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0.0001)]
	var d: Vector3 = dirs[stage]
	cam.position = c + d * r * 4.0
	cam.look_at(c, Vector3.UP if stage < 3 else Vector3(0, 0, -1))
	cam.near = 0.01; cam.far = r * 10.0

func _save() -> void:
	if shots.size() < 4: return
	var w: int = shots[0].get_width(); var h: int = shots[0].get_height()
	var img := Image.create(w * 4, h, false, shots[0].get_format())
	for i in 4:
		img.blit_rect(shots[i], Rect2i(0, 0, w, h), Vector2i(w * i, 0))
	img.save_png(out.path_join(files[idx].get_basename() + ".png"))
	print("OK ", files[idx], " ", aabb)
