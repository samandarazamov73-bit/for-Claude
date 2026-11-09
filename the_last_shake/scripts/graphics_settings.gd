extends Node
## Graphics presets (LOW / MEDIUM / HIGH / ULTRA).
##
## A preset is a plain dictionary of settings. GraphicsSettings applies the renderer-level parts
## itself (viewport scaling, AA, shadow atlas, filter quality) and emits `changed` so the world can
## apply the scene-level parts (environment effects, sun shadows, LOD / draw distances, density).
## The choice is stored in user://graphics.cfg. On first launch a preset is picked from the GPU name.
## Features that the Mobile renderer does not have (SSAO, SSIL, SSR, volumetric fog) are switched
## off automatically when the game runs with --rendering-method mobile.

signal changed(settings: Dictionary)

enum Preset { LOW, MEDIUM, HIGH, ULTRA }
const NAMES := ["Low", "Medium", "High", "Ultra"]
const CONFIG_PATH := "user://graphics.cfg"

const PRESETS := {
	Preset.LOW: {
		"render_scale": 0.75, "fsr": true, "msaa": 0, "taa": false, "fxaa": true,
		"ssao": false, "ssil": false, "ssr": false, "glow": false, "volumetric_fog": false,
		"shadow_atlas": 2048, "shadow_distance": 60.0, "shadow_splits": 2, "soft_shadow_quality": 1,
		"sun_angular": 0.0, "lod_scale": 0.6, "far_scale": 0.62, "cover_distance": 0.55, "cover_density": 0.45,
		"cover_shadows": false, "terrain_lod_scale": 0.65, "anisotropy": 1, "fog_scale": 1.45,
		"far_plane": 650.0, "terrain_anti_tiling": false, "shadow_lod1": false, "shadow_coarse": true,
	},
	Preset.MEDIUM: {
		"render_scale": 0.85, "fsr": true, "msaa": 0, "taa": false, "fxaa": true,
		"ssao": true, "ssil": false, "ssr": false, "glow": true, "volumetric_fog": false,
		"shadow_atlas": 4096, "shadow_distance": 90.0, "shadow_splits": 2, "soft_shadow_quality": 2,
		"sun_angular": 0.0, "lod_scale": 0.8, "far_scale": 0.8, "cover_distance": 0.8, "cover_density": 0.75,
		"cover_shadows": false, "terrain_lod_scale": 0.85, "anisotropy": 2, "fog_scale": 1.15,
		"far_plane": 900.0, "terrain_anti_tiling": true, "shadow_lod1": false, "shadow_coarse": true,
	},
	Preset.HIGH: {
		"render_scale": 1.0, "fsr": false, "msaa": 0, "taa": true, "fxaa": false,
		"ssao": true, "ssil": true, "ssr": false, "glow": true, "volumetric_fog": true,
		"shadow_atlas": 4096, "shadow_distance": 110.0, "shadow_splits": 2, "soft_shadow_quality": 3,
		"sun_angular": 0.3, "lod_scale": 1.0, "far_scale": 1.0, "cover_distance": 1.0, "cover_density": 1.0,
		"cover_shadows": false, "terrain_lod_scale": 1.0, "anisotropy": 3, "fog_scale": 1.0,
		"far_plane": 1200.0, "terrain_anti_tiling": true, "shadow_lod1": true, "shadow_coarse": false,
	},
	Preset.ULTRA: {
		"render_scale": 1.0, "fsr": false, "msaa": 2, "taa": true, "fxaa": false,
		"ssao": true, "ssil": true, "ssr": true, "glow": true, "volumetric_fog": true,
		"shadow_atlas": 8192, "shadow_distance": 190.0, "shadow_splits": 4, "soft_shadow_quality": 4,
		"sun_angular": 0.5, "lod_scale": 1.35, "far_scale": 1.4, "cover_distance": 1.4, "cover_density": 1.0,
		"cover_shadows": true, "terrain_lod_scale": 1.3, "anisotropy": 4, "fog_scale": 0.8,
		"far_plane": 1500.0, "terrain_anti_tiling": true, "shadow_lod1": true, "shadow_coarse": false,
	},
}

var preset: int = Preset.MEDIUM
var settings: Dictionary = {}
var fps_cap := 0
var auto_detected := false


