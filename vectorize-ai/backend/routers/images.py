"""Web application image endpoints."""
from __future__ import annotations

import json
import re
from pathlib import Path

from fastapi import APIRouter, Depends, File, Form, Request, Response, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session as DbSession

from api.errors import ApiError
from billing.credits import active_subscription
from database import Image, Job, User
from export_engine import MIME, ExportError, RasterTooLarge, export, parse_export_public
from image_processing import MAX_FILE_BYTES, ImageDecodeError, probe_size
from vectorization_engine import OptionError, ProcessingOptions, VectorGraph
from vectorization_engine.background import detect_background
from vectorization_engine.edits import EditState, apply_edits

from ..deps import AppState, anon_id, current_user, get_db, image_expiry, owned_image, start_job, state
from ..fetch import FetchError, fetch_image
from ..storage import new_token

router = APIRouter(prefix="/api", tags=["web"])
EXAMPLES_DIR = Path(__file__).resolve().parent.parent / "examples"


def _examples() -> list[dict]:
    manifest = EXAMPLES_DIR / "examples.json"
    if not manifest.exists():
        return []
    return json.loads(manifest.read_text())


def _parse_crop(raw, width: int, height: int) -> list[int] | None:
    if raw in (None, "", "null"):
        return None
    try:
        vals = json.loads(raw) if isinstance(raw, str) else raw
        x, y, w, h = (int(round(float(v))) for v in vals)
    except (ValueError, TypeError) as exc:
        raise ApiError("invalid_crop") from exc
    x, y = max(0, x), max(0, y)
    w, h = min(w, width - x), min(h, height - y)
    if w < 2 or h < 2:
        raise ApiError("invalid_crop")
    return [x, y, w, h]


def _parse_options(raw) -> dict:
    if raw in (None, "", "null"):
        return ProcessingOptions().to_dict()
    try:
        d = json.loads(raw) if isinstance(raw, str) else dict(raw)
        return ProcessingOptions.from_dict(d).to_dict()
    except OptionError as exc:
        raise ApiError("invalid_option", str(exc)) from exc
    except (ValueError, TypeError) as exc:
        raise ApiError("invalid_option", "options must be a JSON object") from exc


def ingest(st: AppState, db: DbSession, data: bytes, filename: str, user: User | None, anon: str | None, crop_raw=None, options_raw=None, is_example: bool = False) -> dict:
    if len(data) > MAX_FILE_BYTES:
        raise ApiError("file_too_large")
    try:
        fmt, w, h = probe_size(data)
    except ImageDecodeError as exc:
        raise ApiError(exc.code if exc.code in ("unsupported_format", "corrupt_image") else "corrupt_image", exc.message) from exc
    if w * h > 33_554_432:
        raise ApiError("too_many_pixels")
    crop = _parse_crop(crop_raw, w, h)
    options = _parse_options(options_raw)
    token = new_token()
    st.storage.write_source(token, data)
    safe_name = re.sub(r"[^\w.\- ]+", "_", (filename or "image"))[:120] or "image"
    img = Image(
        token=token,
        user_id=user.id if user else None,
        anon_id=None if user else anon,
        origin="web",
        filename=safe_name,
        source_format=fmt,
        width=w,
        height=h,
        size_bytes=len(data),
        crop=crop,
        options=options,
        is_example=is_example,
        expires_at=image_expiry(st.settings, user),
    )
    db.add(img)
    db.flush()
    job = start_job(st, db, img, options)
    return {"token": token, "jobId": job.id, "width": w, "height": h, "format": fmt, "filename": safe_name}


@router.post("/images")
async def upload_image(
    request: Request,
    response: Response,
    file: UploadFile = File(...),
    crop: str | None = Form(None),
    options: str | None = Form(None),
    db: DbSession = Depends(get_db),
    user: User | None = Depends(current_user),
):
    st = state(request)
    if file.size is not None and file.size > MAX_FILE_BYTES:
        raise ApiError("file_too_large")
    data = await file.read(MAX_FILE_BYTES + 1)
    anon = anon_id(request, response)
    return ingest(st, db, data, file.filename or "image", user, anon, crop, options)


class UrlIn(BaseModel):
    url: str = Field(..., max_length=2048)
    crop: list[float] | None = None
    options: dict | None = None


