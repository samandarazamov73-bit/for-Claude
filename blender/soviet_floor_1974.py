# -*- coding: utf-8 -*-
"""
Советский пол 1974 — полностью автономный скрипт для Blender 4.x.

Что делает: очищает сцену, строит пол 5x5 м с PBR-материалом из фотографии
мозаичной плитки (терраццо), ставит свет и камеру, рендерит кадр в Cycles
и экспортирует готовую 3D-модель пола в .glb (с вшитыми текстурами).

Запуск без интерфейса (из командной строки):
    blender -b -P soviet_floor_1974.py
    blender -b -P soviet_floor_1974.py -- "D:/textures/my_floor.jpg"

Путь после "--" (необязательный) заменяет floor_image_path.
"""

# =============================================================================
# НАСТРОЙКИ (меняйте здесь)
# =============================================================================

# Путь к фотографии пола (JPG/PNG). Пишите прямые слэши "C:/папка/файл.jpg"
# (или r"C:\папка\файл.jpg"). Если файла нет, скрипт поищет картинку
# с тем же именем рядом с собой и в папке textures/ рядом с собой.
floor_image_path = "C:/Soviet_Floor_Texture.jpg"

# Куда сохранить результаты. Если папка недоступна для записи (например,
# корень диска C:\ без прав администратора), файлы будут сохранены
# на Рабочий стол или в домашнюю папку — путь будет выведен в консоль.
RENDER_OUTPUT_PATH = "C:/Soviet_Floor_Render.png"
GLB_OUTPUT_PATH = "C:/Soviet_Floor_1974.glb"

FLOOR_SIZE_M = 5.0              # размер пола (квадрат), метры
TILE_SIZE_M = 0.40              # реальный размер одной плитки, метры
AUTO_CROP_WHOLE_TILES = True    # вырезать из фото только целые плитки -> бесшовный тайлинг
FORCE_SQUARE_TILES = True       # исправить сплющенность фото, чтобы плитки были квадратными
FALLBACK_TEXTURE_WIDTH_M = 2.0  # ширина фото в метрах, если швы найти не удалось

ROUGHNESS = 0.4                 # шероховатость поверхности
BUMP_STRENGTH = 1.0             # сила рельефа (нода Bump)
BUMP_DISTANCE_M = 0.003         # глубина швов, метры (3 мм)
# Контраст карты высот (линейная яркость): всё темнее LOW — дно шва,
# всё светлее HIGH — ровная поверхность плитки.
HEIGHT_RAMP_LOW = 0.09
HEIGHT_RAMP_HIGH = 0.17

RENDER_RESOLUTION = (1920, 1080)
RENDER_SAMPLES = 128
USE_GPU = True                  # использовать видеокарту, если она есть (иначе CPU)

# =============================================================================

import math
import os
import sys
import traceback

import bpy
import numpy as np
from mathutils import Vector


def log(msg):
    print("[SovietFloor] " + msg, flush=True)


# -----------------------------------------------------------------------------
# Вспомогательные функции: пути
# -----------------------------------------------------------------------------

def script_directory():
    try:
        return os.path.dirname(os.path.abspath(__file__))
    except NameError:
        return os.getcwd()


def resolve_image_path(path):
    """Находит текстуру: заданный путь, затем рядом со скриптом."""
    name = os.path.basename(path)
    here = script_directory()
    candidates = [path, os.path.join(here, name), os.path.join(here, "textures", name)]
    for candidate in candidates:
        if os.path.isfile(candidate):
            return os.path.abspath(candidate)
    raise FileNotFoundError(
        "Картинка пола не найдена. Проверьте floor_image_path. Искал:\n  "
        + "\n  ".join(candidates))


def _can_write(folder):
    probe = os.path.join(folder, ".soviet_floor_write_test.tmp")
    try:
        with open(probe, "w") as f:
            f.write("ok")
        os.remove(probe)
        return True
    except OSError:
        return False


