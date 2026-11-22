extends Node3D
## Эпилог: больница, ночь, 1975. Умер старик, которого игрок раньше не видел, — на койке тело под простынёй,
## монитор тянет одну линию. Доктор объясняет его детям, Малике и Шухрату: сердце остановилось, а мозг жил ещё
## около двадцати минут — может, вспоминал лучшее, а может, сочинил чью-то жизнь, которой не было. Только приборы
## показывали, что всё это время он боялся и с кем-то дрался. Затем логотип на трёх языках и манифест.

const StoryUI = preload("res://story/story_ui.gd")
const Actor = preload("res://story/actor.gd")
const Props = preload("res://story/props.gd")

var ui
var cam: Camera3D
var doctor                     # story/actor.gd
var malika                     # story/actor.gd — дочь умершего (модель мамы в платке, спиной к нам)
var shukhrat                   # story/actor.gd — сын умершего
var _scarf: MeshInstance3D
var flat: AudioStreamPlayer    # монитор: одна сплошная линия
var mon_light: OmniLight3D
var beep_t := 0.0
var beep_rate := 0.45          # с между ударами
var screen_line: MeshInstance3D
var _t := 0.0
var _done := false
var _blur: ColorRect


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	GameState.set_fade(1.0)
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	ui = StoryUI.new()
	add_child(ui)
	_build_room()
	_blur = ColorRect.new()
	_blur.color = Color(0.0, 0.0, 0.0, 1.0)
	_blur.set_anchors_preset(Control.PRESET_FULL_RECT)
	_blur.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	layer.add_child(_blur)
	_blur.modulate.a = 0.0
	_run()


func _mat(c: Color, rough := 0.85) -> StandardMaterial3D:
	return Props.mat(c, rough)


