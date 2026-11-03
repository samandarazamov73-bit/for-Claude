extends Node
## Звук начала игры. Пока нет настоящих файлов, всё синтезируется кодом (двигатель, дорога, двери, гонг).
## Свои звуки: положи файл в intro/assets/audio/ с нужным именем (.ogg, .wav или .mp3) — он заменит синтез.
##   engine  — двигатель автобуса (петля)        road   — шум колёс (петля)
##   motor   — мотор коляски (петля)             hiss   — пневматика дверей
##   beeps   — писк перед закрытием дверей       chime  — гонг автоинформатора
##   ding    — звонок кнопки «остановка»         tick   — поворотник
##   ramp    — выезд пандуса

const RATE: int = 22050
const AUDIO_DIR: String = "res://intro/assets/audio/"

var volume: float = 0.8

var _engine: AudioStreamPlayer
var _road: AudioStreamPlayer
var _motor: AudioStreamPlayer
var _pool: Array = []
var _sfx: Dictionary = {}
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_rng.seed = 5
	_engine = _make_player(_custom("engine", _engine_loop()))
	_road = _make_player(_custom("road", _noise_loop(2.0, 0.08)))
	_motor = _make_player(_custom("motor", _motor_loop()))
	for i in 5:
		var p: AudioStreamPlayer = AudioStreamPlayer.new()
		add_child(p)
		_pool.append(p)
	_sfx = {
		"hiss": _custom("hiss", _hiss()),
		"beeps": _custom("beeps", _beeps()),
		"chime": _custom("chime", _chime()),
		"ding": _custom("ding", _ding()),
		"tick": _custom("tick", _tick()),
		"ramp": _custom("ramp", _ramp()),
	}
	_set_vol(_engine, 0.0)
	_set_vol(_road, 0.0)
	_set_vol(_motor, 0.0)


func _make_player(stream: AudioStream) -> AudioStreamPlayer:
	var p: AudioStreamPlayer = AudioStreamPlayer.new()
	p.stream = stream
	add_child(p)
	p.play()
	return p


static func _custom(sound_name: String, fallback: AudioStream) -> AudioStream:
	for ext in ["ogg", "wav", "mp3"]:
		var path: String = AUDIO_DIR + sound_name + "." + ext
		if ResourceLoader.exists(path):
			var r: Resource = load(path)
			if r is AudioStream:
				return r
	return fallback


func _set_vol(p: AudioStreamPlayer, v: float) -> void:
	p.volume_db = linear_to_db(maxf(v * volume, 0.0001))


# --- Каждый кадр ----------------------------------------------------------------------------

func update(speed: float, accel: float, moving: bool) -> void:
	var throttle: float = clampf(accel / 0.9, 0.0, 1.0)
	_engine.pitch_scale = 0.8 + speed / 25.0 + throttle * 0.1
	_set_vol(_engine, (0.07 + throttle * 0.04 + speed * 0.002) if moving else 0.0)
	_road.pitch_scale = 0.7 + speed / 30.0
	_set_vol(_road, clampf(speed / 12.0, 0.0, 1.0) * 0.12 if moving else 0.0)


func set_motor(level: float) -> void:
	_set_vol(_motor, clampf(level, 0.0, 1.0) * 0.06)


func fade_engine_out() -> void:
	_set_vol(_engine, 0.0)
	_set_vol(_road, 0.0)


func play_sfx(sound_name: String, gain: float = 1.0) -> void:
	if not _sfx.has(sound_name):
		return
	for p in _pool:
		var pl: AudioStreamPlayer = p as AudioStreamPlayer
		if not pl.playing:
			pl.stream = _sfx[sound_name]
			pl.volume_db = linear_to_db(maxf(gain * volume, 0.0001))
			pl.play()
			return


# --- Синтез -----------------------------------------------------------------------------------

static func _wav(samples: PackedFloat32Array, loop: bool) -> AudioStreamWAV:
	var data: PackedByteArray = PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var w: AudioStreamWAV = AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = samples.size()
	return w


func _buf(seconds: float) -> PackedFloat32Array:
	var b: PackedFloat32Array = PackedFloat32Array()
	b.resize(int(float(RATE) * seconds))
	return b


## Двигатель: целое число периодов за секунду — петля без щелчка.
func _engine_loop() -> AudioStreamWAV:
	var s: PackedFloat32Array = _buf(1.0)
	var n: int = s.size()
	var phases: Array = []
	for h in 8:
		phases.append(_rng.randf() * TAU)
	for i in n:
		var t: float = float(i) / float(n)
		var v: float = 0.0
		for h in range(1, 9):
			v += sin(TAU * 42.0 * float(h) * t + float(phases[h - 1])) / float(h)
		v += sin(TAU * 21.0 * t) * 0.7
		v *= 0.7 + 0.3 * sin(TAU * 3.0 * t)
		s[i] = v * 0.28
	return _wav(s, true)


