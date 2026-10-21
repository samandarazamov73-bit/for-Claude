extends Node3D
## Dev tool: assembles one building per facade style and renders it.
## Run: godot --path . res://tools/test_buildings.tscn -- view=0

func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(get_tree().quit)
	var view := 0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("view="): view = int(a.substr(5))
	var envc := EnvironmentController.new()
	add_child(envc)
	var mats := CityMaterials.new()
	var kit := KitLibrary.new(mats)
	var props := PropFactory.new(mats, kit)
	var bg := BuildingGenerator.new(kit, mats, props)
	var chunk := CityChunk.new("test", Vector3.ZERO)
	var styles := ["brick_trim", "limestone", "redwhite", "painted", "metal_loft", "brick_single"]
	var x := 0.0
	var i := 0
	for s in styles:
		var spec := {"rect": Rect2(x, -18, 16, 18), "floors": 6, "ground_h": 4.0, "style": s, "seed": 0.1 + i * 0.13,
			"wall": [0, 9, 5, 13, 0, 1][i], "wall2": [9, 9, 0, 13, 3, 9][i], "trim": [0, 1, 0, 2, 4, 0][i],
			"street_sides": ["S", "E"], "roof": "mansard" if i % 2 == 0 else "flat",
			"storefronts": [{"side": "S", "offset": 8.0, "width": 6.0, "awning": "green", "sign": "T_Sign_Bakery"}]}
		if s == "brick_single":
			spec["fire_escape"] = {"side": "S", "offset": 3.0, "width": 6.0}
		bg.build(chunk, spec)
		x += 22.0
		i += 1
	var jg := {"prebuilt": "Building_Large_2", "xform": Transform3D(Basis(), Vector3(-20, 0, 0)), "seed": 0.3, "wall": 0, "trim": 4}
	bg.build(chunk, jg)
	var t := props.tree_mesh(0)
	for k in 6:
		chunk.add_instance(t, Transform3D(Basis(), Vector3(k * 22.0 + 4.0, 0, 6)), Color(0.5, 0.5, 0.3, 0), "street", true)
		chunk.add_instance(props.tree_guard_mesh(), Transform3D(Basis(), Vector3(k * 22.0 + 4.0, 0, 6)), Color(), "props")
	chunk.add_instance(props.lamp_mesh(), Transform3D(Basis(), Vector3(10, 0, 7)), Color(), "street", true)
	chunk.add_instance(props.signal_mesh(), Transform3D(Basis(), Vector3(32, 0, 7)), Color(), "street", true)
	chunk.add_instance(props.hydrant_mesh(), Transform3D(Basis(), Vector3(14, 0, 6)), Color(), "props")
	chunk.add_instance(props.planter_mesh(3.0), Transform3D(Basis(), Vector3(26, 0, 1)), Color(), "props")
	chunk.ground.set_material(mats.sidewalk)
	chunk.ground.add_quad(Vector3(-60, 0, 12), Vector3(160, 0, 12), Vector3(160, 0, -40), Vector3(-60, 0, -40), Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1))
	chunk.ground.set_material(mats.road)
	chunk.ground.color = Color(0.6, 0, 0, 1)
	chunk.ground.uv2 = Vector2(220, 0)
	var rb := chunk.ground
	rb.set_material(mats.road, true)
	rb.uv2 = Vector2(220, 0)
	rb.add_quad(Vector3(-60, -0.15, 24), Vector3(160, -0.15, 24), Vector3(160, -0.15, 12), Vector3(-60, -0.15, 12), Vector2(0, -6), Vector2(220, -6), Vector2(220, 6), Vector2(0, 6))
	chunk.build(self, envc.quality_settings())
	print("instances: ", chunk.stats.instances)
	var cam := Camera3D.new()
	cam.far = 2000
	add_child(cam)
	var views := [[Vector3(30, 6, 45), Vector3(40, 14, -9)], [Vector3(-45, 3, 25), Vector3(-15, 14, -8)], [Vector3(110, 35, 40), Vector3(80, 18, -9)], [Vector3(2, 2, 14), Vector3(8, 10, -2)]]
	cam.position = views[view][0]
	cam.look_at(views[view][1])
	for k in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://test_buildings_%d.png" % view)
	print("saved")
	get_tree().quit()