def resolve_output_path(path):
    """Возвращает путь, куда реально можно записать файл (с запасным вариантом)."""
    folder = os.path.dirname(path)
    if os.path.isabs(path):
        try:
            os.makedirs(folder, exist_ok=True)
        except OSError:
            pass
        if os.path.isdir(folder) and _can_write(folder):
            return path

    home = os.path.expanduser("~")
    for fallback in (os.path.join(home, "Desktop"), home, os.getcwd()):
        if os.path.isdir(fallback) and _can_write(fallback):
            new_path = os.path.join(fallback, os.path.basename(path))
            log("ВНИМАНИЕ: нет доступа к '%s', сохраняю в '%s'" % (path, new_path))
            return new_path
    raise PermissionError("Не найдено ни одной папки, доступной для записи.")


# -----------------------------------------------------------------------------
# 1. Инициализация и очистка сцены
# -----------------------------------------------------------------------------

def clear_scene():
    # Удаляем все объекты (дефолтные куб, камеру, свет и всё остальное)
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)

    # Удаляем вложенные коллекции сцены
    for coll in list(bpy.data.collections):
        bpy.data.collections.remove(coll)

    # Удаляем «осиротевшие» данные: меши, материалы, камеры, лампы, картинки
    for datablocks in (bpy.data.meshes, bpy.data.materials, bpy.data.cameras,
                       bpy.data.lights, bpy.data.textures, bpy.data.node_groups,
                       bpy.data.curves):
        for block in list(datablocks):
            datablocks.remove(block)
    for img in list(bpy.data.images):
        if img.type not in {"RENDER_RESULT", "COMPOSITING"}:
            bpy.data.images.remove(img)
    log("Сцена очищена")


# -----------------------------------------------------------------------------
# 2. Загрузка текстуры и подготовка карт (цвет + нормали)
# -----------------------------------------------------------------------------

def image_to_array(img):
    """Пиксели картинки -> numpy (высота, ширина, 4). Строка 0 — низ картинки."""
    w, h = img.size
    ch = img.channels
    buf = np.empty(w * h * ch, dtype=np.float32)
    img.pixels.foreach_get(buf)
    buf = buf.reshape(h, w, ch)
    if ch == 4:
        return buf
    rgba = np.ones((h, w, 4), dtype=np.float32)
    rgba[..., :3] = buf[..., :3] if ch >= 3 else buf[..., :1]  # ч/б картинка -> RGB
    return rgba


def array_to_image(name, arr, non_color=False):
    """numpy (высота, ширина, 4) -> новая картинка Blender, упакованная в сцену."""
    h, w = arr.shape[:2]
    img = bpy.data.images.new(name, width=w, height=h, alpha=False)
    if non_color:
        img.colorspace_settings.name = "Non-Color"
    img.pixels.foreach_set(np.ascontiguousarray(arr, dtype=np.float32).ravel())
    img.update()
    img.pack()  # упаковываем, чтобы картинка попала в GLB без внешних файлов
    return img


def linear_luminance(rgba, is_srgb):
    rgb = rgba[..., :3]
    if is_srgb:
        rgb = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    return rgb @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)


