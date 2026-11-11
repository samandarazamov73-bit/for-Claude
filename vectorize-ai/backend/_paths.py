"""Make the hyphenated module folders importable when running from source."""
import os
import sys

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for _sub in ("export-engine", "vectorization-engine", "geometry-engine", "image-processing", "."):
    _p = os.path.join(_ROOT, _sub)
    if _p not in sys.path:
        sys.path.insert(0, _p)
