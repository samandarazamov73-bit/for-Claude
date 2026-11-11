"""Colour utilities: sRGB <-> CIELAB, hex parsing and custom palette specs."""
from __future__ import annotations

import re
from dataclasses import dataclass

import cv2
import numpy as np

ALPHA_WEIGHT = 100.0  # a full alpha difference counts like dE=100
MAX_ARGB_DISTANCE = 510.0  # sqrt(4) * 255
MAX_PALETTE_ENTRIES = 1024

_HEX_RE = re.compile(r"^#?([0-9a-fA-F]{6}|[0-9a-fA-F]{8}|[0-9a-fA-F]{3})$")


def parse_hex(value: str) -> tuple[int, int, int, int]:
    m = _HEX_RE.match(value.strip())
    if not m:
        raise ValueError(f"Invalid colour '{value}'. Use #RRGGBB or #RRGGBBAA.")
    h = m.group(1)
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    a = int(h[6:8], 16) if len(h) == 8 else 255
    return r, g, b, a


def to_hex(rgba, include_alpha: bool | None = None) -> str:
    r, g, b = (int(round(float(v))) for v in rgba[:3])
    a = int(round(float(rgba[3]))) if len(rgba) > 3 else 255
    if include_alpha is None:
        include_alpha = a < 255
    s = f"#{r:02x}{g:02x}{b:02x}"
    return s + f"{a:02x}" if include_alpha else s


def srgb_to_lab(rgb_u8: np.ndarray) -> np.ndarray:
    """(..., 3) uint8 sRGB -> (..., 3) float32 CIELAB (D65)."""
    shape = rgb_u8.shape
    flat = rgb_u8.reshape(-1, 1, 3).astype(np.float32) / 255.0
    lab = cv2.cvtColor(flat, cv2.COLOR_RGB2LAB)
    return lab.reshape(shape[:-1] + (3,))


def rgba_features(rgba_u8: np.ndarray) -> np.ndarray:
    """Perceptual clustering features: CIELAB + weighted alpha."""
    lab = srgb_to_lab(rgba_u8[..., :3])
    alpha = rgba_u8[..., 3:4].astype(np.float32) * (ALPHA_WEIGHT / 255.0)
    return np.concatenate([lab, alpha], axis=-1)


def delta_e(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    return np.sqrt(((a - b) ** 2).sum(axis=-1))


@dataclass
class PaletteEntry:
    match: tuple[int, int, int, int]
    output: tuple[int, int, int, int]
    tolerance: float | None = None  # fraction of the max ARGB distance


def parse_palette(spec: str) -> list[PaletteEntry]:
    """Parse ``#RRGGBB[AA] [-> #RRGGBB[AA]] [~ tolerance]`` entries separated
    by ``;`` or new lines."""
    entries: list[PaletteEntry] = []
    for raw in re.split(r"[;\n]", spec or ""):
        item = raw.strip()
        if not item:
            continue
        tol = None
        if "~" in item:
            item, tol_s = item.split("~", 1)
            try:
                tol = float(tol_s.strip())
            except ValueError as exc:
                raise ValueError(f"Invalid tolerance in palette entry '{raw.strip()}'.") from exc
            if not 0.0 <= tol <= 1.0:
                raise ValueError("Palette tolerance must be between 0 and 1.")
        if "->" in item:
            src, dst = item.split("->", 1)
            match, output = parse_hex(src), parse_hex(dst)
        else:
            match = output = parse_hex(item)
        entries.append(PaletteEntry(match=match, output=output, tolerance=tol))
        if len(entries) > MAX_PALETTE_ENTRIES:
            raise ValueError(f"A palette may contain at most {MAX_PALETTE_ENTRIES} colours.")
    return entries
