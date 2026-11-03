extends RefCounted
## «Водитель»: разгоняется, тормозит перед поворотами и точно останавливается у остановок и светофора.

const C = preload("res://intro/cfg.gd")

var route                     # маршрут (route.gd)
var s: float = 0.0            # пройдено по маршруту, м
var v: float = 0.0            # скорость, м/с
var accel: float = 0.0        # ускорение (для наклона кузова)
var index: int = 0            # номер следующего события
var stopped: bool = false     # стоит у события и ждёт release()


func _init(r) -> void:
	route = r
	s = r.start_s
	v = C.BUS_CRUISE * 0.85


func next_event() -> Variant:
	if index < route.events.size():
		return route.events[index]
	return null


func release() -> void:
	if not stopped:
		return
	stopped = false
	index += 1


func update(dt: float) -> void:
	if dt <= 0.0:
		return
	var prev_v: float = v
	if not stopped:
		var ev: Variant = next_event()
		var allowed: float = route.plan_at(s)
		if ev != null:
			var dist: float = float(ev["s"]) - s
			allowed = minf(allowed, sqrt(2.0 * C.BUS_DECEL * maxf(0.0, dist)))
		else:
			allowed = minf(allowed, C.BUS_CRUISE)
		v = maxf(0.0, minf(v + C.BUS_ACCEL * dt, allowed))
		s += v * dt
		if ev != null and float(ev["s"]) - s < 0.25 and v < 0.6:
			s = float(ev["s"])
			v = 0.0
			stopped = true
			accel = 0.0
			return
	# Ограничиваем: при «доводке» до остановки скорость обнуляется рывком,
	# и без ограничения кузов клевал бы носом.
	accel = clampf((v - prev_v) / dt, -C.BUS_DECEL * 1.5, C.BUS_ACCEL * 1.5)
