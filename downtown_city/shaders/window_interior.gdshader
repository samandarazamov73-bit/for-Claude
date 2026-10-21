// Interior mapping ("fake rooms") behind the windows, plus glass reflection.
// Mesh contract (see tools/prepare_kit.py):
//   UV    : 0..1 across the room plane, u left->right seen from outside, v top->bottom
//   UV2   : plane size in metres (width, height)
//   COLOR : r = random seed per plane
// Every pixel ray-traces a box room (back wall, side walls, floor, ceiling) with procedural
// furniture silhouettes, curtains/blinds and a ceiling light; no textures are sampled.
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

#include "res://shaders/include/city_common.gdshaderinc"

uniform float lit_bias = 0.0;
uniform bool force_dark = false;
uniform bool shop = false;
uniform bool office = false;
uniform float min_depth = 3.0;
uniform float max_depth = 5.5;

varying vec3 v_world;
varying vec3 v_wnormal;
varying float v_seed;

const vec3 WALL_COLORS[8] = vec3[8](
	vec3(0.86, 0.84, 0.78), vec3(0.90, 0.86, 0.74), vec3(0.78, 0.80, 0.80), vec3(0.70, 0.78, 0.84),
	vec3(0.74, 0.80, 0.68), vec3(0.88, 0.76, 0.62), vec3(0.62, 0.42, 0.36), vec3(0.93, 0.92, 0.90)
);

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wnormal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 o = MODEL_MATRIX[3].xyz;
	v_seed = fract(COLOR.r + hash13(floor(o * 3.1) + 17.0) + INSTANCE_CUSTOM.a * 0.37);
}

float box_mask(vec2 p, vec2 a, vec2 b) {
	vec2 s = step(a, p) * step(p, b);
	return s.x * s.y;
}

