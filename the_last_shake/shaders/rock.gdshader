// Photoscanned rocks and props (stumps, logs, branches) from a shared 4K atlas, with
// world-space moss growing on their upper surfaces in damp, shaded places.
shader_type spatial;
render_mode world_vertex_coords, cull_back, depth_draw_opaque, diffuse_burley;

#include "res://shaders/include/forest_common.gdshaderinc"

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;   // rgb albedo, a AO
uniform sampler2D normal_tex : filter_linear_mipmap_anisotropic, repeat_disable;                 // rg normal, b roughness
uniform sampler2DArray moss_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray moss_normal : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float moss_amount = 0.7;
uniform float moss_tiling = 0.9;
uniform float normal_strength = 1.0;
uniform float far_shade = 0.3;
uniform vec3 tint : source_color = vec3(1.0);

varying flat vec2 v_fade;
varying flat vec4 v_inst;     // x rnd, y rnd, z dist, w moisture
varying vec3 v_wpos;
varying vec3 v_wnormal;

void vertex() {
	vec3 inst_pos = MODEL_MATRIX[3].xyz;
	float size_scale = 0.5 + 0.5 * INSTANCE_CUSTOM.z;
	v_fade = lod_fade(inst_pos, size_scale, IN_SHADOW_PASS);
	if (lod_hidden(v_fade)) {
		VERTEX = inst_pos;
	}
	v_inst = vec4(INSTANCE_CUSTOM.x, INSTANCE_CUSTOM.y, distance(inst_pos, main_camera_pos), INSTANCE_CUSTOM.w);
	v_wpos = VERTEX;
	v_wnormal = NORMAL;
}

void fragment() {
	if (lod_dither_discard(FRAGCOORD.xy, v_fade)) {
		discard;
	}
	vec4 a = texture(albedo_tex, UV);
	vec4 n = texture(normal_tex, UV);
	vec3 col = a.rgb * tint * mix(0.85, 1.1, v_inst.x);
	vec2 nxy = n.rg;
	float rough = n.b;
	vec3 wn = normalize(v_wnormal);
	float canopy = canopy_at(v_wpos.xz);
	// triplanar-free top projection is enough for moss (it only grows on upward faces)
	float up = smoothstep(0.25, 0.85, wn.y);
	vec2 muv = v_wpos.xz * moss_tiling;
	vec4 m = texture(moss_albedo, vec3(muv, 2.0));
	vec4 mn = texture(moss_normal, vec3(muv, 2.0));
	float wetspot = clamp(v_inst.w * 1.2 + canopy * 0.4, 0.0, 1.0);
	float moss = up * moss_amount * (0.35 + 0.65 * wetspot);
	float mmask = smoothstep(0.35, 0.7, moss + (m.a - 0.5) * 0.7 - (a.a - 0.6) * 0.3);
	col = mix(col, m.rgb * 0.9, mmask);
	nxy = mix(nxy, mn.rg, mmask);
	rough = mix(rough, 0.92, mmask);
	float wet = wetness * (1.0 - up) * 0.25 + wetness * 0.15;
	col *= mix(1.0, 0.75, wet);
	rough = mix(rough, 0.3, wet);
	col *= far_canopy_shade(v_inst.z, canopy, far_shade);
	ALBEDO = lod_debug_tint(col);
	ROUGHNESS = clamp(rough, 0.2, 1.0);
	SPECULAR = 0.35;
	AO = a.a * mix(1.0, 0.6, canopy);
	AO_LIGHT_AFFECT = 0.2;
	NORMAL_MAP = vec3(nxy, 1.0);
	NORMAL_MAP_DEPTH = normal_strength;
}
