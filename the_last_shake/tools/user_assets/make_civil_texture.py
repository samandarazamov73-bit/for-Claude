"""Текстура Шухрата для эпилога: модель деда без больничной рубашки.

Рубашка в горошек → тёмная гражданская ткань (с теми же складками), больничный браслет → цвет кожи.
Рубашку узнаём по кускам атласа, в которых есть синие точки (седые волосы такого же светлого цвета не трогаем).

    python3 make_civil_texture.py <grandpa_tex.jpg> <out.jpg>

Текстуру из characters/grandpa.glb можно достать любым просмотрщиком glTF (она одна, JPEG 1024×1024).
"""
import sys
import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

src, dst = sys.argv[1], sys.argv[2]
im = np.asarray(Image.open(src).convert("RGB")).astype(np.float32) / 255.0
r, g, b = im[..., 0], im[..., 1], im[..., 2]
lum = 0.299 * r + 0.587 * g + 0.114 * b
chroma = im.max(-1) - im.min(-1)
skin = (r > g + 0.10) & (r > b + 0.14)
dots = (b > r + 0.08) & (b > g + 0.04) & (lum > 0.2)
light = (lum > 0.45) & (chroma < 0.2) & ~skin

lab, n = ndimage.label(ndimage.binary_closing(light | dots, iterations=2))
idx = np.arange(1, n + 1)
frac = np.zeros(n + 1)
frac[1:] = ndimage.sum(dots.astype(np.float32), lab, index=idx) / np.maximum(ndimage.sum(np.ones_like(lum), lab, index=idx), 1)
gown = (frac > 0.01)[lab] & (lab > 0)
gown = ndimage.binary_dilation(gown, iterations=2) & ~skin & (lum > 0.2)
lm = np.asarray(Image.fromarray((np.clip(lum, 0, 1) * 255).astype(np.uint8)).filter(ImageFilter.MedianFilter(5))) / 255.0
shade = np.clip(lm / 0.80, 0.35, 1.12)
out = im.copy()
out[gown] = np.array([0.27, 0.26, 0.23])[None, :] * shade[gown][:, None]

# браслет: белое внутри кусков кожи — цветом кожи этого куска
white = (lum > 0.7) & (chroma < 0.15)
skin2 = (out[..., 0] > out[..., 1] + 0.10) & (out[..., 0] > out[..., 2] + 0.14)
lab, n = ndimage.label(ndimage.binary_closing(skin2 | white, iterations=2))
for i in range(1, n + 1):
    m = lab == i
    if (m & skin2).sum() > 200 and (m & white).any():
        w = ndimage.binary_dilation(m & white, iterations=2) & m & ~skin2
        out[w] = out[m & skin2].mean(0)
Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8)).save(dst, quality=92)
print("saved", dst)
