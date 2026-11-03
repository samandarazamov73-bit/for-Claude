extends RefCounted
## Текстуры. Пока нет настоящих — рисуются кодом. Настоящие фото-текстуры (PBR) кладутся в
## intro/assets/textures/<имя>/ — папкой, как скачал с ambientcg.com или polyhaven.com, БЕЗ переименования.
## Имена папок: road, sidewalk, curb, grass, facade, hospital.
## Код сам находит в папке цвет (Color / diff), рельеф (NormalGL / nor_gl), шероховатость (Roughness / rough)
## и затенение (AmbientOcclusion / ao). Можно и отдельными файлами: road.jpg, road_normal.jpg, road_rough.jpg, road_ao.jpg.

const TEX_DIR: String = "res://intro/assets/textures/"
const IMAGE_EXT: Array = ["png", "jpg", "jpeg", "webp"]

static var _pbr_cache: Dictionary = {}


## Фото-текстура: {"albedo", "normal", "rough", "ao"} — только то, что нашлось (может быть пусто).
static func pbr(name: String) -> Dictionary:
	if _pbr_cache.has(name):
		return _pbr_cache[name]
	var out: Dictionary = {}
	var normal_is_gl: bool = false
	for path in _list_images(TEX_DIR + name + "/"):
		var low: String = path.get_file().to_lower()
		var kind: String = _kind_of(low)
		if kind == "":
			continue
		var gl: bool = kind == "normal" and (low.contains("gl") or not low.contains("dx"))
		if out.has(kind) and not (kind == "normal" and gl and not normal_is_gl):
			continue
		var t: Texture2D = _load_tex(path)
		if t != null:
			out[kind] = t
			if kind == "normal":
				normal_is_gl = gl
	if not out.has("albedo") and out.has("plain"):
		out["albedo"] = out["plain"]
	out.erase("plain")
	# Отдельные файлы рядом: road.jpg, road_normal.jpg, road_rough.jpg, road_ao.jpg
	var single: Dictionary = {"albedo": "", "normal": "_normal", "rough": "_rough", "ao": "_ao"}
	for kind in single:
		if out.has(kind):
			continue
		for ext in IMAGE_EXT:
			var t2: Texture2D = _load_tex(TEX_DIR + name + str(single[kind]) + "." + ext)
			if t2 != null:
				out[kind] = t2
				break
	_pbr_cache[name] = out
	return out


## Только цветная картинка (или null).
static func custom(name: String) -> Texture2D:
	return pbr(name).get("albedo") as Texture2D


static func _kind_of(low: String) -> String:
	for skip in ["disp", "height", "bump", "metal", "opacity", "preview", "spec", "_arm", "mask"]:
		if low.contains(skip):
			return ""
	if low.contains("normal") or low.contains("_nor"):
		return "normal"
	if low.contains("rough"):
		return "rough"
	if low.contains("ambientocclusion") or low.contains("_ao") or low.begins_with("ao"):
		return "ao"
	for key in ["color", "col_", "diff", "albedo", "base"]:
		if low.contains(key):
			return "albedo"
	return "plain"             # картинка без подписи (у ambientcg это превью-шарик) — только если цвета нет


static func _list_images(dir_path: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var d: DirAccess = DirAccess.open(dir_path)
	if d == null:
		return out
	var files: PackedStringArray = d.get_files()
	files.sort()
	for f in files:
		# В собранной игре рядом лежат только «*.jpg.import» — имя без суффикса всё равно грузится.
		var n: String = f.trim_suffix(".import").trim_suffix(".remap")
		if IMAGE_EXT.has(n.get_extension().to_lower()) and not out.has(dir_path + n):
			out.append(dir_path + n)
	return out


static func _load_tex(path: String) -> Texture2D:
	if not ResourceLoader.exists(path):
		return null
	var r: Resource = load(path)
	if r is Texture2D:
		return r
	return null


static func _img(w: int, h: int) -> Image:
	return Image.create_empty(w, h, false, Image.FORMAT_RGBA8)


static func _tex(img: Image) -> ImageTexture:
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func asphalt() -> Texture2D:
	var c: Texture2D = custom("road")
	if c != null:
		return c
	var img: Image = _img(256, 256)
	img.fill(Color(0.29, 0.30, 0.32))
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 11
	for i in 9000:
		var g: float = rng.randf_range(-0.07, 0.07)
		img.set_pixel(rng.randi_range(0, 255), rng.randi_range(0, 255), Color(0.29 + g, 0.30 + g, 0.32 + g))
	for i in 6:
		img.fill_rect(Rect2i(rng.randi_range(0, 200), rng.randi_range(0, 200), rng.randi_range(30, 90), rng.randi_range(20, 60)),
			Color(0.24, 0.25, 0.27, 1.0))
	return _tex(img)


static func paving() -> Texture2D:
	var c: Texture2D = custom("sidewalk")
	if c != null:
		return c
	var img: Image = _img(128, 128)
	img.fill(Color(0.72, 0.70, 0.66))
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 3
	for i in 1500:
		var g: float = rng.randf_range(-0.05, 0.05)
		img.set_pixel(rng.randi_range(0, 127), rng.randi_range(0, 127), Color(0.72 + g, 0.70 + g, 0.66 + g))
	var line: Color = Color(0.56, 0.54, 0.51)
	for i in 3:
		img.fill_rect(Rect2i(i * 64, 0, 2, 128), line)
		img.fill_rect(Rect2i(0, i * 64, 128, 2), line)
	return _tex(img)


static func grass() -> Texture2D:
	var c: Texture2D = custom("grass")
	if c != null:
		return c
	var img: Image = _img(128, 128)
	img.fill(Color(0.37, 0.54, 0.23))
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 7
	for i in 3500:
		var g: float = rng.randf_range(-0.07, 0.07)
		img.set_pixel(rng.randi_range(0, 127), rng.randi_range(0, 127), Color(0.37 + g, 0.54 + g, 0.23 + g * 0.5))
	return _tex(img)


## Один «пролёт» фасада: 3×3 метра, окно по центру. Стена светлая — цвет дома задаётся вершинами.
static func facade(variant: int = 0) -> Texture2D:
	var c: Texture2D = custom("facade" if variant != 9 else "hospital")
	if c != null:
		return c
	var img: Image = _img(128, 128)
	img.fill(Color(1, 1, 1))
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 20 + variant
	for i in 500:
		var g: float = rng.randf_range(-0.05, 0.0)
		img.set_pixel(rng.randi_range(0, 127), rng.randi_range(0, 127), Color(1.0 + g, 1.0 + g, 1.0 + g))
	var wx: int = 18 if variant == 1 else 30
	var ww: int = 92 if variant == 1 else 68
	img.fill_rect(Rect2i(wx - 5, 26, ww + 10, 70), Color(0.82, 0.83, 0.84))       # рама
	for y in 62:                                                                    # стекло с градиентом
		var t: float = float(y) / 61.0
		img.fill_rect(Rect2i(wx, 30 + y, ww, 1), Color(0.36 - t * 0.2, 0.48 - t * 0.25, 0.59 - t * 0.25))
	img.fill_rect(Rect2i(wx + ww / 2 - 2, 30, 4, 62), Color(0.82, 0.83, 0.84))     # импост
	img.fill_rect(Rect2i(wx - 8, 96, ww + 16, 6), Color(0.77, 0.78, 0.79))         # подоконник
	return _tex(img)
