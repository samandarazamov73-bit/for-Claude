// Masonry walls of the kit modules (MI_RedBrick / MI_RedBrick_Pale).
// Per-building look comes from the MultiMesh custom data:
//   INSTANCE_CUSTOM.r = primary wall palette index / 15   (used by MI_RedBrick surfaces)
//   INSTANCE_CUSTOM.g = secondary wall palette index / 15 (used by MI_RedBrick_Pale surfaces)
//   INSTANCE_CUSTOM.a = building seed (0..1)
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

#include "res://shaders/include/city_common.gdshaderinc"

uniform bool secondary = false;
uniform float wear_strength = 0.6;

uniform sampler2D red_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D red_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D red_orm : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D pale_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D pale_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D pale_orm : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D stone_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D stone_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D stone_orm : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

varying vec3 v_tint;
varying flat int v_tex;
varying float v_desat;
varying float v_seed;
varying vec3 v_world;
varying vec3 v_wnormal;

void vertex() {
	int idx = int((secondary ? INSTANCE_CUSTOM.g : INSTANCE_CUSTOM.r) * 15.0 + 0.5);
	vec4 e = WALL_PALETTE[clamp(idx, 0, 15)];
	v_tint = e.rgb;
	v_tex = int(e.a) % 4;
	v_desat = e.a >= 4.0 ? 1.0 : 0.0;
	v_seed = INSTANCE_CUSTOM.a;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wnormal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 alb;
	vec3 nm;
	vec3 orm;
	if (v_tex == 1) {
		alb = texture(pale_albedo, UV).rgb;
		nm = texture(pale_normal, UV).rgb;
		orm = texture(pale_orm, UV).rgb;
	} else if (v_tex == 2) {
		alb = texture(stone_albedo, UV).rgb;
		nm = texture(stone_normal, UV).rgb;
		orm = texture(stone_orm, UV).rgb;
	} else {
		alb = texture(red_albedo, UV).rgb;
		nm = texture(red_normal, UV).rgb;
		orm = texture(red_orm, UV).rgb;
	}
	float lum = dot(alb, vec3(0.299, 0.587, 0.114));
	alb = mix(alb, vec3(lum) * 1.6, v_desat) * v_tint;
	alb *= 0.94 + 0.12 * fract(v_seed * 13.17);

	float wear = (1.0 - COLOR.g) * wear_strength;
	float g = facade_grime(v_world, v_wnormal) + wear;
	alb *= 1.0 - clamp(g, 0.0, 0.7) * 0.55;

	ALBEDO = alb;
	NORMAL_MAP = nm;
	NORMAL_MAP_DEPTH = 1.0;
	AO = orm.r;
	AO_LIGHT_AFFECT = 0.35;
	ROUGHNESS = clamp(orm.g + g * 0.1, 0.0, 1.0);
	SPECULAR = 0.35;
}
