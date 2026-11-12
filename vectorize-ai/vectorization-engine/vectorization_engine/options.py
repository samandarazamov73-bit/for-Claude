"""Processing options.

``OPTION_SPECS`` is the single source of truth for every processing
parameter: the public API parser, the OpenAPI document, the web editor and
the pipeline all read it."""
from __future__ import annotations

import hashlib
import json
from dataclasses import asdict, dataclass, fields
from typing import Any

from image_processing import DEFAULT_MAX_PIXELS, MAX_WORKING_PIXELS, parse_palette

# bump when stages 1-3 change their output, so on-disk caches are not reused
SEGMENTATION_VERSION = 3

DETAIL_LEVELS = {"normal": 0, "high": 1, "max": 2}


@dataclass
class ProcessingOptions:
    max_pixels: int = DEFAULT_MAX_PIXELS
    color_profile: str = "convert"
    denoise: str = "auto"
    max_colors: int = 0
    palette: str = ""
    color_threshold: float = 0.0
    detail: str = "normal"  # normal | high | max
    gradients: bool = True
    min_area_px: float = 0.0
    fit_tolerance: float = 0.0
    subpixel: bool = True
    curves_quadratic: bool = True
    curves_cubic: bool = True
    curves_arcs: bool = True
    corners_mode: str = "auto"
    corners_strength: float = 0.5
    shapes_enabled: bool = True
    shapes_circle: bool = True
    shapes_ellipse: bool = True
    shapes_rectangle: bool = True
    shapes_rounded_rectangle: bool = True
    shapes_triangle: bool = True
    shapes_quadrilateral: bool = True
    shapes_star: bool = True
    symmetry_mirror: bool = True
    symmetry_rotation: bool = True
    symmetry_repeats: bool = True
    symmetry_tolerance: float = 0.8

    @property
    def detail_level(self) -> int:
        """0 = normal, 1 = high, 2 = max (photo-like fidelity)."""
        return DETAIL_LEVELS.get(self.detail, 0)

    def enabled_shapes(self) -> set[str]:
        if not self.shapes_enabled:
            return set()
        names = ("circle", "ellipse", "rectangle", "rounded_rectangle", "triangle", "quadrilateral", "star")
        return {n for n in names if getattr(self, f"shapes_{n}")}

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict | None) -> "ProcessingOptions":
        data = data or {}
        valid = {f.name for f in fields(cls)}
        opts = cls(**{k: v for k, v in data.items() if k in valid})
        return validate(opts)

    def segmentation_key(self) -> str:
        """Hash of every option that affects stages 1-3 (cacheable)."""
        key = {k: getattr(self, k) for k in ("max_pixels", "color_profile", "denoise", "max_colors", "palette", "color_threshold", "min_area_px", "gradients", "detail")}
        key["engine"] = SEGMENTATION_VERSION  # cached results of older algorithms are not reused
        return hashlib.sha256(json.dumps(key, sort_keys=True).encode()).hexdigest()[:20]


@dataclass(frozen=True)
class OptionSpec:
    name: str  # public dotted name
    attr: str  # ProcessingOptions attribute
    kind: str  # integer | number | boolean | enum | string
    description: str
    minimum: float | None = None
    maximum: float | None = None
    enum: tuple[str, ...] = ()
    group: str = "processing"


