"""Code executed inside worker processes.

Workers report progress through a queue and poll a shared cancellation
map; they write results to the image's storage directory and return a small
picklable summary."""
from __future__ import annotations

import time
import traceback

PIPELINE_SHARE = 0.94  # remaining share is the "rendering" (result writing) phase


def run_vectorize_job(spec: dict, progress_q, cancel_flags) -> dict:
    import backend._paths  # noqa: F401  (spawned interpreters)
    from pathlib import Path

    import cv2
    import numpy as np

    from backend.storage import Storage
    from image_processing import ImageDecodeError
    from vectorization_engine import STAGE_PHASE, Cancelled, OptionError, ProcessingOptions, StageCache, vectorize

    job_id = spec["job_id"]
    token = spec["token"]
    storage = Storage(Path(spec["data_dir"]))
    last = {"t": 0.0, "f": -1.0, "stage": ""}

    def emit(phase: str, stage: str, frac: float, msg: str, force: bool = False) -> None:
        now = time.monotonic()
        if force or stage != last["stage"] or frac - last["f"] >= 0.01 or now - last["t"] > 0.3:
            last.update(t=now, f=frac, stage=stage)
            progress_q.put((job_id, phase, stage, float(frac), msg))

    def on_progress(stage: str, frac: float, msg: str) -> None:
        if cancel_flags.get(job_id):
            raise Cancelled()
        emit(STAGE_PHASE.get(stage, "processing"), stage, frac * PIPELINE_SHARE, msg)

    try:
        data = storage.read_source(token)
        opts = ProcessingOptions.from_dict(spec.get("options"))
        crop = tuple(spec["crop"]) if spec.get("crop") else None
        res = vectorize(data, opts, progress=on_progress, cache=StageCache(str(storage.cache_dir(token))), crop=crop)
        if cancel_flags.get(job_id):
            raise Cancelled()
        emit("rendering", "rendering", PIPELINE_SHARE + 0.01, "writing vector graph", force=True)
        storage.save_graph(token, res.graph.to_json())
        emit("rendering", "rendering", PIPELINE_SHARE + 0.03, "rendering previews", force=True)
        rgba = res.prepared.rgba
        bgra = cv2.cvtColor(rgba, cv2.COLOR_RGBA2BGRA)
        ok, buf = cv2.imencode(".png", bgra, [cv2.IMWRITE_PNG_COMPRESSION, 5])
        if ok:
            p = storage.preview_path(token)
            p.with_suffix(".tmp").write_bytes(buf.tobytes())
            p.with_suffix(".tmp").replace(p)
        h, w = rgba.shape[:2]
        s = 240.0 / max(h, w)
        thumb = cv2.resize(bgra, (max(1, int(w * s)), max(1, int(h * s))), interpolation=cv2.INTER_AREA) if s < 1 else bgra
        ok, buf = cv2.imencode(".png", thumb)
        if ok:
            storage.thumb_path(token).write_bytes(buf.tobytes())
        emit("rendering", "rendering", 1.0, "done", force=True)
        stats = res.graph.stats
        return {"ok": True, "stats": stats, "width": int(np.asarray(stats["original_width"])), "height": int(stats["original_height"])}
    except Cancelled:
        return {"ok": False, "code": "cancelled", "message": "Processing was cancelled."}
    except ImageDecodeError as exc:
        return {"ok": False, "code": exc.code, "message": exc.message}
    except OptionError as exc:
        return {"ok": False, "code": "invalid_option", "message": str(exc)}
    except MemoryError:
        return {"ok": False, "code": "out_of_memory", "message": "The image needs more memory than is available.", "retryable": True}
    except ValueError as exc:
        return {"ok": False, "code": "invalid_input", "message": str(exc)}
    except Exception as exc:  # noqa: BLE001 - reported to the job, logged
        return {"ok": False, "code": "processing_error", "message": f"{type(exc).__name__}: {exc}", "trace": traceback.format_exc()[-4000:], "retryable": True}