@router.post("/images/from-url")
async def upload_from_url(body: UrlIn, request: Request, response: Response, db: DbSession = Depends(get_db), user: User | None = Depends(current_user)):
    st = state(request)
    try:
        fetched = await fetch_image(body.url, max_bytes=MAX_FILE_BYTES, allow_private=st.settings.allow_private_urls)
    except FetchError as exc:
        raise ApiError(exc.code, exc.message) from exc
    anon = anon_id(request, response)
    return ingest(st, db, fetched.data, fetched.filename, user, anon, body.crop, body.options)


@router.get("/examples")
def list_examples():
    return [{"name": e["name"], "title": e["title"], "thumbnail": f"/examples/{e['name']}.png"} for e in _examples()]


@router.post("/examples/{name}")
def use_example(name: str, request: Request, response: Response, db: DbSession = Depends(get_db), user: User | None = Depends(current_user)):
    ex = next((e for e in _examples() if e["name"] == name), None)
    if ex is None:
        raise ApiError("not_found")
    data = (EXAMPLES_DIR / f"{name}.png").read_bytes()
    anon = anon_id(request, response)
    return ingest(state(request), db, data, f"{name}.png", user, anon, None, None, is_example=True)


def _image_json(img: Image, job: Job | None, st: AppState) -> dict:
    live = st.jobs.get(job.id) if job else None
    return {
        "token": img.token,
        "filename": img.filename,
        "format": img.source_format,
        "width": img.width,
        "height": img.height,
        "crop": img.crop,
        "status": live.status if live else img.status,
        "options": img.options,
        "edits": img.edits or {},
        "stats": img.stats or {},
        "isExample": img.is_example,
        "createdAt": img.created_at.isoformat() + "Z",
        "expiresAt": img.expires_at.isoformat() + "Z",
        "hasResult": st.storage.has_graph(img.token),
        "job": (live.public() if live else _job_row(job)) if job else None,
    }


def _job_row(job: Job) -> dict:
    return {"id": job.id, "token": job.image_token, "status": job.status, "stage": job.stage, "progress": job.progress, "message": job.message, "error_code": job.error_code, "error_message": job.error_message, "attempts": job.attempts, "queue_position": 0}


def _latest_job(db: DbSession, token: str) -> Job | None:
    return db.scalar(select(Job).where(Job.image_token == token).order_by(Job.created_at.desc()).limit(1))


@router.get("/images")
def history(request: Request, db: DbSession = Depends(get_db), user: User | None = Depends(current_user)):
    anon = request.cookies.get("vz_anon")
    q = select(Image).where(Image.origin == "web")
    if user is not None:
        q = q.where(Image.user_id == user.id)
    elif anon:
        q = q.where(Image.anon_id == anon, Image.user_id.is_(None))
    else:
        return []
    st = state(request)
    imgs = db.scalars(q.order_by(Image.created_at.desc()).limit(200)).all()
    return [
        {"token": i.token, "filename": i.filename, "status": i.status, "width": i.width, "height": i.height, "createdAt": i.created_at.isoformat() + "Z", "expiresAt": i.expires_at.isoformat() + "Z", "hasResult": st.storage.has_graph(i.token), "isExample": i.is_example, "colors": (i.stats or {}).get("colors"), "shapes": (i.stats or {}).get("shapes")}
        for i in imgs
    ]


def _img(request: Request, token: str, db: DbSession, user: User | None) -> Image:
    return owned_image(db, token, user, request.cookies.get("vz_anon"))


@router.get("/images/{token}")
def get_image(token: str, request: Request, db: DbSession = Depends(get_db), user: User | None = Depends(current_user)):
    img = _img(request, token, db, user)
    return _image_json(img, _latest_job(db, token), state(request))


@router.get("/images/{token}/source.png")
def source_png(token: str, request: Request, db: DbSession = Depends(get_db), user: User | None = Depends(current_user)):
    _img(request, token, db, user)
    p = state(request).storage.preview_path(token)
    if not p.exists():
        raise ApiError("not_ready")
    return FileResponse(p, media_type="image/png", headers={"Cache-Control": "private, max-age=3600"})


@router.get("/images/{token}/thumb.png")
def thumb_png(token: str, request: Request, db: DbSession = Depends(get_db), user: User | None = Depends(current_user)):
    _img(request, token, db, user)
    p = state(request).storage.thumb_path(token)
    if not p.exists():
        raise ApiError("not_ready")
    return FileResponse(p, media_type="image/png", headers={"Cache-Control": "private, max-age=3600"})


