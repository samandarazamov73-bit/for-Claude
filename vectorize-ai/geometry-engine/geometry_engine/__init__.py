"""Geometry engine: curve primitives, fitting, corners, shapes, symmetry."""
from .boundary import BoundaryFit, fit_closed, fit_open
from .fitting import CornerOptions, CurveOptions, fit_circle, fit_section, rdp, smooth_points
from .primitives import (
    Affine,
    Arc,
    CubicBezier,
    EllipticArc,
    Line,
    QuadBezier,
    Segment,
    move_endpoint,
    path_flatten,
    reverse_path,
    segment_from_json,
    signed_area,
)
from .shapes import SHAPE_TYPES, Primitive, recognize, resample_closed
from .symmetry import SymmetryResult, detect_symmetry, group_transforms, match_congruent, signature, symmetrize

__all__ = [
    "Affine",
    "Arc",
    "BoundaryFit",
    "CornerOptions",
    "CubicBezier",
    "CurveOptions",
    "EllipticArc",
    "Line",
    "Primitive",
    "QuadBezier",
    "SHAPE_TYPES",
    "Segment",
    "SymmetryResult",
    "detect_symmetry",
    "fit_circle",
    "fit_closed",
    "fit_open",
    "fit_section",
    "group_transforms",
    "match_congruent",
    "move_endpoint",
    "path_flatten",
    "rdp",
    "recognize",
    "resample_closed",
    "reverse_path",
    "segment_from_json",
    "signature",
    "signed_area",
    "smooth_points",
    "symmetrize",
]
