// Bark for trunks, branches, roots and fallen logs. One material for all species: the bark is
// picked per vertex from a Texture2DArray (UV2.x = layer, +0.5 = dead wood).
// Layers: 0 scots pine, 1 spruce/fir, 2 silver birch, 3 oak, 4 deciduous, 5 alder/hornbeam.
shader_type spatial;
render_mode world_vertex_coords, cull_back, depth_draw_opaque, diffuse_burley;

#include "res://shaders/include/forest_common.gdshaderinc"

global uniform sampler2D terrain_height : filter_nearest, repeat_disable;

uniform sampler2DArray bark_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray bark_normal : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray moss_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;   // terrain layers (2 = moss)
uniform sampler2DArray moss_normal : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float normal_strength = 1.1;
uniform float moss_amount = 0.85;
uniform vec3 pine_upper_tint : source_color = vec3(0.78, 0.42, 0.24);
uniform float far_shade = 0.25;

varying flat vec2 v_fade;
varying flat vec4 v_inst;      // x: colour rnd, y: moisture/canopy, z: distance, w: plant height
varying vec3 v_wpos;
varying vec3 v_wnormal;

void vertex() {
	vec3 inst_pos = MODEL_MATRIX[3].xyz;
	float size_scale = 0.5 + 0.5 * INSTANCE_CUSTOM.z;
	v_fade = lod_fade(inst_pos, size_scale, IN_SHADOW_PASS);
	if (lod_hidden(v_fade)) {
		VERTEX = inst_pos;
	} else {
		VERTEX += wind_offset(TIME, VERTEX, inst_pos, COLOR, UV2.y, plant_params.x * INSTANCE_CUSTOM.z, INSTANCE_CUSTOM.y);
	}
	v_inst = vec4(INSTANCE_CUSTOM.x, INSTANCE_CUSTOM.w, distance(inst_pos, main_camera_pos), plant_params.x * INSTANCE_CUSTOM.z);
	v_wpos = VERTEX;
	v_wnormal = NORMAL;
}

float ground_at(vec2 xz) {
	vec2 t = xz - world_rect.xy;
	ivec2 i = ivec2(floor(t));
	vec2 f = fract(t);
	ivec2 mx = ivec2(world_rect.zw) - 1;
	float a = texelFetch(terrain_height, clamp(i, ivec2(0), mx), 0).r;
	float b = texelFetch(terrain_height, clamp(i + ivec2(1, 0), ivec2(0), mx), 0).r;
	float c = texelFetch(terrain_height, clamp(i + ivec2(0, 1), ivec2(0), mx), 0).r;
	float d = texelFetch(terrain_height, clamp(i + ivec2(1, 1), ivec2(0), mx), 0).r;
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void fragment() {
	if (lod_dither_discard(FRAGCOORD.xy, v_fade)) {
		discard;
	}
	float layer_f = UV2.x;
	float layer = floor(layer_f + 0.01);
	bool dead = fract(layer_f) > 0.25;
	vec4 a = texture(bark_albedo, vec3(UV, layer));
	vec4 n = texture(bark_normal, vec3(UV, layer));
	vec3 col = a.rgb;
	float rough = n.b;
	vec2 nxy = n.rg;
	float above = v_wpos.y - ground_at(v_wpos.xz);
	float hnorm = UV2.y;

	if (layer < 0.5) {
		// scots pine: thin orange flaky bark on the upper trunk
		float up = smoothstep(0.45, 0.7, hnorm + (a.a - 0.5) * 0.15);
		col = mix(col, col * pine_upper_tint * 2.2, up);
	} else if (layer > 1.5 && layer < 2.5) {
		// silver birch: the bottom metre or two turns into dark, deeply furrowed bark
		float base = 1.0 - smoothstep(0.6, 2.4 + v_inst.x * 1.5, above + (a.a - 0.5) * 0.8);
		vec4 dark = texture(bark_albedo, vec3(UV * vec2(1.0, 0.7), 3.0));
		vec4 darkn = texture(bark_normal, vec3(UV * vec2(1.0, 0.7), 3.0));
		col = mix(col, dark.rgb * 0.55, base);
		nxy = mix(nxy, darkn.rg, base);
		rough = mix(rough, darkn.b, base);
	}
	if (dead) {
		float l = dot(col, vec3(0.3, 0.55, 0.15));
		col = mix(col, vec3(l) * vec3(0.95, 0.92, 0.86) * 1.15, 0.65);
		rough = min(rough + 0.1, 1.0);
	}
	col = hue_vary(col, v_inst.x, 0.35);

	// moss: north- and up-facing surfaces close to the ground, more in moist shade
	vec3 wn = normalize(v_wnormal);
	float facing = clamp(dot(wn, normalize(vec3(0.15, 0.55, -0.8))) * 1.4, 0.0, 1.0);
	float low = 1.0 - smoothstep(0.2, 1.6 + 1.2 * v_inst.x, above);
	float canopy = canopy_at(v_wpos.xz);
	float moss = clamp((facing * 0.7 + 0.3) * low * (0.5 + 0.8 * canopy) * moss_amount, 0.0, 1.0);
	moss = clamp(moss + clamp(wn.y, 0.0, 1.0) * 0.6 * moss_amount * (dead ? 1.0 : 0.3), 0.0, 1.0);
	if (moss > 0.01) {
		vec2 muv = UV * vec2(0.9, 0.55);
		vec4 m = texture(moss_albedo, vec3(muv, 2.0));
		vec4 mn = texture(moss_normal, vec3(muv, 2.0));
		float mmask = smoothstep(0.35, 0.75, moss + (m.a - 0.5) * 0.6 + (1.0 - a.a) * 0.3);
		col = mix(col, m.rgb * 0.85, mmask);
		nxy = mix(nxy, mn.rg, mmask);
		rough = mix(rough, 0.9, mmask);
	}
	// damp trunk bases
	float wet = wetness * low * 0.6;
	col *= mix(1.0, 0.72, wet);
	rough = mix(rough, 0.35, wet * 0.6);

	float ao = COLOR.r * n.a;
	col *= far_canopy_shade(v_inst.z, canopy, far_shade);
	ALBEDO = lod_debug_tint(col);
	ROUGHNESS = clamp(rough, 0.3, 1.0);
	SPECULAR = 0.3;
	AO = ao * mix(1.0, 0.6, canopy);
	AO_LIGHT_AFFECT = 0.25;
	NORMAL_MAP = vec3(nxy, 1.0);
	NORMAL_MAP_DEPTH = normal_strength;
}
