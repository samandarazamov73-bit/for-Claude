"""Generate the demo images shown on the landing page.

All artwork is original and drawn procedurally with true box-filter
anti-aliasing (supersampled), like real exported raster logos."""
from __future__ import annotations

import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "tests"))

import cv2  # noqa: E402
import numpy as np  # noqa: E402
from synthetic import Scene, heart_points  # noqa: E402

OUT = os.path.join(ROOT, "backend", "examples")


def badge():
    s = Scene(480, 480, (246, 243, 236, 255))
    s.circle(240, 240, 200, (24, 48, 92, 255))
    s.circle(240, 240, 176, (246, 243, 236, 255))
    s.circle(240, 240, 160, (230, 92, 52, 255))
    s.star(240, 232, 104, 44, 5, (246, 243, 236, 255))
    s.rounded_rect(130, 360, 350, 402, 21, (24, 48, 92, 255))
    for i in range(12):
        a = i * math.pi / 6
        s.circle(240 + 188 * math.cos(a), 240 + 188 * math.sin(a), 5, (246, 243, 236, 255))
    return s.image()


def landscape():
    s = Scene(640, 420, (233, 242, 248, 255))
    s.circle(470, 120, 62, (255, 190, 60, 255))
    s.polygon([(0, 420), (190, 150), (330, 330), (420, 230), (640, 420)], (44, 86, 120, 255))
    s.polygon([(150, 207), (190, 150), (232, 210), (210, 196), (190, 214), (170, 196)], (240, 246, 250, 255))
    s.polygon([(0, 420), (0, 330), (120, 290), (260, 340), (420, 300), (640, 350), (640, 420)], (66, 140, 96, 255))
    s.ellipse(520, 360, 60, 22, 0, (52, 112, 78, 255))
    return s.image()


def fox():
    s = Scene(480, 480, (255, 255, 255, 0))
    orange, dark, cream = (238, 116, 44, 255), (40, 36, 44, 255), (255, 244, 230, 255)
    s.polygon([(110, 90), (190, 170), (130, 210)], orange)
    s.polygon([(370, 90), (290, 170), (350, 210)], orange)
    s.polygon([(130, 112), (172, 166), (140, 186)], dark)
    s.polygon([(350, 112), (308, 166), (340, 186)], dark)
    s.polygon([(90, 200), (240, 150), (390, 200), (330, 330), (240, 410), (150, 330)], orange)
    s.polygon([(150, 300), (240, 290), (240, 410)], cream)
    s.polygon([(330, 300), (240, 290), (240, 410)], cream)
    s.ellipse(190, 250, 16, 22, 0, dark)
    s.ellipse(290, 250, 16, 22, 0, dark)
    s.circle(184, 242, 5, cream)
    s.circle(284, 242, 5, cream)
    s.polygon([(222, 356), (258, 356), (240, 378)], dark)
    return s.image()


def sticker():
    s = Scene(460, 400, (250, 250, 250, 255))
    s.polygon(heart_points(230, 205, 11.0), (219, 39, 99, 255))
    s.polygon(heart_points(230, 205, 8.4), (255, 255, 255, 255))
    s.polygon(heart_points(230, 205, 6.6), (244, 114, 182, 255))
    for k, (x, y) in enumerate([(70, 70), (390, 80), (60, 330), (400, 320)]):
        s.star(x, y, 22, 9, 4, (250, 204, 21, 255), rot=-math.pi / 2 + k * 0.3)
    return s.image()


def main():
    os.makedirs(OUT, exist_ok=True)
    items = [("badge", "Badge logo", badge), ("landscape", "Flat landscape", landscape), ("fox", "Geometric fox (transparent)", fox), ("sticker", "Heart sticker", sticker)]
    manifest = []
    for name, title, fn in items:
        img = fn()
        cv2.imwrite(os.path.join(OUT, f"{name}.png"), cv2.cvtColor(img, cv2.COLOR_RGBA2BGRA))
        manifest.append({"name": name, "title": title})
    with open(os.path.join(OUT, "examples.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print("wrote", len(manifest), "examples to", OUT)


if __name__ == "__main__":
    main()
