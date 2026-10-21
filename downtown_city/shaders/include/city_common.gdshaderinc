// Shared helpers for Downtown City shaders.

// 0 = full day, 1 = night (set by scripts/environment_controller.gd)
global uniform float night_factor;
// Tileable RGBA noise (R low fbm, G mid fbm, B cells, A vertical streaks)
global uniform sampler2D city_noise : filter_linear_mipmap, repeat_enable;

// Wall palette: rgb = tint applied on top of the texture,
// a = texture id (0 red brick, 1 buff brick, 2 limestone) + 4 if the brick is painted (desaturated).
const vec4 WALL_PALETTE[16] = vec4[16](
	vec4(1.00, 1.00, 1.00, 0.0),  // 0 red brick
	vec4(0.80, 0.70, 0.64, 0.0),  // 1 brown brick
	vec4(1.08, 0.94, 0.84, 0.0),  // 2 orange brick
	vec4(0.62, 0.54, 0.52, 0.0),  // 3 dark brick
	vec4(0.92, 0.72, 0.68, 0.0),  // 4 deep red brick
	vec4(1.00, 1.00, 1.00, 1.0),  // 5 buff brick
	vec4(1.03, 0.97, 0.86, 1.0),  // 6 yellow buff brick
	vec4(0.90, 0.90, 0.89, 1.0),  // 7 grey brick
	vec4(1.02, 0.94, 0.90, 1.0),  // 8 pinkish buff brick
	vec4(1.00, 1.00, 1.00, 2.0),  // 9 limestone
	vec4(1.04, 0.98, 0.89, 2.0),  // 10 warm limestone
	vec4(0.86, 0.86, 0.85, 2.0),  // 11 grey limestone
	vec4(0.70, 0.68, 0.64, 2.0),  // 12 sooty limestone
	vec4(0.40, 0.45, 0.56, 4.0),  // 13 painted slate-blue brick
	vec4(0.36, 0.36, 0.38, 4.0),  // 14 painted charcoal brick
	vec4(0.66, 0.60, 0.50, 4.0)   // 15 painted khaki brick
);

// Trim / cornice palette.
const vec3 TRIM_PALETTE[8] = vec3[8](
	vec3(0.93, 0.89, 0.80),  // 0 cream
	vec3(0.95, 0.94, 0.91),  // 1 white stone
	vec3(0.78, 0.78, 0.76),  // 2 light grey
	vec3(0.86, 0.78, 0.65),  // 3 beige
	vec3(0.13, 0.13, 0.14),  // 4 dark
	vec3(0.16, 0.34, 0.25),  // 5 green
	vec3(0.38, 0.27, 0.21),  // 6 brown
	vec3(0.58, 0.57, 0.55)   // 7 sooty grey
);

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

float hash13(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

vec3 hash33(vec3 p3) {
	p3 = fract(p3 * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yxz + 33.33);
	return fract((p3.xxy + p3.yxx) * p3.zyx);
}

// Weathering for vertical facades: rain streaks, soot under ledges, splash dirt at street level.
float facade_grime(vec3 wp, vec3 wn) {
	float vertical = 1.0 - abs(wn.y);
	float h = wp.x * 0.73 + wp.z * 0.69;
	float streak = texture(city_noise, vec2(h * 0.09, wp.y * 0.011)).a;
	float patches = texture(city_noise, vec2(h * 0.013, wp.y * 0.02)).r;
	float g = clamp((streak - 0.5) * 1.4, 0.0, 1.0) * 0.35;
	g += clamp((patches - 0.55) * 1.2, 0.0, 1.0) * 0.25;
	g += smoothstep(1.4, 0.0, wp.y) * 0.35;
	return g * vertical;
}
