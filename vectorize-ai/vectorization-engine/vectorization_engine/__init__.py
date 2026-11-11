"""Vectorisation engine: Vector Graph construction and the full pipeline."""
from .graph import Interface, Node, Shape, VectorGraph
from .ml import ModelRegistry, registry
from .options import OPTION_SPECS, OptionError, ProcessingOptions, parse_public, schema_json
from .pipeline import STAGE_PHASE, STAGES, Cancelled, PipelineResult, PreparedImage, StageCache, vectorize

__all__ = [
    "Cancelled",
    "Interface",
    "ModelRegistry",
    "Node",
    "OPTION_SPECS",
    "OptionError",
    "PipelineResult",
    "PreparedImage",
    "ProcessingOptions",
    "STAGES",
    "STAGE_PHASE",
    "Shape",
    "StageCache",
    "VectorGraph",
    "parse_public",
    "registry",
    "schema_json",
    "vectorize",
]
