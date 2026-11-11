"""Stage 2 — preprocessing: reduction to the working resolution, image
analysis (noise level, edge softness, sharpness) and edge-preserving
denoising."""
from __future__ import annotations

import math
from dataclasses import asdict, dataclass

import cv2
import numpy as np

from .limits import DEFAULT_MAX_PIXELS, MAX_WORKING_PIXELS


@dataclass
class ImageAnalysis:
    noise_sigma: float  # estimated Gaussian noise std-dev in 0..255 units
    edge_width: float  # typical transition width of strong edges, in px
    sharpness: float  # variance of Laplacian (classic focus measure)
    soft_edge_ratio: float  # share of strong-edge pixels that are anti-aliased
    has_alpha: bool
    opaque_ratio: float
    blockiness: float = 1.0  # >1.1 indicates JPEG-style 8x8 block coding

    @property
    def compressed(self) -> bool:
        return self.blockiness > 1.12

    def to_dict(self) -> dict:
        return {k: round(float(v), 4) if isinstance(v, float) else v for k, v in asdict(self).items()}


@dataclass
class PreprocessResult:
    rgba: np.ndarray  # (h, w, 4) uint8 working image (after reduction + denoise)
    scale: float  # working size / original size
    original_size: tuple[int, int]
    analysis: ImageAnalysis
    denoise_applied: str


def clamp_max_pixels(value: int | None) -> int:
    if not value:
        return DEFAULT_MAX_PIXELS
    return int(max(100, min(int(value), MAX_WORKING_PIXELS)))


def resize_rgba(rgba: np.ndarray, width: int, height: int) -> np.ndarray:
    """Area resampling in premultiplied space so transparent pixels do not
    bleed their (meaningless) colour into the visible ones."""
    f = rgba.astype(np.float32) / 255.0
    a = f[..., 3:4]
    f[..., :3] *= a
    out = cv2.resize(f, (width, height), interpolation=cv2.INTER_AREA)
    alpha = out[..., 3:4]
    with np.errstate(invalid="ignore", divide="ignore"):
        out[..., :3] = np.where(alpha > 1e-6, out[..., :3] / np.maximum(alpha, 1e-6), 0.0)
    return np.clip(out * 255.0 + 0.5, 0, 255).astype(np.uint8)


def reduce_to_max_pixels(rgba: np.ndarray, max_pixels: int) -> tuple[np.ndarray, float]:
    h, w = rgba.shape[:2]
    if w * h <= max_pixels:
        return rgba, 1.0
    s = math.sqrt(max_pixels / float(w * h))
    nw, nh = max(1, int(w * s)), max(1, int(h * s))
    while nw * nh > max_pixels:
        if nw >= nh:
            nw -= 1
        else:
            nh -= 1
    return resize_rgba(rgba, nw, nh), nw / float(w)


def jpeg_blockiness(rgba: np.ndarray) -> float:
    """Ratio of mean luminance steps on 8x8 block borders vs. inside blocks.
    ~1.0 for clean images, clearly above 1 for block-coded (JPEG) images."""
    g = rgba[..., :3].astype(np.float32).mean(-1)
    h, w = g.shape
    if w < 32 or h < 32:
        return 1.0
    dx = np.abs(np.diff(g, axis=1))
    dy = np.abs(np.diff(g, axis=0))
    mask_x = dx < 20
    mask_y = dy < 20
    cols = np.arange(w - 1) % 8 == 7
    rows = np.arange(h - 1) % 8 == 7
    on = np.concatenate([dx[:, cols][mask_x[:, cols]], dy[rows, :][mask_y[rows, :]]])
    off = np.concatenate([dx[:, ~cols][mask_x[:, ~cols]], dy[~rows, :][mask_y[~rows, :]]])
    if on.size < 64 or off.size < 64:
        return 1.0
    return float((on.mean() + 0.05) / (off.mean() + 0.05))


def _gray(rgba: np.ndarray) -> np.ndarray:
    f = rgba.astype(np.float32)
    a = f[..., 3] / 255.0
    # Composite over mid-gray so transparency edges count as edges.
    g = 0.299 * f[..., 0] + 0.587 * f[..., 1] + 0.114 * f[..., 2]
    return g * a + 128.0 * (1.0 - a)