func _build_room() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.06, 0.09)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# ночная палата: главный свет — люминесцентная трубка, остальное — отражённый от стен свет (SSIL);
	# ровной «заливки» почти нет, углы и пол под кроватью тёмные
	env.ambient_light_color = Color(0.55, 0.62, 0.68)
	env.ambient_light_energy = 0.08
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_agx_white = 8.0
	env.tonemap_agx_contrast = 1.3
	env.ssao_enabled = true
	env.ssil_enabled = true
	env.ssil_radius = 4.0
	env.ssil_intensity = 1.4
	env.glow_enabled = true
	env.glow_intensity = 0.8
	env.adjustment_enabled = true
	env.adjustment_saturation = 0.8
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var wall := _mat(Color(0.62, 0.72, 0.66))
	var white := _mat(Color(0.88, 0.88, 0.85))
	var floor_m := _mat(Color(0.45, 0.42, 0.38), 0.6)
	var metal := Props.mat(Color(0.75, 0.76, 0.78), 0.35, 0.6)
	# комната 5 × 6 м, высота 3 м
	Props.box(self, Vector3(0, -0.05, 0), Vector3(5.0, 0.1, 6.0), floor_m)
	Props.box(self, Vector3(0, 3.05, 0), Vector3(5.0, 0.1, 6.0), white)
	Props.box(self, Vector3(-2.55, 1.5, 0), Vector3(0.1, 3.0, 6.0), wall)
	Props.box(self, Vector3(0, 1.5, 3.05), Vector3(5.0, 3.0, 0.1), wall)
	Props.box(self, Vector3(0, 1.5, -3.05), Vector3(5.0, 3.0, 0.1), wall)
	# правая стена с окном (дневной свет)
	Props.box(self, Vector3(2.55, 0.45, 0), Vector3(0.1, 0.9, 6.0), wall)
	Props.box(self, Vector3(2.55, 2.75, 0), Vector3(0.1, 0.5, 6.0), wall)
	Props.box(self, Vector3(2.55, 1.7, -2.2), Vector3(0.1, 1.6, 1.6), wall)
	Props.box(self, Vector3(2.55, 1.7, 2.2), Vector3(0.1, 1.6, 1.6), wall)
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.05, 0.07, 0.12)     # за окном ночь
	glass.emission_enabled = true
	glass.emission = Color(0.08, 0.1, 0.18)
	glass.emission_energy_multiplier = 0.6
	Props.box(self, Vector3(2.58, 1.7, 0), Vector3(0.02, 1.6, 2.8), glass)
	for z in [-0.7, 0.7]:
		Props.box(self, Vector3(2.53, 1.7, z), Vector3(0.05, 1.6, 0.06), white)
	# одна лампа дневного света под потолком — холодная, ночная
	var fill := OmniLight3D.new()
	fill.position = Vector3(0.2, 2.8, 0.6)
	fill.omni_range = 7.5
	fill.omni_attenuation = 1.3                         # как лампы в санатории (lights.gd)
	fill.light_energy = 1.5
	fill.light_color = Color(0.84, 0.95, 0.92)          # «холодная белая» трубка ~4100 K, чуть зелёная
	fill.shadow_enabled = true
	add_child(fill)
	Props.box(self, Vector3(0.2, 2.98, 0.6), Vector3(1.2, 0.05, 0.2), _mat(Color(0.95, 0.98, 0.95), 0.4))
	# кровать: на ней тело под простынёй (своя модель epi_bed — если есть)
	if not _model("epi_bed", Vector3(-0.6, 0.0, 0.3), 0.0):
		Props.box(self, Vector3(-0.6, 0.55, 0.3), Vector3(1.0, 0.18, 2.1), white)
		Props.box(self, Vector3(-0.6, 0.66, -0.2), Vector3(0.96, 0.08, 1.2), _mat(Color(0.8, 0.82, 0.85)))
		for z in [-0.75, 1.35]:
			Props.box(self, Vector3(-0.6, 0.75, z), Vector3(1.05, 0.9, 0.05), metal)
	_model("epi_cabinet", Vector3(-2.2, 0.0, 2.2), PI * 0.5)
	_model("epi_lamp", Vector3(0.2, 3.0, 0.6), 0.0)
	# тело под простынёй — округлые формы, чтобы читался силуэт: голова, грудь, ноги, стопы приподнимают ткань
	var sheet := _mat(Color(0.84, 0.85, 0.86), 0.95)
	_blob(_capsule(0.2, 0.8), Vector3(-0.6, 0.8, -0.02), Vector3(PI * 0.5, 0, 0), Vector3(1.2, 1.0, 0.62), sheet)   # грудь, живот
	_blob(_sphere(0.115), Vector3(-0.6, 0.84, -0.55), Vector3.ZERO, Vector3(1.0, 0.9, 1.1), sheet)                  # голова
	for x in [-0.1, 0.1]:
		_blob(_capsule(0.085, 0.95), Vector3(-0.6 + x, 0.76, 0.72), Vector3(PI * 0.5, 0, 0), Vector3(1.0, 1.0, 0.8), sheet)   # ноги
		_blob(_capsule(0.05, 0.2), Vector3(-0.6 + x * 1.2, 0.84, 1.17), Vector3(0.2, 0, 0), Vector3.ONE, sheet)            # стопы
	Props.box(self, Vector3(-0.6, 0.7, 0.3), Vector3(0.98, 0.03, 2.0), sheet)       # простыня свисает с краёв
	# монитор сердца с зелёной линией и капельница
	var have_cab: bool = _model("epi_cabinet_2", Vector3(0.75, 0.0, -0.95), deg_to_rad(-35))
	var top_y: float = 0.85 if have_cab else 1.1
	if not have_cab:
		Props.box(self, Vector3(0.6, 0.55, -0.9), Vector3(0.4, 1.1, 0.35), _mat(Color(0.75, 0.75, 0.72)))
	var mon := Node3D.new()
	add_child(mon)
	mon.position = Vector3(0.68, top_y + 0.175, -0.92)
	mon.rotation.y = deg_to_rad(-35)
	var line := StandardMaterial3D.new()
	line.emission_enabled = true
	line.emission = Color(0.3, 1.0, 0.4)
	line.emission_energy_multiplier = 3.0
	line.albedo_color = Color(0.3, 1.0, 0.4)
	# зелёный отсвет экрана кардиомонитора на стене и тумбе (гаснет, когда монитор выключают)
	mon_light = OmniLight3D.new()
	mon_light.light_color = Color(0.35, 1.0, 0.5)
	mon_light.light_energy = 0.12
	mon_light.omni_range = 1.4
	mon_light.omni_attenuation = 2.0
	mon.add_child(mon_light)
	mon_light.position = Vector3(0, 0.07, 0.35)
	if ResourceLoader.exists("res://sanatorium/models/epi_monitor.glb"):
		var m := Props.glb("res://sanatorium/models/epi_monitor.glb", 1.0)
		mon.add_child(m)
		m.position = Vector3(0, -0.175, 0)
		screen_line = Props.box(mon, Vector3(-0.085, 0.07, 0.196), Vector3(0.15, 0.006, 0.004), line)
	else:
		Props.box(mon, Vector3.ZERO, Vector3(0.45, 0.35, 0.3), _mat(Color(0.3, 0.32, 0.3)))
		var scr := StandardMaterial3D.new()
		scr.albedo_color = Color(0.02, 0.08, 0.04)
		scr.emission_enabled = true
		scr.emission = Color(0.05, 0.25, 0.1)
		Props.box(mon, Vector3(0, 0.02, 0.151), Vector3(0.36, 0.24, 0.01), scr)
		screen_line = Props.box(mon, Vector3(0, 0.02, 0.157), Vector3(0.3, 0.008, 0.005), line)
	if not _model("epi_iv", Vector3(-1.45, 0.0, -0.65), 0.6):
		Props.cyl(self, Vector3(-1.4, 0.95, -0.6), 0.015, 1.9, metal)
		var bag := StandardMaterial3D.new()
		bag.albedo_color = Color(0.9, 0.95, 1.0, 0.5)
		bag.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		Props.box(self, Vector3(-1.4, 1.8, -0.6), Vector3(0.12, 0.2, 0.05), bag)
	# календарь
	var cal := Label3D.new()
	cal.text = "НОЯБРЬ\n1975"
	cal.font_size = 64
	cal.pixel_size = 0.004
	cal.modulate = Color(0.55, 0.1, 0.1)
	cal.position = Vector3(-0.6, 1.9, 2.99)
	cal.rotation.y = PI
	add_child(cal)
	Props.box(self, Vector3(-0.6, 1.85, 3.0), Vector3(0.6, 0.75, 0.01), _mat(Color(0.95, 0.94, 0.9)))
	# доктор в белом халате (тот самый «мужчина в белом»)
	doctor = Actor.new()
	add_child(doctor)
	doctor.setup("res://characters/psycho.glb")
	doctor.global_position = Vector3(0.35, 0.0, 0.55)
	# дети умершего — Малика (в платке) и Шухрат; мы стоим у двери за их спинами
	malika = Actor.new()
	add_child(malika)
	malika.setup("res://characters/mom.glb")
	malika.global_position = Vector3(0.7, 0.0, 1.95)
	shukhrat = Actor.new()
	add_child(shukhrat)
	shukhrat.setup("res://characters/grandpa.glb")
	shukhrat.global_position = Vector3(1.35, 0.0, 1.75)
	# Шухрат — не пациент: та же модель, но вместо больничной рубашки тёмная гражданская (перекрашенная текстура)
	var civ := "res://characters/grandpa_civil.jpg"
	if ResourceLoader.exists(civ) and shukhrat.get("model"):
		var cm := StandardMaterial3D.new()
		cm.albedo_texture = load(civ)
		cm.roughness = 0.85
		cm.cull_mode = BaseMaterial3D.CULL_DISABLED
		for mi in (shukhrat.model as Node).find_children("*", "MeshInstance3D", true, false):
			if str(mi.name).begins_with("geometry"):
				(mi as MeshInstance3D).material_override = cm
	# платок Малики: покрывает голову и затылок, сзади свисает треугольный хвост
	var sc_mat := _mat(Color(0.15, 0.12, 0.14), 0.95)
	_scarf = MeshInstance3D.new()                       # корень платка — следует за головой
	_scarf.top_level = true
	malika.add_child(_scarf)
	var cap := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.118
	sm.height = 0.25
	cap.mesh = sm
	cap.material_override = sc_mat
	cap.position = Vector3(0, 0.0, 0.03)
	cap.scale = Vector3(1.04, 1.0, 1.08)
	_scarf.add_child(cap)
	var tail := MeshInstance3D.new()
	var pm := PrismMesh.new()
	pm.size = Vector3(0.2, 0.26, 0.02)
	tail.mesh = pm
	tail.material_override = sc_mat
	tail.position = Vector3(0, -0.22, 0.1)
	tail.rotation = Vector3(-0.12, 0, PI)
	_scarf.add_child(tail)
	cam = Camera3D.new()
	cam.fov = 58.0
	add_child(cam)
	cam.position = Vector3(1.75, 1.6, 2.75)
	cam.look_at(Vector3(-0.1, 1.05, 0.4), Vector3.UP)
	cam.make_current()
	doctor.face(Vector3(0.9, 0, 1.9), true)
	malika.face(doctor.global_position, true)
	shukhrat.face(doctor.global_position, true)


