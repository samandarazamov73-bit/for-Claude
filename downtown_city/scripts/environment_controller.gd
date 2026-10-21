class_name EnvironmentController
extends Node3D
## Sky, sun, post-processing, time of day and render quality.
## Quality presets are tuned for an Apple M1 (Metal, Forward+); an adaptive render-scale
## controller lowers the internal resolution (FSR upscaling) whenever the frame rate drops
## below the target, so the city stays above 30 FPS.

signal quality_changed(name: String)
signal time_changed(name: String)

const TIMES := {
	"day": {"sun_elev": 47.0, "sun_azim": 236.0, "sun_color": Color(1.0, 0.96, 0.9), "sun_energy": 1.55,
		"zenith": Color(0.16, 0.36, 0.74), "horizon": Color(0.66, 0.77, 0.9), "cloud": Color(1, 1, 1), "cloud_shadow": Color(0.66, 0.71, 0.8),
		"ambient": 1.0, "fog": Color(0.66, 0.74, 0.86), "fog_density": 0.0011, "night": 0.0, "exposure": 1.0, "stars": 0.0},
	"golden": {"sun_elev": 11.0, "sun_azim": 250.0, "sun_color": Color(1.0, 0.72, 0.45), "sun_energy": 1.7,
		"zenith": Color(0.2, 0.33, 0.6), "horizon": Color(0.95, 0.72, 0.5), "cloud": Color(1.0, 0.85, 0.7), "cloud_shadow": Color(0.55, 0.5, 0.6),
		"ambient": 0.75, "fog": Color(0.9, 0.72, 0.56), "fog_density": 0.0014, "night": 0.15, "exposure": 1.05, "stars": 0.0},
	"dusk": {"sun_elev": -3.0, "sun_azim": 262.0, "sun_color": Color(0.9, 0.5, 0.35), "sun_energy": 0.25,
		"zenith": Color(0.05, 0.08, 0.2), "horizon": Color(0.55, 0.36, 0.34), "cloud": Color(0.6, 0.45, 0.5), "cloud_shadow": Color(0.18, 0.18, 0.28),
		"ambient": 0.45, "fog": Color(0.3, 0.26, 0.32), "fog_density": 0.0016, "night": 0.7, "exposure": 1.25, "stars": 0.3},
	"night": {"sun_elev": 35.0, "sun_azim": 120.0, "sun_color": Color(0.55, 0.65, 0.9), "sun_energy": 0.12,
		"zenith": Color(0.01, 0.015, 0.04), "horizon": Color(0.06, 0.07, 0.12), "cloud": Color(0.12, 0.13, 0.18), "cloud_shadow": Color(0.04, 0.045, 0.07),
		"ambient": 0.35, "fog": Color(0.06, 0.07, 0.1), "fog_density": 0.0018, "night": 1.0, "exposure": 1.4, "stars": 1.0},
}
const TIME_ORDER := ["day", "golden", "dusk", "night"]

const QUALITY := {
	"low": {"scale": 0.6, "shadow_size": 2048, "splits": 2, "shadow_dist": 140.0, "ssao": false, "ssil": false, "ssr": false,
		"glow": true, "detail_shadows": false, "msaa": Viewport.MSAA_DISABLED, "fxaa": true, "soft_shadow": 0, "lod": 4.0},
	"medium": {"scale": 0.8, "shadow_size": 4096, "splits": 2, "shadow_dist": 200.0, "ssao": true, "ssil": false, "ssr": false,
		"glow": true, "detail_shadows": false, "msaa": Viewport.MSAA_DISABLED, "fxaa": true, "soft_shadow": 1, "lod": 2.0},
	"high": {"scale": 1.0, "shadow_size": 4096, "splits": 4, "shadow_dist": 280.0, "ssao": true, "ssil": true, "ssr": false,
		"glow": true, "detail_shadows": true, "msaa": Viewport.MSAA_2X, "fxaa": false, "soft_shadow": 2, "lod": 1.0},
}

var world_env: WorldEnvironment
var env: Environment
var sun: DirectionalLight3D
var sky_mat: ShaderMaterial
var current_time := "day"
var night_factor := 0.0
var current_quality := "medium"
var adaptive := true
var target_fps := 30.0
var _cur := {}
var _target := {}
var _blend := 1.0
var _fps_acc := 0.0
var _fps_frames := 0
var _fps_timer := 0.0
var _max_scale := 0.8


func _ready() -> void:
	world_env = WorldEnvironment.new()
	env = Environment.new()
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/sky.gdshader")
	sky_mat.set_shader_parameter("clouds_tex", load("res://textures/T_Clouds.png"))
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	sky.process_mode = Sky.PROCESS_MODE_AUTOMATIC
	env.sky = sky
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = 6.0
	env.ssao_radius = 1.4
	env.ssao_intensity = 1.8
	env.ssao_power = 1.4
	env.ssao_detail = 0.6
	env.ssao_horizon = 0.06
	env.ssao_light_affect = 0.15
	env.ssil_radius = 4.0
	env.ssil_intensity = 0.6
	env.glow_intensity = 0.55
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 1.1
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.set_glow_level(0, 0.0)
	env.set_glow_level(1, 0.6)
	env.set_glow_level(2, 0.8)
	env.set_glow_level(3, 0.5)
	env.set_glow_level(4, 0.3)
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_aerial_perspective = 0.55
	env.fog_sun_scatter = 0.12
	env.fog_sky_affect = 0.0
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.06
	env.adjustment_saturation = 1.08
	world_env.environment = env
	add_child(world_env)

	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.shadow_enabled = true
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_fade_start = 0.85
	sun.light_angular_distance = 0.0
	sun.shadow_opacity = 1.0
	add_child(sun)

	_cur = TIMES["day"].duplicate()
	_target = _cur
	_apply_time(_cur)
	set_quality(current_quality)


