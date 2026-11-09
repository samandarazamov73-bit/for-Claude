extends Node
## Graphics quality: Low / Medium / High, switched with G (or F2) and remembered between runs.
## The 3D picture is rendered at a resolution limited by a pixel budget and upscaled with AMD FSR 1,
## so a Retina MacBook (2560x1600 and more) does not render 4 million pixels per frame.
## Mac (Apple M1 and newer) starts on Medium, Windows and Linux on High.

const NAMES := ["Низкое", "Среднее", "Высокое"]
const SAVE_PATH := "user://settings.cfg"

# per level: Low, Medium, High
const PIXEL_BUDGET := [1280 * 720, 1700 * 960, 0]   # max 3D pixels per frame, 0 = native resolution
const SSAO := [false, true, true]
const SSIL := [false, false, true]
const FOG_SIZE := [[40, 48], [52, 56], [64, 64]]       # volumetric fog froxel grid (xy, depth)
const SHADOWED_LAMPS := [3, 5, 8]
const SHADOW_ATLAS := [2048, 2048, 4096]
const MOON_ATLAS := [2048, 2048, 4096]
const MOON_SHADOW_DIST := [24.0, 32.0, 40.0]
# The moon's shadow is redrawn every frame and was most of all shadow work (about 87 % of the shadow
# draw calls in the hall). Two cascades instead of four: sharp up to about 8 m, softer beyond.
const MOON_TWO_SPLITS := [true, true, false]
# High only (too heavy for a fanless MacBook): reflections of the lamps in the polished terrazzo and
# linoleum, and a camera lens that softly loses focus beyond about 15 m, as in a film.
const SSR := [false, false, true]
const DOF_FAR := [false, false, true]
const SOFT_SHADOWS := [RenderingServer.SHADOW_QUALITY_SOFT_VERY_LOW, RenderingServer.SHADOW_QUALITY_SOFT_LOW,
	RenderingServer.SHADOW_QUALITY_SOFT_LOW]

## Frame-rate limit, switched with L: 30 fps or none (then the screen's refresh rate, with vsync).
## On Medium a MacBook GPU does not reach 60 fps, so it works flat out and only a limit below what it
## manages makes it cooler. On by default on a MacBook Air, which has no fan.
const FPS_LIMIT := 30

var game
var level := 2
var fps_limited := false


func setup(g) -> void:
	game = g
	level = 1 if OS.has_feature("macos") else 2
	fps_limited = OS.get_model_name().begins_with("MacBookAir")
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		level = clampi(int(cfg.get_value("graphics", "quality", level)), 0, 2)
		fps_limited = bool(cfg.get_value("graphics", "fps_limit_30", fps_limited))
	get_window().size_changed.connect(_apply_scale)
	apply()
	game.hud.update_fps_cap()


func cycle() -> void:
	level = (level + 1) % NAMES.size()
	apply()
	_save("quality", level)
	game.hud.message("Графика: " + NAMES[level])


func toggle_fps_limit() -> void:
	fps_limited = not fps_limited
	_save("fps_limit_30", fps_limited)
	game.hud.update_fps_cap()
	game.hud.message("Не больше %d кадров/с: меньше греется" % FPS_LIMIT if fps_limited else "Без ограничения кадров")


## The frame-rate limit for normal play, 0 = none.
func fps_cap() -> int:
	return FPS_LIMIT if fps_limited else 0


func _save(key: String, value) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SAVE_PATH)
	cfg.set_value("graphics", key, value)
	cfg.save(SAVE_PATH)


func apply() -> void:
	var env: Environment = game.env
	env.volumetric_fog_enabled = fog_supported()
	env.ssao_enabled = SSAO[level]
	env.ssil_enabled = SSIL[level]
	env.ssr_enabled = SSR[level]
	env.ssr_max_steps = 40
	env.ssr_fade_in = 0.15
	env.ssr_fade_out = 2.0
	env.ssr_depth_tolerance = 0.25
	if game.player and game.player.cam:
		var ca: CameraAttributesPractical = game.player.cam.attributes
		if ca == null:
			ca = CameraAttributesPractical.new()
			ca.dof_blur_far_distance = 15.0
			ca.dof_blur_far_transition = 12.0
			ca.dof_blur_amount = 0.05
			game.player.cam.attributes = ca
		ca.dof_blur_far_enabled = DOF_FAR[level]
	RenderingServer.environment_set_volumetric_fog_volume_size(FOG_SIZE[level][0], FOG_SIZE[level][1])
	RenderingServer.positional_soft_shadow_filter_set_quality(SOFT_SHADOWS[level])
	RenderingServer.directional_soft_shadow_filter_set_quality(SOFT_SHADOWS[level])
	RenderingServer.directional_shadow_atlas_set_size(MOON_ATLAS[level], true)
	game.moon.directional_shadow_max_distance = MOON_SHADOW_DIST[level]
	if MOON_TWO_SPLITS[level]:
		game.moon.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		game.moon.directional_shadow_split_1 = 0.25
	else:
		game.moon.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		game.moon.directional_shadow_split_1 = 0.1
	get_viewport().positional_shadow_atlas_size = SHADOW_ATLAS[level]
	shadow_budget()
	if game.hud:
		game.hud.set_lens(level >= 1)
	_apply_scale()


## Lamp shadows, and the torch's: on Low the torch has none, otherwise it takes the place of one lamp shadow,
## so switching it on does not make the GPU work harder.
func shadow_budget() -> void:
	var torch_on: bool = game.player != null and game.player.torch != null and game.player.torch_on
	if game.player and game.player.torch:
		game.player.torch.shadow_enabled = level >= 1
	if game.lights:
		game.lights.max_shadows = SHADOWED_LAMPS[level] - (1 if torch_on and level >= 1 else 0)


## Godot 4.7's Metal driver turns on texture atomics from the macOS version alone, but the texture format
## behind volumetric fog needs an Apple Silicon GPU. On Intel Macs and virtual GPUs the fog breaks, so it
## stays off there unless GODOT_MTL_DISABLE_IMAGE_ATOMICS=1 makes Godot use its fallback path.
func fog_supported() -> bool:
	if RenderingServer.get_current_rendering_driver_name() != "metal":
		return true
	if OS.get_environment("GODOT_MTL_DISABLE_IMAGE_ATOMICS") == "1":
		return true
	return RenderingServer.get_video_adapter_name().begins_with("Apple M")


func _apply_scale() -> void:
	var vp := get_viewport()
	var px := get_window().size
	var budget: int = PIXEL_BUDGET[level]
	var scale := 1.0
	if budget > 0 and px.x * px.y > budget:
		scale = clampf(sqrt(float(budget) / float(px.x * px.y)), 0.4, 1.0)
	if scale < 0.99:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
		vp.scaling_3d_scale = scale
		vp.fsr_sharpness = 0.25
	else:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		vp.scaling_3d_scale = 1.0
