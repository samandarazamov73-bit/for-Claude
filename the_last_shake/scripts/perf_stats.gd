@tool
class_name PerfStats
extends RefCounted
## Collects the numbers shown by the F3 overlay and written by the benchmark:
## * allocated (unique) triangles — every distinct mesh/LOD the environment owns, i.e. the asset budget;
## * submitted triangles per frame — what the GPU processes this frame (main pass and shadow passes),
##   which is much larger because instanced meshes are drawn many times;
## * draw calls, objects, instances per LOD, memory.


static func snapshot(world: Node) -> Dictionary:
	var vp := world.get_viewport()
	var d := {}
	d["fps"] = Engine.get_frames_per_second()
	d["frame_ms"] = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	d["main_primitives"] = vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
	d["main_draw_calls"] = vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	d["main_objects"] = vp.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_OBJECTS_IN_FRAME)
	d["shadow_primitives"] = vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_PRIMITIVES_IN_FRAME)
	d["shadow_draw_calls"] = vp.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)
	d["video_mem_mb"] = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	d["texture_mem_mb"] = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0
	d["buffer_mem_mb"] = Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0
	d["ram_static_mb"] = Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0
	d["nodes"] = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	d["gpu"] = RenderingServer.get_video_adapter_name()
	d["renderer"] = str(ProjectSettings.get_setting("rendering/renderer/rendering_method"))
	if RenderingServer.has_method("get_current_rendering_method"):
		d["renderer"] = str(RenderingServer.call("get_current_rendering_method"))
	d["api"] = RenderingServer.get_video_adapter_api_version()
	return d


## Unique triangles per budget category, read from assets/catalog.json plus terrain and road.
static func allocated_budget(world: Node) -> Dictionary:
	var cat: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/catalog.json"))
	var b := {}
	for v in cat["variants"]:
		var key := ""
		match str(v["category"]):
			"tree": key = "large_trees"
			"understory": key = "medium_vegetation"
			"bush": key = "bushes_and_plants"
			"rock": key = "rocks_and_stones"
			"prop": key = "ground_details"
			"detail": key = "additional_details"
			"cover":
				match str(v["kind"]):
					"stone": key = "rocks_and_stones"
					"branches": key = "ground_details"
					"sprouts": key = "ground_details"
					_: key = "bushes_and_plants"
		var t := 0
		for x in v["tris"]:
			t += int(x)
		b[key] = int(b.get(key, 0)) + t
	if world.has_method("get_terrain_triangles"):
		b["terrain"] = world.get_terrain_triangles()
		b["road"] = world.get_road_triangles()
	var total := 0
	for k in b:
		total += int(b[k])
	b["total"] = total
	return b
