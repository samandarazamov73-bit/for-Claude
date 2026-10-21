// Sky with soft cumulus clouds, sun disc and horizon haze. Static, so the radiance
// map only refreshes when the time of day changes.
shader_type sky;
render_mode use_half_res_pass;

uniform vec3 zenith_color : source_color = vec3(0.16, 0.36, 0.72);
uniform vec3 horizon_color : source_color = vec3(0.62, 0.74, 0.88);
uniform vec3 ground_color : source_color = vec3(0.32, 0.33, 0.35);
uniform vec3 cloud_color : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 cloud_shadow : source_color = vec3(0.62, 0.68, 0.78);
uniform float cloud_cover : hint_range(0.0, 1.0) = 0.45;
uniform float sun_size = 0.9995;
uniform float stars = 0.0;
uniform sampler2D clouds_tex : filter_linear_mipmap, repeat_enable;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void sky() {
	vec3 d = EYEDIR;
	float h = d.y;
	vec3 col = mix(horizon_color, zenith_color, pow(clamp(h, 0.0, 1.0), 0.55));
	col = mix(col, ground_color, smoothstep(0.0, -0.08, h));
	vec3 sd = LIGHT0_DIRECTION;
	float sdot = dot(d, sd);
	// sun glow
	col += LIGHT0_COLOR * LIGHT0_ENERGY * 0.25 * pow(max(sdot, 0.0), 12.0) * step(0.0, sd.y + 0.15);
	if (h > 0.0) {
		vec2 cuv = d.xz / (h + 0.12) * 0.22;
		float c1 = texture(clouds_tex, cuv * 0.6 + vec2(0.13, 0.27)).r;
		float c2 = texture(clouds_tex, cuv * 1.7 + vec2(0.71, 0.11)).g;
		float c = c1 * 0.7 + c2 * 0.3;
		float cov = smoothstep(1.0 - cloud_cover, 1.0 - cloud_cover + 0.28, c);
		cov *= smoothstep(0.0, 0.12, h);
		float lightness = clamp(c2 * 1.4 - 0.2, 0.0, 1.0);
		vec3 cc = mix(cloud_shadow, cloud_color, lightness);
		cc += LIGHT0_COLOR * 0.15 * pow(max(sdot, 0.0), 6.0);
		col = mix(col, cc, cov * 0.92);
		if (stars > 0.0 && !AT_CUBEMAP_PASS) {
			vec2 sp = floor(d.xz / (h + 0.3) * 400.0);
			float st = step(0.997, hash(sp)) * (1.0 - cov);
			col += vec3(st) * stars;
		}
	}
	if (!AT_CUBEMAP_PASS) {
		col += LIGHT0_COLOR * LIGHT0_ENERGY * 4.0 * smoothstep(sun_size, sun_size + 0.0002, sdot) * step(0.0, sd.y + 0.02);
	}
	COLOR = col;
}
