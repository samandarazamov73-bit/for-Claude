class_name CityMaterials
extends RefCounted
## Creates every material of the city once; all generators share these instances,
## which keeps the number of shader variants / pipeline states small.

var kit := {}        # kit material name -> Material
var road: ShaderMaterial
var sidewalk: ShaderMaterial
var curb: ShaderMaterial
var plaza: ShaderMaterial
var roof_tar: ShaderMaterial
var courtyard: ShaderMaterial
var far_facade: ShaderMaterial
var decal: ShaderMaterial
var metal_dark: StandardMaterial3D
var metal_green: StandardMaterial3D
var iron: StandardMaterial3D
var steel: StandardMaterial3D
var bark: StandardMaterial3D
var leaves: ShaderMaterial
var hedge: ShaderMaterial
var soil: StandardMaterial3D
var lamp_glass: ShaderMaterial
var signal_red: StandardMaterial3D
var signal_off: StandardMaterial3D
var awning := {}     # colour name -> StandardMaterial3D
var signs := {}      # texture file -> ShaderMaterial
var fabric_white: StandardMaterial3D
var hydrant_red: StandardMaterial3D
var trash_green: StandardMaterial3D
var mailbox_blue: StandardMaterial3D
var wood_bench: StandardMaterial3D
var water_tank: StandardMaterial3D
var interior_default: ShaderMaterial
var interior_shop: ShaderMaterial
var interior_office: ShaderMaterial
var interior_dark: ShaderMaterial
var interior_lit: ShaderMaterial
var shadow_only: StandardMaterial3D


static func tex(name: String) -> Texture2D:
	return load("res://textures/%s.png" % name)


