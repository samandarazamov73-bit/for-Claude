"""Вид из окон утренней больницы: 6 граней куба (снимки tests/shots.gd --case=panorama: лес ясным утром
вокруг здания) -> одна равнопромежуточная панорама sanatorium/assets/morning_panorama.jpg.

Направление на пиксель панорамы (u, v) — как в шейдере неба game.gd (MORNING_SKY_SHADER):
    u = atan2(x, -z) / 2pi (0 — смотрим на -Z, 0.25 — на +X),  v = acos(y) / pi (0 — зенит).
Грань снята камерой Basis.looking_at(fwd, up) с углом 90°: пиксель (a, b) в [-1, 1] слева направо и
сверху вниз смотрит по fwd + a * right - b * up, где right = fwd x up.

    python3 tools/user_assets/make_window_panorama.py <папка с cube_*.png> [ширина]
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

FACES = {  # имя: (вперёд, вверх) — как в tests/shots.gd
    "px": ((1, 0, 0), (0, 1, 0)), "nx": ((-1, 0, 0), (0, 1, 0)),
    "py": ((0, 1, 0), (0, 0, 1)), "ny": ((0, -1, 0), (0, 0, -1)),
    "pz": ((0, 0, 1), (0, 1, 0)), "nz": ((0, 0, -1), (0, 1, 0)),
}


def main() -> None:
    src = Path(sys.argv[1])
    w = int(sys.argv[2]) if len(sys.argv) > 2 else 4096
    h = w // 2
    faces = {k: np.asarray(Image.open(src / f"cube_{k}.png").convert("RGB"), dtype=np.float32) for k in FACES}
    n = next(iter(faces.values())).shape[0]
    u = (np.arange(w) + 0.5) / w
    v = (np.arange(h) + 0.5) / h
    uu, vv = np.meshgrid(u, v)
    phi = uu * 2 * np.pi
    theta = vv * np.pi
    d = np.stack([np.sin(theta) * np.sin(phi), np.cos(theta), -np.sin(theta) * np.cos(phi)], -1)
    out = np.zeros((h, w, 3), np.float32)
    best = np.full((h, w), -1.0)
    for k, (f, up) in FACES.items():
        f = np.array(f, float)
        up = np.array(up, float)
        right = np.cross(f, up)
        dz = d @ f
        mask = (dz > best) & (dz > 0)
        best = np.where(mask, dz, best)
        a = (d @ right) / np.maximum(dz, 1e-6)
        b = -(d @ up) / np.maximum(dz, 1e-6)
        # билинейная выборка
        x = np.clip((a + 1) * 0.5 * n - 0.5, 0, n - 1.001)
        y = np.clip((b + 1) * 0.5 * n - 0.5, 0, n - 1.001)
        x0 = np.floor(x).astype(int)
        y0 = np.floor(y).astype(int)
        fx = (x - x0)[..., None]
        fy = (y - y0)[..., None]
        img = faces[k]
        c = (img[y0, x0] * (1 - fx) * (1 - fy) + img[y0, x0 + 1] * fx * (1 - fy)
             + img[y0 + 1, x0] * (1 - fx) * fy + img[y0 + 1, x0 + 1] * fx * fy)
        out = np.where(mask[..., None], c, out)
    dst = Path(__file__).resolve().parents[2] / "sanatorium" / "assets" / "morning_panorama.jpg"
    Image.fromarray(np.clip(out, 0, 255).astype(np.uint8)).save(dst, quality=90)
    print("saved", dst, w, "x", h)


if __name__ == "__main__":
    main()
