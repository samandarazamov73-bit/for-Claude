// Alpha-tested foliage cards for every tree, bush and ground-cover plant (one shared material,
// one shared 4K atlas). Vertex colour layout: see tools/meshkit.py.
shader_type spatial;
render_mode world_vertex_coords, cull_disabled, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/include/forest_common.gdshaderinc"

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D normal_tex : filter_linear_mipmap_anisotropic, repeat_disable;   // rg normal, b roughness, a translucency
uniform float alpha_cutoff = 0.42;
uniform float normal_strength = 0.75;
uniform vec3 translucency_color : source_color = vec3(0.62, 0.78, 0.25);
uniform float translucency = 0.55;
uniform float ao_strength = 0.75;
uniform float canopy_ambient = 0.55;     // how much the canopy above darkens ambient light
uniform float far_shade = 0.35;
uniform bool is_ground_cover = false;    // grass/ferns: shrink as they fade out instead of dithering only

varying flat vec2 v_fade;
varying flat vec4 v_inst;      // x: colour rnd, y: canopy at the plant, z: distance, w: unused
varying vec3 v_wpos;

void vertex() {
	vec3 inst_pos = MODEL_MATRIX[3].xyz;
	float size_scale = 0.5 + 0.5 * INSTANCE_CUSTOM.z;
	v_fade = lod_fade(inst_pos, size_scale, IN_SHADOW_PASS);
	if (lod_hidden(v_fade)) {
		VERTEX = inst_pos;     // collapse: zero-area triangles are not rasterised
	} else {
		if (is_ground_cover) {
			// ground cover sinks into the floor over the last part of its range
			float shrink = 1.0 - v_fade.y;
			VERTEX = inst_pos + (VERTEX - inst_pos) * mix(0.25, 1.0, shrink);
		}
		float hnorm = UV2.y;
		VERTEX += wind_offset(TIME, VERTEX, inst_pos, COLOR, hnorm, plant_params.x * INSTANCE_CUSTOM.z, INSTANCE_CUSTOM.y);
	}
	v_inst = vec4(INSTANCE_CUSTOM.x, INSTANCE_CUSTOM.w, distance(inst_pos, main_camera_pos), 0.0);
	v_wpos = VERTEX;
}

void fragment() {
	if (lod_dither_discard(FRAGCOORD.xy, v_fade)) {
		discard;
	}
	vec4 a = texture(albedo_tex, UV);
	// keep alpha-tested coverage stable in the lower mip levels (foliage would otherwise thin out with distance)
	float mip = textureQueryLod(albedo_tex, UV).y;
	float alpha = a.a * (1.0 + max(mip, 0.0) * 0.22);
	ALPHA = alpha;
	ALPHA_SCISSOR_THRESHOLD = alpha_cutoff;

	// keep the crown-shaped normal for both sides of the card (Godot flips it for back faces)
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	vec4 n = texture(normal_tex, UV);
	NORMAL_MAP = vec3(n.rg, 1.0);
	NORMAL_MAP_DEPTH = normal_strength;

	float ao = mix(1.0, COLOR.r, ao_strength);
	vec3 col = hue_vary(a.rgb, v_inst.x, plant_params.z * 0.8);
	float canopy = is_ground_cover ? v_inst.y : canopy_at(v_wpos.xz) * 0.6;
	col *= far_canopy_shade(v_inst.z, canopy, far_shade);
	ALBEDO = lod_debug_tint(col * mix(0.72, 1.0, ao));
	AO = ao * mix(1.0, 1.0 - canopy_ambient, canopy);
	AO_LIGHT_AFFECT = 0.15;
	// leaves are rough and only mildly specular: strong highlights turn backlit cards chalk-white
	ROUGHNESS = clamp(n.b * 0.6 + 0.4, 0.6, 1.0);
	SPECULAR = 0.18;
	BACKLIGHT = col * translucency_color * (translucency * plant_params.y * UV2.x * n.a * 1.1);
}