def find_grout_lines(lum, axis):
    """
    Ищет тёмные линии швов между плитками.
    axis=1 — вертикальные швы (по столбцам), axis=0 — горизонтальные (по строкам).
    Возвращает отсортированный список координат швов с регулярным шагом.
    """
    off = 4
    contrast = (np.roll(lum, off, axis=axis) + np.roll(lum, -off, axis=axis)) * 0.5 - lum
    profile = contrast.mean(axis=1 - axis)
    # Сглаживание, чтобы слегка наклонённые швы давали чёткий пик
    profile = np.convolve(profile, np.ones(5) / 5.0, mode="same")
    n = profile.size
    margin = max(8, n // 50)
    profile[:margin] = 0.0
    profile[-margin:] = 0.0

    threshold = 0.25 * profile.max()
    min_gap = max(10, n // 12)
    peaks = []
    for i in np.argsort(profile)[::-1]:
        if profile[i] < threshold or profile[i] <= 0:
            break
        if all(abs(int(i) - p) > min_gap for p in peaks):
            peaks.append(int(i))
    peaks.sort()
    if len(peaks) < 2:
        return []

    # Оставляем самую длинную цепочку швов с примерно равным шагом
    gaps = np.diff(peaks)
    median = float(np.median(gaps))
    best, run = [], [peaks[0]]
    for p, g in zip(peaks[1:], gaps):
        if 0.7 * median <= g <= 1.3 * median:
            run.append(p)
        else:
            run = [p]
        if len(run) > len(best):
            best = list(run)
    return best if len(best) >= 2 else []


def build_floor_textures(src_img):
    """
    Готовит бесшовную текстуру цвета и карту нормалей для GLB.
    Возвращает (картинка_цвета, картинка_нормалей, ширина_м, высота_м).
    """
    rgba = image_to_array(src_img)
    h, w = rgba.shape[:2]
    is_srgb = (not src_img.is_float) and "srgb" in src_img.colorspace_settings.name.lower()
    lum = linear_luminance(rgba, is_srgb)

    # --- Обрезка по швам: только целые плитки, чтобы тайлинг был без стыков
    x0, x1, y0, y1 = 0, w, 0, h
    nx = ny = 0
    if AUTO_CROP_WHOLE_TILES:
        cols = find_grout_lines(lum, axis=1)
        rows = find_grout_lines(lum, axis=0)
        if cols:
            x0, x1, nx = cols[0], cols[-1], len(cols) - 1
        if rows:
            y0, y1, ny = rows[0], rows[-1], len(rows) - 1
        log("Найдено плиток в кадре фото: %d x %d (швы X=%s, Y=%s)" % (nx, ny, cols, rows))
    crop_w, crop_h = x1 - x0, y1 - y0

    # --- Реальный размер текстуры в метрах (масштаб берём из размера плитки)
    if nx:
        m_per_px = TILE_SIZE_M * nx / crop_w
    elif ny:
        m_per_px = TILE_SIZE_M * ny / crop_h
    else:
        m_per_px = FALLBACK_TEXTURE_WIDTH_M / w
    tex_w, tex_h = crop_w * m_per_px, crop_h * m_per_px
    if FORCE_SQUARE_TILES and nx and ny:
        tex_w, tex_h = nx * TILE_SIZE_M, ny * TILE_SIZE_M

    if (crop_w, crop_h) == (w, h):
        color_img = src_img
        log("Швы не найдены — используется вся картинка целиком")
    else:
        color = rgba[y0:y1, x0:x1].copy()
        color[..., 3] = 1.0
        color_img = array_to_image("Soviet_Floor_BaseColor", color)
    color_img.name = "Soviet_Floor_BaseColor"

    # --- Карта высот: тот же контраст, что у ноды ColorRamp в материале
    height = np.clip((lum[y0:y1, x0:x1] - HEIGHT_RAMP_LOW)
                     / (HEIGHT_RAMP_HIGH - HEIGHT_RAMP_LOW), 0.0, 1.0)

    # --- Карта нормалей (tangent space) из карты высот — аналог ноды Bump для GLB
    px_per_m_u = crop_w / tex_w
    px_per_m_v = crop_h / tex_h
    dh_du = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * 0.5 * px_per_m_u
    dh_dv = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * 0.5 * px_per_m_v
    k = BUMP_STRENGTH * BUMP_DISTANCE_M
    normal = np.dstack((-k * dh_du, -k * dh_dv, np.ones_like(height)))
    normal /= np.linalg.norm(normal, axis=2, keepdims=True)
    normal_rgba = np.ones((crop_h, crop_w, 4), dtype=np.float32)
    normal_rgba[..., :3] = normal * 0.5 + 0.5
    normal_img = array_to_image("Soviet_Floor_Normal", normal_rgba, non_color=True)

    log("Текстура: %dx%d px = %.2f x %.2f м (повторов на полу: %.1f x %.1f)"
        % (crop_w, crop_h, tex_w, tex_h, FLOOR_SIZE_M / tex_w, FLOOR_SIZE_M / tex_h))
    return color_img, normal_img, tex_w, tex_h


# -----------------------------------------------------------------------------
# 3. Геометрия пола с UV-развёрткой
# -----------------------------------------------------------------------------

def create_floor(tex_w, tex_h):
    half = FLOOR_SIZE_M / 2.0
    mesh = bpy.data.meshes.new("Soviet_Floor_Mesh")
    mesh.from_pydata([(-half, -half, 0), (half, -half, 0), (half, half, 0), (-half, half, 0)],
                     [], [(0, 1, 2, 3)])

    # Планарная UV-развёртка в реальном масштабе: 1 повтор текстуры = tex_w x tex_h метров.
    # Пропорции плитки сохраняются, текстура повторяется (REPEAT) без растяжения.
    uv_layer = mesh.uv_layers.new(name="UVMap")
    for loop in mesh.loops:
        co = mesh.vertices[loop.vertex_index].co
        uv_layer.data[loop.index].uv = ((co.x + half) / tex_w, (co.y + half) / tex_h)
    mesh.update()

    floor = bpy.data.objects.new("Soviet_Floor_1974", mesh)
    bpy.context.scene.collection.objects.link(floor)
    log("Пол %.0fx%.0f м создан, UV-развёртка готова" % (FLOOR_SIZE_M, FLOOR_SIZE_M))
    return floor


# -----------------------------------------------------------------------------
# 4. PBR-материал на нодах
# -----------------------------------------------------------------------------

def create_material(color_img):
    mat = bpy.data.materials.new("Soviet_Terrazzo_1974")
    mat.use_nodes = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    nodes.clear()

    output = nodes.new("ShaderNodeOutputMaterial")
    output.location = (400, 0)
    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.location = (100, 0)
    bsdf.inputs["Roughness"].default_value = ROUGHNESS
    bsdf.inputs["Metallic"].default_value = 0.0
    links.new(bsdf.outputs["BSDF"], output.inputs["Surface"])

    # Картинка пола -> Base Color
    tex = nodes.new("ShaderNodeTexImage")
    tex.name = "BaseColorTex"
    tex.location = (-600, 150)
    tex.image = color_img
    tex.interpolation = "Cubic"
    tex.extension = "REPEAT"
    links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])

    # Та же картинка как карта высот: ColorRamp усиливает контраст швов,
    # тёмные швы становятся «углублениями»
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.location = (-300, -150)
    ramp.color_ramp.elements[0].position = HEIGHT_RAMP_LOW
    ramp.color_ramp.elements[1].position = HEIGHT_RAMP_HIGH
    links.new(tex.outputs["Color"], ramp.inputs["Fac"])

    bump = nodes.new("ShaderNodeBump")
    bump.name = "Bump"
    bump.location = (-50, -250)
    bump.inputs["Strength"].default_value = BUMP_STRENGTH
    bump.inputs["Distance"].default_value = BUMP_DISTANCE_M
    links.new(ramp.outputs["Color"], bump.inputs["Height"])
    links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])

    log("Материал создан: Base Color + Roughness %.2f + Bump" % ROUGHNESS)
    return mat


