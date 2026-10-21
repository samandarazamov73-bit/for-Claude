// Street-lamp glass: off by day, warm glow at night.
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

#include "res://shaders/include/city_common.gdshaderinc"

uniform vec3 color : source_color = vec3(1.0, 0.85, 0.6);
uniform float energy = 6.0;

void fragment() {
	ALBEDO = vec3(0.85, 0.84, 0.8);
	EMISSION = color * energy * smoothstep(0.35, 0.8, night_factor);
	ROUGHNESS = 0.2;
}