func _motor_loop() -> AudioStreamWAV:
	var s: PackedFloat32Array = _buf(1.0)
	var n: int = s.size()
	for i in n:
		var t: float = float(i) / float(n)
		s[i] = (sin(TAU * 150.0 * t) + 0.4 * sin(TAU * 300.0 * t) + 0.15 * sin(TAU * 450.0 * t)) * 0.3
	return _wav(s, true)


## Шум с плавным стыком начала и конца (петля).
func _noise_loop(seconds: float, lp: float) -> AudioStreamWAV:
	var n: int = int(float(RATE) * seconds)
	var f: int = 2000
	var raw: PackedFloat32Array = PackedFloat32Array()
	raw.resize(n + f)
	var y: float = 0.0
	for i in n + f:
		y += lp * (_rng.randf_range(-1.0, 1.0) - y)
		raw[i] = y
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(n)
	for i in n:
		var v: float = raw[i]
		if i < f:
			var k: float = float(i) / float(f)
			v = raw[i] * k + raw[n + i] * (1.0 - k)
		out[i] = v * 1.8
	return _wav(out, true)


func _hiss() -> AudioStreamWAV:
	var s: PackedFloat32Array = _buf(0.9)
	var prev: float = 0.0
	for i in s.size():
		var t: float = float(i) / float(RATE)
		var x: float = _rng.randf_range(-1.0, 1.0)
		var hp: float = x - prev
		prev = x
		var env: float = minf(t / 0.03, 1.0) * exp(-t * 4.5)
		s[i] = hp * env * 0.5
	return _wav(s, false)


func _beeps() -> AudioStreamWAV:
	var s: PackedFloat32Array = _buf(1.0)
	for k in 3:
		var start: int = int(float(k) * 0.32 * float(RATE))
		var ln: int = int(0.16 * float(RATE))
		for i in ln:
			if start + i < s.size():
				var sq: float = 1.0 if sin(TAU * 1450.0 * float(i) / float(RATE)) > 0.0 else -1.0
				s[start + i] = sq * 0.18
	return _wav(s, false)


func _chime() -> AudioStreamWAV:
	var s: PackedFloat32Array = _buf(1.5)
	var freqs: Array = [660.0, 880.0, 990.0]
	for k in 3:
		var start: int = int(float(k) * 0.22 * float(RATE))
		var ln: int = int(0.6 * float(RATE))
		for i in ln:
			if start + i < s.size():
				var t: float = float(i) / float(RATE)
				s[start + i] += sin(TAU * float(freqs[k]) * t) * exp(-t * 5.0) * 0.3
	return _wav(s, false)


func _ding() -> AudioStreamWAV:
	var s: PackedFloat32Array = _buf(1.2)
	for i in s.size():
		var t: float = float(i) / float(RATE)
		s[i] = (sin(TAU * 1250.0 * t) + 0.35 * sin(TAU * 2500.0 * t)) * exp(-t * 4.0) * 0.35
	return _wav(s, false)


func _tick() -> AudioStreamWAV:
	var s: PackedFloat32Array = _buf(0.05)
	for i in int(0.02 * float(RATE)):
		var sq: float = 1.0 if sin(TAU * 2200.0 * float(i) / float(RATE)) > 0.0 else -1.0
		s[i] = sq * 0.12 * (1.0 - float(i) / (0.02 * float(RATE)))
	return _wav(s, false)


## Пандус: гул мотора и короткие писки.
func _ramp() -> AudioStreamWAV:
	var s: PackedFloat32Array = _buf(2.4)
	for i in s.size():
		var t: float = float(i) / float(RATE)
		var saw: float = fmod(t * 95.0, 1.0) * 2.0 - 1.0
		var env: float = minf(t / 0.2, 1.0) * minf((2.4 - t) / 0.3, 1.0)
		s[i] = saw * env * 0.18
	for k in 4:
		var start: int = int(float(k) * 0.6 * float(RATE))
		for i in int(0.12 * float(RATE)):
			if start + i < s.size():
				var sq: float = 1.0 if sin(TAU * 1800.0 * float(i) / float(RATE)) > 0.0 else -1.0
				s[start + i] += sq * 0.1
	return _wav(s, false)
