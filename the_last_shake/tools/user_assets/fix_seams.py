"""Make the non-tiling sets seamless: crop to the pattern period, then stitch along a minimum-error cut."""
import sys, os, glob, numpy as np
from scipy import ndimage as ndi
sys.path.insert(0, os.path.dirname(__file__))
from texlib import *

SRC = sys.argv[1]; OUT = sys.argv[2]
def folder(prefix): return glob.glob(os.path.join(SRC, prefix + "*"))[0]
def base(prefix): return os.path.basename(folder(prefix))

def best_period(s, axis, B, lo, hi):
    A = lum(s["albedo"]); A = A if axis == 1 else A.T
    A = ndi.gaussian_filter(A, 1.0)
    best = None
    for Wn in range(lo, hi):
        d = ((A[:, Wn:Wn + B] - A[:, :B]) ** 2).mean()
        if best is None or d < best[0]:
            best = (d, Wn)
    return best[1]

def auto(s, axis, B=40, max_crop=170):
    W = s["albedo"].shape[1 if axis == 1 else 0]
    Wn = best_period(s, axis, B, W - max_crop, W - B)
    o, _ = (tile_x if axis == 1 else tile_y)(s, B, 0, Wn)
    return o, Wn

JOBS = [  # material in game, source folder prefix, albedo override, axes to fix
 ("M_Tile_WallWhite", "Поте_ртая_стена", "Состаренная_плиточная_стена_с_штукатуркои", "M_Tile_WallWhite.png", "x"),
 ("M_Wallpaper_Geometric", "Винтажные_обои_с_ромбами", None, None, "x"),
 ("M_Wallpaper_Floral", "Винтажные_обои_с_деревянным", None, None, "x"),
 ("M_Concrete_FacadeWall", "Состаренная_бетонная_фасадная", None, None, "yE"),
 ("M_Terrazzo", "Серая_терраццо", None, None, "xy"),
 ("M_Tile_FloorCeramic", "Состаренная_терракотово", None, None, "xy"),
 ("M_Ceramic_Tile_RedBrown", "Текстура_старои_краснои", None, None, "xy"),
 ("M_Wood_DoorDark", "Состаренная_ореховая", None, None, "x"),
]
for mat, fpref, setbase, alb, axes in JOBS:
    f = folder(fpref)
    s = load_set(f, setbase or os.path.basename(f), alb)
    H, W = s["albedo"].shape[:2]
    before = (seam_score(s["albedo"], 1), seam_score(s["albedo"], 0))
    info = []
    for ax in axes:
        if ax == "E":
            s = edge_match_x(s); info.append("x:edge"); continue
        s, n = auto(s, 1 if ax == "x" else 0)
        info.append(f"{ax}:{n}")
    after = (seam_score(s["albedo"], 1), seam_score(s["albedo"], 0))
    h, w = s["albedo"].shape[:2]
    save_set(s, os.path.join(OUT, mat))
    print(f"{mat:24s} {W}x{H} -> {w}x{h} ({' '.join(info)})  seam x {before[0]:.2f}->{after[0]:.2f}  y {before[1]:.2f}->{after[1]:.2f}")
