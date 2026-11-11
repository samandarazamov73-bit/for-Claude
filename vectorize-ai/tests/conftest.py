import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for sub in (".", "image-processing", "geometry-engine", "vectorization-engine", "export-engine", "tests"):
    p = os.path.join(ROOT, sub)
    if p not in sys.path:
        sys.path.insert(0, p)

import pytest  # noqa: E402

from synthetic import logo_scene, png_bytes  # noqa: E402


@pytest.fixture(scope="session")
def logo_result():
    from vectorization_engine import vectorize

    return vectorize(png_bytes(logo_scene()))
