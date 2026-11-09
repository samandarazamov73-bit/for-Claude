// Shared helpers for the forest shaders.
//
// Per-instance LOD cross-fade
// ---------------------------
// Every LOD level of a plant is drawn by its own MultiMesh bucket (see scripts/lod_manager.gd).
// Buckets are filled coarsely per 32 m cell on the CPU; the exact per-instance decision happens here:
// the vertex shader measures the distance from the *main* camera (global main_camera_pos, so shadow
// passes pick the same LOD) to the instance origin and collapses instances outside the bucket's
// [begin, end] band. Inside the fade bands, complementary screen-space dither patterns let LOD n
// dissolve into LOD n+1 without popping (the two masks partition the pixels exactly).

global uniform vec3 main_camera_pos;
global uniform vec4 wind;              // xy: direction, z: strength, w: speed
global uniform vec4 world_rect;        // x, z origin of the terrain maps, size in texels (1 m)
global uniform sampler2D world_control1 : filter_linear, repeat_disable;   // b: canopy density, a: wetness
global uniform float wetness;
global uniform vec2 far_shadow;        // distance band where real shadows end and canopy shading takes over
global uniform bool shadow_coarse;     // Low/Medium: shadows of nearby plants come from the LOD1 mesh
global uniform bool debug_lod;         // F4: tint by LOD level

// x: begin, y: begin fade width, z: end, w: end fade width   (metres, already scaled by the preset)
instance uniform vec4 lod_range = vec4(0.0, 0.0, 100000.0, 1.0);
// x: plant height (m), y: translucency, z: colour variation amount, w: LOD index of this bucket
instance uniform vec4 plant_params = vec4(10.0, 1.0, 1.0, 0.0);

vec2 lod_fade(vec3 inst_pos, float size_scale, bool shadow_pass) {
	float d = distance(inst_pos, main_camera_pos) / max(size_scale, 0.05);
	float t_in = lod_range.y > 0.0 ? clamp((d - (lod_range.x - lod_range.y * 0.5)) / lod_range.y, 0.0, 1.0) : 1.0;
	float t_out = clamp((d - (lod_range.z - lod_range.w * 0.5)) / max(lod_range.w, 0.001), 0.0, 1.0);
	if (shadow_pass && plant_params.w > 0.5 && plant_params.w < 1.5 && d > far_shadow.x) {
		return vec2(0.0, 1.0);              // far LOD1 plants: canopy shading replaces their shadow
	}
	if (shadow_pass && shadow_coarse) {
		if (plant_params.w < 0.5) {
			return vec2(0.0, 1.0);          // LOD0 casts no shadow ...
		} else if (plant_params.w < 1.5) {
			t_in = 1.0;                      // ... LOD1 casts it instead, right up to the camera
		}
	}
	return vec2(t_in, t_out);
}

bool lod_hidden(vec2 f) {
	return f.x <= 0.0 || f.y >= 1.0;
}

// Interleaved gradient noise in [0, 1).
float ign(vec2 p) {
	return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

// true when this pixel belongs to the other LOD level of the cross-fade
bool lod_dither_discard(vec2 fragcoord, vec2 f) {
	if (f.x >= 1.0 && f.y <= 0.0) {
		return false;
	}
	float n = ign(fragcoord);
	return n >= f.x || n < f.y;
}

vec3 wind_offset(float time, vec3 wpos, vec3 inst_pos, vec4 col, float hnorm, float height_m, float rnd) {
	vec2 dir = normalize(wind.xy + vec2(1e-4));
	float strength = wind.z;
	float ph = dot(inst_pos.xz, vec2(0.031, 0.047)) + rnd * 6.2831;
	float t = time * wind.w;
	float gust = 0.55 + 0.45 * sin(t * 0.37 + ph * 0.21) * sin(t * 0.11 + ph * 0.13 + 1.3);
	// whole plant bends with the wind, more at the top
	float bend = strength * gust * hnorm * hnorm * (0.012 * height_m + 0.01) * (1.0 + 0.25 * sin(t * 0.9 + ph));
	vec3 off = vec3(dir.x, 0.0, dir.y) * bend;
	// branches sway around that
	float s1 = sin(t * 1.6 + ph + col.a * 6.2831) * 0.6 + sin(t * 2.7 + ph * 1.3 + col.a * 3.1) * 0.4;
	off += vec3(dir.x, 0.3, dir.y) * (col.g * strength * (0.035 + 0.06 * gust) * s1);
	// leaves flutter
	float s2 = sin(t * 7.3 + dot(wpos, vec3(2.1, 1.7, 2.9)) + col.a * 12.0);
	vec3 side = vec3(-dir.y, 0.0, dir.x);
	off += (vec3(0.0, 1.0, 0.0) * 0.6 + side * 0.4) * (col.b * strength * gust * 0.022 * s2);
	return off;
}

vec2 world_uv(vec2 xz) {
	return (xz - world_rect.xy + 0.5) / world_rect.zw;
}

float canopy_at(vec2 xz) {
	return texture(world_control1, world_uv(xz)).b;
}

// Beyond the shadow-map distance there are no real tree shadows, so darken by canopy density instead.
float far_canopy_shade(float dist, float canopy, float strength) {
	return mix(1.0, 1.0 - strength * canopy, smoothstep(far_shadow.x, far_shadow.y, dist));
}

vec3 hue_vary(vec3 c, float r, float amount) {
	// small brightness / yellow-blue shifts per instance (keeps the forest from looking cloned)
	float b = mix(0.82, 1.12, r);
	vec3 warm = c * vec3(1.08, 1.02, 0.80);
	vec3 cool = c * vec3(0.90, 1.0, 1.04);
	vec3 o = mix(cool, warm, fract(r * 7.13));
	return mix(c, o * b, amount);
}

// F4 debug view: LOD0 red, LOD1 green, LOD2 blue, ground cover yellow
vec3 lod_debug_tint(vec3 c) {
	if (!debug_lod) {
		return c;
	}
	float l = plant_params.w;
	vec3 t = l < 0.5 ? vec3(1.0, 0.15, 0.1) : (l < 1.5 ? vec3(0.15, 1.0, 0.15) : (l < 2.5 ? vec3(0.2, 0.35, 1.0) : vec3(1.0, 0.9, 0.1)));
	return mix(c, t * 0.6, 0.7);
}
