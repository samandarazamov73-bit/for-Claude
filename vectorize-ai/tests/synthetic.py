"""Synthetic test images with exactly known geometry.

Shapes are drawn at ``SS``x resolution and area-downsampled, which produces
true box-filter anti-aliasing (the same model real rasterisers use)."""
from __future__ import annotations

import math

import cv2
import numpy as np

SS = 8


def _canvas(w, h, bg):
    img = np.zeros((h * SS, w * SS, 4), dtype=np.uint8)
    img[:] = bg
    return img


def _finish(img, w, h):
    f = img.astype(np.float32)
    f[..., :3] *= f[..., 3:4] / 255.0
    small = cv2.resize(f, (w, h), interpolation=cv2.INTER_AREA)
    a = small[..., 3:4]
    small[..., :3] = np.where(a > 1e-3, small[..., :3] * 255.0 / np.maximum(a, 1e-3), 0)
    return np.clip(small + 0.5, 0, 255).astype(np.uint8)


def _pts(points):
    return np.array([[round(x * SS), round(y * SS)] for x, y in points], dtype=np.int32)


class Scene:
    def __init__(self, w, h, bg=(255, 255, 255, 255)):
        self.w, self.h = w, h
        self.img = _canvas(w, h, bg)

    def circle(self, cx, cy, r, color):
        cv2.circle(self.img, (round(cx * SS), round(cy * SS)), round(r * SS), color, -1, lineType=cv2.LINE_8)
        return self

    def ellipse(self, cx, cy, rx, ry, angle_deg, color):
        cv2.ellipse(self.img, (round(cx * SS), round(cy * SS)), (round(rx * SS), round(ry * SS)), angle_deg, 0, 360, color, -1)
        return self

    def polygon(self, points, color):
        cv2.fillPoly(self.img, [_pts(points)], color)
        return self

    def rect(self, x0, y0, x1, y1, color):
        return self.polygon([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], color)

    def rounded_rect(self, x0, y0, x1, y1, r, color):
        c = color
        self.rect(x0 + r, y0, x1 - r, y1, c).rect(x0, y0 + r, x1, y1 - r, c)
        for cx, cy in ((x0 + r, y0 + r), (x1 - r, y0 + r), (x0 + r, y1 - r), (x1 - r, y1 - r)):
            self.circle(cx, cy, r, c)
        return self

    def star(self, cx, cy, r_out, r_in, n, color, rot=-math.pi / 2):
        pts = []
        for i in range(2 * n):
            r = r_out if i % 2 == 0 else r_in
            a = rot + i * math.pi / n
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
        return self.polygon(pts, color)

    def image(self):
        return _finish(self.img, self.w, self.h)


def jpeg_roundtrip(rgba, quality=80):
    ok, buf = cv2.imencode(".jpg", cv2.cvtColor(rgba[..., :3], cv2.COLOR_RGB2BGR), [cv2.IMWRITE_JPEG_QUALITY, quality])
    assert ok
    bgr = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    out = np.empty(rgba.shape, np.uint8)
    out[..., :3] = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
    out[..., 3] = 255
    return out


def logo_scene():
    s = Scene(320, 240, (250, 250, 248, 255))
    s.rounded_rect(20, 20, 300, 220, 28, (28, 63, 140, 255))
    s.circle(110, 120, 62, (255, 196, 0, 255))
    s.circle(110, 120, 30, (28, 63, 140, 255))
    s.star(230, 120, 58, 24, 5, (230, 57, 70, 255))
    return s.image()


def png_bytes(rgba):
    ok, buf = cv2.imencode(".png", cv2.cvtColor(rgba, cv2.COLOR_RGBA2BGRA))
    assert ok
    return buf.tobytes()


def heart_points(cx, cy, scale):
    t = np.linspace(0, 2 * math.pi, 400, endpoint=False)
    x = 16 * np.sin(t) ** 3
    y = -(13 * np.cos(t) - 5 * np.cos(2 * t) - 2 * np.cos(3 * t) - np.cos(4 * t))
    return [(cx + scale * a, cy + scale * b) for a, b in zip(x, y)]


def arrow_points(cx, cy, size, angle):
    base = [(-1.0, -0.25), (0.2, -0.25), (0.2, -0.6), (1.0, 0.0), (0.2, 0.6), (0.2, 0.25), (-1.0, 0.25)]
    co, si = math.cos(angle), math.sin(angle)
    return [(cx + size * (co * x - si * y), cy + size * (si * x + co * y)) for x, y in base]


def touching_scene():
    s = Scene(260, 200, (255, 255, 255, 255))
    s.rect(30, 40, 170, 160, (220, 40, 40, 255))
    s.circle(170, 100, 55, (30, 90, 200, 255))
    s.polygon(heart_points(70, 100, 2.2), (255, 220, 0, 255))
    return s.image()


def transparent_scene():
    s = Scene(240, 200, (0, 0, 0, 0))
    s.polygon(heart_points(120, 95, 5.0), (210, 30, 90, 255))
    s.circle(120, 85, 22, (255, 255, 255, 255))
    return s.image()


def repeats_scene():
    s = Scene(300, 220, (245, 245, 245, 255))
    for i, (x, y, a) in enumerate([(70, 60, 0.0), (220, 60, 0.7), (70, 160, 2.0), (220, 160, -1.2)]):
        s.polygon(arrow_points(x, y, 48, a), (40, 120, 60, 255))
    return s.image()


