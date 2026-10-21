"""Procedural PBR texture generator for Downtown City.

Generates every texture the project needs that is not shipped with the kit
(the kit repos only contain the concrete/asphalt set). All textures tile.
Normal maps use the OpenGL (Y+) convention that Godot expects.
ORM = (ambient occlusion, roughness, metallic).

Usage: python3 tools/gen_textures.py <project_dir>
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

RNG = np.random.default_rng(1337)
OUT = "textures"

FONT_DIRS = ["/usr/share/fonts/opentype/urw-base35", "/usr/share/fonts/opentype/noto",
             "/usr/share/fonts/truetype/dejavu", "/usr/share/fonts/truetype/liberation"]


def font(name, size, index=0):
    for d in FONT_DIRS:
        p = os.path.join(d, name)
        if os.path.exists(p):
            return ImageFont.truetype(p, size, index=index)
    return ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", size)


# --------------------------------------------------------------------------- noise
def value_noise(size, cells, seed=None):
    """Tileable smooth value noise in [0,1] (size x size), `cells` lattice cells."""
    rng = np.random.default_rng(seed) if seed is not None else RNG
    if isinstance(cells, int):
        cells = (cells, cells)
    lat = rng.random((cells[1], cells[0]))
    ys = np.linspace(0, cells[1], size[1] if isinstance(size, tuple) else size, endpoint=False)
    xs = np.linspace(0, cells[0], size[0] if isinstance(size, tuple) else size, endpoint=False)
    xi = np.floor(xs).astype(int)
    yi = np.floor(ys).astype(int)
    xf = xs - xi
    yf = ys - yi
    xf = xf * xf * (3 - 2 * xf)
    yf = yf * yf * (3 - 2 * yf)
    x0, x1 = xi % cells[0], (xi + 1) % cells[0]
    y0, y1 = yi % cells[1], (yi + 1) % cells[1]
    a = lat[np.ix_(y0, x0)]
    b = lat[np.ix_(y0, x1)]
    c = lat[np.ix_(y1, x0)]
    d = lat[np.ix_(y1, x1)]
    top = a + (b - a) * xf[None, :]
    bot = c + (d - c) * xf[None, :]
    return top + (bot - top) * yf[:, None]


def fbm(size, base_cells, octaves=5, gain=0.5, seed=None):
    rng = np.random.default_rng(seed) if seed is not None else RNG
    total = 0.0
    amp = 1.0
    norm = 0.0
    cells = base_cells
    for _ in range(octaves):
        total = total + amp * value_noise(size, cells, int(rng.integers(1 << 30)))
        norm += amp
        amp *= gain
        cells = (cells[0] * 2, cells[1] * 2) if isinstance(cells, tuple) else cells * 2
    return total / norm


def blur_wrap(a, r):
    """Gaussian-ish blur with wrap-around (box blur x3)."""
    if r <= 0:
        return a
    out = a.astype(np.float64)
    for _ in range(3):
        acc = np.zeros_like(out)
        for dx in range(-r, r + 1):
            acc += np.roll(out, dx, axis=1)
        out = acc / (2 * r + 1)
        acc = np.zeros_like(out)
        for dy in range(-r, r + 1):
            acc += np.roll(out, dy, axis=0)
        out = acc / (2 * r + 1)
    return out


def normal_from_height(h, strength):
    dx = (np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)) * 0.5
    dy = (np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)) * 0.5
    nx = -dx * strength
    ny = dy * strength  # OpenGL convention: +Y up in tangent space (image rows go down)
    nz = np.ones_like(h)
    ln = np.sqrt(nx * nx + ny * ny + nz * nz)
    n = np.stack([nx / ln, ny / ln, nz / ln], axis=-1)
    return ((n * 0.5 + 0.5) * 255).clip(0, 255).astype(np.uint8)


def save_rgb(arr, name):
    Image.fromarray((np.clip(arr, 0, 1) * 255).astype(np.uint8), "RGB").save(os.path.join(OUT, name), optimize=True)


def save_rgba(arr, name):
    Image.fromarray((np.clip(arr, 0, 1) * 255).astype(np.uint8), "RGBA").save(os.path.join(OUT, name), optimize=True)


def save_normal(n, name):
    Image.fromarray(n, "RGB").save(os.path.join(OUT, name), optimize=True)


def save_orm(ao, rough, metal, name):
    save_rgb(np.stack([ao, rough, metal], -1), name)


def srgb(c):
    return np.array(c, dtype=np.float64) / 255.0


# --------------------------------------------------------------------------- masonry
def masonry(size, cols, rows, mortar_px, colors, color_jitter, bevel_px, offset=0.5,
            chip=0.3, seed=0, mortar_color=(0.62, 0.6, 0.57), name="", rough_unit=0.82,
            rough_mortar=0.95, height_noise=0.25, stain=0.25, chroma=1.0):
    """Running-bond masonry. Returns albedo, height, ao, rough."""
    rng = np.random.default_rng(seed)
    H = W = size
    y = np.arange(H)[:, None].repeat(W, 1).astype(np.float64)
    x = np.arange(W)[None, :].repeat(H, 0).astype(np.float64)
    ch = H / rows
    row = np.floor(y / ch).astype(int)
    shift = (row % 2) * offset * (W / cols)
    cw = W / cols
    xs = (x + shift) % W
    col = np.floor(xs / cw).astype(int)
    lx = xs - col * cw
    ly = y - row * ch
    # distance to the unit edge in px
    edge = np.minimum.reduce([lx, cw - lx, ly, ch - ly])
    unit_id = (row * 7919 + col * 104729) % 100003
    ids = np.unique(unit_id)
    lut_col = {}
    pal = np.array(colors, dtype=np.float64) / 255.0
    for i in ids:
        base = pal[rng.integers(len(pal))]
        j = 1.0 + rng.normal(0, color_jitter, 3) * np.array([1.0, 0.9, 0.8]) * chroma
        j *= 1.0 + rng.normal(0, color_jitter * 0.8)
        lut_col[i] = np.clip(base * j, 0, 1)
    keys = np.array(list(lut_col.keys()))
    vals = np.array([lut_col[k] for k in keys])
    order = np.argsort(keys)
    keys, vals = keys[order], vals[order]
    idx = np.searchsorted(keys, unit_id)
    unit_albedo = vals[idx]
    n1 = fbm(size, 8, 5, seed=seed + 1)
    n2 = fbm(size, 32, 3, seed=seed + 2)
    speck = value_noise(size, size // 3, seed + 3)
    mortar = edge < mortar_px
    # bevel profile
    prof = np.clip((edge - mortar_px) / max(bevel_px, 1), 0, 1)
    prof = np.sin(prof * np.pi * 0.5)
    height = np.where(mortar, 0.0, 0.55 + 0.45 * prof)
    height += (n2 - 0.5) * height_noise * (~mortar)
    # chips near edges
    chips = (speck > 1 - chip * 0.25) & (edge < mortar_px + bevel_px * 1.8) & (~mortar)
    height = np.where(chips, height - 0.35, height)
    alb = unit_albedo * (0.86 + 0.28 * n2[..., None])
    alb *= (0.92 + 0.16 * n1[..., None])
    mc = np.array(mortar_color)[None, None, :] * (0.85 + 0.3 * n2[..., None])
    alb = np.where(mortar[..., None], mc, alb)
    # soot / weathering stains, mostly vertical
    st = blur_wrap(fbm((size, size), (4, 2), 4, seed=seed + 5), 2)
    alb *= (1.0 - stain * np.clip(st - 0.45, 0, 1)[..., None] * 2.0)
    ao = np.where(mortar, 0.55, 0.75 + 0.25 * prof)
    ao = blur_wrap(ao, 1)
    rough = np.where(mortar, rough_mortar, rough_unit + 0.1 * (n2 - 0.5))
    return alb, height, ao, rough


def gen_brick(size=1024):
    # kit UVs: U 0..1 per 2 m, V 0..1.5 per 3 m -> 1 tile = 2 m x 2 m
    # 10 bricks across (0.2 m), 27 courses (0.074 m)
    reds = [(140, 62, 46), (126, 54, 40), (150, 70, 52), (112, 48, 38), (134, 72, 56), (98, 42, 34), (152, 80, 60)]
    alb, h, ao, rough = masonry(size, 10, 27, 2.6, reds, 0.08, 3, seed=11, mortar_color=(0.58, 0.55, 0.52))
    save_rgb(alb, "T_RedBrick_BaseColor.png")
    save_normal(normal_from_height(h, 2.2), "T_RedBrick_Normal.png")
    save_orm(ao, rough, np.zeros_like(ao), "T_RedBrick_ORM.png")


def gen_pale_brick(size=1024):
    buff = [(214, 200, 176), (204, 190, 166), (222, 210, 188), (196, 182, 160), (210, 196, 170)]
    alb, h, ao, rough = masonry(size, 10, 27, 2.4, buff, 0.05, 3, seed=21, mortar_color=(0.78, 0.76, 0.72), stain=0.12, chroma=0.15)
    save_rgb(alb, "T_PaleBrick_BaseColor.png")
    save_normal(normal_from_height(h, 1.8), "T_PaleBrick_Normal.png")
    save_orm(ao, rough, np.zeros_like(ao), "T_PaleBrick_ORM.png")


def gen_limestone(size=1024):
    # 1 tile = 2 m x 2 m : 4 blocks across (0.5 m), 6 courses (0.333 m)
    stone = [(206, 199, 182), (214, 207, 190), (198, 191, 175), (210, 204, 186)]
    alb, h, ao, rough = masonry(size, 4, 6, 2.0, stone, 0.03, 5, seed=31, mortar_color=(0.74, 0.71, 0.66),
                                chip=0.1, rough_unit=0.78, height_noise=0.12, stain=0.15, chroma=0.12)
    # fine sandstone grain
    grain = value_noise(size, size // 2, 33)
    alb *= (0.95 + 0.1 * grain[..., None])
    save_rgb(alb, "T_Limestone_BaseColor.png")
    save_normal(normal_from_height(h + grain * 0.04, 2.0), "T_Limestone_Normal.png")
    save_orm(ao, rough, np.zeros_like(ao), "T_Limestone_ORM.png")


def gen_trim(size=512):
    """Neutral, near-white stone for mouldings (tinted per material in the shader)."""
    n1 = fbm(size, 6, 5, seed=41)
    n2 = value_noise(size, size // 2, 42)
    streak = blur_wrap(fbm((size, size), (12, 2), 3, seed=43), 1)
    base = 0.93 + 0.08 * (n1 - 0.5) + 0.05 * (n2 - 0.5) - 0.06 * np.clip(streak - 0.55, 0, 1)
    alb = np.stack([base, base * 0.985, base * 0.96], -1)
    save_rgb(alb, "T_Trim_BaseColor.png")
    save_normal(normal_from_height(n1 * 0.6 + n2 * 0.3, 1.2), "T_Trim_Normal.png")
    save_orm(0.9 + 0.1 * n1, 0.72 + 0.12 * n2, np.zeros_like(n1), "T_Trim_ORM.png")


def gen_metal(size=512):
    """Kit trim sheet MetalConcrete: V<0.55 painted dark metal, V>0.55 concrete (steps/curbs)."""
    n1 = fbm(size, 8, 5, seed=51)
    n2 = value_noise(size, size // 2, 52)
    scratches = value_noise((size, size), (size // 2, 6), 53)
    v = np.linspace(0, 1, size, endpoint=False)[:, None].repeat(size, 1)
    metal = 0.16 + 0.03 * (n1 - 0.5) + 0.02 * (n2 - 0.5)
    metal = metal + 0.05 * np.clip(scratches - 0.8, 0, 1) * 4
    conc = 0.58 + 0.08 * (n1 - 0.5) + 0.05 * (n2 - 0.5)
    is_c = v > 0.555
    g = np.where(is_c, conc, metal)
    alb = np.stack([g * 0.98, g * 0.99, g * 1.03], -1)
    rough = np.where(is_c, 0.9, 0.45 + 0.15 * n1)
    metallic = np.where(is_c, 0.0, 0.55)
    save_rgb(alb, "T_MetalConcrete_BaseColor.png")
    save_normal(normal_from_height(n1 * 0.4 + n2 * 0.2, 1.0), "T_MetalConcrete_Normal.png")
    save_orm(np.ones_like(n1), rough, metallic, "T_MetalConcrete_ORM.png")


def gen_slate(size=1024):
    # tile 2 m x 2 m, slates 0.25 m wide, 0.2 m exposure -> 8 x 10
    cols, rows = 8, 10
    rng = np.random.default_rng(61)
    H = W = size
    y = np.arange(H)[:, None].repeat(W, 1).astype(np.float64)
    x = np.arange(W)[None, :].repeat(H, 0).astype(np.float64)
    ch = H / rows
    cw = W / cols
    row = np.floor(y / ch).astype(int)
    xs = (x + (row % 2) * cw * 0.5) % W
    col = np.floor(xs / cw).astype(int)
    lx = xs - col * cw
    ly = y - row * ch
    uid = row * 31 + col
    shade = rng.normal(0, 0.06, rows * 31 + cols + 1)[uid]
    gap = (lx < 2) | (lx > cw - 2)
    # each slate is thicker at its lower edge (overlapping shingles)
    h = ly / ch
    h = np.where(gap, 0.0, h)
    n = fbm(size, 16, 4, seed=62)
    base = np.array([0.24, 0.26, 0.31])
    alb = base[None, None, :] * (1 + shade[..., None]) * (0.9 + 0.2 * n[..., None])
    alb = np.where(gap[..., None], base * 0.45, alb)
    lichen = np.clip(fbm(size, 5, 4, seed=63) - 0.62, 0, 1) * 1.6
    alb = alb * (1 - lichen[..., None]) + np.array([0.36, 0.37, 0.33]) * lichen[..., None]
    save_rgb(alb, "T_RoofSlate_BaseColor.png")
    save_normal(normal_from_height(h * 3.0 + n * 0.5, 2.0), "T_RoofSlate_Normal.png")
    save_orm(np.where(gap, 0.5, 0.85 + 0.15 * h), 0.55 + 0.2 * n, np.zeros_like(n), "T_RoofSlate_ORM.png")


def gen_sidewalk(size=1024):
    """Light concrete flagstones, 1 tile = 3 m x 3 m (2 x 2 slabs of 1.5 m)."""
    rng = np.random.default_rng(71)
    H = W = size
    y = np.arange(H)[:, None].repeat(W, 1).astype(np.float64)
    x = np.arange(W)[None, :].repeat(H, 0).astype(np.float64)
    cw = W / 2
    lx = x % cw
    ly = y % cw
    sid = (np.floor(y / cw) * 2 + np.floor(x / cw)).astype(int)
    tone = rng.normal(0, 0.035, 4)[sid]
    edge = np.minimum.reduce([lx, cw - lx, ly, cw - ly])
    joint = edge < 3.0
    n1 = fbm(size, 6, 5, seed=72)
    n2 = value_noise(size, size // 2, 73)
    stains = np.clip(fbm(size, 4, 5, seed=74) - 0.58, 0, 1) * 1.4
    gum = (value_noise(size, 96, 75) > 0.93).astype(np.float64) * 0.08
    g = 0.72 + tone + 0.07 * (n1 - 0.5) + 0.05 * (n2 - 0.5) - stains * 0.25 - gum
    alb = np.stack([g * 0.99, g, g * 1.02], -1)
    alb = np.where(joint[..., None], np.array([0.42, 0.42, 0.42]), alb)
    prof = np.clip((edge - 3.0) / 6.0, 0, 1)
    h = np.where(joint, 0.0, 0.6 + 0.4 * prof) + (n2 - 0.5) * 0.08
    save_rgb(alb, "T_Sidewalk_BaseColor.png")
    save_normal(normal_from_height(h, 2.5), "T_Sidewalk_Normal.png")
    save_orm(np.where(joint, 0.6, 1.0), 0.8 + 0.1 * n1 - stains * 0.3, np.zeros_like(n1), "T_Sidewalk_ORM.png")


def gen_roof_tar(size=512):
    """Flat roof: grey bitumen membrane with seams and gravel."""
    n1 = fbm(size, 6, 5, seed=81)
    grav = value_noise(size, size // 2, 82)
    y = np.arange(size)[:, None].repeat(size, 1)
    seam = (y % (size // 4)) < 3
    g = 0.30 + 0.06 * (n1 - 0.5) + 0.07 * (grav - 0.5)
    g = np.where(seam, g * 0.8, g)
    alb = np.stack([g, g * 0.99, g * 0.97], -1)
    save_rgb(alb, "T_RoofTar_BaseColor.png")
    save_normal(normal_from_height(grav * 0.7 + seam * 0.4, 1.5), "T_RoofTar_Normal.png")


def gen_dirt(size=256):
    n = fbm(size, 8, 5, seed=91)
    c = np.stack([0.24 + 0.1 * n, 0.17 + 0.07 * n, 0.11 + 0.05 * n], -1)
    save_rgb(c, "T_Dirt_BaseColor.png")


def gen_ornaments(size=512):
    """Kit ornament sheet (AC unit, manhole, drain) - painted to the kit's UV islands."""
    n = fbm(size, 8, 4, seed=95)
    img = np.ones((size, size, 3)) * (0.55 + 0.1 * (n[..., None] - 0.5))
    yy, xx = np.mgrid[0:size, 0:size] / size
    # AC unit grille (u .01-.46, v .57-.79)
    ac = (xx > 0.01) & (xx < 0.46) & (yy > 0.57) & (yy < 0.79)
    img[ac] = 0.72 + 0.05 * (n[ac, None] - 0.5)
    gr = ac & (((xx * size) % 6) < 2)
    img[gr] = 0.35
    # manhole (u .47-.70, v .57-.79)
    cx, cy, r = 0.585, 0.68, 0.11
    d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / r
    mh = d < 1.0
    patt = ((np.floor((xx - cx) * size / 5) + np.floor((yy - cy) * size / 5)) % 2 == 0)
    img[mh] = np.where(patt[mh, None], 0.22, 0.3)
    img[(d > 0.9) & (d < 1.0)] = 0.18
    # drain grate (u .63-.83, v .8-1.0)
    dr = (xx > 0.63) & (xx < 0.83) & (yy > 0.8)
    img[dr] = np.where((((xx[dr] * size) % 8) < 3)[:, None], 0.08, 0.25)
    save_rgb(img, "T_Ornaments_BaseColor.png")