## Своя модель из sanatorium/models (если есть): на пол в точке pos, поворот yaw. true — поставлена.
func _model(nm: String, pos: Vector3, yaw: float) -> bool:
	var path := "res://sanatorium/models/%s.glb" % nm
	if not ResourceLoader.exists(path):
		return false
	var m := Props.glb(path, 1.0)
	add_child(m)
	m.position = pos
	m.rotation.y = yaw
	return true


func _capsule(r: float, h: float) -> Mesh:
	var m := CapsuleMesh.new()
	m.radius = r
	m.height = h
	m.radial_segments = 16
	m.rings = 6
	return m


func _sphere(r: float) -> Mesh:
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0
	m.radial_segments = 16
	m.rings = 8
	return m


func _blob(mesh: Mesh, pos: Vector3, rot: Vector3, scl: Vector3, m: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = m
	mi.position = pos
	mi.rotation = rot
	mi.scale = scl
	add_child(mi)


func stream(sound: String, loop := false) -> AudioStream:
	var path: String = "res://story/sfx/%s.wav" % sound
	if not ResourceLoader.exists(path):
		path = "res://sanatorium/assets/sfx/%s.wav" % sound       # щелчок кнопки — из звуков здания
	var s: AudioStream = load(path)
	if loop and s is AudioStreamWAV:
		var w: AudioStreamWAV = (s as AudioStreamWAV).duplicate()
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = int(w.get_length() * w.mix_rate)
		return w
	return s


func snd(sound: String, vol := 0.0, pitch := 1.0) -> void:
	var p := AudioStreamPlayer.new()
	p.stream = stream(sound)
	p.volume_db = vol
	p.pitch_scale = pitch
	add_child(p)
	p.finished.connect(p.queue_free)
	p.play()


func wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _run() -> void:
	await wait(1.0)
	var hum := AudioStreamPlayer.new()
	hum.stream = stream("hospital_hum", true)
	hum.volume_db = -16.0
	add_child(hum)
	hum.play()
	# монитор тянет одну линию — потом его выключают
	beep_rate = 0.0
	flat = AudioStreamPlayer.new()
	flat.stream = stream("monitor_beep", true)
	flat.volume_db = -14.0
	flat.pitch_scale = 0.98
	add_child(flat)
	flat.play()
	GameState.set_fade(0.0)
	_blur.modulate.a = 1.0
	var tw := create_tween()
	tw.tween_property(_blur, "modulate:a", 0.0, 3.0).set_ease(Tween.EASE_OUT)
	await wait(3.5)
	doctor.set_look(malika.head_pos())
	malika.set_look(doctor.head_pos())
	shukhrat.set_look(doctor.head_pos())
	await _say(doctor, "doctor", "Малика Ахмедовна… Присядьте, пожалуйста.")
	await _say(malika, "malika", "Не надо. Говорите.")
	await wait(0.8)
	flat.stop()                                       # монитор выключают
	if mon_light:
		mon_light.visible = false
	if screen_line:
		screen_line.visible = false
	snd("button", -12.0, 0.8)
	await wait(1.2)
	await _say(doctor, "doctor", "Ваш отец умер сегодня ночью, в двадцать три четырнадцать. Сердце остановилось во сне.")
	await wait(1.5)
	await _say(shukhrat, "shukhrat", "…Он мучился?")
	await _say(doctor, "doctor", "Нет. Но я должен вам кое-что объяснить. Это важно — послушайте.")
	await _say(doctor, "doctor", "Когда сердце останавливается, мозг умирает не сразу. Ещё примерно двадцать минут он работает.")
	await _say(malika, "malika", "Двадцать минут… И что он… всё это время?")
	await _say(doctor, "doctor", "Мы не знаем. Приборы показали только одно: всё это время его мозг был очень активен. Как во сне.")
	await _say(doctor, "doctor", "Может быть, он вспоминал. Самое лучшее, что было в его жизни, — вас маленькими, свою жену, свой дом.")
	await _say(doctor, "doctor", "А может быть, его мозг сочинил целую историю. Чью-то жизнь — жизнь человека, которого никогда не было. Только приборы показывали, что всё это время он боялся. И с кем-то дрался.")
	await wait(1.0)
	# Малика плачет; Шухрат обнимает её за плечи
	snd("crying", -6.0, 1.05)
	malika.set_look(null)
	shukhrat.set_look(malika.head_pos())
	var to: Vector3 = malika.global_position - shukhrat.global_position
	to.y = 0.0
	var tw2 := create_tween()
	tw2.tween_property(shukhrat, "global_position", malika.global_position - to.normalized() * 0.45, 1.2).set_trans(Tween.TRANS_SINE)
	await tw2.finished
	var sh: Vector3 = malika.head_pos() + Vector3(0, -0.22, 0)
	shukhrat.set_hands(sh + Vector3(0, 0, -0.1), sh + Vector3(0, 0, 0.12), 0.9)
	await wait(2.5)
	await _say(doctor, "doctor", "Что он видел в эти двадцать минут, мы никогда не узнаем. У нас есть только эти показатели.")
	await _say(doctor, "doctor", "Мне очень жаль.")
	await wait(1.5)
	await GameState.fade_to(1.0, 3.0)
	hum.stop()
	ui.hide_line()
	# титры — на своём чёрном фоне под слоем надписей (общее затемнение лежит поверх всего интерфейса)
	var bg_layer := CanvasLayer.new()
	bg_layer.layer = 29
	add_child(bg_layer)
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg_layer.add_child(bg)
	GameState.set_fade(0.0)
	await wait(1.0)
	_done = true
	await ui.show_title("THE LAST SHAKE", "(Последний Скачок / Soʻnggi Silkiniş)", 80, 3.0)
	await wait(3.0)
	await ui.clear_title(1.5)
	await ui.show_title("«The Last Shake» — это манифест силы духа.",
		"Игра была полностью создана 16-летним соло-разработчиком с ограниченными физическими возможностями.", 34, 2.5)
	await wait(6.0)
	ui.hint("Нажмите любую клавишу", 999.0)
	set_process_unhandled_input(true)


## Реплика с жестами: говорящий жестикулирует только пока говорит.
func _say(who_node, who: String, text: String) -> void:
	who_node.play("talk_loop", 0.35)
	await ui.line(who, text)
	who_node.play("idle_loop", 0.45)


func _line(who: String, text: String, sec := 0.0) -> void:
	await ui.line(who, text, sec)


func _process(dt: float) -> void:
	_t += dt
	if _scarf and malika:                              # платок на голове Малики
		_scarf.global_position = malika.head_pos() + Vector3(0, -0.02, 0)
		_scarf.rotation = Vector3(0, malika.rotation.y, 0)
	if cam:
		cam.rotation.z = sin(_t * 0.7) * 0.01
	if beep_rate <= 0.0:
		return
	beep_t -= dt
	if screen_line:
		screen_line.scale.y = 1.0 + maxf(0.0, 18.0 * (1.0 - (beep_rate - beep_t) * 6.0))
	if beep_t <= 0.0:
		beep_t = beep_rate
		snd("monitor_beep", -10.0)


func _unhandled_input(event: InputEvent) -> void:
	if not _done:
		return
	if (event is InputEventKey or event is InputEventMouseButton) and event.is_pressed() and ui.line_visible() == false:
		_done = false
		GameState.to_menu()