def switch_material_to_normal_map(mat, normal_img):
    """
    Формат glTF не понимает ноду Bump, поэтому перед экспортом рельеф
    подключается через готовую карту нормалей (Normal Map) — так он сохранится в GLB.
    """
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    bsdf = next(n for n in nodes if n.type == "BSDF_PRINCIPLED")

    ntex = nodes.new("ShaderNodeTexImage")
    ntex.location = (-600, -500)
    ntex.image = normal_img
    ntex.interpolation = "Cubic"
    nmap = nodes.new("ShaderNodeNormalMap")
    nmap.location = (-300, -500)
    nmap.inputs["Strength"].default_value = 1.0
    links.new(ntex.outputs["Color"], nmap.inputs["Color"])
    links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])  # заменяет связь с Bump


# -----------------------------------------------------------------------------
# 5. Освещение, окружение и камера
# -----------------------------------------------------------------------------

def look_at(obj, target):
    direction = Vector(target) - obj.location
    obj.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()


def setup_world():
    scene = bpy.context.scene
    world = scene.world or bpy.data.worlds.new("World")
    scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background") or world.node_tree.nodes.new("ShaderNodeBackground")
    bg.inputs["Color"].default_value = (0.55, 0.62, 0.75, 1.0)  # прохладный свет «из окна»
    bg.inputs["Strength"].default_value = 0.25