def gen_bark(w=256, h=1024):
    """Birch bark: white with dark horizontal lenticels and knots."""
    n = fbm((w, h), (4, 16), 5, seed=101)
    marks = value_noise((w, h), (6, 64), 102)
    knots = value_noise((w, h), (3, 12), 103)
    g = 0.86 + 0.08 * (n - 0.5)
    dark = np.clip((marks - 0.72) * 5, 0, 1)
    dark = np.maximum(dark, np.clip((knots - 0.83) * 8, 0, 1))
    g = g * (1 - 0.8 * dark)
    alb = np.stack([g * 0.98, g * 0.97, g * 0.93], -1)
    save_rgb(alb, "T_Birch_BaseColor.png")
    save_normal(normal_from_height(n * 0.5 - dark * 0.6, 2.0), "T_Birch_Normal.png")


def gen_leaves(size=512):
    """Leaf-clump surface: overlapping leaf blobs (albedo + normal), used on canopy clumps."""
    rng = np.random.default_rng(111)
    img = Image.new("RGB", (size, size), (52, 92, 32))
    hmap = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(img)
    dh = ImageDraw.Draw(hmap)
    for _ in range(2600):
        x, y = rng.random(2) * size
        r = rng.uniform(7, 15)
        ang = rng.uniform(0, np.pi)
        shade = rng.uniform(0.7, 1.25)
        col = (int(78 * shade), int(132 * shade), int(44 * shade * rng.uniform(0.8, 1.1)))
        pts = []
        for k in range(10):
            t = k / 10 * 2 * np.pi
            rr = r * (0.55 + 0.45 * abs(np.cos(t)))
            px = x + np.cos(t + ang) * rr
            py = y + np.sin(t + ang) * rr * 0.6
            pts.append((px, py))
        for ox in (-size, 0, size):
            for oy in (-size, 0, size):
                d.polygon([(p[0] + ox, p[1] + oy) for p in pts], fill=col)
                dh.polygon([(p[0] + ox, p[1] + oy) for p in pts], fill=int(80 + 170 * rng.random()))
    alb = np.asarray(img).astype(np.float64) / 255
    h = np.asarray(hmap.filter(ImageFilter.GaussianBlur(1.2))).astype(np.float64) / 255
    save_rgb(alb, "T_Leaves_BaseColor.png")
    save_normal(normal_from_height(h, 3.0), "T_Leaves_Normal.png")


