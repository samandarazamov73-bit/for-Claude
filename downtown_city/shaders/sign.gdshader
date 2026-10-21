// Shop signs / banners: textured, faintly self-lit, glowing at night.
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

#include "res://shaders/include/city_common.gdshaderinc"

uniform sampler2D tex : source_color, filter_linear_mipmap_anisotropic;
uniform float glow = 0.6;
uniform bool alpha_cut = false;

void fragment() {
	vec4 t = texture(tex, UV);
	if (alpha_cut && t.a < 0.5) discard;
	ALBEDO = t.rgb;
	EMISSION = t.rgb * glow * mix(0.05, 1.5, night_factor);
	ROUGHNESS = 0.45;
	SPECULAR = 0.5;
}