def create_light(target):
    data = bpy.data.lights.new("Softbox", type="AREA")
    data.shape = "RECTANGLE"
    data.size, data.size_y = 3.0, 1.5
    data.energy = 450.0                     # Вт — мощный мягкий свет
    data.color = (1.0, 0.93, 0.84)          # тёплый оттенок лампы накаливания
    light = bpy.data.objects.new("Softbox", data)
    bpy.context.scene.collection.objects.link(light)
    # Свет сзади-сбоку и невысоко: скользящие лучи проявляют швы,
    # а камера видит мягкий блик на полированной поверхности
    light.location = (-1.8, 4.2, 2.0)
    look_at(light, target)
    light.visible_camera = False            # сам софтбокс в кадре не виден
    return light


def create_camera(target):
    data = bpy.data.cameras.new("Camera")
    data.lens = 45.0
    data.sensor_width = 36.0
    cam = bpy.data.objects.new("Camera", data)
    bpy.context.scene.collection.objects.link(cam)
    # Взгляд сверху вниз под углом ~50°, с лёгким поворотом по диагонали
    cam.location = (1.0, -1.5, 2.4)
    look_at(cam, target)
    # Лёгкая глубина резкости для фотореализма
    data.dof.use_dof = True
    data.dof.focus_distance = (Vector(target) - cam.location).length
    data.dof.aperture_fstop = 5.6
    bpy.context.scene.camera = cam
    return cam


# -----------------------------------------------------------------------------
# 6. Рендер (Cycles)
# -----------------------------------------------------------------------------

def enable_gpu(scene):
    """Пробует включить GPU (OptiX/CUDA/HIP/Metal/oneAPI), иначе остаётся CPU."""
    scene.cycles.device = "CPU"
    if not USE_GPU:
        return "CPU"
    try:
        prefs = bpy.context.preferences.addons["cycles"].preferences
    except KeyError:
        return "CPU"
    for backend in ("OPTIX", "CUDA", "HIP", "METAL", "ONEAPI"):
        try:
            prefs.compute_device_type = backend
        except TypeError:
            continue
        (prefs.refresh_devices if hasattr(prefs, "refresh_devices") else prefs.get_devices)()
        gpus = [d for d in prefs.devices if d.type == backend]
        if gpus:
            for d in prefs.devices:
                d.use = d.type == backend
            scene.cycles.device = "GPU"
            return "GPU (%s: %s)" % (backend, ", ".join(d.name for d in gpus))
    return "CPU"


