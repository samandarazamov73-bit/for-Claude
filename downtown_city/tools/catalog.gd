extends Node3D
## Dev tool: renders every kit module in a labelled grid (flat colours per material).
## Run: godot --path . res://tools/catalog.tscn -- page=0

const COLORS := {
	"MI_RedBrick": Color(0.55, 0.22, 0.17), "MI_RedBrick_Pale": Color(0.85, 0.8, 0.7),
	"MI_Trim": Color(0.93, 0.9, 0.8), "MI_Trim_MetalConcrete": Color(0.18, 0.18, 0.2),
	"MI_Trim_Dark": Color(0.1, 0.1, 0.1), "MI_Trim_Green": Color(0.2, 0.45, 0.3),
	"MI_FakeInterior": Color(1.0, 0.75, 0.3), "MI_Roof_Slate": Color(0.25, 0.27, 0.35),
	"MI_Asphalt": Color(0.2, 0.2, 0.22), "MI_StreetDecals": Color(1, 1, 1),
	"MI_Ornaments": Color(0.5, 0.5, 0.6), "MI_Dirt": Color(0.3, 0.2, 0.1), "MI_Concrete": Color(0.6, 0.6, 0.6),
}

func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(get_tree().quit)
	var page := 0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("page="): page = int(a.substr(5))
	var env := WorldEnvironment.new(); var e := Environment.new()
	e.background_mode = Environment.BG_COLOR; e.background_color = Color(0.5, 0.6, 0.7)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; e.ambient_light_color = Color(0.6, 0.6, 0.6)
	env.environment = e; add_child(env)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-35, -30, 0); add_child(sun)
	var files: Array[String] = []
	for f in DirAccess.get_files_at("res://models/kit"):
		if f.ends_with(".gltf") and not f.begins_with("Building_"): files.append(f)
	files.sort()
	var per := 48
	var cols := 8
	var sub := files.slice(page * per, page * per + per)
	for i in sub.size():
		var ps: PackedScene = load("res://models/kit/" + sub[i])
		if ps == null:
			continue
		var n: Node3D = ps.instantiate()
		add_child(n)
		var x := (i % cols) * 6.0
		var y := -(i / cols) * 6.0
		n.position = Vector3(x, y, 0)
		for mi in n.find_children("*", "MeshInstance3D", true, false):
			var m: Mesh = mi.mesh
			for s in m.get_surface_count():
				var mat := StandardMaterial3D.new()
				var nm: String = m.surface_get_material(s).resource_name
				mat.albedo_color = COLORS.get(nm, Color.MAGENTA)
				mi.set_surface_override_material(s, mat)
		var l := Label3D.new(); l.text = sub[i].get_basename(); l.font_size = 40; l.pixel_size = 0.006
		l.position = Vector3(x, y - 0.6, 1.5); l.modulate = Color.BLACK; l.outline_size = 0
		add_child(l)
	var cam := Camera3D.new(); cam.projection = Camera3D.PROJECTION_ORTHOGONAL; cam.size = 37.0
	cam.position = Vector3(21, -14, 40); add_child(cam)
	cam.rotation_degrees = Vector3(-8, 12, 0)
	print("built"); for k in 4:
		await get_tree().process_frame
		print("frame ", k)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://catalog_%d.png" % page)
	get_tree().quit()
