extends RefCounted
## Настройки начала игры (поездка на автобусе). Меняй числа здесь — остальной код трогать не нужно.

# --- Куда идти дальше ---
const NEXT_SCENE: String = "res://level.tscn"       # твой уровень; если файла нет — покажется «Конец пролога»
const MENU_SCENE: String = "res://main_menu.tscn"   # кнопка «В меню» на паузе

# --- Поездка ---
const RIDE_MINUTES: float = 4.0     # длина поездки: 3–5 минут (маршрут подгоняется сам)
const DARK_SECONDS: float = 8.0     # сколько длится чёрный экран, пока мама и коляска выходят
const FAST_FORWARD: float = 8.0     # перемотка поездки при зажатой клавише Tab

# --- Автобус ---
const BUS_CRUISE: float = 11.5      # м/с (~41 км/ч)
const BUS_ACCEL: float = 0.9
const BUS_DECEL: float = 1.1
const BUS_LAT_ACCEL: float = 1.1    # боковое ускорение в поворотах (ограничивает скорость)
const BUS_DWELL: float = 10.0       # секунд стоит на остановке
const BUS_RED_LIGHT: float = 11.0   # секунд ждёт на красном
const DOOR_EXTRA: float = 3.4       # секунд на двери и паузу вокруг стоянки (для подбора длины маршрута)
const LANE_OFFSET: float = 5.25     # правая полоса
const CURB_OFFSET: float = 5.62     # у остановки прижимается к бордюру
const BUS_LENGTH: float = 12.0
const BUS_WIDTH: float = 2.55
const BUS_HEIGHT: float = 3.05
const FLOOR_Y: float = 0.35         # пол салона (низкопольный автобус)

# --- Дорога ---
const ROAD_HALF: float = 7.0
const SIDEWALK: float = 4.2
const CURB: float = 0.15
const SIDE_OUT: float = 11.2        # край тротуара = ROAD_HALF + SIDEWALK

# --- Герой ---
# --- Модели (intro/assets/models/) ---
const MODELS_DIR: String = "res://intro/assets/models/"
const PEOPLE_DIR: String = "res://intro/assets/models/people/"
# Коляска с героем (wheelchair.glb) «смотрит» в +Z и мельче настоящей — поправка при загрузке:
const WHEELCHAIR_SCALE: float = 1.2         # длина станет 1.08 м, спинка 1.10 м
const WHEELCHAIR_YAW_DEG: float = 180.0
const WHEELCHAIR_LIFT: float = 0.552        # колёса — на пол
const WHEELCHAIR_EYE: Vector3 = Vector3(0.0, 1.19, 0.20)   # глаза героя: от центра коляски на полу (+Z — назад)
# Кто на каком сиденье (метки seat_* в bus.glb → файл в models/people/). Пустые сиденья — просто не пиши их.
const PASSENGERS: Dictionary = {
	"seat_13_w_r": "elder",        # прямо перед героем, у окна
	"seat_12_w_r": "hatman",
	"seat_20_s_r": "student",
	"seat_19_s": "worker",
	"seat_10_w": "grandma",
	"seat_11_a": "schoolgirl",
	"seat_06_w": "woman",
}

# --- Фото-текстуры ---
# Сколько метров покрывает одна картинка. Плитка или трещины выглядят слишком крупными — уменьши число.
const TEX_METERS: Dictionary = {"road": 3.0, "sidewalk": 2.0, "curb": 1.0, "grass": 3.0, "facade": 3.0, "hospital": 3.0}

const EYE_HEIGHT: float = 1.2       # высота глаз над полом автобуса (сидя в коляске)
const MOUSE_SENS: float = 0.0022


static func smooth(a: float, b: float, x: float) -> float:
	var t: float = clampf((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


static func damp(a: float, b: float, rate: float, dt: float) -> float:
	return lerpf(a, b, 1.0 - exp(-rate * dt))
