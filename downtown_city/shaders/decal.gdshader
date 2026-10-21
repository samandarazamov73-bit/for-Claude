// Road paint text/arrows from the T_RoadDecals atlas (alpha blended quads, 1 cm above asphalt).
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, diffuse_burley;

uniform sampler2D atlas : source_color, filter_linear_mipmap_anisotropic;

void fragment() {
	vec4 t = texture(atlas, UV);
	ALBEDO = t.rgb * 0.85;
	ALPHA = t.a * 0.95;
	ROUGHNESS = 0.7;
	SPECULAR = 0.3;
}
