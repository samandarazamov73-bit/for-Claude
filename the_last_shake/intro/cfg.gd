extends RefCounted
## Настройки начала игры. Меняй числа здесь — остальной код трогать не нужно.

# --- Куда идти дальше ---
const NEXT_SCENE: String = "res://level.tscn"       # твой уровень (санаторий внутри); если файла нет — «Конец пролога»
const MENU_SCENE: String = "res://main_menu.tscn"   # кнопка «В меню» на паузе

# --- Поездка ---
const RIDE_MINUTES: float = 4.0     # длина поездки: 3–5 минут (маршрут подгоняется сам)
const DARK_SECONDS: float = 8.0     # сколько длится чёрный экран, пока мама и коляска выходят
const FAST_FORWARD: float = 8.0     # перемотка поездки при зажатой клавише Tab

# --- Автобус ---
const BUS_CRUISE: float = 12.5      # м/с (~45 км/ч) — загородная дорога
const BUS_ACCEL: float = 0.9
const BUS_DECEL: float = 1.1
const BUS_LAT_ACCEL: float = 1.1    # боковое ускорение в поворотах (ограничивает скорость)
const BUS_DWELL: float = 10.0       # секунд стоит на остановке
const BUS_RED_LIGHT: float = 11.0   # (если появится светофор) секунд ждёт на красном
const DOOR_EXTRA: float = 3.4       # секунд на двери и паузу вокруг стоянки (для подбора длины маршрута)
const LANE_OFFSET: float = 1.8      # своя полоса двухполосной лесной дороги
const CURB_OFFSET: float = 4.6      # у остановки заезжает в «карман»
const BUS_LENGTH: float = 12.0
const BUS_WIDTH: float = 2.55
const BUS_HEIGHT: float = 3.05
const FLOOR_Y: float = 0.35         # пол салона автобуса-заглушки (у ЛиАЗа пол берётся из модели)

# --- Лесная дорога ---
const ROAD_HALF: float = 3.6        # асфальт: 2 полосы по 3.6 м
const SHOULDER: float = 1.6         # гравийная обочина
const SIDE_OUT: float = 5.2         # край обочины = ROAD_HALF + SHOULDER
const POCKET_OUT: float = 6.4       # край заездного кармана у остановки
const FOREST_FROM: float = 12.0      # лес начинается в стольких метрах от оси дороги (до него — трава и кусты)
const FOREST_TO: float = 52.0       # дальше — туман
const TREE_SPACING: float = 4.5     # среднее расстояние между деревьями (меньше — гуще и тяжелее)
const ONCOMING_CARS: int = 5        # встречные машины

# --- Выход из автобуса и дорога через лес ---
const WALK_SPEED: float = 1.5       # м/с — коляска вперёд (Shift — быстрее)
const WALK_TURN: float = 1.4        # рад/с — поворот коляски (A / D)
const PATH_HALF: float = 1.7        # насколько можно отъехать от середины тропинки
const PATH_LENGTH: float = 260.0    # длина тропинки от остановки до санатория, м
const MOM_AHEAD: float = 2.8        # мама идёт впереди на столько метров
const NIGHT_AFTER: float = 210.0    # даже если стоять на месте, через столько секунд станет совсем темно
const FLASHLIGHT_ENERGY: float = 4.0

# --- Модели (intro/assets/models/) ---
const MODELS_DIR: String = "res://intro/assets/models/"
const PEOPLE_DIR: String = "res://intro/assets/models/people/"
const SANATORIUM_MODEL: String = "res://intro/assets/models/sanatorium.glb"   # положи модель здания — заменит заглушку
# Коляска с героем (wheelchair.glb) «смотрит» в +Z и мельче настоящей — поправка при загрузке:
const WHEELCHAIR_SCALE: float = 1.2         # длина станет 1.08 м, спинка 1.10 м
const WHEELCHAIR_YAW_DEG: float = 180.0
const WHEELCHAIR_LIFT: float = 0.552        # колёса — на пол
const WHEELCHAIR_EYE: Vector3 = Vector3(0.0, 1.19, 0.20)   # глаза героя: от центра коляски на полу (+Z — назад)
# Кто на каком сиденье (метки seat_* в bus.glb → файл в models/people/). Пустые сиденья — просто не пиши их.
# У окна — только те, кто помещается; слишком широких код сам чуть сдвигает к проходу.
const PASSENGERS: Dictionary = {
	"seat_13_w_r": "grandma_scarf",     # прямо перед героем, у окна
	"seat_11_a": "man_newspaper",       # дед с газетой — у прохода: газета шире места у окна
	"seat_19_s": "mother_baby",         # справа
}

# --- Фото-текстуры ---
# Сколько метров покрывает одна картинка. Плитка или трещины выглядят слишком крупными — уменьши число.
const TEX_METERS: Dictionary = {"road": 3.0, "sidewalk": 2.0, "curb": 1.0, "grass": 3.0, "facade": 3.0, "hospital": 3.0,
	"forest_floor": 4.0, "gravel": 2.0, "path": 2.0}

# --- Герой ---
const EYE_HEIGHT: float = 1.2       # высота глаз над полом (герой-заглушка без модели коляски)
const MOUSE_SENS: float = 0.0022


static func smooth(a: float, b: float, x: float) -> float:
	var t: float = clampf((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


static func damp(a: float, b: float, rate: float, dt: float) -> float:
	return lerpf(a, b, 1.0 - exp(-rate * dt))
