"""Fixed texture sets (fix_glare / fix_seams / copy_rest output) → sanatorium/assets/tex/<name>_{albedo,normal,orm}.jpg.
Every material gets its own normal and ORM (R — AO, G — roughness, B — metallic). 1280 px: a multiple of 4 for
VRAM compression, about the user's own 1254 px."""
import sys, os
from PIL import Image

SRC, DST = sys.argv[1], sys.argv[2]           # <fixed>/tex, the_last_shake/sanatorium/assets/tex
SIZE = 1280
NAMES = {
    "M_Paint_WallBeige": "wall_beige", "M_Paint_WallBlue": "wall_blue", "M_Paint_WallPeach": "wall_peach",
    "M_Tile_WallWhite": "wall_tile", "M_Wallpaper_Floral": "wallpaper_floral", "M_Wallpaper_Geometric": "wallpaper_geometric",
    "M_Plaster_White": "plaster", "M_Linoleum_Brown": "linoleum", "M_Linoleum_Parquet": "parquet",
    "M_Tile_FloorCeramic": "floor_ceramic", "M_Terrazzo": "terrazzo", "M_Wood_DoorDark": "door",
    "M_Concrete_FacadeWall": "ext_facade_wall", "M_Concrete_FacadePanel": "ext_facade_panel",
    "M_Concrete_Weathered": "ext_concrete_weathered", "M_Concrete_Trim": "ext_concrete_trim",
    "M_Concrete_Paving": "ext_paving", "M_Concrete_Interior": "ext_concrete_interior",
    "M_Roofing_Bitumen": "ext_roofing", "M_Ceramic_Tile_RedBrown": "ext_brick",
}
for mat, name in NAMES.items():
    d = os.path.join(SRC, mat)
    for src, suffix, q in (("albedo", "albedo", 92), ("normal_gl", "normal", 95), ("orm", "orm", 92)):
        im = Image.open(os.path.join(d, src + ".png")).convert("RGB")
        if im.size != (SIZE, SIZE):
            im = im.resize((SIZE, SIZE), Image.LANCZOS)
        im.save(os.path.join(DST, f"{name}_{suffix}.jpg"), quality=q, subsampling=0, optimize=True)
    print(mat, "→", name)