void fragment() {
	float w = max(UV2.x, 0.3);
	float h = max(UV2.y, 0.3);
	float s = v_seed;
	vec3 r3 = hash33(vec3(s * 91.7, s * 13.3, s * 47.9));
	vec3 r4 = hash33(r3 * 37.1 + 3.7);
	float r5 = hash11(s * 173.3 + 1.7);

	vec3 n = normalize(v_wnormal);
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), n));
	vec3 up = cross(n, right);
	vec3 rdw = normalize(v_world - CAMERA_POSITION_WORLD);
	vec3 rd = vec3(dot(rdw, right), dot(rdw, up), dot(rdw, n));
	rd.z = min(rd.z, -0.02);
	rd.x += rd.x >= 0.0 ? 1e-4 : -1e-4;
	rd.y += rd.y >= 0.0 ? 1e-4 : -1e-4;
	vec3 o = vec3(UV.x * w, (1.0 - UV.y) * h, 0.0);

	float depth = shop ? mix(6.0, 9.0, r3.x) : mix(min_depth, max_depth, r3.x);
	vec3 inv = 1.0 / rd;
	float tx = ((rd.x > 0.0 ? w : 0.0) - o.x) * inv.x;
	float ty = ((rd.y > 0.0 ? h : 0.0) - o.y) * inv.y;
	float tz = (-depth - o.z) * inv.z;
	float t = min(min(tx, ty), tz);
	vec3 p = o + rd * t;

	// room style
	vec3 wall = WALL_COLORS[int(r3.y * 8.0) % 8];
	bool wood = r3.z > 0.35;
	vec3 floor_col = wood ? mix(vec3(0.42, 0.26, 0.15), vec3(0.62, 0.44, 0.28), r4.x) : mix(vec3(0.35, 0.36, 0.38), vec3(0.55, 0.45, 0.40), r4.x);
	bool is_office = office || (r4.y > 0.82 && !shop);
	float p_lit = shop ? 0.85 : mix(0.28, 0.62, night_factor);
	bool lit = !force_dark && (fract(s * 7.13 + r4.z) < p_lit + lit_bias);
	vec3 light_col = is_office ? vec3(0.92, 0.96, 1.0) : mix(vec3(1.0, 0.78, 0.52), vec3(1.0, 0.88, 0.70), r5);

	vec3 col;
	float face_ao = 1.0;
	if (t == tz) {
		// back wall with a picture frame and a cabinet / sofa silhouette
		col = wall;
		vec2 q = p.xy;
		float pic_c = w * mix(0.3, 0.7, r4.x);
		float pic = box_mask(q, vec2(pic_c - 0.35, 1.45), vec2(pic_c + 0.35, 1.95));
		col = mix(col, mix(vec3(0.15, 0.2, 0.3), vec3(0.6, 0.35, 0.2), r3.z), pic * 0.85);
		float cab_a = w * mix(0.05, 0.45, r3.x);
		float cab = box_mask(q, vec2(cab_a, 0.0), vec2(cab_a + mix(0.8, 1.6, r4.y), mix(0.5, 0.95, r5)));
		col = mix(col, mix(vec3(0.18, 0.12, 0.08), vec3(0.45, 0.38, 0.32), r4.z), cab);
		if (shop) {
			float shelf = step(0.5, fract(q.y * 2.2)) * step(q.y, 2.1);
			col = mix(col, mix(vec3(0.75, 0.45, 0.3), vec3(0.3, 0.5, 0.65), fract(q.x * 1.7)), shelf * 0.6);
		}
		face_ao = 0.85;
	} else if (t == ty) {
		if (rd.y > 0.0) {
			col = vec3(0.92);
			face_ao = 0.95;
		} else {
			col = floor_col;
			if (wood) col *= 0.88 + 0.12 * step(0.5, fract(p.x * 5.0));
			float rug = box_mask(p.xz, vec2(w * 0.2, -depth * 0.75), vec2(w * 0.8, -depth * 0.3));
			col = mix(col, mix(vec3(0.5, 0.15, 0.12), vec3(0.2, 0.3, 0.45), r5), rug * step(0.5, r3.z));
			face_ao = 0.9;
		}
	} else {
		col = wall * 0.9;
		float door = box_mask(vec2(-p.z, p.y), vec2(depth * 0.55, 0.0), vec2(depth * 0.55 + 0.9, 2.1));
		col = mix(col, vec3(0.45, 0.32, 0.22), door * step(0.6, r3.x));
		face_ao = 0.8;
	}
	// soft corner darkening
	float edge = min(min(p.x, w - p.x), min(p.y, h - p.y));
	face_ao *= mix(0.65, 1.0, smoothstep(0.0, 0.6, edge));

	// lighting inside the room
	float day = 1.0 - night_factor;
	float window_light = (0.06 + 0.16 * day) * exp(p.z / depth * 1.3);
	vec3 lighting = vec3(window_light) * mix(vec3(0.9, 0.95, 1.0), vec3(0.25, 0.3, 0.45), night_factor);
	if (lit) {
		vec3 lamp = vec3(w * 0.5, h - 0.05, -depth * 0.5);
		float d2 = dot(p - lamp, p - lamp);
		float k = (is_office ? 1.3 : 0.9) / (0.6 + d2 * 0.22);
		lighting += light_col * k * mix(0.45, 1.5, night_factor);
		if (t == ty && rd.y > 0.0) {
			// the fixture itself
			vec2 lp = abs(p.xz - lamp.xz);
			float fixture = is_office ? box_mask(lp, vec2(0.0), vec2(w * 0.35, 0.25)) : smoothstep(0.32, 0.18, length(lp));
			lighting += light_col * fixture * 6.0;
		}
	}
	col *= lighting * face_ao;

	// curtains / blinds just behind the glass
	float tc = (-0.06 - o.z) * inv.z;
	vec3 pc = o + rd * tc;
	float cw = w * mix(0.08, 0.32, r3.y);
	float has_curtain = step(0.25, r4.x);
	float curtain = has_curtain * (step(pc.x, cw) + step(w - cw, pc.x));
	float aa = clamp(fwidth(pc.x) * 30.0, 0.0, 1.0);
	float folds = 0.84 + 0.16 * sin(pc.x * 38.0 + r4.y * 6.0) * (1.0 - aa);
	vec3 curtain_col = mix(vec3(0.92, 0.9, 0.86), vec3(0.75, 0.62, 0.45), step(0.8, r3.z)) * folds;
	vec3 curtain_light = (lit ? light_col * mix(0.25, 0.8, night_factor) : vec3(0.0)) + vec3(0.2 * day + 0.03);
	col = mix(col, curtain_col * curtain_light, clamp(curtain, 0.0, 1.0) * 0.8);
	float blinds_h = h * mix(0.15, 0.6, r4.z) * step(0.78, r3.x);
	float blinds = step(h - blinds_h, pc.y) * (0.8 + 0.2 * step(0.5, fract(pc.y * 14.0)) * (1.0 - clamp(fwidth(pc.y) * 28.0, 0.0, 1.0)));
	col = mix(col, vec3(0.85, 0.84, 0.8) * curtain_light, clamp(blinds, 0.0, 1.0) * 0.92);

	// mullion shadow / dirt on glass
	col *= 0.92;
	ALBEDO = vec3(0.02);
	EMISSION = col * mix(1.0, 1.25, night_factor);
	ROUGHNESS = 0.14;
	METALLIC = 0.0;
	SPECULAR = 0.22;
}
