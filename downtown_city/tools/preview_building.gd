extends Node3D
## Dev tool: preview a kit prebuilt building with flat material colours.
## Run: godot --path . res://tools/preview_building.tscn -- name=Building_Large_2 yaw=35

func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(get_tree().quit)
	var bname := "Building_Large_2"
	var yaw := 35.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("name="): bname = a.substr(5)
		if a.begins_with("yaw="): yaw = float(a.substr(4))
	var cat := preload("res://tools/catalog.gd")
	var env := WorldEnvironment.new(); var e := Environment.new()
	e.background_mode = Environment.BG_COLOR; e.background_color = Color(0.55, 0.7, 0.9)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR; e.ambient_light_color = Color(0.5, 0.5, 0.55)
	env.environment = e; add_child(env)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-40, -60, 0); sun.shadow_enabled = true; add_child(sun)
	var n: Node3D = load("res://models/kit/%s.gltf" % bname).instantiate()
	add_child(n)
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		var m: Mesh = mi.mesh
		for s in m.get_surface_count():
			var mat := StandardMaterial3D.new()
			var nm: String = m.surface_get_material(s).resource_name
			mat.albedo_color = cat.COLORS.get(nm, Color(1, 0.6, 0.2) if nm.begins_with("MI_FakeInterior") else Color.MAGENTA)
			mi.set_surface_override_material(s, mat)
	var aabb := AABB()
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		aabb = mi.get_aabb()
	var c := aabb.get_center()
	var cam := Camera3D.new(); add_child(cam); cam.fov = 60
	var d := aabb.size.length() * 1.1
	cam.position = c + Vector3(sin(deg_to_rad(yaw)), 0.0, cos(deg_to_rad(yaw))) * d + Vector3(0, -c.y + 2.0, 0)
	cam.look_at(c + Vector3(0, 2, 0))
	for k in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://preview_%s_%d.png" % [bname, int(yaw)])
	get_tree().quit()
