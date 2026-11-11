"""Stage 1 — image decoding.

Turns untrusted bytes into a straight-alpha sRGB RGBA ``uint8`` array.
The container format is detected from magic bytes (never from the file name
or the client supplied MIME type) and must agree with what Pillow decodes.
"""
from __future__ import annotations

import io
import warnings
from dataclasses import dataclass

import numpy as np
from PIL import Image, ImageCms, ImageOps

from .limits import MAX_FILE_BYTES, MAX_UPLOAD_PIXELS

# Pillow raises DecompressionBombError above 2x this value and warns above it.
Image.MAX_IMAGE_PIXELS = MAX_UPLOAD_PIXELS

SUPPORTED_FORMATS = ("PNG", "JPEG", "GIF", "BMP", "WEBP", "TIFF")

MIME_TYPES = {
    "PNG": "image/png",
    "JPEG": "image/jpeg",
    "GIF": "image/gif",
    "BMP": "image/bmp",
    "WEBP": "image/webp",
    "TIFF": "image/tiff",
}


class ImageDecodeError(Exception):
    """Raised for any input that cannot be accepted as an image."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass
class DecodedImage:
    rgba: np.ndarray  # (H, W, 4) uint8, straight alpha, sRGB
    source_format: str
    has_alpha: bool
    dpi: tuple[float, float] | None
    icc_converted: bool
    frame_count: int

    @property
    def width(self) -> int:
        return int(self.rgba.shape[1])

    @property
    def height(self) -> int:
        return int(self.rgba.shape[0])


def sniff_format(data: bytes) -> str | None:
    """Identify the container from its signature bytes."""
    head = data[:16]
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "PNG"
    if head.startswith(b"\xff\xd8\xff"):
        return "JPEG"
    if head.startswith((b"GIF87a", b"GIF89a")):
        return "GIF"
    if head.startswith(b"BM") and len(data) > 26:
        return "BMP"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "WEBP"
    if head.startswith((b"II*\x00", b"MM\x00*", b"II+\x00", b"MM\x00+")):
        return "TIFF"
    return None


def probe_size(data: bytes) -> tuple[str, int, int]:
    """Return (format, width, height) without decoding pixel data."""
    fmt = sniff_format(data)
    if fmt is None:
        raise ImageDecodeError("unsupported_format", "Unsupported or unrecognised image format.")
    try:
        with Image.open(io.BytesIO(data)) as img:
            return fmt, int(img.width), int(img.height)
    except Exception as exc:  # noqa: BLE001 - Pillow raises many types
        raise ImageDecodeError("corrupt_image", f"Could not read image header: {exc}") from exc


def _to_8bit_gray(img: Image.Image) -> Image.Image:
    arr = np.asarray(img)
    if arr.dtype == np.uint8:
        return Image.fromarray(arr, "L")
    arr = arr.astype(np.float64)
    if img.mode == "F":
        lo, hi = float(np.nanmin(arr)), float(np.nanmax(arr))
        scale = 255.0 / (hi - lo) if hi > lo else 0.0
        arr = (arr - lo) * scale
    else:
        maxval = 65535.0 if arr.max() > 255 else 255.0
        arr = arr * (255.0 / maxval)
    return Image.fromarray(np.clip(arr + 0.5, 0, 255).astype(np.uint8), "L")


def _apply_icc(img: Image.Image, icc: bytes) -> tuple[Image.Image, bool]:
    try:
        src = ImageCms.ImageCmsProfile(io.BytesIO(icc))
        dst = ImageCms.createProfile("sRGB")
        if img.mode == "CMYK":
            return ImageCms.profileToProfile(img, src, dst, outputMode="RGB"), True
        if img.mode in ("RGB", "RGBA"):
            return ImageCms.profileToProfile(img, src, dst, outputMode=img.mode), True
    except Exception:  # noqa: BLE001 - broken/unsupported profiles are ignored
        pass
    return img, False


def decode_image(
    data: bytes,
    *,
    color_profile: str = "convert",
    max_pixels: int = MAX_UPLOAD_PIXELS,
    max_bytes: int = MAX_FILE_BYTES,
) -> DecodedImage:
    if not data:
        raise ImageDecodeError("empty_file", "The uploaded file is empty.")
    if len(data) > max_bytes:
        raise ImageDecodeError("file_too_large", f"File exceeds the {max_bytes // (1024 * 1024)} MiB limit.")
    fmt = sniff_format(data)
    if fmt is None:
        raise ImageDecodeError(
            "unsupported_format",
            "Unsupported image format. Use PNG, JPEG, GIF, BMP, WebP or TIFF.",
        )
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            img = Image.open(io.BytesIO(data))
            if (img.format or "").upper() not in SUPPORTED_FORMATS or (img.format or "").upper() != fmt:
                raise ImageDecodeError("format_mismatch", "File contents do not match a supported image format.")
            if img.width * img.height > max_pixels:
                raise ImageDecodeError(
                    "too_many_pixels",
                    f"Image has {img.width * img.height:,} pixels; the maximum is {max_pixels:,}.",
                )
            frame_count = int(getattr(img, "n_frames", 1) or 1)
            if frame_count > 1:
                img.seek(0)
            img.load()
    except ImageDecodeError:
        raise
    except (Image.DecompressionBombError, Image.DecompressionBombWarning) as exc:
        raise ImageDecodeError("too_many_pixels", "Image dimensions are too large.") from exc
    except Exception as exc:  # noqa: BLE001
        raise ImageDecodeError("corrupt_image", f"The image could not be decoded: {exc}") from exc

    dpi = img.info.get("dpi")
    if dpi is not None:
        try:
            dpi = (float(dpi[0]), float(dpi[1]))
        except (TypeError, ValueError, IndexError):
            dpi = None
    icc = img.info.get("icc_profile")

    try:
        img = ImageOps.exif_transpose(img)
    except Exception:  # noqa: BLE001 - malformed EXIF must not block decoding
        pass

    mode = img.mode
    icc_converted = False
    if mode in ("I;16", "I;16B", "I;16L", "I", "F"):
        img = _to_8bit_gray(img)
        mode = "L"
    if mode == "P":
        img = img.convert("RGBA")
    elif mode in ("1", "L"):
        img = img.convert("RGB")
    elif mode == "LA":
        img = img.convert("RGBA")
    elif mode == "PA":
        img = img.convert("RGBA")
    elif mode in ("CMYK", "YCbCr", "LAB", "HSV"):
        if mode == "CMYK" and icc and color_profile == "convert":
            img, icc_converted = _apply_icc(img, icc)
        if img.mode != "RGB":
            img = img.convert("RGB")
    elif mode == "RGBa":
        img = img.convert("RGBA")
    elif mode not in ("RGB", "RGBA"):
        img = img.convert("RGBA")

    if icc and color_profile == "convert" and not icc_converted and img.mode in ("RGB", "RGBA"):
        img, icc_converted = _apply_icc(img, icc)

    if img.mode == "RGB":
        rgb = np.asarray(img, dtype=np.uint8)
        rgba = np.empty(rgb.shape[:2] + (4,), dtype=np.uint8)
        rgba[..., :3] = rgb
        rgba[..., 3] = 255
    else:
        rgba = np.array(img.convert("RGBA"), dtype=np.uint8)

    has_alpha = bool((rgba[..., 3] < 255).any())
    return DecodedImage(
        rgba=np.ascontiguousarray(rgba),
        source_format=fmt,
        has_alpha=has_alpha,
        dpi=dpi,
        icc_converted=icc_converted,
        frame_count=frame_count,
    )


def encode_png(rgba: np.ndarray) -> bytes:
    buf = io.BytesIO()
    Image.fromarray(rgba, "RGBA").save(buf, format="PNG", optimize=False, compress_level=6)
    return buf.getvalue()
