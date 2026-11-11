"""Extension points for learned models.

The pipeline never calls an algorithm directly for the two stages where a
neural network brings the biggest gain; it asks this registry instead:

* ``SegmentationModel`` – produces the palette label map (stage 3).
  Default: :class:`ClassicalSegmentation` (anti-aliasing aware clustering).
* ``EdgeRefiner`` – optionally refines sub-pixel boundary samples (stage 5).
  Default: none (the analytic coverage model is used).

A GPU model is plugged in by implementing the protocol and registering it,
e.g. in a worker start-up hook::

    from vectorization_engine.ml import registry
    registry.register_segmentation(MyOnnxSegmenter("model.onnx"))

or by setting ``VZ_SEGMENTATION_MODEL=package.module:factory``.
"""
from __future__ import annotations

import importlib
import os
from typing import Protocol, runtime_checkable

import numpy as np

from image_processing import Segmentation, SegmentationOptions, segment


@runtime_checkable
class SegmentationModel(Protocol):
    name: str

    def segment(
        self,
        rgba: np.ndarray,
        opts: SegmentationOptions,
        *,
        noise_sigma: float,
        edge_width: float,
        compressed: bool,
        progress=None,
    ) -> Segmentation: ...


@runtime_checkable
class EdgeRefiner(Protocol):
    name: str

    def refine(self, rgba: np.ndarray, cracks, samples: np.ndarray) -> np.ndarray: ...


class ClassicalSegmentation:
    name = "classical-aa-mixture"

    def segment(self, rgba, opts, *, noise_sigma, edge_width, compressed, progress=None):
        return segment(rgba, opts, noise_sigma=noise_sigma, edge_width=edge_width, compressed=compressed, progress=progress)


def _load_factory(spec: str):
    mod, _, attr = spec.partition(":")
    factory = getattr(importlib.import_module(mod), attr or "create")
    return factory()


class ModelRegistry:
    def __init__(self):
        self._seg: SegmentationModel | None = None
        self._edge: EdgeRefiner | None = None

    def register_segmentation(self, model: SegmentationModel) -> None:
        if not isinstance(model, SegmentationModel):
            raise TypeError("model does not implement SegmentationModel")
        self._seg = model

    def register_edge_refiner(self, model: EdgeRefiner | None) -> None:
        if model is not None and not isinstance(model, EdgeRefiner):
            raise TypeError("model does not implement EdgeRefiner")
        self._edge = model

    def segmentation(self) -> SegmentationModel:
        if self._seg is None:
            spec = os.environ.get("VZ_SEGMENTATION_MODEL")
            self._seg = _load_factory(spec) if spec else ClassicalSegmentation()
        return self._seg

    def edge_refiner(self) -> EdgeRefiner | None:
        if self._edge is None and os.environ.get("VZ_EDGE_REFINER"):
            self._edge = _load_factory(os.environ["VZ_EDGE_REFINER"])
        return self._edge

    def describe(self) -> dict:
        e = self.edge_refiner()
        return {"segmentation": self.segmentation().name, "edge_refiner": e.name if e else "analytic-coverage"}


registry = ModelRegistry()