def gen_noise(size=256):
    """RGBA tileable noise for shaders: R fbm low, G fbm mid, B cells/high, A streaks."""
    r = fbm(size, 4, 5, seed=121)
    g = fbm(size, 16, 4, seed=122)
    b = value_noise(size, 64, 123)
    a = blur_wrap(fbm((size, size), (16, 2), 4, seed=124), 1)
    for ch in (r, g, b, a):
        ch -= ch.min()
        ch /= ch.max()
    save_rgba(np.stack([r, g, b, a], -1), "T_Noise.png")


def gen_clouds(size=512):
    c = fbm(size, 4, 7, gain=0.55, seed=131)
    c2 = fbm(size, 8, 6, gain=0.5, seed=132)
    c = (c - c.min()) / (c.max() - c.min())
    c2 = (c2 - c2.min()) / (c2.max() - c2.min())
    save_rgba(np.stack([c, c2, c, c2], -1), "T_Clouds.png")


# --------------------------------------------------------------------------- road markings
def gen_decals():
    """Road marking atlas (RGBA, white/yellow paint on transparent).
    Layout (u,v in 0..1, 1024x512 px):
      ONLY      : (0.00,0.00)-(0.50,0.25)
      STOP      : (0.50,0.00)-(1.00,0.25)   (yellow)
      ARROW_UP  : (0.00,0.25)-(0.125,1.00)
      ARROW_L   : (0.125,0.25)-(0.375,1.00)
      ARROW_R   : (0.375,0.25)-(0.625,1.00)
      SLOW      : (0.625,0.25)-(1.00,0.50)
      BIKE      : (0.625,0.50)-(1.00,1.00)
    """
    W, H = 1024, 512
    img = Image.new("RGBA", (W, H), (255, 255, 255, 0))
    d = ImageDraw.Draw(img)
    white = (236, 236, 230, 255)
    yellow = (222, 170, 40, 255)
    f = font("NimbusSansNarrow-Bold.otf", 120)

    def text_in(box, txt, col):
        x0, y0, x1, y1 = box
        bb = d.textbbox((0, 0), txt, font=f)
        tw, th = bb[2] - bb[0], bb[3] - bb[1]
        sx = (x1 - x0 - 20) / tw
        sy = (y1 - y0 - 16) / th
        tmp = Image.new("RGBA", (tw + 4, th + 4), (255, 255, 255, 0))
        ImageDraw.Draw(tmp).text((-bb[0] + 2, -bb[1] + 2), txt, font=f, fill=col)
        tmp = tmp.resize((int((tw + 4) * sx), int((th + 4) * sy)), Image.LANCZOS)
        img.alpha_composite(tmp, (x0 + 10, y0 + 8))

    text_in((0, 0, 512, 128), "ONLY", white)
    text_in((512, 0, 1024, 128), "STOP", yellow)
    text_in((640, 128, 1024, 256), "SLOW", white)

    def arrow_up(x0, y0, x1, y1):
        cx = (x0 + x1) / 2
        w = (x1 - x0)
        d.rectangle([cx - w * 0.14, y0 + (y1 - y0) * 0.32, cx + w * 0.14, y1 - 6], fill=white)
        d.polygon([(cx, y0 + 6), (x0 + w * 0.06, y0 + (y1 - y0) * 0.34), (x1 - w * 0.06, y0 + (y1 - y0) * 0.34)], fill=white)

    arrow_up(0, 128, 128, 512)

    def arrow_turn(x0, y0, x1, y1, left):
        w = x1 - x0
        h = y1 - y0
        sx = x0 + w * (0.72 if left else 0.28)
        d.rectangle([sx - w * 0.07, y0 + h * 0.35, sx + w * 0.07, y1 - 6], fill=white)
        d.rectangle([sx - w * 0.07 if not left else x0 + w * 0.3, y0 + h * 0.35, sx + w * 0.07 if left else x1 - w * 0.3, y0 + h * 0.48], fill=white)
        if left:
            d.polygon([(x0 + 6, y0 + h * 0.415), (x0 + w * 0.32, y0 + h * 0.25), (x0 + w * 0.32, y0 + h * 0.58)], fill=white)
        else:
            d.polygon([(x1 - 6, y0 + h * 0.415), (x1 - w * 0.32, y0 + h * 0.25), (x1 - w * 0.32, y0 + h * 0.58)], fill=white)

    arrow_turn(128, 128, 384, 512, True)
    arrow_turn(384, 128, 640, 512, False)
    # bicycle symbol
    bx, by = 830, 390
    for cx in (bx - 70, bx + 70):
        d.ellipse([cx - 52, by - 52, cx + 52, by + 52], outline=white, width=12)
    d.line([(bx - 70, by), (bx - 10, by - 80), (bx + 50, by - 80), (bx + 70, by)], fill=white, width=12)
    d.line([(bx - 10, by - 80), (bx, by)], fill=white, width=12)
    d.ellipse([bx - 5, by - 128, bx + 35, by - 92], fill=white)
    # paint wear
    a = np.asarray(img).astype(np.float64)
    wear = value_noise((W, H), (128, 64), 141)
    wear2 = fbm((W, H), (16, 8), 4, seed=142)
    a[..., 3] *= np.clip(0.75 + 0.5 * (wear - 0.5) - 0.6 * np.clip(wear2 - 0.6, 0, 1), 0, 1)
    Image.fromarray(a.astype(np.uint8), "RGBA").save(os.path.join(OUT, "T_RoadDecals.png"), optimize=True)


