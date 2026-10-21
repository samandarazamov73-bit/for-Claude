// Asphalt with procedural lane markings (anti-aliased, no decal geometry).
// Mesh contract (scripts/city_generator.gd):
//   UV  = (distance along the segment in m, signed offset across the road in m; + = left of travel dir)
//   UV2 = (segment length in m, marking kind) kind: 0 dashed white centre, 1 double yellow,
//         2 intersection / plain asphalt, 3 one-way (lane dashes only)
//   COLOR.r = half width of the road in m / 10
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

#include "res://shaders/include/city_common.gdshaderinc"

uniform sampler2D asphalt_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D asphalt_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D asphalt_orm : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float tex_scale = 0.3;
uniform vec3 tint : source_color = vec3(0.92, 0.93, 0.98);

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float aa_band(float x, float c, float half_w) {
	float d = abs(x - c) - half_w;
	float fw = max(fwidth(x), 1e-4);
	return 1.0 - smoothstep(-fw * 0.5, fw * 0.5, d);
}

float aa_range(float x, float a, float b) {
	float fw = max(fwidth(x), 1e-4);
	return smoothstep(a - fw * 0.5, a + fw * 0.5, x) * (1.0 - smoothstep(b - fw * 0.5, b + fw * 0.5, x));
}

void fragment() {
	vec2 wuv = v_world.xz * tex_scale;
	vec3 base = texture(asphalt_albedo, wuv).rgb * tint;
	vec3 orm = texture(asphalt_orm, wuv).rgb;
	vec3 nm = texture(asphalt_normal, wuv).rgb;
	float n_low = texture(city_noise, v_world.xz * 0.012).r;
	float n_mid = texture(city_noise, v_world.xz * 0.05).g;
	// patched asphalt and sealed cracks
	base *= 0.86 + 0.24 * n_low;
	float patch = smoothstep(0.62, 0.66, texture(city_noise, v_world.xz * 0.02 + 0.37).r);
	base = mix(base, base * 0.72, patch);

	float along = UV.x;
	float across = UV.y;
	float len = UV2.x;
	int kind = int(UV2.y + 0.5);
	float hw = COLOR.r * 10.0;
	float paint = 0.0;
	float yellow = 0.0;
	if (kind != 2) {
		float lane_edge = hw - 1.5;
		bool in_cross = along < 4.6 || along > len - 4.6;
		bool near_end = along < 6.0 || along > len - 6.0;
		// tyre polish along the lanes
		float tyre = aa_range(abs(abs(across) - lane_edge * 0.5), 0.35, 0.9);
		base *= 1.0 - tyre * 0.06;
		if (!in_cross) {
			paint += aa_band(abs(across), lane_edge, 0.08);
			if (kind == 0 && !near_end) {
				float dash = step(fract(along / 9.0), 0.33);
				paint += aa_band(across, 0.0, 0.07) * dash;
			} else if (kind == 1) {
				yellow += aa_band(across, 0.14, 0.06) + aa_band(across, -0.14, 0.06);
			} else if (kind == 3 && !near_end) {
				float dash = step(fract(along / 9.0), 0.33);
				paint += aa_band(across, 0.0, 0.07) * dash;
			}
			// stop lines for the lanes approaching each end
			float stop_a = aa_range(along, 5.0, 5.45) * aa_range(across, 0.0, lane_edge);
			float stop_b = aa_range(along, len - 5.45, len - 5.0) * aa_range(across, -lane_edge, 0.0);
			paint += (stop_a + stop_b) * (kind == 3 ? 0.0 : 1.0);
		} else {
			// zebra crosswalk: bars parallel to traffic, 0.6 m wide with 0.6 m gaps
			float zone = aa_range(along, 1.0, 4.2) + aa_range(along, len - 4.2, len - 1.0);
			float bars = aa_range(fract((across + hw) / 1.2) * 1.2, 0.3, 0.9) * aa_range(abs(across), 0.0, hw - 0.6);
			paint += zone * bars;
		}
		paint = clamp(paint, 0.0, 1.0);
		yellow = clamp(yellow, 0.0, 1.0);
		float worn = smoothstep(0.25, 0.6, n_mid + texture(city_noise, v_world.xz * 0.4).b * 0.35);
		paint *= worn;
		yellow *= worn;
	}
	// gutter grime next to the curb
	float gutter = smoothstep(hw - 0.7, hw, abs(across));
	base *= 1.0 - gutter * 0.25;

	vec3 col = base;
	col = mix(col, vec3(0.82, 0.82, 0.78), paint);
	col = mix(col, vec3(0.80, 0.60, 0.14), yellow);
	ALBEDO = col;
	NORMAL_MAP = nm;
	NORMAL_MAP_DEPTH = mix(1.0, 0.3, max(paint, yellow));
	ROUGHNESS = mix(clamp(orm.g * 0.95, 0.5, 1.0), 0.65, max(paint, yellow));
	SPECULAR = 0.35;
}
