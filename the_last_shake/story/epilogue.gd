extends Node3D
## Эпилог: больница, ночь. Дед Анвар умер — на койке тело под простынёй, монитор тянет одну линию.
## Доктор по шагам объясняет его дочери Барно: сердце остановилось, а мозг жил ещё около двадцати минут —
## может, он вспоминал лучшее в жизни, а может, придумал чью-то жизнь, которой не было. Что он видел,
## мы никогда не узнаем. Затем логотип на трёх языках, манифест, автор.

const StoryUI = preload("res://story/story_ui.gd")
const Actor = preload("res://story/actor.gd")
const Props = preload("res://story/props.gd")

var ui
var cam: Camera3D
var doctor                     # story/actor.gd
var barno                      # story/actor.gd — дочь деда (настоящая, обычная)
var flat: AudioStreamPlayer    # монитор: одна сплошная линия
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
	env.ambient_light_color = Color(0.55, 0.62, 0.68)
	env.ambient_light_energy = 0.32
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.ssao_enabled = true
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
	fill.omni_range = 6.5
	fill.light_energy = 0.9
	fill.light_color = Color(0.86, 0.95, 0.92)
	fill.shadow_enabled = true
	add_child(fill)
	Props.box(self, Vector3(0.2, 2.98, 0.6), Vector3(1.2, 0.05, 0.2), _mat(Color(0.95, 0.98, 0.95), 0.4))
	# кровать: на ней тело деда под простынёй
	Props.box(self, Vector3(-0.6, 0.55, 0.3), Vector3(1.0, 0.18, 2.1), white)
	Props.box(self, Vector3(-0.6, 0.66, -0.2), Vector3(0.96, 0.08, 1.2), _mat(Color(0.8, 0.82, 0.85)))
	for z in [-0.75, 1.35]:
		Props.box(self, Vector3(-0.6, 0.75, z), Vector3(1.05, 0.9, 0.05), metal)
	var sheet := _mat(Color(0.9, 0.9, 0.88), 0.95)
	Props.box(self, Vector3(-0.6, 0.78, 0.4), Vector3(0.62, 0.22, 1.55), sheet)     # тело
	Props.box(self, Vector3(-0.6, 0.8, -0.45), Vector3(0.36, 0.24, 0.3), sheet)     # голова
	Props.box(self, Vector3(-0.6, 0.7, 0.3), Vector3(0.98, 0.04, 2.0), sheet)       # свисающая простыня
	# монитор сердца с зелёной линией и капельница
	var mon := Node3D.new()
	add_child(mon)
	mon.position = Vector3(0.6, 1.25, -0.9)
	mon.rotation.y = deg_to_rad(-35)
	Props.box(mon, Vector3.ZERO, Vector3(0.45, 0.35, 0.3), _mat(Color(0.3, 0.32, 0.3)))
	var scr := StandardMaterial3D.new()
	scr.albedo_color = Color(0.02, 0.08, 0.04)
	scr.emission_enabled = true
	scr.emission = Color(0.05, 0.25, 0.1)
	Props.box(mon, Vector3(0, 0.02, 0.151), Vector3(0.36, 0.24, 0.01), scr)
	var line := StandardMaterial3D.new()
	line.emission_enabled = true
	line.emission = Color(0.3, 1.0, 0.4)
	line.emission_energy_multiplier = 3.0
	line.albedo_color = Color(0.3, 1.0, 0.4)
	screen_line = Props.box(mon, Vector3(0, 0.02, 0.157), Vector3(0.3, 0.008, 0.005), line)
	Props.box(self, Vector3(0.6, 0.55, -0.9), Vector3(0.4, 1.1, 0.35), _mat(Color(0.75, 0.75, 0.72)))
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
	# дочь деда — Барно (та же модель, что «мама», но здесь обычная, уставшая)
	barno = Actor.new()
	add_child(barno)
	barno.setup("res://characters/mom.glb")
	barno.global_position = Vector3(0.55, 0.0, 2.05)
	# камера: мы стоим у двери рядом с Барно и смотрим на койку и доктора
	cam = Camera3D.new()
	cam.fov = 58.0
	add_child(cam)
	cam.position = Vector3(1.45, 1.6, 2.55)
	cam.look_at(Vector3(-0.1, 1.05, 0.4), Vector3.UP)
	cam.make_current()
	doctor.face(Vector3(0.55, 0, 2.05), true)
	barno.face(doctor.global_position, true)


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
	doctor.set_look(cam.global_position)
	barno.set_look(doctor.head_pos())
	await _say(doctor, "doctor", "Барно Анваровна… Присядьте, пожалуйста.")
	await _say(barno, "mom", "Не надо. Говорите.")
	await wait(0.8)
	flat.stop()                                       # монитор выключают
	snd("button", -12.0, 0.8)
	await wait(1.2)
	await _say(doctor, "doctor", "Ваш отец умер сегодня ночью, в двадцать три четырнадцать. Сердце остановилось во сне.")
	await wait(1.5)
	await _say(barno, "mom", "…Он мучился?")
	await _say(doctor, "doctor", "Нет. Но я должен вам кое-что объяснить. Это важно — послушайте.")
	await _say(doctor, "doctor", "Когда сердце останавливается, мозг умирает не сразу. Ещё примерно двадцать минут он работает.")
	await _say(barno, "mom", "Двадцать минут… И что он… всё это время?")
	await _say(doctor, "doctor", "Мы не знаем. Приборы показали только одно: всё это время его мозг был очень активен. Как во сне.")
	await _say(doctor, "doctor", "Может быть, он вспоминал. Самое лучшее, что было в его жизни, — вас маленькой, свою жену, свой дом.")
	await _say(doctor, "doctor", "А может быть, его мозг сочинил целую историю. Чью-то жизнь — жизнь человека, которого никогда не было.")
	await wait(2.0)
	await _say(barno, "mom", "…Перед самым концом он звал Самана. Так я хотела назвать сына. Он умер, не родившись.")
	await wait(1.5)
	await _say(doctor, "doctor", "Что он видел в эти двадцать минут, мы никогда не узнаем.")
	await _say(doctor, "doctor", "Мне очень жаль.")
	await wait(1.5)
	await GameState.fade_to(1.0, 3.0)
	hum.stop()
	ui.hide_line()
	await ui.title("Двадцать минут.",
		"Столько живёт мозг после того, как остановилось сердце. Что видел Анвар в свои последние двадцать " +
		"минут — Самана, санаторий, землетрясение — знал только он.", 7.0, 44)
	await wait(1.0)
	_done = true
	await ui.show_title("THE LAST SHAKE", "(Последний Скачок / Soʻnggi Silkiniş)", 80, 3.0)
	await wait(3.0)
	await ui.clear_title(1.5)
	await ui.show_title("«The Last Shake» — это манифест силы духа.",
		"Игра была полностью создана 16-летним соло-разработчиком с ограниченными физическими возможностями.\n\n" +
		"«Никакие барьеры в реальном мире не смогут запереть твой разум и твою мечту.\nСпасибо, что прошли этот путь со мной».\n\n" +
		"Автор игры и сценария: Саман", 34, 2.5)
	await wait(9.0)
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
