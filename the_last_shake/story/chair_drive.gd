extends RefCounted
## Как едет электроколяска — то же, что в санатории (sanatorium/scripts/wheelchair.gd): 5 скоростей (Q / R),
## плавный разгон и более резкое торможение, назад медленнее, разворот на месте, на скорости поворачивает
## медленнее, при смене направления колёсики уводят чуть в сторону. Здесь только расчёт скорости и
## поворота — куда можно ехать, решает сцена (в прологе: тропинка и пандус).

const SPEEDS := [1.1, 1.75, 2.4, 3.1, 3.9]     # м/с: 4,0; 6,3; 8,6; 11,2; 14,0 км/ч
const REVERSE := 0.45
const ACCEL := 0.8
const BRAKE := 1.8
const YAW_MAX := 1.35
const YAW_ACC := 7.0
const YAW_STOP := 11.0

var speed_level := 2
var v := 0.0                 # м/с вперёд
var w := 0.0                 # рад/с (плюс — влево)
var _caster := 0.0
var _caster_kick := 0.0
var _last_dir := 1.0


## Клавиши: W/S — вперёд/назад, A/D — поворот (как в здании).
func joystick() -> Vector2:
	var thr: float = Input.get_action_strength("drive_forward") - Input.get_action_strength("drive_back")
	var st: float = Input.get_action_strength("turn_right") - Input.get_action_strength("turn_left")
	return Vector2(thr, st)


## Q / R — скорость. Возвращает true, если поменялась.
func handle_speed_keys() -> bool:
	if Input.is_action_just_pressed("speed_up") and speed_level < SPEEDS.size() - 1:
		speed_level += 1
		return true
	if Input.is_action_just_pressed("speed_down") and speed_level > 0:
		speed_level -= 1
		return true
	return false


## Шаг: возвращает поворот за кадр (рад); скорость — в v.
func step(j: Vector2, dt: float) -> float:
	var vmax: float = SPEEDS[speed_level]
	var vt: float = j.x * vmax * (REVERSE if j.x < 0.0 else 1.0)
	var acc: float = maxf(ACCEL, vmax * 0.55)
	var brk: float = maxf(BRAKE, vmax * 1.1)
	var a: float = acc if (absf(vt) > absf(v) and signf(vt) == signf(v)) or absf(v) < 0.02 else brk
	if absf(j.x) < 0.05:
		a = brk
	v = move_toward(v, vt, a * dt)
	var turn_scale: float = 1.0 - 0.55 * clampf(absf(v) / SPEEDS[-1], 0.0, 1.0)
	var wt: float = -j.y * YAW_MAX * turn_scale * (0.75 if speed_level < 1 else 1.0)
	w = move_toward(w, wt, (YAW_ACC if absf(wt) > absf(w) and signf(wt) == signf(w) else YAW_STOP) * dt)
	var dir: float = signf(v) if absf(v) > 0.05 else _last_dir
	if dir != _last_dir:
		_caster_kick = randf_range(-1.0, 1.0) * 0.5
		_last_dir = dir
	_caster = lerpf(_caster, _caster_kick, 6.0 * dt)
	_caster_kick = move_toward(_caster_kick, 0.0, 1.5 * dt)
	return (w + _caster * 0.35 * clampf(absf(v) * 2.0, 0.0, 1.0)) * dt


## Упёрся (край тропинки, дверь, мама впереди): скорость гасится.
func blocked(k := 0.2) -> void:
	v *= k


func stop() -> void:
	v = 0.0
	w = 0.0
