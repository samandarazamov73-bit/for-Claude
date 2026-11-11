"""Image decoding, analysis, preprocessing and colour segmentation."""
from .color import PaletteEntry, parse_hex, parse_palette, to_hex
from .decode import DecodedImage, ImageDecodeError, decode_image, encode_png, probe_size, sniff_format
from .limits import (
    DEFAULT_MAX_PIXELS,
    MAX_BASE64_BYTES,
    MAX_FILE_BYTES,
    MAX_PNG_EXPORT_PIXELS,
    MAX_UPLOAD_PIXELS,
    MAX_WORKING_PIXELS,
)
from .preprocess import ImageAnalysis, PreprocessResult, preprocess, resize_rgba
from .segmentation import TRANSPARENT, Segmentation, SegmentationOptions, label_regions, segment
from .gradients import merge_gradients

__all__ = [
    "DecodedImage",
    "ImageDecodeError",
    "decode_image",
    "encode_png",
    "probe_size",
    "sniff_format",
    "PaletteEntry",
    "parse_hex",
    "parse_palette",
    "to_hex",
    "ImageAnalysis",
    "PreprocessResult",
    "preprocess",
    "resize_rgba",
    "Segmentation",
    "SegmentationOptions",
    "segment",
    "merge_gradients",
    "label_regions",
    "TRANSPARENT",
    "DEFAULT_MAX_PIXELS",
    "MAX_BASE64_BYTES",
    "MAX_FILE_BYTES",
    "MAX_PNG_EXPORT_PIXELS",
    "MAX_UPLOAD_PIXELS",
    "MAX_WORKING_PIXELS",
]