func cycle_time() -> void:
	set_time(TIME_ORDER[(TIME_ORDER.find(current_time) + 1) % TIME_ORDER.size()])


func set_time(name: String, instant := false) -> void:
	current_time = name
	_target = TIMES[name]
	_blend = 1.0 if instant else 0.0
	if instant:
		_cur = _target.duplicate()
		_apply_time(_cur)
	time_changed.emit(name)


func cycle_quality() -> void:
	var order := ["low", "medium", "high"]
	set_quality(order[(order.find(current_quality) + 1) % order.size()])


func set_quality(name: String) -> void:
	current_quality = name
	var q: Dictionary = QUALITY[name]
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if q.scale < 0.99 else Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = q.scale
	vp.fsr_sharpness = 0.35
	_max_scale = q.scale
	vp.msaa_3d = q.msaa
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if q.fxaa else Viewport.SCREEN_SPACE_AA_DISABLED
	vp.mesh_lod_threshold = q.lod
	RenderingServer.directional_shadow_atlas_set_size(q.shadow_size, true)
	RenderingServer.directional_soft_shadow_filter_set_quality(q.soft_shadow)
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS if q.splits == 4 else DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = q.shadow_dist
	sun.directional_shadow_split_1 = 0.12 if q.splits == 4 else 0.2
	sun.directional_shadow_split_2 = 0.3
	sun.directional_shadow_split_3 = 0.6
	env.ssao_enabled = q.ssao
	env.ssil_enabled = q.ssil
	env.ssr_enabled = q.ssr
	env.glow_enabled = q.glow
	for n in get_tree().get_nodes_in_group("detail_shadow_casters"):
		(n as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if q.detail_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	quality_changed.emit(name)


func quality_settings() -> Dictionary:
	return QUALITY[current_quality]


func _process(delta: float) -> void:
	if _blend < 1.0:
		_blend = minf(_blend + delta * 0.6, 1.0)
		var k := _blend * _blend * (3.0 - 2.0 * _blend)
		var mixed := {}
		for key in _target:
			var a = _cur[key]
			var b = _target[key]
			if a is Color:
				mixed[key] = (a as Color).lerp(b, k)
			elif a is float:
				mixed[key] = lerpf(a, b, k)
			else:
				mixed[key] = b
		_apply_time(mixed)
		if _blend >= 1.0:
			_cur = _target.duplicate()
	_adaptive_resolution(delta)


func _apply_time(t: Dictionary) -> void:
	var elev := deg_to_rad(t.sun_elev)
	var azim := deg_to_rad(t.sun_azim)
	# direction *towards* the sun; azimuth measured from north (-Z) clockwise
	var to_sun := Vector3(sin(azim) * cos(elev), sin(elev), -cos(azim) * cos(elev))
	sun.look_at_from_position(Vector3.ZERO, -to_sun, Vector3.UP if absf(to_sun.y) < 0.99 else Vector3.FORWARD)
	sun.light_color = t.sun_color
	sun.light_energy = t.sun_energy
	sun.shadow_enabled = t.sun_energy > 0.2
	sky_mat.set_shader_parameter("zenith_color", t.zenith)
	sky_mat.set_shader_parameter("horizon_color", t.horizon)
	sky_mat.set_shader_parameter("cloud_color", t.cloud)
	sky_mat.set_shader_parameter("cloud_shadow", t.cloud_shadow)
	sky_mat.set_shader_parameter("ground_color", (t.horizon as Color).darkened(0.55))
	sky_mat.set_shader_parameter("stars", t.stars)
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = t.ambient
	env.fog_light_color = t.fog
	env.fog_density = t.fog_density
	env.tonemap_exposure = t.exposure
	night_factor = t.night
	RenderingServer.global_shader_parameter_set("night_factor", t.night)


func _adaptive_resolution(delta: float) -> void:
	_fps_timer += delta
	_fps_frames += 1
	if _fps_timer < 1.5:
		return
	var fps := _fps_frames / _fps_timer
	_fps_timer = 0.0
	_fps_frames = 0
	if not adaptive:
		return
	var vp := get_viewport()
	var s := vp.scaling_3d_scale
	if fps < target_fps + 3.0 and s > 0.5:
		s = maxf(s - 0.07, 0.5)
	elif fps > target_fps * 1.75 and s < _max_scale:
		s = minf(s + 0.05, _max_scale)
	if not is_equal_approx(s, vp.scaling_3d_scale):
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if s < 0.99 else Viewport.SCALING_3D_MODE_BILINEAR
		vp.scaling_3d_scale = s
