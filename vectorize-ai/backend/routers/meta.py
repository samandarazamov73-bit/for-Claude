"""Health and option schema endpoints."""
from __future__ import annotations

from fastapi import APIRouter, Request

from api.errors import error_table
from export_engine import EXPORT_SPECS, ExportOptions
from vectorization_engine import registry, schema_json
from vectorization_engine.background import neural_available

from ..deps import state

router = APIRouter(prefix="/api", tags=["meta"])


@router.get("/health")
def health(request: Request):
    st = state(request)
    return {
        "ok": True,
        "queue": st.jobs.queue_length,
        "workers": st.jobs.workers,
        "workerMode": st.jobs.mode,
        "models": registry.describe(),
        "capabilities": {"neuralBackground": neural_available()},
    }


@router.get("/meta/options")
def options():
    d = ExportOptions()
    export = []
    for name, attr, kind, extra, desc in EXPORT_SPECS:
        e = {"name": name, "attr": attr, "type": kind, "description": desc, "default": getattr(d, attr)}
        if kind == "enum":
            e["enum"] = list(extra)
        elif kind == "number":
            e["minimum"], e["maximum"] = extra
        export.append(e)
    return {"processing": schema_json(), "export": export, "errors": error_table()}
