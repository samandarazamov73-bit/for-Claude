// Painted metal window frames, doors, metal cornices, plus concrete steps
// (MI_Trim_MetalConcrete trim sheet: V < 0.555 metal, V >= 0.555 concrete).
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

#include "res://shaders/include/city_common.gdshaderinc"

uniform vec3 paint_tint : source_color = vec3(0.17, 0.17, 0.18);
uniform vec3 concrete_tint : source_color = vec3(0.70, 0.70, 0.69);
uniform float wear_strength = 0.5;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D orm_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

varying vec3 v_world;
varying vec3 v_wnormal;
varying float v_var;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wnormal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_var = fract(INSTANCE_CUSTOM.a * 3.71);
}

void fragment() {
	float v = fract(UV.y);
	bool conc = v >= 0.555;
	vec3 t = texture(albedo_tex, UV).rgb;
	vec3 orm = texture(orm_tex, UV).rgb;
	float wear = (1.0 - COLOR.g) * wear_strength;
	float g = facade_grime(v_world, v_wnormal) * 0.5 + wear;
	vec3 base = conc ? t * concrete_tint * 1.35 : (paint_tint * (0.9 + 0.2 * v_var)) * (0.75 + t.r * 1.4);
	ALBEDO = base * (1.0 - clamp(g, 0.0, 0.7) * 0.4);
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	ROUGHNESS = conc ? 0.9 : clamp(0.42 + g * 0.3 + orm.g * 0.15, 0.0, 1.0);
	METALLIC = conc ? 0.0 : 0.35;
	SPECULAR = 0.5;
}