func _init() -> void:
	var wall_sh: Shader = load("res://shaders/kit_wall.gdshader")
	var trim_sh: Shader = load("res://shaders/kit_trim.gdshader")
	var metal_sh: Shader = load("res://shaders/kit_metal.gdshader")
	var ground_sh: Shader = load("res://shaders/ground.gdshader")
	var interior_sh: Shader = load("res://shaders/window_interior.gdshader")

	var wall_primary := ShaderMaterial.new()
	wall_primary.shader = wall_sh
	_set_wall_textures(wall_primary)
	var wall_secondary := wall_primary.duplicate() as ShaderMaterial
	wall_secondary.set_shader_parameter("secondary", true)
	kit["MI_RedBrick"] = wall_primary
	kit["MI_RedBrick_Pale"] = wall_secondary

	var trim := ShaderMaterial.new()
	trim.shader = trim_sh
	trim.set_shader_parameter("albedo_tex", tex("T_Trim_BaseColor"))
	trim.set_shader_parameter("normal_tex", tex("T_Trim_Normal"))
	trim.set_shader_parameter("orm_tex", tex("T_Trim_ORM"))
	kit["MI_Trim"] = trim
	var trim_dark := trim.duplicate() as ShaderMaterial
	trim_dark.set_shader_parameter("use_palette", false)
	trim_dark.set_shader_parameter("fixed_tint", Color(0.115, 0.115, 0.125))
	trim_dark.set_shader_parameter("roughness_bias", -0.25)
	kit["MI_Trim_Dark"] = trim_dark
	var trim_green := trim.duplicate() as ShaderMaterial
	trim_green.set_shader_parameter("use_palette", false)
	trim_green.set_shader_parameter("fixed_tint", Color(0.13, 0.30, 0.21))
	trim_green.set_shader_parameter("roughness_bias", -0.2)
	kit["MI_Trim_Green"] = trim_green

	var metal := ShaderMaterial.new()
	metal.shader = metal_sh
	metal.set_shader_parameter("albedo_tex", tex("T_MetalConcrete_BaseColor"))
	metal.set_shader_parameter("normal_tex", tex("T_MetalConcrete_Normal"))
	metal.set_shader_parameter("orm_tex", tex("T_MetalConcrete_ORM"))
	kit["MI_Trim_MetalConcrete"] = metal

	var slate := StandardMaterial3D.new()
	slate.albedo_texture = tex("T_RoofSlate_BaseColor")
	slate.normal_enabled = true
	slate.normal_texture = tex("T_RoofSlate_Normal")
	slate.roughness_texture = tex("T_RoofSlate_ORM")
	slate.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
	slate.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	slate.metallic_specular = 0.4
	kit["MI_Roof_Slate"] = slate

	var orn := StandardMaterial3D.new()
	orn.albedo_texture = tex("T_Ornaments_BaseColor")
	orn.roughness = 0.6
	orn.metallic = 0.3
	kit["MI_Ornaments"] = orn

	soil = StandardMaterial3D.new()
	soil.albedo_texture = tex("T_Dirt_BaseColor")
	soil.roughness = 1.0
	soil.uv1_scale = Vector3(2, 2, 1)
	kit["MI_Dirt"] = soil

	var conc := ShaderMaterial.new()
	conc.shader = ground_sh
	conc.set_shader_parameter("albedo_tex", tex("T_Concrete_BaseColor"))
	conc.set_shader_parameter("normal_tex", tex("T_Concrete_Normal"))
	conc.set_shader_parameter("orm_tex", tex("T_Concrete_ORM"))
	conc.set_shader_parameter("tile_m", 2.0)
	conc.set_shader_parameter("tint", Color(1.1, 1.1, 1.08))
	kit["MI_Concrete"] = conc

	roof_tar = ShaderMaterial.new()
	roof_tar.shader = ground_sh
	roof_tar.set_shader_parameter("albedo_tex", tex("T_RoofTar_BaseColor"))
	roof_tar.set_shader_parameter("normal_tex", tex("T_RoofTar_Normal"))
	roof_tar.set_shader_parameter("orm_tex", tex("T_Concrete_ORM"))
	roof_tar.set_shader_parameter("tile_m", 4.0)
	roof_tar.set_shader_parameter("variation", 0.35)
	kit["MI_Asphalt"] = roof_tar

	interior_default = ShaderMaterial.new()
	interior_default.shader = interior_sh
	interior_shop = interior_default.duplicate() as ShaderMaterial
	interior_shop.set_shader_parameter("shop", true)
	interior_office = interior_default.duplicate() as ShaderMaterial
	interior_office.set_shader_parameter("office", true)
	interior_office.set_shader_parameter("min_depth", 5.0)
	interior_office.set_shader_parameter("max_depth", 8.0)
	interior_dark = interior_default.duplicate() as ShaderMaterial
	interior_dark.set_shader_parameter("force_dark", true)
	interior_lit = interior_default.duplicate() as ShaderMaterial
	interior_lit.set_shader_parameter("lit_bias", 0.25)
	kit["MI_FakeInterior"] = interior_default
	kit["MI_FakeInterior_1"] = interior_lit
	kit["MI_FakeInterior_2"] = interior_office
	kit["MI_FakeInterior_3"] = interior_default
	kit["MI_FakeInterior_4"] = interior_dark

	# --- streets
	road = ShaderMaterial.new()
	road.shader = load("res://shaders/road.gdshader")
	road.set_shader_parameter("asphalt_albedo", tex("T_Concrete_Asphalt_BaseColor"))
	road.set_shader_parameter("asphalt_normal", tex("T_Concrete_Normal"))
	road.set_shader_parameter("asphalt_orm", tex("T_Concrete_ORM"))

	sidewalk = ShaderMaterial.new()
	sidewalk.shader = ground_sh
	sidewalk.set_shader_parameter("albedo_tex", tex("T_Sidewalk_BaseColor"))
	sidewalk.set_shader_parameter("normal_tex", tex("T_Sidewalk_Normal"))
	sidewalk.set_shader_parameter("orm_tex", tex("T_Sidewalk_ORM"))
	sidewalk.set_shader_parameter("tile_m", 3.0)
	sidewalk.set_shader_parameter("tint", Color(0.74, 0.75, 0.78))

	curb = conc.duplicate() as ShaderMaterial
	curb.set_shader_parameter("tile_m", 1.5)
	curb.set_shader_parameter("tint", Color(0.95, 0.95, 0.95))

	plaza = sidewalk.duplicate() as ShaderMaterial
	plaza.set_shader_parameter("tint", Color(0.82, 0.82, 0.84))
	plaza.set_shader_parameter("tile_m", 6.0)

	courtyard = conc.duplicate() as ShaderMaterial
	courtyard.set_shader_parameter("tint", Color(0.75, 0.75, 0.75))
	courtyard.set_shader_parameter("tile_m", 4.0)

	far_facade = ShaderMaterial.new()
	far_facade.shader = load("res://shaders/facade_far.gdshader")
	far_facade.set_shader_parameter("red_albedo", tex("T_RedBrick_BaseColor"))
	far_facade.set_shader_parameter("pale_albedo", tex("T_PaleBrick_BaseColor"))
	far_facade.set_shader_parameter("stone_albedo", tex("T_Limestone_BaseColor"))
	far_facade.set_shader_parameter("roof_albedo", tex("T_RoofTar_BaseColor"))

	decal = ShaderMaterial.new()
	decal.shader = load("res://shaders/decal.gdshader")
	decal.set_shader_parameter("atlas", tex("T_RoadDecals"))
	decal.render_priority = 1

	# --- props
	metal_dark = _std(Color(0.07, 0.07, 0.075), 0.45, 0.6)
	metal_green = _std(Color(0.10, 0.20, 0.15), 0.5, 0.5)
	iron = _std(Color(0.05, 0.05, 0.05), 0.55, 0.7)
	steel = _std(Color(0.42, 0.43, 0.44), 0.4, 0.8)
	hydrant_red = _std(Color(0.55, 0.06, 0.05), 0.45, 0.2)
	trash_green = _std(Color(0.11, 0.24, 0.15), 0.6, 0.3)
	mailbox_blue = _std(Color(0.08, 0.16, 0.38), 0.5, 0.3)
	wood_bench = _std(Color(0.36, 0.22, 0.12), 0.75, 0.0)
	water_tank = _std(Color(0.36, 0.28, 0.22), 0.9, 0.0)
	fabric_white = _std(Color(0.85, 0.83, 0.78), 0.9, 0.0)
	signal_off = _std(Color(0.02, 0.02, 0.02), 0.3, 0.0)
	signal_red = _std(Color(0.1, 0.01, 0.01), 0.3, 0.0)
	signal_red.emission_enabled = true
	signal_red.emission = Color(1.0, 0.08, 0.05)
	signal_red.emission_energy_multiplier = 3.0

	bark = StandardMaterial3D.new()
	bark.albedo_texture = tex("T_Birch_BaseColor")
	bark.normal_enabled = true
	bark.normal_texture = tex("T_Birch_Normal")
	bark.roughness = 0.85
	bark.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC

	leaves = ShaderMaterial.new()
	leaves.shader = load("res://shaders/foliage.gdshader")
	leaves.set_shader_parameter("leaf_albedo", tex("T_Leaves_BaseColor"))
	leaves.set_shader_parameter("leaf_normal", tex("T_Leaves_Normal"))
	leaves.set_shader_parameter("tint", Color(1.32, 1.22, 0.78))
	hedge = leaves.duplicate() as ShaderMaterial
	hedge.set_shader_parameter("sway", 0.0)
	hedge.set_shader_parameter("tint", Color(0.72, 0.8, 0.62))

	lamp_glass = ShaderMaterial.new()
	lamp_glass.shader = load("res://shaders/emissive_lamp.gdshader")

	var awning_colors := {"green": Color(0.10, 0.30, 0.20), "red": Color(0.48, 0.07, 0.06), "navy": Color(0.08, 0.12, 0.26),
			"black": Color(0.05, 0.05, 0.05), "striped": Color(0.55, 0.18, 0.14), "tan": Color(0.55, 0.45, 0.32)}
	for key in awning_colors:
		var m := _std(awning_colors[key], 0.85, 0.0)
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		awning[key] = m

	shadow_only = StandardMaterial3D.new()
	shadow_only.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED


func _set_wall_textures(m: ShaderMaterial) -> void:
	m.set_shader_parameter("red_albedo", tex("T_RedBrick_BaseColor"))
	m.set_shader_parameter("red_normal", tex("T_RedBrick_Normal"))
	m.set_shader_parameter("red_orm", tex("T_RedBrick_ORM"))
	m.set_shader_parameter("pale_albedo", tex("T_PaleBrick_BaseColor"))
	m.set_shader_parameter("pale_normal", tex("T_PaleBrick_Normal"))
	m.set_shader_parameter("pale_orm", tex("T_PaleBrick_ORM"))
	m.set_shader_parameter("stone_albedo", tex("T_Limestone_BaseColor"))
	m.set_shader_parameter("stone_normal", tex("T_Limestone_Normal"))
	m.set_shader_parameter("stone_orm", tex("T_Limestone_ORM"))


static func _std(c: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m


func sign_material(file: String, glow := 0.6, alpha_cut := false) -> ShaderMaterial:
	var key := "%s|%s" % [file, alpha_cut]
	if signs.has(key):
		return signs[key]
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/sign.gdshader")
	m.set_shader_parameter("tex", tex(file))
	m.set_shader_parameter("glow", glow)
	m.set_shader_parameter("alpha_cut", alpha_cut)
	signs[key] = m
	return m
