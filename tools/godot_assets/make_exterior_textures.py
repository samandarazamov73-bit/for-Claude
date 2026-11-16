#!/usr/bin/env python3
"""Наружные материалы санатория для «The Last Shake»: фасадные панели, бетон цоколя и карнизов, отмостка,
кровля, кирпичный цоколь, бетон лестничных клеток. Раскладка (швы панелей, подтёки, заплаты кровли) — от старых текстур модели;
поверх неё — настоящая фактура бетона и асфальта с фото Poly Haven (CC0): поры, раковины, пятна, рельеф
и шероховатость. Цвет остаётся прежним (фото даёт только светлее/темнее), UV модели не меняются.

Запуск: python3 make_exterior_textures.py <папка фото Poly Haven 4k> <sanatorium.glb> <выход sanatorium/assets/tex>
Нужные фото (_diff, _nor = nor_gl, _rough) 4k: concrete_wall_006, concrete_wall_008, dirty_concrete,
concrete_floor_worn_001, asphalt_02.
"""
import io
import json
import os
import struct
import sys

import numpy as np
from PIL import Image

SRC, GLB, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
N = int(os.environ.get("TEX_N", "2048"))
os.makedirs(OUT, exist_ok=True)

# материал модели → (фото, повторов фото на текстуру, сила фактуры, сила пятен, сила рельефа фото, имя файла,
#                    глубина швов старой текстуры)
MATS = {
    "Concrete_FacadeWall":  ("concrete_wall_008", 2, 0.85, 0.30, 0.8, "ext_facade_wall", 1.0),
    "Concrete_FacadePanel": ("concrete_wall_006", 2, 0.75, 0.30, 0.8, "ext_facade_panel", 1.0),
    "Concrete_Weathered":   ("dirty_concrete", 1, 0.55, 0.25, 0.7, "ext_concrete_weathered", 1.0),
    "Concrete_Trim":        ("concrete_wall_008", 1, 0.8, 0.25, 0.7, "ext_concrete_trim", 1.0),
    "Concrete_Paving":      ("concrete_floor_worn_001", 2, 0.9, 0.3, 0.9, "ext_paving", 1.0),
    "Concrete_Interior":    ("concrete_wall_008", 1, 0.7, 0.2, 0.6, "ext_concrete_interior", 1.0),
    "Roofing_Bitumen":      ("asphalt_02", 2, 0.8, 0.2, 0.8, "ext_roofing", 1.0),
    # цоколь из красного кирпича: раскладка кирпичей своя, сверху — зерно и пятна, швы глубже
    "Ceramic_Tile_RedBrown": ("dirty_concrete", 4, 0.5, 0.35, 0.35, "ext_brick", 1.8),
}

IMPORT = """[remap]

importer="texture"
type="CompressedTexture2D"

[params]

compress/mode=2
compress/high_quality=false
compress/lossy_quality=0.7
compress/uastc_level=0
compress/rdo_quality_loss=0.0
compress/hdr_compression=1
compress/normal_map={nm}
compress/channel_pack=0
mipmaps/generate=true
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/channel_remap/red=0
process/channel_remap/green=1
process/channel_remap/blue=2
process/channel_remap/alpha=3
process/fix_alpha_border=true
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=0
"""


def glb_images(path):
    f = open(path, "rb").read()
    ln = struct.unpack("<I", f[12:16])[0]
    j = json.loads(f[20:20 + ln])
    binoff = 20 + ln + 8
    out = {}
    for img in j["images"]:
        bv = j["bufferViews"][img["bufferView"]]
        o = binoff + bv.get("byteOffset", 0)
        out[img.get("name")] = f[o:o + bv["byteLength"]]
    return out


IMAGES = glb_images(GLB)


def old(name, kind):
    im = Image.open(io.BytesIO(IMAGES[f"T_{name}_{kind}"])).convert("RGB").resize((N, N), Image.LANCZOS)
    return np.asarray(im).astype(np.float32) / 255.0


def photo(name, kind, tile, gray=False):
    im = Image.open(os.path.join(SRC, f"{name}_{kind}.jpg")).convert("L" if gray else "RGB")
    side = N // tile
    im = im.resize((side, side), Image.LANCZOS)
    a = np.asarray(im).astype(np.float32) / 255.0
    return np.tile(a, (tile, tile) if gray else (tile, tile, 1))


def srgb_to_lin(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def lin_to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * c ** (1 / 2.4) - 0.055)


def blur(a, r):
    """Гаусс через FFT с переносом по краям (бесшовное остаётся бесшовным); r — в пикселях при N=2048."""
    r = r * N / 2048.0
    if a.ndim == 3:
        return np.stack([blur(a[..., i], r * 2048.0 / N) for i in range(a.shape[2])], -1)
    h, w = a.shape
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.rfftfreq(w)[None, :]
    g = np.exp(-2.0 * (np.pi * r) ** 2 * (fx ** 2 + fy ** 2))
    return np.fft.irfft2(np.fft.rfft2(a) * g, s=a.shape).astype(np.float32)


def lum(rgb):
    return rgb[..., 0] * 0.2126 + rgb[..., 1] * 0.7152 + rgb[..., 2] * 0.0722


def ncombine(*ns):
    x = sum(n[..., 0] / np.maximum(n[..., 2], 0.2) for n in ns)
    y = sum(n[..., 1] / np.maximum(n[..., 2], 0.2) for n in ns)
    v = np.stack([x, y, np.ones_like(x)], -1)
    return v / np.linalg.norm(v, axis=-1, keepdims=True)


def nflat(n, s):
    out = n.copy()
    out[..., 0:2] *= s
    return out


def save(arr, name, normal=False):
    img = Image.fromarray((np.clip(arr, 0, 1) * 255 + 0.5).astype(np.uint8))
    path = os.path.join(OUT, name + ".jpg")
    img.save(path, quality=90, subsampling=0 if normal else 2)
    if not os.path.exists(path + ".import"):
        with open(path + ".import", "w") as f:
            f.write(IMPORT.format(nm=1 if normal else 0))
    print("wrote", name)


for mat, (ph, tile, k_det, k_stain, k_nrm, out, k_old) in MATS.items():
    o_alb, o_nrm, o_orm = old(mat, "BaseColor"), old(mat, "Normal") * 2.0 - 1.0, old(mat, "ORM")
    p_d = photo(ph, "diff", tile)
    p_n = photo(ph, "nor", tile) * 2.0 - 1.0
    p_r = photo(ph, "rough", tile, gray=True)
    pl = lum(srgb_to_lin(p_d))
    fine = pl / np.maximum(blur(pl, 24), 1e-3)                 # поры, раковины, зерно
    stain = blur(pl, 24) / max(float(pl.mean()), 1e-3)          # пятна, разводы
    mult = (1.0 + (fine - 1.0) * k_det) * np.clip(1.0 + (stain - 1.0) * k_stain, 0.7, 1.2)
    alb = lin_to_srgb(srgb_to_lin(o_alb) * mult[..., None])
    save(alb, out + "_albedo")
    save(ncombine(nflat(o_nrm, k_old), nflat(p_n, k_nrm)) * 0.5 + 0.5, out + "_normal", normal=True)
    rough = np.clip(o_orm[..., 1] * 0.5 + 0.45 + (p_r - p_r.mean()) * 0.6, 0.25, 1.0)
    save(np.stack([o_orm[..., 0], rough, o_orm[..., 2]], -1), out + "_orm")
print("done")
