extends Node
## Звуковые пугалки 3-го этажа (акт 4), пока Саман 3–4 минуты ищет маму:
##   • проезжаешь мимо закрытой двери палаты — изнутри резкий стук или глухой женский плач;
##   • в пустом коридоре за спиной — тяжёлое дыхание и быстрые босые шаги; стоит остановиться — обрываются;
##   • из дальних комнат — звон падающих инструментов, глухой смех, шёпот «Саман…».

var d                       # director
var running := false
var elapsed := 0.0
var count := 0
var _next := 7.0
var _steps: AudioStreamPlayer3D
var _breath: AudioStreamPlayer3D
var _follow_t := 0.0
var _last := ""
var _used_doors := {}


func start(director) -> void:
	d = director
	running = true
	elapsed = 0.0
	count = 0
	_next = 7.0
	if _steps == null:
		_steps = _player("barefoot_steps")
		_breath = _player("breathing")


func stop() -> void:
	running = false
	_cut_follow()


func _player(sound: String) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.stream = d.stream(sound, true)
	p.bus = "World"
	p.unit_size = 2.5
	p.max_distance = 18.0
	p.volume_db = -2.0
	add_child(p)
	return p


func _cut_follow() -> void:
	_follow_t = 0.0
	if _steps:
		_steps.stop()
		_breath.stop()


func _process(dt: float) -> void:
	if not running or get_tree().paused:
		return
	elapsed += dt
	var pl = d.player
	var pp: Vector3 = pl.global_position
	if _follow_t > 0.0:
		_follow_t -= dt
		var back: Vector3 = pl.global_transform.basis.z.normalized()
		_steps.global_position = pp + back * 3.2 + Vector3(0, 0.3, 0)
		_breath.global_position = pp + back * 2.6 + Vector3(0, 1.5, 0)
		# остановился — шаги обрываются на полушаге
		if absf(pl.v) < 0.15 or _follow_t <= 0.0:
			_cut_follow()
	_next -= dt
	if _next > 0.0:
		return
	_next = randf_range(8.0, 16.0)
	var door = _closed_door_near(pp, 3.2)
	var kinds: Array = []
	if door != null:
		kinds.append_array(["knock", "cry"])
	if absf(pl.v) > 0.5 and _last != "follow":
		kinds.append("follow")
	kinds.append_array(["far", "far"])
	var k: String = kinds[randi() % kinds.size()]
	if k == _last and kinds.size() > 1:
		k = kinds[(kinds.find(k) + 1) % kinds.size()]
	_last = k
	count += 1
	match k:
		"knock":
			_used_doors[door] = true
			var p: Vector3 = _behind_door(door, pp)
			d.snd("knock", p, 2.0, randf_range(0.9, 1.1), 20.0)
			door.rattle(1.5)
		"cry":
			_used_doors[door] = true
			d.snd("crying", _behind_door(door, pp), -4.0, randf_range(0.95, 1.05), 14.0)
		"follow":
			_follow_t = randf_range(3.0, 5.5)
			_steps.play()
			_breath.play()
		_:
			var what: Array = ["instruments_fall", "laughter", "whisper_saman"]
			var s: String = what[randi() % what.size()]
			var a: float = randf() * TAU
			var dist: float = randf_range(9.0, 17.0)
			var p := Vector3(clampf(pp.x + cos(a) * dist, 1.0, 74.0), pp.y + 1.3, clampf(pp.z + sin(a) * dist * 0.4, -15.0, -1.0))
			d.snd(s, p, -1.0 if s != "whisper_saman" else -6.0, randf_range(0.92, 1.05), 40.0)


func _closed_door_near(pp: Vector3, r: float):
	var best = null
	var bd := r
	for dg in d.game.door_groups:
		if dg.ext or dg.locked or _used_doors.has(dg):
			continue
		if dg.center.y < pp.y or dg.center.y > pp.y + 2.5 or dg.angle > 3.0:
			continue
		var dist: float = Vector2(dg.center.x - pp.x, dg.center.z - pp.z).length()
		if dist < bd:
			bd = dist
			best = dg
	return best


## Точка за дверью — со стороны, противоположной игроку.
func _behind_door(dg, pp: Vector3) -> Vector3:
	var c: Vector3 = dg.center
	var away := Vector3(c.x - pp.x, 0, c.z - pp.z)
	if away.length() < 0.01:
		away = Vector3(0, 0, 1)
	return c + away.normalized() * 1.2
