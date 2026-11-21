"""Pictures/decals: real transparency instead of black/white backgrounds and colour fringes; crop single items."""
import sys, os, glob, numpy as np
from PIL import Image
from scipy import ndimage as ndi

SRC, OUT = (sys.argv[1:3] + ["", ""])[:2]
# id in the game sheet → (folder prefix, mode)  mode: cut = remove bg + crop, cutsheet = remove bg keep frame, keep = as is
PICS = {
 "fire_label": ("Винтажная_инструкция", "cut"), "mosaic": ("Винтажная_мозаика", "keep"),
 "call_numbers": ("Винтажная_панель_вызова", "keep"), "chess_board": ("Винтажная_шахматная", "cut"),
 "med_labels": ("Винтажные_аптечные_этикетки", "keep"), "binder_spines": ("Винтажные_архивные", "keep"),
 "med_boxes": ("Винтажные_советские_аптечные", "cutsheet"), "dials": ("Винтажные_советские_измерительные", "cutsheet"),
 "monitor_screen": ("Винтажныи_зеле_ныи_экран", "keep"), "phone_dial": ("Винтажныи_кремовыи_диск", "cut"),
 "radio_front": ("Винтажныи_советскии_радиогромкоговоритель", "cut"), "clock_face": ("Винтажныи_циферблат", "cut"),
 "book_spines": ("Изношенные_советские_книги", "keep"), "tv_badge": ("Металлическая_табличка", "cut"),
 "painting_2": ("Натюрморт_с_гранатами", "keep"), "painting_1": ("Осеннии_поток", "keep"),
 "tv_screen": ("Пустои_экран", "keep"), "electro_sign": ("Ржавая_советская_табличка", "cut"),
 "painting_3": ("Советскии_санатории", "keep"), "key_tag": ("Старинные_бирки", "cutsheet"),
 "notices": ("Четыре_состаренных", "cutsheet"),
}
MAPS = ("albedo", "normal_gl", "height", "roughness", "ao", "orm")

def bg_mask(rgb):
    r = rgb.astype(np.int16)
    mx, mn = r.max(-1), r.min(-1)
    dark, white = mx < 26, mn > 240
    extreme = ((r < 50) | (r > 205)).all(-1) & ((mx - mn) > 120)          # pure yellow/red/magenta… fringe garbage
    like = dark | white | extreme
    lab, n = ndi.label(like)
    border = np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))
    bg = np.isin(lab, border[border > 0])
    # swallow the fringe: garbage or near-bg pixels touching the background, a few passes
    for _ in range(3):
        near = ndi.binary_dilation(bg, iterations=1) & ~bg
        bg |= near & (extreme | dark | white | (((r < 70) | (r > 190)).all(-1) & ((mx - mn) > 90)))
    bg = ndi.binary_closing(np.pad(bg, 6, constant_values=True), iterations=2)[6:-6, 6:-6]
    # remove tiny islands of foreground (specks of garbage) and holes in the foreground
    fg = ~bg
    lab, n = ndi.label(fg)
    if n:
        sizes = ndi.sum(fg, lab, range(1, n + 1))
        fg = np.isin(lab, 1 + np.flatnonzero(sizes > 0.002 * fg.size))
    fg = ndi.binary_fill_holes(fg)
    fg = ndi.binary_erosion(np.pad(fg, 4), iterations=2)[4:-4, 4:-4]          # trim the last fringe pixel ring
    return fg

def bleed(rgb, fg):
    """fill transparent pixels with the nearest foreground colour (no dark halos in mipmaps)"""
    idx = ndi.distance_transform_edt(~fg, return_distances=False, return_indices=True)
    return rgb[idx[0], idx[1]]

def run():
    for pid, (pref, mode) in PICS.items():
        d = glob.glob(os.path.join(SRC, pref + "*"))[0]; b = os.path.basename(d)
        ims = {m: Image.open(os.path.join(d, f"{b}_{m}.png")) for m in MAPS}
        rgb = np.asarray(ims["albedo"].convert("RGB"))
        out = os.path.join(OUT, pid); os.makedirs(out, exist_ok=True)
        box = None
        if mode == "keep":
            alpha = None
        else:
            fg = bg_mask(rgb)
            a = ndi.gaussian_filter(fg.astype(np.float32), 0.8)
            alpha = (np.clip(a, 0, 1) * 255).astype(np.uint8)
            if mode == "cut":
                ys, xs = np.nonzero(fg); m = 6
                box = (max(xs.min() - m, 0), max(ys.min() - m, 0), min(xs.max() + m + 1, rgb.shape[1]), min(ys.max() + m + 1, rgb.shape[0]))
        for m, im in ims.items():
            if m == "albedo":
                if alpha is not None:
                    im = Image.fromarray(np.dstack([bleed(rgb, alpha > 127), alpha]), "RGBA")
                else:
                    im = im.convert("RGB")
            elif alpha is not None:
                arr = np.asarray(im.convert("RGB" if m in ("normal_gl", "orm") else "L"))
                im = Image.fromarray(bleed(arr, alpha > 127))
            if box:
                im = im.crop(box)
            im.save(os.path.join(out, m + ".png"))
        cov = "-" if alpha is None else f"{100 * (alpha > 127).mean():.0f}% opaque"
        print(f"{pid:15s} {mode:8s} {rgb.shape[1]}x{rgb.shape[0]} -> {Image.open(os.path.join(out, 'albedo.png')).size} {cov}")

if __name__ == "__main__":
    run()
