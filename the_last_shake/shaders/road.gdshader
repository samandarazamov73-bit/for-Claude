// Rural two-lane asphalt road. UV.x = lateral offset from the centreline in metres (left +),
// UV.y = distance along the road in metres. All detail is procedural in road space on top of two
// scanned asphalt sets: worn/cracked areas, repair patches, sealed cracks, polished wheel paths,
// worn paint, crumbling edges, gravel shoulders, leaf litter and puddles (global `wetness`).
shader_type spatial;
render_mode cull_back, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/include/forest_common.gdshaderinc"

uniform sampler2DArray asphalt_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray asphalt_normal : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray ground_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray ground_normal : filter_linear_mipmap_anisotropic, repeat_enable;
uniform float asphalt_tiling = 3.4;
uniform float gravel_tiling = 1.6;
uniform int marking_style = 0;          // 0: double yellow centre + white edge lines, 1: European dashed white centre
uniform vec3 paint_white : source_color = vec3(0.84, 0.84, 0.80);
uniform vec3 paint_yellow : source_color = vec3(0.86, 0.63, 0.12);
uniform float paint_wear = 0.4;
uniform float edge_line_offset = 3.45;
uniform float edge_line_width = 0.13;
uniform float centre_line_width = 0.11;
uniform float centre_gap = 0.11;
uniform float half_asphalt = 4.10;
uniform float road_edge = 5.0;
uniform float lane_width = 3.4;
uniform float asphalt_brightness = 0.5;
uniform float puddle_amount = 1.0;

varying vec3 v_wpos;

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x), mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	return vnoise(p) * 0.55 + vnoise(p * 2.13 + 7.1) * 0.3 + vnoise(p * 4.7 + 1.3) * 0.15;
}

