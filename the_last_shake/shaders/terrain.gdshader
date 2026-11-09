// Chunked GPU terrain. Every chunk shares one flat grid mesh per LOD; heights come from the 1 m
// heightmap (global terrain_height). Odd vertices morph onto the next-coarser grid as the camera
// moves away (CDLOD-style), so LOD switches do not pop; skirts hide any remaining T-junctions.
// Six material layers are blended from two control maps with height-based blending, two rotated
// samples per layer against tiling, and a macro normal map.
shader_type spatial;
render_mode cull_back, depth_draw_opaque, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/include/forest_common.gdshaderinc"

global uniform sampler2D terrain_height : filter_nearest, repeat_disable;
global uniform sampler2D terrain_normal : filter_linear_mipmap, repeat_disable;

uniform sampler2D control0 : filter_linear, repeat_disable;
uniform sampler2DArray layer_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray layer_normal : filter_linear_mipmap_anisotropic, repeat_enable;
// litter, needles, moss, grass, soil, gravel
uniform float layer_tiling[6];     // metres per texture repeat (set in assets/materials/terrain.tres)
uniform float height_blend = 0.18;
uniform float micro_relief = 0.08;
uniform float detail_distance = 160.0;
uniform bool anti_tiling = true;
uniform float normal_strength = 1.0;
uniform float canopy_ao = 0.55;
uniform float far_shade = 0.55;

// x: grid spacing (m), y: morph start, z: morph end (metres from camera), w: skirt depth
instance uniform vec4 chunk_info = vec4(1.0, 10000.0, 10001.0, 0.5);

varying vec3 v_wpos;
varying float v_micro_w;

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

float micro(vec2 p) {
	return (vnoise(p * 0.85) - 0.5) + (vnoise(p * 2.3 + 17.1) - 0.5) * 0.45;
}

float tex_h(ivec2 i) {
	return texelFetch(terrain_height, clamp(i, ivec2(0), ivec2(world_rect.zw) - 1), 0).r;
}

float height_bilinear(vec2 w) {
	vec2 t = w - world_rect.xy;
	vec2 fl = floor(t);
	vec2 fr = t - fl;
	ivec2 i = ivec2(fl);
	float a = tex_h(i);
	float b = tex_h(i + ivec2(1, 0));
	float c = tex_h(i + ivec2(0, 1));
	float d = tex_h(i + ivec2(1, 1));
	return mix(mix(a, b, fr.x), mix(c, d, fr.x), fr.y);
}

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec2 local = VERTEX.xz;
	float g = chunk_info.x;
	float d = distance(origin.xz + local, main_camera_pos.xz);
	float k = clamp((d - chunk_info.y) / max(chunk_info.z - chunk_info.y, 1.0), 0.0, 1.0);
	vec2 odd = mod(local + 0.001, 2.0 * g) - 0.001;
	local -= odd * k;
	vec2 wxz = origin.xz + local;
	float h = height_bilinear(wxz);
	// sub-metre forest-floor relief near the camera (not on the road shoulders)
	float road_w = textureLod(world_control1, world_uv(wxz), 0.0).g;
	float mw = (1.0 - smoothstep(0.05, 0.4, road_w)) * (1.0 - smoothstep(45.0, 65.0, d));
	h += micro(wxz) * micro_relief * mw;
	h -= UV2.x * chunk_info.w;
	VERTEX = vec3(local.x, h - origin.y, local.y);
	NORMAL = vec3(0.0, 1.0, 0.0);
	v_wpos = vec3(wxz.x, h, wxz.y);
	v_micro_w = mw;
}

vec2 rot(vec2 v, float a) {
	float c = cos(a), s = sin(a);
	return vec2(c * v.x - s * v.y, s * v.x + c * v.y);
}