# --------------------------------------------------------------------------- signs
def fit_font(d, txt, name, start, max_w):
    size = start
    while size > 12:
        f = font(name, size)
        bb = d.textbbox((0, 0), txt, font=f)
        if bb[2] - bb[0] <= max_w:
            return f, bb
        size -= 4
    f = font(name, size)
    return f, d.textbbox((0, 0), txt, font=f)


def gen_signs():
    gold = (236, 200, 80)
    red = (196, 24, 28)

    # THE JADE GARDEN storefront sign (4:1)
    W, H = 1024, 256
    im = Image.new("RGB", (W, H), red)
    d = ImageDraw.Draw(im)
    d.rectangle([10, 10, W - 11, H - 11], outline=gold, width=8)
    d.rectangle([26, 26, W - 27, H - 27], outline=(150, 14, 18), width=3)
    f, bb = fit_font(d, "THE JADE GARDEN", "NimbusSans-Bold.otf", 120, W - 90)
    d.text(((W - (bb[2] - bb[0])) / 2 - bb[0], 90 - bb[1]), "THE JADE GARDEN", font=f, fill=gold)
    fs = font("NotoSansCJK-Bold.ttc", 46)
    bb = d.textbbox((0, 0), "翡翠花园", font=fs)
    d.text(((W - (bb[2] - bb[0])) / 2 - bb[0], 24 - bb[1]), "翡翠花园", font=fs, fill=gold)
    im.save(os.path.join(OUT, "T_Sign_JadeGarden.png"), optimize=True)

    # vertical banner (1:4): JADE GARDEN + 翡翠花园
    W, H = 256, 1024
    im = Image.new("RGB", (W, H), red)
    d = ImageDraw.Draw(im)
    d.rectangle([8, 8, W - 9, H - 9], outline=gold, width=8)
    f = font("NimbusSans-Bold.otf", 62)
    y = 34
    for ch in "JADE":
        bb = d.textbbox((0, 0), ch, font=f)
        d.text(((W - (bb[2] - bb[0])) / 2 - bb[0], y - bb[1]), ch, font=f, fill=gold)
        y += 70
    y += 26
    for ch in "GARDEN":
        bb = d.textbbox((0, 0), ch, font=f)
        d.text(((W - (bb[2] - bb[0])) / 2 - bb[0], y - bb[1]), ch, font=f, fill=gold)
        y += 70
    y += 16
    fs = font("NotoSansCJK-Bold.ttc", 64)
    for i, ch in enumerate("翡翠花园"):
        bb = d.textbbox((0, 0), ch, font=fs)
        x = 44 if i % 2 == 0 else W - 44 - (bb[2] - bb[0])
        yy = y + (i // 2) * 76
        d.text((x - bb[0], yy - bb[1]), ch, font=fs, fill=gold)
    im.save(os.path.join(OUT, "T_Sign_JadeBanner.png"), optimize=True)

    # small square blade sign 翡翠花园 with gold dots
    W = H = 256
    im = Image.new("RGB", (W, H), red)
    d = ImageDraw.Draw(im)
    d.rectangle([6, 6, W - 7, H - 7], outline=gold, width=6)
    fs = font("NotoSansCJK-Bold.ttc", 84)
    for i, ch in enumerate("翡翠花园"):
        bb = d.textbbox((0, 0), ch, font=fs)
        x = 30 + (i % 2) * 110
        yy = 30 + (i // 2) * 105
        d.text((x - bb[0], yy - bb[1]), ch, font=fs, fill=gold)
    for (x, y) in ((20, 20), (W - 20, 20), (20, H - 20), (W - 20, H - 20)):
        d.ellipse([x - 9, y - 9, x + 9, y + 9], fill=gold)
    im.save(os.path.join(OUT, "T_Sign_JadeSquare.png"), optimize=True)

    # Paul & Sons Bakery (green, script)
    W, H = 1024, 256
    green = (22, 74, 52)
    im = Image.new("RGB", (W, H), green)
    d = ImageDraw.Draw(im)
    d.rectangle([8, 8, W - 9, H - 9], outline=(232, 226, 200), width=5)
    fz, bb = fit_font(d, "Paul & Sons Bakery", "Z003-MediumItalic.otf", 150, W - 80)
    d.text(((W - (bb[2] - bb[0])) / 2 - bb[0], 40 - bb[1]), "Paul & Sons Bakery", font=fz, fill=(240, 236, 220))
    fsb = font("NimbusSans-Bold.otf", 30)
    t = "••• BREAD BAKED FRESH DAILY •••"
    bb = d.textbbox((0, 0), t, font=fsb)
    d.text(((W - (bb[2] - bb[0])) / 2 - bb[0], 196 - bb[1]), t, font=fsb, fill=(240, 236, 220))
    im.save(os.path.join(OUT, "T_Sign_Bakery.png"), optimize=True)

    # PA SAVINGS BANK BUILDING raised letters (alpha)
    W, H = 2048, 160
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    f = font("C059-Roman.otf", 128)
    t = "PA SAVINGS BANK BUILDING"
    bb = d.textbbox((0, 0), t, font=f)
    d.text(((W - (bb[2] - bb[0])) / 2 - bb[0], (H - (bb[3] - bb[1])) / 2 - bb[1]), t, font=f, fill=(46, 44, 42, 255))
    im.save(os.path.join(OUT, "T_Sign_Bank.png"), optimize=True)

    # generic shop signs: (file, bg, fg, text, font, subtitle)
    shops = [
        ("T_Sign_Mays.png", (120, 40, 140), (250, 236, 250), "May's Salon & Beauty", "Z003-MediumItalic.otf", None),
        ("T_Sign_Carmines.png", (240, 238, 228), (190, 30, 30), "Carmine's Original Pizza", "C059-BdIta.otf", None),
        ("T_Sign_Deli.png", (24, 54, 104), (250, 220, 90), "DELI & GROCERY", "NimbusSansNarrow-Bold.otf", "OPEN 24 HOURS"),
        ("T_Sign_Books.png", (40, 40, 44), (230, 210, 160), "Hudson Books", "P052-BoldItalic.otf", "USED & RARE"),
        ("T_Sign_Cafe.png", (32, 72, 64), (240, 230, 210), "Corner Cafe", "Z003-MediumItalic.otf", "COFFEE • BAGELS"),
        ("T_Sign_Pharmacy.png", (200, 30, 40), (255, 255, 255), "PHARMACY", "NimbusSans-Bold.otf", None),
        ("T_Sign_Laundry.png", (60, 120, 170), (255, 255, 255), "LAUNDROMAT", "NimbusSans-Bold.otf", "WASH • DRY • FOLD"),
        ("T_Sign_Hardware.png", (180, 120, 30), (30, 24, 20), "HARDWARE", "NimbusSansNarrow-Bold.otf", "KEYS CUT"),
    ]
    for fn, bg, fg, txt, fnt, sub in shops:
        W, H = 1024, 256
        im = Image.new("RGB", (W, H), bg)
        d = ImageDraw.Draw(im)
        d.rectangle([8, 8, W - 9, H - 9], outline=fg, width=4)
        size = 130
        while True:
            f = font(fnt, size)
            bb = d.textbbox((0, 0), txt, font=f)
            if bb[2] - bb[0] < W - 80 or size < 40:
                break
            size -= 6
        ty = 40 if sub else (H - (bb[3] - bb[1])) / 2
        d.text(((W - (bb[2] - bb[0])) / 2 - bb[0], ty - bb[1]), txt, font=f, fill=fg)
        if sub:
            fs = font("NimbusSans-Bold.otf", 34)
            bb = d.textbbox((0, 0), sub, font=fs)
            d.text(((W - (bb[2] - bb[0])) / 2 - bb[0], 192 - bb[1]), sub, font=fs, fill=fg)
        im.save(os.path.join(OUT, fn), optimize=True)

    # street name plate + one-way sign atlas (512x256: left = street sign green, right = ONE WAY)
    W, H = 1024, 256
    im = Image.new("RGB", (W, H), (20, 110, 60))
    d = ImageDraw.Draw(im)
    f = font("NimbusSans-Bold.otf", 96)
    d.rectangle([0, 0, 511, 127], fill=(20, 110, 60))
    d.rectangle([4, 4, 507, 123], outline=(245, 245, 245), width=4)
    d.text((24, 12), "BROADWAY", font=font("NimbusSans-Bold.otf", 88), fill=(245, 245, 245))
    d.rectangle([0, 128, 511, 255], fill=(20, 110, 60))
    d.rectangle([4, 132, 507, 251], outline=(245, 245, 245), width=4)
    d.text((24, 140), "W 34 ST", font=f, fill=(245, 245, 245))
    d.rectangle([512, 0, 1023, 255], fill=(16, 16, 16))
    d.rectangle([530, 40, 1005, 216], fill=(245, 245, 245))
    d.polygon([(560, 128), (900, 80), (900, 104), (1000, 104), (1000, 152), (900, 152), (900, 176)], fill=(16, 16, 16))
    d.text((640, 105), "ONE WAY", font=font("NimbusSans-Bold.otf", 44), fill=(245, 245, 245))
    im.save(os.path.join(OUT, "T_StreetSigns.png"), optimize=True)


def main():
    global OUT
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    OUT = os.path.join(root, "textures")
    os.makedirs(OUT, exist_ok=True)
    steps = [gen_brick, gen_pale_brick, gen_limestone, gen_trim, gen_metal, gen_slate, gen_sidewalk,
             gen_roof_tar, gen_dirt, gen_ornaments, gen_bark, gen_leaves, gen_noise, gen_clouds, gen_decals, gen_signs]
    for s in steps:
        s()
        print("ok", s.__name__)
    # downsize the kit's 2k concrete textures for Apple M1 memory budget
    for fn in ("T_Concrete_Asphalt_BaseColor.png", "T_Concrete_BaseColor.png", "T_Concrete_Normal.png", "T_Concrete_ORM.png"):
        p = os.path.join(OUT, fn)
        if os.path.exists(p):
            im = Image.open(p)
            if im.size[0] > 1024:
                im = im.convert("RGB").resize((1024, 1024), Image.LANCZOS)
                im.save(p, optimize=True)


if __name__ == "__main__":
    main()