@router.get("/images/{token}/graph")
def graph(token: str, request: Request, db: DbSession = Depends(get_db), user: User | None = Depends(current_user)):
    _img(request, token, db, user)
    p = state(request).storage.graph_path(token)
    if not p.exists():
        raise ApiError("not_ready")
    data = p.read_bytes()
    if "gzip" in request.headers.get("accept-encoding", ""):
        return Response(data, media_type="application/json", headers={"Content-Encoding": "gzip", "Vary": "Accept-Encoding", "Cache-Control": "no-store"})
    import gzip

    return Response(gzip.decompress(data), media_type="application/json")


class ReprocessIn(BaseModel):
    options: dict = Field(default_factory=dict)


@router.post("/images/{token}/reprocess")
def reprocess(token: str, body: ReprocessIn, request: Request, db: DbSession = Depends(get_db), user: User | None = Depends(current_user)):
    img = _img(request, token, db, user)
    st = state(request)
    options = _parse_options(body.options)
    job = start_job(st, db, img, options)
    return {"token": token, "jobId": job.id}


@router.put("/images/{token}/edits")
async def save_edits(token: str, request: Request, db: DbSession = Depends(get_db), user: User | None = Depends(current_user)):
    img = _img(request, token, db, user)
    raw = await request.body()
    if len(raw) > 4 * 1024 * 1024:
        raise ApiError("invalid_request", "Edit state is too large.")
    try:
        edits = EditState.from_json(json.loads(raw or b"{}"))
    except (ValueError, TypeError, AttributeError) as exc:
        raise ApiError("invalid_request", f"Invalid edits: {exc}") from exc
    img.edits = edits.to_json()
    return {"ok": True}


class BackgroundIn(BaseModel):
    method: str = "auto"
    includeEnclosed: bool = False


@router.post("/images/{token}/background")
def background(token: str, body: BackgroundIn, request: Request, db: DbSession = Depends(get_db), user: User | None = Depends(current_user)):
    _img(request, token, db, user)
    st = state(request)
    if not st.storage.has_graph(token):
        raise ApiError("not_ready")
    g = VectorGraph.from_json(st.storage.load_graph_json(token))
    rgba = None
    if body.method in ("auto", "grabcut", "neural") and st.storage.preview_path(token).exists():
        import cv2

        bgra = cv2.imread(str(st.storage.preview_path(token)), cv2.IMREAD_UNCHANGED)
        if bgra is not None:
            rgba = cv2.cvtColor(bgra, cv2.COLOR_BGRA2RGBA) if bgra.shape[2] == 4 else cv2.cvtColor(bgra, cv2.COLOR_BGR2RGBA)
    try:
        return detect_background(g, rgba, body.method, body.includeEnclosed)
    except ValueError as exc:
        raise ApiError("invalid_request", str(exc)) from exc


def can_download(db: DbSession, img: Image, user: User | None) -> bool:
    if img.is_example:
        return True
    return user is not None and active_subscription(db, user.id, "web") is not None


@router.get("/images/{token}/download")
def download(token: str, request: Request, db: DbSession = Depends(get_db), user: User | None = Depends(current_user)):
    img = _img(request, token, db, user)
    st = state(request)
    if not st.storage.has_graph(token):
        raise ApiError("not_ready")
    if not can_download(db, img, user):
        raise ApiError("subscription_required", "Downloading requires a Pro subscription (examples are free to download).")
    params = dict(request.query_params)
    if "format" in params:
        params["output.file_format"] = params.pop("format")
    try:
        eopts = parse_export_public(params)
    except ExportError as exc:
        raise ApiError("invalid_output_option", str(exc)) from exc
    g = VectorGraph.from_json(st.storage.load_graph_json(token))
    edits = EditState.from_json(img.edits or {})
    g = apply_edits(g, edits, merge_same_color=params.get("merge", "true") != "false")
    try:
        data = export(g, eopts)
    except RasterTooLarge as exc:
        raise ApiError("output_too_large", str(exc)) from exc
    base = re.sub(r"\.[A-Za-z0-9]+$", "", img.filename) or "vectorized"
    fname = f"{base}.{eopts.file_format}"
    return Response(data, media_type=MIME[eopts.file_format], headers={"Content-Disposition": f'attachment; filename="{fname}"', "Cache-Control": "no-store"})


@router.delete("/images/{token}")
def delete_image(token: str, request: Request, db: DbSession = Depends(get_db), user: User | None = Depends(current_user)):
    img = _img(request, token, db, user)
    st = state(request)
    for job in db.scalars(select(Job).where(Job.image_token == token)):
        st.jobs.cancel(job.id)
        db.delete(job)
    db.delete(img)
    st.storage.delete(token)
    return {"ok": True}