void fragment() {
	vec3 wp = v_wpos;
	vec2 cuv = world_uv(wp.xz);
	vec4 c0 = texture(control0, cuv);
	vec4 c1 = texture(world_control1, cuv);
	float w[6] = float[6](c0.r, c0.g, c0.b, c0.a, c1.r, c1.g);
	float canopy = c1.b;
	float wet = c1.a * wetness;
	float dist = length(wp - CAMERA_POSITION_WORLD);
	bool near = dist < detail_distance;

	// macro normal (+ micro relief gradient)
	vec3 tn = texture(terrain_normal, cuv).rgb * 2.0 - 1.0;
	vec3 N = normalize(vec3(tn.x, tn.z, tn.y));
	if (v_micro_w > 0.001) {
		float e = 0.15;
		float h0 = micro(wp.xz);
		float hx = micro(wp.xz + vec2(e, 0.0));
		float hz = micro(wp.xz + vec2(0.0, e));
		vec3 g = vec3(-(hx - h0) / e, 0.0, -(hz - h0) / e) * micro_relief * v_micro_w;
		N = normalize(N + g);
	}

	// break up the control-map edges a little
	float nb = vnoise(wp.xz * 0.9) - 0.5;
	vec3 alb = vec3(0.0);
	vec2 nxy = vec2(0.0);
	float rough = 0.0;
	float ao = 0.0;
	float hmax = -10.0;
	float hs[6];
	vec4 la[6];
	vec4 ln[6];
	float macro = vnoise(wp.xz * 0.021);
	float mix_n = smoothstep(0.4, 0.6, vnoise(wp.xz * 0.09 + 3.7));
	for (int i = 0; i < 6; i++) {
		hs[i] = -10.0;
		if (w[i] < 0.015) {
			continue;
		}
		vec2 uv1 = wp.xz / layer_tiling[i];
		vec4 a1 = texture(layer_albedo, vec3(uv1, float(i)));
		vec4 n1 = texture(layer_normal, vec3(uv1, float(i)));
		if (anti_tiling && near) {
			float ang = 1.1 + float(i) * 0.7;
			vec2 uv2 = rot(uv1 * 0.87, ang) + vec2(0.31, 0.57) * float(i + 1);
			vec4 a2 = texture(layer_albedo, vec3(uv2, float(i)));
			vec4 n2 = texture(layer_normal, vec3(uv2, float(i)));
			n2.rg = rot(n2.rg * 2.0 - 1.0, -ang) * 0.5 + 0.5;
			float t = mix_n;
			a1 = mix(a1, a2, t);
			n1 = mix(n1, n2, t);
		}
		la[i] = a1;
		ln[i] = n1;
		hs[i] = w[i] + (a1.a + nb * 0.35) * height_blend * 2.0;
		hmax = max(hmax, hs[i]);
	}
	float wsum = 0.0;
	for (int i = 0; i < 6; i++) {
		if (hs[i] < -5.0) {
			continue;
		}
		float bw = max(hs[i] - (hmax - height_blend), 0.0);
		alb += la[i].rgb * bw;
		nxy += (ln[i].rg * 2.0 - 1.0) * bw;
		rough += ln[i].b * bw;
		ao += ln[i].a * bw;
		wsum += bw;
	}
	wsum = max(wsum, 1e-4);
	alb /= wsum;
	nxy /= wsum;
	rough /= wsum;
	ao /= wsum;

	// large-scale variation so the floor never repeats
	alb *= mix(0.86, 1.12, macro);
	alb = mix(alb, alb * vec3(1.06, 1.0, 0.86), smoothstep(0.55, 0.9, vnoise(wp.xz * 0.006 + 9.0)) * 0.6);
	// damp ditches and hollows
	alb *= mix(1.0, 0.62, wet);
	rough = mix(rough, 0.18, wet * 0.85);
	// distant canopy shading (beyond the shadow maps)
	alb *= far_canopy_shade(dist, canopy, far_shade);

	// tangent frame from the terrain normal (u = +x, image-up = -z)
	vec3 T = normalize(vec3(1.0, 0.0, 0.0) - N * N.x);
	vec3 B = cross(N, T);
	nxy *= normal_strength * (1.0 - wet * 0.6);
	vec3 nw = normalize(T * nxy.x + B * nxy.y + N * sqrt(max(1.0 - dot(nxy, nxy), 0.05)));
	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
	if (debug_lod) {
		float k = log2(chunk_info.x) + 1.0;   // 0.5 m -> 0 ... 8 m -> 4
		alb = mix(alb, vec3(0.5 + 0.5 * cos(k * 1.3), 0.5 + 0.5 * cos(k * 1.3 + 2.1), 0.5 + 0.5 * cos(k * 1.3 + 4.2)) * 0.5, 0.6);
	}
	ALBEDO = alb;
	ROUGHNESS = clamp(rough, 0.08, 1.0);
	SPECULAR = 0.4;
	AO = ao * mix(1.0, 1.0 - canopy_ao, canopy);
	AO_LIGHT_AFFECT = 0.1;
}