def hard_edge_scene():
    img = np.zeros((160, 200, 4), np.uint8)
    img[:] = (255, 255, 255, 255)
    cv2.circle(img, (70, 80), 45, (0, 0, 0, 255), -1, lineType=cv2.LINE_8)
    cv2.fillPoly(img, [np.array([[120, 30], [190, 60], [150, 140]], np.int32)], (0, 140, 255, 255), lineType=cv2.LINE_8)
    return img


def photo_like(w=1400, h=1000, seed=3):
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    img = np.zeros((h, w, 4), np.float32)
    img[..., 0] = 120 + 100 * np.sin(xx / 170.0) * np.cos(yy / 230.0)
    img[..., 1] = 110 + 80 * np.cos(xx / 260.0 + yy / 310.0)
    img[..., 2] = 140 + 90 * np.sin((xx + yy) / 400.0)
    for _ in range(25):
        cx, cy, r = rng.uniform(0, w), rng.uniform(0, h), rng.uniform(20, 120)
        col = rng.uniform(0, 255, 3)
        m = (xx - cx) ** 2 + (yy - cy) ** 2 < r * r
        img[m, :3] = img[m, :3] * 0.3 + col * 0.7
    img[..., :3] += rng.normal(0, 4, (h, w, 3))
    img[..., 3] = 255
    return np.clip(img, 0, 255).astype(np.uint8)


def _radial(h, w, cx, cy, r, c_in, c_out):
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    t = np.clip(np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / r, 0, 1)[..., None]
    return np.asarray(c_in, np.float32) * (1 - t) + np.asarray(c_out, np.float32) * t


def label_scene(w=560, h=960, seed=5, noise=2.0):
    """Packaging-label style test image: gradient backgrounds, Cyrillic
    text, shaded spheres with highlights, a plate, gold stroke, mild noise
    and a transparent surround (similar to real product labels)."""
    from PIL import Image, ImageDraw, ImageFont

    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    img = np.zeros((h, w, 3), np.float32)
    # vertical green gradient background
    t = (yy / h)[..., None]
    img[:] = np.array([170, 225, 120]) * (1 - t) + np.array([20, 120, 40]) * t
    # white panel with soft gradient
    panel = (((xx - w / 2) / (w * 0.42)) ** 2 + ((yy - h * 0.3) / (h * 0.24)) ** 2) < 1
    pg = np.array([255, 255, 252]) * (1 - (yy / h)[..., None] * 0.6) + np.array([200, 235, 190]) * (yy / h)[..., None] * 0.6
    img[panel] = pg[panel]
    # plate (radial gradient disc) and two "apples" (shaded spheres)
    plate = _radial(h, w, w * 0.45, h * 0.66, w * 0.3, (250, 250, 250), (175, 180, 185))
    m = (xx - w * 0.45) ** 2 + (yy - h * 0.66) ** 2 < (w * 0.3) ** 2
    img[m] = plate[m]
    for cx, cy, r in ((w * 0.33, h * 0.74, w * 0.18), (w * 0.62, h * 0.78, w * 0.14)):
        sph = _radial(h, w, cx - r * 0.35, cy - r * 0.35, r * 1.4, (215, 255, 120), (40, 120, 20))
        m = (xx - cx) ** 2 + (yy - cy) ** 2 < r * r
        img[m] = sph[m]
        hl = (xx - (cx - r * 0.4)) ** 2 + (yy - (cy - r * 0.45)) ** 2 < (r * 0.12) ** 2
        img[hl] = (250, 255, 240)
    # dark banner
    band = (yy > h * 0.86) & (yy < h * 0.95)
    img[band] = np.array([2, 70, 30]) * 1.0
    if noise > 0:
        img += rng.normal(0, noise, img.shape)
    rgba = np.zeros((h, w, 4), np.uint8)
    rgba[..., :3] = np.clip(img, 0, 255)
    rgba[..., 3] = 255
    pil = Image.fromarray(rgba, "RGBA")
    d = ImageDraw.Draw(pil)
    font_path = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
    try:
        big = ImageFont.truetype(font_path, int(w * 0.13))
        mid = ImageFont.truetype(font_path, int(w * 0.065))
    except OSError:
        big = mid = ImageFont.load_default()
    d.text((w / 2, h * 0.17), "AROMA", font=big, fill=(2, 50, 22, 255), anchor="mm")
    d.text((w / 2, h * 0.27), "ГЕЛЬ ДЛЯ", font=mid, fill=(2, 50, 22, 255), anchor="mm")
    d.text((w / 2, h * 0.33), "ПОСУДЫ", font=mid, fill=(2, 50, 22, 255), anchor="mm")
    d.text((w / 2, h * 0.905), "500 мл", font=mid, fill=(255, 255, 255, 255), anchor="mm")
    d.arc((w * 0.15, h * 0.15, w * 0.85, h * 0.25), 20, 160, fill=(220, 170, 40, 255), width=max(2, w // 80))
    rgba = np.array(pil)
    # transparent surround: oval label shape
    outside = (((xx - w / 2) / (w * 0.49)) ** 2 + ((yy - h / 2) / (h * 0.49)) ** 2) > 1
    rgba[outside] = 0
    return rgba