func _ready() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK and cfg.has_section_key("graphics", "preset"):
		preset = clampi(int(cfg.get_value("graphics", "preset")), 0, 3)
		fps_cap = int(cfg.get_value("graphics", "fps_cap", 0))
	else:
		preset = detect_preset()
		auto_detected = true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--quality="):
			var q := arg.get_slice("=", 1).to_lower()
			for i in NAMES.size():
				if NAMES[i].to_lower() == q:
					preset = i
					auto_detected = false
	settings = build(preset)
	Engine.max_fps = fps_cap
	apply_renderer_settings.call_deferred()


## Picks a starting preset from the GPU name (only used until the player chooses one).
func detect_preset() -> int:
	var gpu := RenderingServer.get_video_adapter_name().to_lower()
	var vendor := RenderingServer.get_video_adapter_vendor().to_lower()
	if gpu.contains("llvmpipe") or gpu.contains("swiftshader") or gpu.contains("lavapipe") or gpu.contains("microsoft basic"):
		return Preset.LOW
	if gpu.contains("apple"):
		if gpu.contains("max") or gpu.contains("ultra") or gpu.contains("pro"):
			return Preset.HIGH
		return Preset.MEDIUM
	if vendor.contains("intel") or gpu.contains("intel"):
		return Preset.MEDIUM if (gpu.contains("arc") or gpu.contains("xe")) else Preset.LOW
	if gpu.contains("radeon(tm) graphics") or gpu.contains("radeon graphics") or gpu.contains("vega"):
		return Preset.MEDIUM
	if gpu.contains("nvidia") or gpu.contains("geforce") or gpu.contains("rtx") or gpu.contains("radeon rx"):
		return Preset.HIGH
	return Preset.MEDIUM


func is_mobile_renderer() -> bool:
	var method := str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "forward_plus"))
	if RenderingServer.has_method("get_current_rendering_method"):
		method = str(RenderingServer.call("get_current_rendering_method"))
	return method != "forward_plus"


func build(p: int) -> Dictionary:
	var s: Dictionary = PRESETS[p].duplicate(true)
	s["name"] = NAMES[p]
	s["preset"] = p
	if is_mobile_renderer():
		for k in ["ssao", "ssil", "ssr", "volumetric_fog"]:
			s[k] = false
		s["taa"] = false
		s["fxaa"] = true
		s["fsr"] = false        # FSR 1 scaling is Forward+ only
	return s


func set_preset(p: int, persist := true) -> void:
	preset = clampi(p, 0, 3)
	settings = build(preset)
	if persist:
		save()
	apply_renderer_settings()


func cycle() -> void:
	set_preset((preset + 1) % 4)


func toggle_fps_cap() -> void:
	fps_cap = 30 if fps_cap == 0 else 0
	Engine.max_fps = fps_cap
	save()


func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("graphics", "preset", preset)
	cfg.set_value("graphics", "fps_cap", fps_cap)
	cfg.save(CONFIG_PATH)


func apply_renderer_settings() -> void:
	var vp := get_tree().root
	var s := settings
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if s["fsr"] else Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = s["render_scale"]
	vp.msaa_3d = [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_4X][clampi(int(s["msaa"]) / 2, 0, 2)]
	vp.use_taa = s["taa"]
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if s["fxaa"] else Viewport.SCREEN_SPACE_AA_DISABLED
	vp.anisotropic_filtering_level = int(s["anisotropy"]) as Viewport.AnisotropicFiltering
	vp.mesh_lod_threshold = 1.0 if preset >= Preset.HIGH else 2.0
	RenderingServer.directional_shadow_atlas_set_size(int(s["shadow_atlas"]), true)
	RenderingServer.directional_soft_shadow_filter_set_quality(int(s["soft_shadow_quality"]) as RenderingServer.ShadowQuality)
	RenderingServer.environment_set_ssao_quality(
		RenderingServer.ENV_SSAO_QUALITY_HIGH if preset >= Preset.HIGH else RenderingServer.ENV_SSAO_QUALITY_MEDIUM,
		true, 0.5, 2, 50.0, 300.0)
	RenderingServer.environment_set_volumetric_fog_volume_size(160 if preset == Preset.ULTRA else 96, 96 if preset == Preset.ULTRA else 64)
	changed.emit(s)
