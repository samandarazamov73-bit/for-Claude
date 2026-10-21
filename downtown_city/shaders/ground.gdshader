// Sidewalk slabs, curbs, plaza paving and roofs: tiled PBR set in world space
// with large-scale variation so repeats are not visible.
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

#include "res://shaders/include/city_common.gdshaderinc"

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D orm_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 tint : source_color = vec3(1.0);
uniform float tile_m = 3.0;
uniform bool use_uv = false;
uniform float variation = 0.18;
uniform float roughness_mul = 1.0;

varying vec3 v_world;
varying vec3 v_wnormal;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wnormal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 uv;
	if (use_uv) {
		uv = UV;
	} else if (abs(v_wnormal.y) > 0.5) {
		uv = v_world.xz / tile_m;
	} else {
		uv = vec2(v_world.x + v_world.z, -v_world.y) / tile_m;
	}
	vec3 a = texture(albedo_tex, uv).rgb * tint;
	vec3 orm = texture(orm_tex, uv).rgb;
	float n = texture(city_noise, v_world.xz * 0.015).r;
	float n2 = texture(city_noise, v_world.xz * 0.11).g;
	a *= 1.0 - variation * 0.5 + variation * (n * 0.7 + n2 * 0.3);
	ALBEDO = a;
	NORMAL_MAP = texture(normal_tex, uv).rgb;
	AO = orm.r;
	ROUGHNESS = clamp(orm.g * roughness_mul, 0.0, 1.0);
	SPECULAR = 0.35;
}
