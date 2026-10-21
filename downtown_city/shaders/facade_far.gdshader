// Distant building shells (HLOD). One box per building, merged per city block; replaces the
// kit modules beyond the detail range. Windows are drawn procedurally.
// Mesh contract (scripts/building_generator.gd):
//   UV      = (metres along the facade, metres above ground); roofs use world xz
//   CUSTOM0 = (bay width m, floor height m, ground floor height m, seed)
//   COLOR   = (primary wall palette index / 15, trim palette index / 7, window style / 3, 1 = roof)
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

#include "res://shaders/include/city_common.gdshaderinc"

uniform sampler2D red_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D pale_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D stone_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D roof_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;

varying vec4 v_params;
varying vec3 v_tint;
varying vec3 v_trim;
varying flat int v_tex;
varying float v_desat;
varying float v_style;
varying float v_roof;
varying vec3 v_world;

void vertex() {
	v_params = CUSTOM0;
	vec4 e = WALL_PALETTE[clamp(int(COLOR.r * 15.0 + 0.5), 0, 15)];
	v_tint = e.rgb;
	v_tex = int(e.a) % 4;
	v_desat = e.a >= 4.0 ? 1.0 : 0.0;
	v_trim = TRIM_PALETTE[clamp(int(COLOR.g * 7.0 + 0.5), 0, 7)];
	v_style = COLOR.b * 3.0;
	v_roof = COLOR.a;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (v_roof > 0.5) {
		ALBEDO = texture(roof_albedo, v_world.xz * 0.25).rgb * 0.9;
		ROUGHNESS = 0.9;
	} else {
		vec2 uvm = UV / 2.0;
		vec3 wall = v_tex == 1 ? texture(pale_albedo, uvm).rgb : (v_tex == 2 ? texture(stone_albedo, uvm).rgb : texture(red_albedo, uvm).rgb);
		float lum = dot(wall, vec3(0.299, 0.587, 0.114));
		wall = mix(wall, vec3(lum) * 1.6, v_desat) * v_tint;
		float bay = max(v_params.x, 1.0);
		float fh = max(v_params.y, 2.5);
		float gh = v_params.z;
		float seed = v_params.w;
		float y = UV.y - gh;
		float fx = fract(UV.x / bay);
		float fy = fract(y / fh);
		vec2 cell = vec2(floor(UV.x / bay), floor(y / fh));
		float ww = v_style > 1.5 ? 0.78 : (v_style > 0.5 ? 0.5 : 0.42);
		float win = step(0.5 - ww * 0.5, fx) * step(fx, 0.5 + ww * 0.5) * step(0.22, fy) * step(fy, 0.86);
		float surround = step(0.5 - ww * 0.5 - 0.06, fx) * step(fx, 0.5 + ww * 0.5 + 0.06) * step(0.16, fy) * step(fy, 0.9);
		win *= step(0.0, y);
		surround *= step(0.0, y);
		float r = hash13(vec3(cell, seed * 113.0));
		float lit = step(r, mix(0.12, 0.55, night_factor));
		vec3 glass = mix(vec3(0.10, 0.12, 0.15), vec3(0.32, 0.38, 0.48), r * 0.6);
		vec3 col = mix(wall, wall * 0.6 + v_trim * 0.4, (surround - win) * 0.8);
		// storefront band
		float shop = step(UV.y, gh) * step(0.6, UV.y) * step(0.1, fract(UV.x / 4.0));
		col = mix(col, vec3(0.08, 0.08, 0.09), shop * 0.9);
		// cornice line at the top is handled by geometry; add a darker grime gradient upward
		col *= 0.9 + 0.1 * texture(city_noise, vec2(UV.x * 0.02, UV.y * 0.01)).a;
		ALBEDO = mix(col, glass * 0.4, win);
		EMISSION = (win * lit + shop * 0.6 * lit) * vec3(1.0, 0.8, 0.55) * mix(0.25, 1.6, night_factor);
		ROUGHNESS = mix(0.85, 0.1, win);
		SPECULAR = mix(0.3, 0.6, win);
	}
}