def analyze(rgba: np.ndarray) -> ImageAnalysis:
    gray = _gray(rgba)
    h, w = gray.shape
    alpha = rgba[..., 3]
    if h < 4 or w < 4:
        return ImageAnalysis(0.0, 1.0, 0.0, 1.0, bool((alpha < 255).any()), float((alpha >= 128).mean()), 1.0)

    gx = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3) / 8.0
    gy = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3) / 8.0
    mag = np.sqrt(gx * gx + gy * gy)

    # Immerkaer noise estimate restricted to non-edge pixels.
    kernel = np.array([[1, -2, 1], [-2, 4, -2], [1, -2, 1]], dtype=np.float32)
    lap = cv2.filter2D(gray, cv2.CV_32F, kernel)
    smooth = mag < max(2.0, float(np.percentile(mag, 60)))
    smooth[:1, :] = smooth[-1:, :] = False
    smooth[:, :1] = smooth[:, -1:] = False
    if smooth.sum() > 64:
        noise = math.sqrt(math.pi / 2.0) * float(np.abs(lap[smooth]).mean()) / 6.0
    else:
        noise = 0.0

    sharp = float(cv2.Laplacian(gray, cv2.CV_32F).var())

    # Edge width: local contrast divided by the peak central-difference slope.
    strong_thr = max(12.0, float(np.percentile(mag, 97)))
    strong = mag >= strong_thr
    edge_width = 1.0
    soft_ratio = 0.0
    if strong.sum() > 16:
        k = np.ones((5, 5), np.uint8)
        local_max = cv2.dilate(gray, k)
        local_min = cv2.erode(gray, k)
        contrast = (local_max - local_min)[strong]
        slope = mag[strong]
        ratio = contrast / np.maximum(slope, 1e-3)
        # A hard step between two pixels gives ratio 2 with this slope measure.
        edge_width = float(np.clip(np.median(ratio) - 1.0, 1.0, 8.0))
        # Soft (anti-aliased) edges contain intermediate values next to the step.
        lo = local_min[strong]
        hi = local_max[strong]
        v = gray[strong]
        t = (v - lo) / np.maximum(hi - lo, 1e-3)
        soft_ratio = float(((t > 0.12) & (t < 0.88)).mean())

    return ImageAnalysis(
        noise_sigma=float(noise),
        edge_width=edge_width,
        sharpness=sharp,
        soft_edge_ratio=soft_ratio,
        has_alpha=bool((alpha < 255).any()),
        opaque_ratio=float((alpha >= 128).mean()),
        blockiness=jpeg_blockiness(rgba),
    )


def denoise(rgba: np.ndarray, strength: str, noise_sigma: float) -> np.ndarray:
    """Edge-preserving smoothing (bilateral) applied to colour channels only."""
    if strength == "off":
        return rgba
    if strength == "light":
        sigma_c = max(12.0, 3.0 * noise_sigma)
        d = 5
    else:  # strong
        sigma_c = max(25.0, 5.0 * noise_sigma)
        d = 7
    rgb = np.ascontiguousarray(rgba[..., :3])
    out = rgba.copy()
    out[..., :3] = cv2.bilateralFilter(rgb, d, sigma_c, 2.0)
    if strength == "strong":
        out[..., :3] = cv2.bilateralFilter(out[..., :3].copy(), d, sigma_c * 0.7, 2.0)
    return out


def preprocess(
    rgba: np.ndarray,
    *,
    max_pixels: int | None = None,
    denoise_mode: str = "auto",
    source_format: str | None = None,
) -> PreprocessResult:
    oh, ow = rgba.shape[:2]
    # Block artefacts are measured before reduction (resampling hides them).
    blockiness = jpeg_blockiness(rgba)
    work, scale = reduce_to_max_pixels(rgba, clamp_max_pixels(max_pixels))
    analysis = analyze(work)
    analysis.blockiness = max(blockiness, 1.2 if source_format == "JPEG" and blockiness > 1.03 else 0.0)
    applied = "off"
    mode = denoise_mode
    if mode == "auto":
        if analysis.noise_sigma > 6.0:
            mode = "strong"
        elif analysis.noise_sigma > 2.2 or analysis.compressed:
            mode = "light"
        else:
            mode = "off"
    if mode in ("light", "strong"):
        work = denoise(work, mode, analysis.noise_sigma)
        applied = mode
    return PreprocessResult(rgba=work, scale=scale, original_size=(ow, oh), analysis=analysis, denoise_applied=applied)
