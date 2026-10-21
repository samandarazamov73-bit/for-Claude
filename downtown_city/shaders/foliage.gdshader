// Tree canopy clumps: leaf texture, wind sway, translucency.
// Instance custom (MultiMesh): r = hue shift, g = brightness, b = phase.
shader_type spatial;
render_mode diffuse_lambert_wrap, specular_schlick_ggx, cull_back;

#include "res://shaders/include/city_common.gdshaderinc"

global uniform float wind_strength;
uniform sampler2D leaf_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D leaf_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 tint : source_color = vec3(1.0);
uniform float sway = 0.12;

varying vec3 v_tint;
varying vec3 v_world;
varying vec3 v_lnormal;

void vertex() {
	vec3 o = MODEL_MATRIX[3].xyz;
	float phase = INSTANCE_CUSTOM.b * 6.283 + o.x * 0.13 + o.z * 0.11;
	float hgt = max(VERTEX.y - 2.0, 0.0);
	float wv = sin(TIME * 1.3 + phase) * 0.6 + sin(TIME * 2.9 + phase * 1.7) * 0.3;
	VERTEX.x += wv * sway * hgt * 0.12 * wind_strength;
	VERTEX.z += cos(TIME * 1.1 + phase) * sway * hgt * 0.06 * wind_strength;
	// flutter of the clumps
	VERTEX += NORMAL * sin(TIME * 4.0 + VERTEX.y * 3.0 + phase) * 0.03 * wind_strength;
	v_tint = tint * mix(vec3(0.92, 1.0, 0.85), vec3(1.05, 1.0, 1.12), INSTANCE_CUSTOM.r) * (0.85 + 0.3 * INSTANCE_CUSTOM.g);
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 wn = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
	vec3 an = abs(wn);
	an /= (an.x + an.y + an.z);
	vec3 p = v_world * 0.45;
	vec3 a = texture(leaf_albedo, p.yz).rgb * an.x + texture(leaf_albedo, p.xz).rgb * an.y + texture(leaf_albedo, p.xy).rgb * an.z;
	vec3 nm = texture(leaf_normal, p.yz).rgb * an.x + texture(leaf_normal, p.xz).rgb * an.y + texture(leaf_normal, p.xy).rgb * an.z;
	// self-shadowing: inner / lower parts of the canopy are darker
	float occl = clamp(COLOR.r, 0.0, 1.0);
	ALBEDO = a * v_tint * mix(0.45, 1.05, occl);
	NORMAL_MAP = nm;
	NORMAL_MAP_DEPTH = 1.4;
	ROUGHNESS = 0.75;
	SPECULAR = 0.25;
	BACKLIGHT = vec3(0.35, 0.45, 0.15) * occl;
	AO = mix(0.5, 1.0, occl);
}
