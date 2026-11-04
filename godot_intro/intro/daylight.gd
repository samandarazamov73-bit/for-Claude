extends Node
## Время суток: вечернее солнце в автобусе → закат у остановки → сумерки и темнота в лесу.
## set_time(t): 0 — день (начало поездки), ~0.4 — выход из автобуса, 1 — ночь.

# [t, высота солнца °, цвет солнца, сила солнца, верх неба, горизонт, туман, плотность тумана, рассеянный свет]
const KEYS: Array = [
	[0.0, 26.0, Color(1.0, 0.94, 0.84), 1.25, Color(0.38, 0.53, 0.72), Color(0.84, 0.82, 0.74), Color(0.7, 0.71, 0.68), 0.005, 1.25],
	[0.38, 10.0, Color(1.0, 0.76, 0.52), 1.1, Color(0.32, 0.4, 0.6), Color(0.96, 0.7, 0.45), Color(0.64, 0.54, 0.45), 0.007, 1.0],
	[0.6, 2.0, Color(1.0, 0.48, 0.26), 0.7, Color(0.18, 0.21, 0.38), Color(0.92, 0.42, 0.24), Color(0.38, 0.27, 0.26), 0.012, 0.5],
	[0.78, -3.0, Color(0.8, 0.3, 0.25), 0.0, Color(0.06, 0.07, 0.16), Color(0.3, 0.15, 0.17), Color(0.12, 0.1, 0.13), 0.018, 0.2],
	[1.0, -12.0, Color(0.3, 0.3, 0.5), 0.0, Color(0.008, 0.01, 0.025), Color(0.025, 0.025, 0.04), Color(0.015, 0.015, 0.022), 0.032, 0.05],
]
const SUN_AZIMUTH: float = -35.0

var env: Environment
var sky_mat: ProceduralSkyMaterial
var sun: DirectionalLight3D
var t: float = 0.0


func _ready() -> void:
	sky_mat = ProceduralSkyMaterial.new()
	var sky: Sky = Sky.new()
	sky.sky_material = sky_mat
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_sky_affect = 0.55
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.05
	env.adjustment_enabled = true
	var we: WorldEnvironment = WorldEnvironment.new()
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 70.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	add_child(sun)
	set_time(0.0)


func set_time(value: float) -> void:
	t = clampf(value, 0.0, 1.0)
	var i: int = 1
	while i < KEYS.size() - 1 and t > float(KEYS[i][0]):
		i += 1
	var a: Array = KEYS[i - 1]
	var b: Array = KEYS[i]
	var k: float = clampf((t - float(a[0])) / maxf(float(b[0]) - float(a[0]), 0.0001), 0.0, 1.0)
	var elev: float = lerpf(float(a[1]), float(b[1]), k)
	var energy: float = lerpf(float(a[3]), float(b[3]), k)
	sun.rotation_degrees = Vector3(-elev, SUN_AZIMUTH, 0.0)
	sun.light_color = (a[2] as Color).lerp(b[2] as Color, k)
	sun.light_energy = energy
	sun.visible = energy > 0.01
	sun.shadow_enabled = energy > 0.08
	var top: Color = (a[4] as Color).lerp(b[4] as Color, k)
	var hor: Color = (a[5] as Color).lerp(b[5] as Color, k)
	sky_mat.sky_top_color = top
	sky_mat.sky_horizon_color = hor
	sky_mat.ground_horizon_color = hor.darkened(0.25)
	sky_mat.ground_bottom_color = hor.darkened(0.7)
	env.fog_light_color = (a[6] as Color).lerp(b[6] as Color, k)
	env.fog_density = lerpf(float(a[7]), float(b[7]), k)
	env.ambient_light_energy = lerpf(float(a[8]), float(b[8]), k)
	env.adjustment_saturation = lerpf(0.95, 0.65, t)
