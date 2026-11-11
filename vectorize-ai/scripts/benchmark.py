"""Quality benchmark: vectorize test images and report size/fidelity.

    python scripts/benchmark.py [--compare] [--vtracer] [--out DIR] [image.png ...]

Without image arguments the synthetic scenes from tests/synthetic.py are
used. Fidelity is measured on the opaque area between the source and the
rasterised vector result (mean absolute error and PSNR, 0..255 scale)."""
from __future__ import annotations

import argparse
import io
import json
import math
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
for sub in (".", "image-processing", "geometry-engine", "vectorization-engine", "export-engine", "tests"):
    sys.path.insert(0, os.path.join(ROOT, sub))

import cv2  # noqa: E402
import numpy as np  # noqa: E402

from export_engine import ExportOptions, export, render_graph  # noqa: E402
from vectorization_engine import ProcessingOptions, vectorize  # noqa: E402


def metrics(src: np.ndarray, ren: np.ndarray) -> dict:
    a = src.astype(np.float64)
    b = ren.astype(np.float64)
    pa, pb = a[..., :3] * a[..., 3:4] / 255, b[..., :3] * b[..., 3:4] / 255
    mask = (a[..., 3] > 8) | (b[..., 3] > 8)
    err = np.abs(pa - pb)[mask]
    mse = float((err ** 2).mean()) if err.size else 0.0
    return {"mae": round(float(err.mean()), 3) if err.size else 0.0, "psnr": round(10 * math.log10(255 ** 2 / max(mse, 1e-9)), 2)}


def run_engine(name: str, data: bytes, opts: ProcessingOptions | None, out: str | None, ref: np.ndarray | None = None, label: str = "vectorize-ai") -> dict:
    t = time.perf_counter()
    res = vectorize(data, opts or ProcessingOptions())
    dt = time.perf_counter() - t
    g = res.graph
    ren = render_graph(g)
    svg = export(g, ExportOptions(file_format="svg"))
    m = metrics(ref if ref is not None else res.prepared.rgba, ren)
    if out:
        cv2.imwrite(os.path.join(out, f"{name}_{label}.png"), cv2.cvtColor(np.concatenate([res.prepared.rgba, ren], 1), cv2.COLOR_RGBA2BGRA))
        open(os.path.join(out, f"{name}_{label}.svg"), "wb").write(svg)
    st = g.stats
    return {"engine": label, "time_s": round(dt, 2), "colors": st["colors"], "shapes": st["shapes"], "segments": st["segments"], "gradients": st.get("gradient_shapes", 0), "svg_kb": round(len(svg) / 1024, 1), **m}


def run_vtracer(name: str, rgba: np.ndarray, out: str | None, ref: np.ndarray | None = None) -> dict:
    import vtracer

    ok, buf = cv2.imencode(".png", cv2.cvtColor(rgba, cv2.COLOR_RGBA2BGRA))
    t = time.perf_counter()
    svg = vtracer.convert_raw_image_to_svg(buf.tobytes(), img_format="png", colormode="color")
    dt = time.perf_counter() - t
    ren = rasterize_svg(svg, rgba.shape[1], rgba.shape[0])
    m = metrics(ref if ref is not None else rgba, ren) if ren is not None else {"mae": None, "psnr": None}
    if out:
        open(os.path.join(out, f"{name}_vtracer.svg"), "w").write(svg)
    return {"engine": "vtracer", "time_s": round(dt, 2), "colors": None, "shapes": svg.count("<path"), "segments": svg.count("C") + svg.count("L"), "gradients": 0, "svg_kb": round(len(svg) / 1024, 1), **m}


def rasterize_svg(svg: str, w: int, h: int):
    """Render an SVG with headless Chromium through Node + Playwright (only
    used for the vtracer comparison). Returns None when unavailable."""
    import shutil
    import subprocess
    import tempfile

    if not shutil.which("node"):
        return None
    with tempfile.TemporaryDirectory() as td:
        src, out = os.path.join(td, "in.svg"), os.path.join(td, "out.png")
        open(src, "w").write(svg)
        js = (
            "const {chromium}=require('playwright');const fs=require('fs');(async()=>{"
            "const b=await chromium.launch();const p=await b.newPage({viewport:{width:%d,height:%d}});"
            "let s=fs.readFileSync(%r,'utf8').replace(/<\\?xml[^>]*>/,'');"
            "s=s.replace('<svg ','<svg style=\"display:block\" width=\"%d\" height=\"%d\" ');"
            "await p.setContent('<html><body style=\"margin:0;background:transparent\">'+s+'</body></html>');"
            "await p.screenshot({path:%r,clip:{x:0,y:0,width:%d,height:%d},omitBackground:true});await b.close();})();"
        ) % (w, h, src, w, h, out, w, h)
        r = subprocess.run(["node", "-e", js], capture_output=True, text=True, timeout=120)
        if r.returncode != 0 or not os.path.exists(out):
            return None
        arr = cv2.imread(out, cv2.IMREAD_UNCHANGED)
    return cv2.cvtColor(arr, cv2.COLOR_BGRA2RGBA)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("images", nargs="*")
    ap.add_argument("--vtracer", action="store_true")
    ap.add_argument("--out", default=None)
    ap.add_argument("--no-gradients", action="store_true")
    ap.add_argument("--compare", action="store_true", help="also run without gradients")
    args = ap.parse_args()
    if args.out:
        os.makedirs(args.out, exist_ok=True)
    cases: list[tuple[str, np.ndarray]] = []
    refs: dict[str, np.ndarray] = {}
    if args.images:
        for p in args.images:
            arr = cv2.imread(p, cv2.IMREAD_UNCHANGED)
            arr = cv2.cvtColor(arr, cv2.COLOR_BGRA2RGBA if arr.shape[2] == 4 else cv2.COLOR_BGR2RGBA)
            cases.append((os.path.splitext(os.path.basename(p))[0], arr))
    else:
        import synthetic as s

        cases = [("logo", s.logo_scene()), ("touching", s.touching_scene()), ("label", s.label_scene()), ("photo", s.photo_like(900, 640))]
        refs["label"] = s.label_scene(noise=0)
    rows = []
    for name, rgba in cases:
        ok, buf = cv2.imencode(".png", cv2.cvtColor(rgba, cv2.COLOR_RGBA2BGRA))
        ref = refs.get(name)
        if args.compare:
            rows.append({"image": name, **run_engine(name, buf.tobytes(), ProcessingOptions(gradients=False), args.out, ref, "flat-only")})
        rows.append({"image": name, **run_engine(name, buf.tobytes(), ProcessingOptions(gradients=not args.no_gradients), args.out, ref)})
        if args.vtracer:
            rows.append({"image": name, **run_vtracer(name, rgba, args.out, ref)})
    keys = ["image", "engine", "time_s", "colors", "shapes", "segments", "gradients", "svg_kb", "mae", "psnr"]
    print(" | ".join(f"{k:>10}" for k in keys))
    for r in rows:
        print(" | ".join(f"{str(r.get(k)):>10}" for k in keys))
    if args.out:
        json.dump(rows, open(os.path.join(args.out, "results.json"), "w"), indent=2)


if __name__ == "__main__":
    main()
