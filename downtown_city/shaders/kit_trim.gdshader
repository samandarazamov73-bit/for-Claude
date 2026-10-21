// Stone mouldings, cornices, window surrounds (MI_Trim, MI_Trim_Dark, MI_Trim_Green).
//   INSTANCE_CUSTOM.b = trim palette index / 7, INSTANCE_CUSTOM.a = building seed
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

#include "res://shaders/include/city_common.gdshaderinc"

uniform bool use_palette = true;
uniform vec3 fixed_tint : source_color = vec3(0.13, 0.13, 0.14);
uniform float roughness_bias = 0.0;
uniform float wear_strength = 0.6;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D orm_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

varying vec3 v_tint;
varying vec3 v_world;
varying vec3 v_wnormal;

void vertex() {
	int idx = int(INSTANCE_CUSTOM.b * 7.0 + 0.5);
	v_tint = use_palette ? TRIM_PALETTE[clamp(idx, 0, 7)] : fixed_tint;
	v_tint *= 0.95 + 0.1 * fract(INSTANCE_CUSTOM.a * 7.31);
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wnormal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 t = texture(albedo_tex, UV * vec2(1.0, 1.0)).rgb;
	vec3 orm = texture(orm_tex, UV).rgb;
	float wear = (1.0 - COLOR.g) * wear_strength;
	float g = facade_grime(v_world, v_wnormal) * 0.8 + wear;
	// soot collects on top of ledges and in recesses
	g += clamp(v_wnormal.y, 0.0, 1.0) * 0.15;
	vec3 alb = t * v_tint * (1.0 - clamp(g, 0.0, 0.7) * 0.5);
	ALBEDO = alb;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	AO = orm.r;
	AO_LIGHT_AFFECT = 0.3;
	ROUGHNESS = clamp(orm.g + roughness_bias, 0.0, 1.0);
	SPECULAR = 0.4;
}