def setup_render(output_path):
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    device = enable_gpu(scene)

    cycles = scene.cycles
    cycles.samples = RENDER_SAMPLES
    cycles.use_adaptive_sampling = True
    cycles.adaptive_threshold = 0.01
    cycles.use_denoising = True
    try:
        cycles.denoiser = "OPENIMAGEDENOISE"
    except TypeError:
        pass

    scene.render.resolution_x, scene.render.resolution_y = RENDER_RESOLUTION
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = False

    # Цветовое управление: AgX (Blender 4.x), при отсутствии — Filmic
    try:
        scene.view_settings.view_transform = "AgX"
    except TypeError:
        scene.view_settings.view_transform = "Filmic"
    try:
        scene.view_settings.look = "AgX - Medium High Contrast"  # чуть сочнее цвета
    except TypeError:
        pass
    scene.view_settings.exposure = 0.0

    settings = scene.render.image_settings
    settings.file_format = "PNG"
    settings.color_mode = "RGB"
    settings.color_depth = "8"
    scene.render.filepath = output_path
    log("Рендер: Cycles, %s, %dx%d, %d сэмплов" % (device, RENDER_RESOLUTION[0],
                                                    RENDER_RESOLUTION[1], RENDER_SAMPLES))


def render_image(output_path):
    log("Рендеринг... (это может занять несколько минут)")
    bpy.ops.render.render(write_still=True)
    if not os.path.isfile(output_path):
        raise RuntimeError("Рендер не сохранился: " + output_path)
    log("Рендер сохранён: " + output_path)


# -----------------------------------------------------------------------------
# 7. Экспорт GLB
# -----------------------------------------------------------------------------

def export_glb(floor, output_path):
    import addon_utils
    if not addon_utils.check("io_scene_gltf2")[1]:
        addon_utils.enable("io_scene_gltf2", default_set=True)

    # Выделяем только пол — камера и свет в модель не попадут
    for obj in bpy.context.scene.objects:
        obj.select_set(False)
    floor.select_set(True)
    bpy.context.view_layer.objects.active = floor

    options = dict(
        filepath=output_path,
        export_format="GLB",          # один файл, текстуры внутри
        use_selection=True,
        export_apply=True,
        export_yup=True,
        export_texcoords=True,
        export_normals=True,
        export_tangents=True,         # касательные для корректной карты нормалей
        export_materials="EXPORT",
        export_image_format="AUTO",
        export_cameras=False,
        export_lights=False,
    )
    # Передаём только те параметры, что есть в данной версии экспортёра
    available = bpy.ops.export_scene.gltf.get_rna_type().properties.keys()
    bpy.ops.export_scene.gltf(**{k: v for k, v in options.items() if k in available})
    if not os.path.isfile(output_path):
        raise RuntimeError("GLB не сохранился: " + output_path)
    log("3D-модель сохранена: " + output_path)


# -----------------------------------------------------------------------------
# Главный сценарий
# -----------------------------------------------------------------------------

def main():
    global floor_image_path
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if argv:
        floor_image_path = argv[0]

    log("Blender %s" % bpy.app.version_string)
    if bpy.app.version < (4, 0, 0):
        log("ВНИМАНИЕ: скрипт рассчитан на Blender 4.x")

    render_path = resolve_output_path(RENDER_OUTPUT_PATH)
    glb_path = resolve_output_path(GLB_OUTPUT_PATH)

    # 1. Очистка
    clear_scene()

    # 2. Текстура
    image_path = resolve_image_path(floor_image_path)
    src_img = bpy.data.images.load(image_path, check_existing=False)
    log("Текстура загружена: %s (%dx%d)" % (image_path, src_img.size[0], src_img.size[1]))
    color_img, normal_img, tex_w, tex_h = build_floor_textures(src_img)

    # 3-4. Пол и материал
    floor = create_floor(tex_w, tex_h)
    mat = create_material(color_img)
    floor.data.materials.append(mat)

    # 5. Свет и камера
    target = (0.0, 0.3, 0.0)
    setup_world()
    create_light(target)
    create_camera(target)

    # 6. Рендер
    setup_render(render_path)
    render_image(render_path)

    # 7. Экспорт (рельеф через карту нормалей)
    switch_material_to_normal_map(mat, normal_img)
    export_glb(floor, glb_path)

    log("ГОТОВО!\n  Рендер: %s\n  Модель: %s" % (render_path, glb_path))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
        log("ОШИБКА — см. сообщение выше")
        if bpy.app.background:
            sys.exit(1)
