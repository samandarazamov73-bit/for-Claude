extends RefCounted
## Процедурные текстуры (пока нет настоящих). Заменить: положи картинку в intro/assets/textures/
## с именем road.png, sidewalk.png, grass.png, facade.png, hospital.png — они подхватятся сами.

const TEX_DIR: String = "res://intro/assets/textures/"


## Своя картинка из папки assets, если она там есть.
static func custom(name: String) -> Texture2D:
	for ext in ["png", "jpg", "webp"]:
		var path: String = TEX_DIR + name + "." + ext
		if ResourceLoader.exists(path):
			var t: Resource = load(path)
			if t is Texture2D:
				return t
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