void vertex() {
	v_wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// thin line mask with anti-aliasing (width in metres)
float line_mask(float d, float half_w) {
	float aa = max(fwidth(d), 0.002);
	return 1.0 - smoothstep(half_w - aa, half_w + aa, abs(d));
}

void fragment() {
	float x = UV.x;
	float s = UV.y;
	float ax = abs(x);
	vec2 rs = vec2(x, s);
	float dist = length(v_wpos - CAMERA_POSITION_WORLD);

	// ---- asphalt: clean + worn/cracked, blended along the road
	vec2 auv = rs / asphalt_tiling;
	vec4 A0 = texture(asphalt_albedo, vec3(auv, 0.0));
	vec4 N0 = texture(asphalt_normal, vec3(auv, 0.0));
	// old asphalt: rotated so the scanned cracks run across the lane (transverse cracking)
	vec2 auv2 = vec2(s, -x) / 6.5 + vec2(0.0, 0.41);
	vec4 A1 = texture(asphalt_albedo, vec3(auv2, 1.0));
	vec4 N1 = texture(asphalt_normal, vec3(auv2, 1.0));
	float worn = smoothstep(0.58, 0.78, fbm(vec2(s * 0.011, x * 0.09)) + 0.12 * (vnoise(vec2(s * 0.09, x * 0.6)) - 0.5));
	worn = max(worn, smoothstep(3.3, 4.1, ax) * 0.45);
	vec3 col = mix(A0.rgb, A1.rgb * 0.95, worn);
	vec2 nxy = mix(N0.rg, N1.rg, worn);
	float rough = mix(N0.b, N1.b, worn);
	float ao = mix(N0.a, N1.a, worn);
	// subtle large-scale discolouration (bitumen ageing, oil, sun bleaching)
	col *= mix(0.86, 1.1, fbm(rs * vec2(0.18, 0.025)));
	col = mix(col, col * vec3(1.04, 1.0, 0.94), smoothstep(0.5, 0.8, vnoise(vec2(s * 0.004, 0.0))) * 0.5);

	// ---- repair patches (fresh, darker asphalt with sealed seams)
	float cell = floor(s / 38.0);
	float r1 = hash11(cell * 1.7 + 0.3);
	float r2 = hash11(cell * 3.1 + 1.1);
	float r3 = hash11(cell * 5.3 + 2.7);
	if (r1 < 0.45) {
		float p0 = cell * 38.0 + 4.0 + r2 * 20.0;
		float plen = 2.5 + r3 * 9.0;
		float x0 = r3 < 0.5 ? 0.15 : -lane_width - 0.1;
		float x1 = r3 < 0.5 ? lane_width + 0.1 : -0.15;
		if (r2 > 0.82) { x0 = -half_asphalt + 0.3; x1 = half_asphalt - 0.3; }
		float jag = (vnoise(rs * 3.0) - 0.5) * 0.12;
		float inside_s = step(p0 + jag, s) * step(s, p0 + plen + jag);
		float inside_x = step(x0 + jag, x) * step(x, x1 + jag);
		float patch = inside_s * inside_x;
		float seam = patch * (1.0 - line_mask(min(min(s - p0 - jag, p0 + plen + jag - s), min(x - x0 - jag, x1 + jag - x)), 0.05));
		col = mix(col, A0.rgb * 0.62, patch);
		rough = mix(rough, 0.55, patch);
		nxy = mix(nxy, mix(vec2(0.5), N0.rg, 0.6), patch);
		col = mix(col, vec3(0.025), (patch - seam) * 0.85);
		rough = mix(rough, 0.25, (patch - seam) * 0.8);
	}

	// ---- sealed cracks: longitudinal joint near the centre + transverse cracks
	float warp = (fbm(vec2(s * 0.35, 3.0)) - 0.5) * 0.35;
	float crack = line_mask(x - 0.22 - warp, 0.018) * smoothstep(0.35, 0.6, vnoise(vec2(s * 0.05, 1.0)));
	float tcell = floor(s / 17.0);
	float tpos = tcell * 17.0 + hash11(tcell) * 11.0;
	float tc = line_mask(s - tpos - (fbm(vec2(x * 0.9, tcell)) - 0.5) * 0.6, 0.02) * step(hash11(tcell + 9.0), 0.55);
	tc *= step(ax, half_asphalt - 0.1) * smoothstep(0.2, 0.5, vnoise(vec2(x * 1.3, tcell * 3.0)));
	float cracks = max(crack, tc);
	col = mix(col, vec3(0.02), cracks * 0.9);
	rough = mix(rough, 0.2, cracks);

	// ---- tyre wear: polished, slightly darker wheel paths; oil drip line between them
	float lane_c = lane_width * 0.5;
	float wp1 = 1.0 - smoothstep(0.18, 0.38, abs(ax - (lane_c - 0.85)));
	float wp2 = 1.0 - smoothstep(0.18, 0.38, abs(ax - (lane_c + 0.85)));
	float wheel = max(wp1, wp2) * step(ax, half_asphalt);
	float oil = (1.0 - smoothstep(0.1, 0.35, abs(ax - lane_c))) * fbm(vec2(s * 0.3, x * 2.0));
	col *= 1.0 - 0.10 * wheel - 0.08 * oil;
	rough = mix(rough, rough * 0.9, wheel);

	// ---- markings (worn paint)
	float paint = 0.0;
	vec3 paint_col = paint_white;
	float edge_l = line_mask(ax - edge_line_offset, edge_line_width * 0.5);
	if (marking_style == 0) {
		float cy = line_mask(ax - (centre_gap * 0.5 + centre_line_width * 0.5), centre_line_width * 0.5);
		paint = max(edge_l, cy);
		paint_col = cy > edge_l ? paint_yellow : paint_white;
	} else {
		float dash = step(fract(s / 12.0), 0.25);
		float cw = line_mask(x, 0.06) * dash;
		paint = max(edge_l, cw);
	}
	float wear = fbm(rs * vec2(6.0, 0.9)) * 0.7 + vnoise(rs * vec2(22.0, 3.0)) * 0.3;
	wear += wheel * 0.3;
	float keep = smoothstep(paint_wear - 0.08, paint_wear + 0.12, 1.0 - wear) * smoothstep(0.05, 0.25, A0.a + 0.1);
	paint *= keep;
	col = mix(col, paint_col * mix(0.85, 1.0, A0.a), paint * 0.92);
	rough = mix(rough, 0.6, paint);
	nxy = mix(nxy, vec2(0.5), paint * 0.6);

	// ---- shoulder: crumbling asphalt edge -> gravel -> soil, with fallen leaves
	float edge_noise = (fbm(vec2(s * 0.8, 0.0)) - 0.5) * 0.22 + (vnoise(vec2(s * 4.0, 2.0)) - 0.5) * 0.06;
	float on_gravel = smoothstep(half_asphalt - 0.04, half_asphalt + 0.04, ax + edge_noise);
	vec2 guv = rs / gravel_tiling;
	vec4 G = texture(ground_albedo, vec3(guv, 5.0));
	vec4 GN = texture(ground_normal, vec3(guv, 5.0));
	vec4 S = texture(ground_albedo, vec3(rs / 2.4, 4.0));
	vec4 SN = texture(ground_normal, vec3(rs / 2.4, 4.0));
	float soil = smoothstep(4.5, 5.0, ax + (vnoise(rs * 1.7) - 0.5) * 0.5);
	vec3 shoulder = mix(G.rgb, S.rgb, soil * 0.4);
	vec2 shoulder_n = mix(GN.rg, SN.rg, soil * 0.4);
	col = mix(col, shoulder, on_gravel);
	nxy = mix(nxy, shoulder_n, on_gravel);
	rough = mix(rough, mix(GN.b, SN.b, soil), on_gravel);
	ao = mix(ao, GN.a, on_gravel);
	// dirt washed onto the asphalt edge
	float dirt = smoothstep(3.55, 4.1, ax) * (0.4 + 0.6 * fbm(rs * vec2(1.5, 0.3)));
	col = mix(col, col * vec3(1.15, 1.02, 0.82) * 1.05, dirt * (1.0 - on_gravel) * 0.6);
	// fallen leaves and needles near the edges
	vec4 Lf = texture(ground_albedo, vec3(rs / 2.3, 0.0));
	vec4 LfN = texture(ground_normal, vec3(rs / 2.3, 0.0));
	float leaves = smoothstep(0.55, 0.8, fbm(rs * vec2(0.8, 0.25)) + smoothstep(3.6, 4.7, ax) * 0.45 - (1.0 - smoothstep(2.8, 3.6, ax)) * 0.5);
	leaves *= smoothstep(0.35, 0.6, Lf.a + 0.2);
	col = mix(col, Lf.rgb * 0.9, leaves);
	nxy = mix(nxy, LfN.rg, leaves);
	rough = mix(rough, 0.8, leaves);

	// ---- wet road: darker, glossier, puddles in the ruts and along the low edge
	float canopy = canopy_at(v_wpos.xz);
	float damp = wetness * (0.65 + 0.35 * canopy);
	col *= mix(1.0, 0.78, damp * (1.0 - on_gravel * 0.3));
	rough = mix(rough, max(rough * 0.85, 0.55), damp);
	float pud_shape = fbm(rs * vec2(0.55, 0.11)) + wheel * 0.16 + smoothstep(3.0, 4.0, ax) * 0.1 - A0.a * 0.25;
	float puddle = smoothstep(0.7 - 0.08 * wetness, 0.73 - 0.08 * wetness, pud_shape) * wetness * puddle_amount * (1.0 - on_gravel);
	col = mix(col, col * 0.6, puddle);
	rough = mix(rough, 0.06, puddle);
	nxy = mix(nxy, vec2(0.5), puddle);

	col *= asphalt_brightness;
	col *= far_canopy_shade(dist, canopy, 0.45);
	ALBEDO = col;
	ROUGHNESS = clamp(rough, 0.02, 1.0);
	SPECULAR = mix(0.42, 0.32, on_gravel);
	NORMAL_MAP = vec3(nxy, 1.0);
	NORMAL_MAP_DEPTH = 1.0 - puddle * 0.9;
	AO = ao * mix(1.0, 0.65, canopy);
	AO_LIGHT_AFFECT = 0.15;
}