OPTION_SPECS: tuple[OptionSpec, ...] = (
    OptionSpec("input.max_pixels", "max_pixels", "integer", "Working resolution limit in pixels; larger images are reduced before vectorisation.", 100, MAX_WORKING_PIXELS, group="input"),
    OptionSpec("input.color_profile", "color_profile", "enum", "Embedded ICC profile handling.", enum=("convert", "ignore"), group="input"),
    OptionSpec("processing.denoise", "denoise", "enum", "Edge-preserving noise reduction before segmentation.", enum=("auto", "off", "light", "strong")),
    OptionSpec("processing.max_colors", "max_colors", "integer", "Maximum number of colours (0 = determined automatically).", 0, 256, group="palette"),
    OptionSpec("processing.palette", "palette", "string", "Custom palette: '#RRGGBB[AA] [-> #RRGGBB[AA]] [~ tolerance]' entries separated by ';' (max 1024).", group="palette"),
    OptionSpec("processing.color_threshold", "color_threshold", "number", "Colour merge threshold in CIE76 dE (0 = automatic, noise adaptive).", 0, 60, group="palette"),
    OptionSpec("processing.detail", "detail", "enum", "Fidelity level. 'normal' gives clean, editable artwork; 'high' and 'max' keep finer colour steps, smaller details and shade almost every region with its own gradient, getting close to the original at the cost of more shapes and a larger file.", enum=("normal", "high", "max"), group="palette"),
    OptionSpec("processing.gradients", "gradients", "boolean", "Represent smooth shading with linear and radial gradients instead of bands of flat colour.", group="palette"),
    OptionSpec("processing.min_area_px", "min_area_px", "number", "Regions smaller than this many pixels are merged into neighbours (0 = automatic).", 0, 10000, group="geometry"),
    OptionSpec("processing.fit_tolerance", "fit_tolerance", "number", "Maximum curve deviation in pixels (0 = automatic). Larger = fewer anchor points.", 0, 5, group="geometry"),
    OptionSpec("processing.subpixel", "subpixel", "boolean", "Use anti-aliasing coverage to place boundaries with sub-pixel precision.", group="geometry"),
    OptionSpec("processing.curves.quadratic", "curves_quadratic", "boolean", "Allow quadratic Bezier curves.", group="geometry"),
    OptionSpec("processing.curves.cubic", "curves_cubic", "boolean", "Allow cubic Bezier curves.", group="geometry"),
    OptionSpec("processing.curves.circular_arcs", "curves_arcs", "boolean", "Allow circular arcs.", group="geometry"),
    OptionSpec("processing.corners.mode", "corners_mode", "enum", "Corner handling: auto classification, force sharp, or keep rounded.", enum=("auto", "sharp", "rounded"), group="corners"),
    OptionSpec("processing.corners.strength", "corners_strength", "number", "Corner correction strength (0..1).", 0, 1, group="corners"),
    OptionSpec("processing.shapes.enabled", "shapes_enabled", "boolean", "Recognise whole parametric shapes.", group="shapes"),
    OptionSpec("processing.shapes.circle", "shapes_circle", "boolean", "Recognise circles.", group="shapes"),
    OptionSpec("processing.shapes.ellipse", "shapes_ellipse", "boolean", "Recognise ellipses.", group="shapes"),
    OptionSpec("processing.shapes.rectangle", "shapes_rectangle", "boolean", "Recognise rectangles and squares.", group="shapes"),
    OptionSpec("processing.shapes.rounded_rectangle", "shapes_rounded_rectangle", "boolean", "Recognise rounded rectangles.", group="shapes"),
    OptionSpec("processing.shapes.triangle", "shapes_triangle", "boolean", "Recognise triangles (general, isosceles, equilateral).", group="shapes"),
    OptionSpec("processing.shapes.quadrilateral", "shapes_quadrilateral", "boolean", "Recognise general quadrilaterals.", group="shapes"),
    OptionSpec("processing.shapes.star", "shapes_star", "boolean", "Recognise regular stars (3-8 points).", group="shapes"),
    OptionSpec("processing.symmetry.mirror", "symmetry_mirror", "boolean", "Detect and enforce mirror symmetry.", group="symmetry"),
    OptionSpec("processing.symmetry.rotation", "symmetry_rotation", "boolean", "Detect and enforce rotational symmetry.", group="symmetry"),
    OptionSpec("processing.symmetry.repeats", "symmetry_repeats", "boolean", "Make repeated shapes exact copies.", group="symmetry"),
    OptionSpec("processing.symmetry.tolerance", "symmetry_tolerance", "number", "Symmetry detection tolerance in pixels.", 0.2, 4, group="symmetry"),
)

SPEC_BY_NAME = {s.name: s for s in OPTION_SPECS}
SPEC_BY_ATTR = {s.attr: s for s in OPTION_SPECS}


class OptionError(ValueError):
    def __init__(self, name: str, message: str):
        super().__init__(f"{name}: {message}")
        self.name = name
        self.message = message


_TRUE = {"true", "1", "yes", "on"}
_FALSE = {"false", "0", "no", "off"}


def coerce(spec: OptionSpec, raw: Any) -> Any:
    try:
        if spec.kind == "boolean":
            if isinstance(raw, bool):
                return raw
            s = str(raw).strip().lower()
            if s in _TRUE:
                return True
            if s in _FALSE:
                return False
            raise ValueError("expected true or false")
        if spec.kind == "integer":
            v = int(str(raw).strip())
        elif spec.kind == "number":
            v = float(str(raw).strip())
        elif spec.kind == "enum":
            v = str(raw).strip()
            if v not in spec.enum:
                raise ValueError(f"expected one of {', '.join(spec.enum)}")
            return v
        else:
            v = str(raw)
            if len(v) > 64_000:
                raise ValueError("value too long")
            return v
    except ValueError as exc:
        raise OptionError(spec.name, str(exc)) from exc
    if spec.minimum is not None and v < spec.minimum:
        raise OptionError(spec.name, f"must be >= {spec.minimum:g}")
    if spec.maximum is not None and v > spec.maximum:
        raise OptionError(spec.name, f"must be <= {spec.maximum:g}")
    return v


def validate(opts: ProcessingOptions) -> ProcessingOptions:
    for spec in OPTION_SPECS:
        setattr(opts, spec.attr, coerce(spec, getattr(opts, spec.attr)))
    if opts.palette:
        try:
            parse_palette(opts.palette)
        except ValueError as exc:
            raise OptionError("processing.palette", str(exc)) from exc
    return opts


def parse_public(params: dict[str, Any]) -> ProcessingOptions:
    """Build options from public dotted parameter names."""
    opts = ProcessingOptions()
    for name, raw in params.items():
        spec = SPEC_BY_NAME.get(name)
        if spec is None or raw is None or raw == "":
            continue
        setattr(opts, spec.attr, coerce(spec, raw))
    return validate(opts)


def schema_json() -> list[dict]:
    defaults = ProcessingOptions()
    out = []
    for s in OPTION_SPECS:
        d = {"name": s.name, "attr": s.attr, "type": s.kind, "description": s.description, "group": s.group, "default": getattr(defaults, s.attr)}
        if s.minimum is not None:
            d["minimum"] = s.minimum
        if s.maximum is not None:
            d["maximum"] = s.maximum
        if s.enum:
            d["enum"] = list(s.enum)
        out.append(d)
    return out
