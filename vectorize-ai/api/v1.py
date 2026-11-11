"""Public REST API v1.

    POST /api/v1/vectorize   multipart: image | image.url | image.base64 | image.token
    POST /api/v1/download    multipart: image.token, receipt, output.*
    POST /api/v1/delete      multipart: image.token
    GET  /api/v1/account

Authentication: HTTP Basic with API Id (user) and API Secret (password).
Results are returned synchronously as the file itself."""
from __future__ import annotations

import base64
import binascii
import datetime as dt
import hashlib
import hmac
import json
import re
import time
import uuid

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, Response
from sqlalchemy import select
from starlette.background import BackgroundTask
from starlette.datastructures import UploadFile

import auth
from billing import credits
from billing.plans import PRICE_MILLI, fmt_credits, retention_cost_milli
from billing.service import account_summary
from database import ApiKey, ApiUsage, Image, Job, utcnow
from export_engine import MIME, ExportError, ExportOptions, RasterTooLarge, export, parse_export_public
from image_processing import MAX_BASE64_BYTES, MAX_FILE_BYTES, ImageDecodeError, probe_size
from vectorization_engine import OptionError, VectorGraph, parse_public
from workers import Overloaded

from .errors import ApiError

router = APIRouter(prefix="/api/v1", tags=["public-api"])
MODES = ("production", "preview", "test", "test_preview")
PREVIEW_MAX_PIXELS = 16_000_000


def _st(request: Request):
    return request.app.state.vz


def authenticate(request: Request, db) -> ApiKey:
    creds = auth.parse_basic(request.headers.get("authorization"))
    challenge = {"WWW-Authenticate": 'Basic realm="Vectorize AI API Id and API Secret"'}
    if creds is None:
        raise ApiError("unauthorized", headers=challenge)
    key = auth.verify_api_key(db, *creds)
    if key is None:
        raise ApiError("unauthorized", headers=challenge)
    return key


def make_receipt(secret: str, token: str, mode: str) -> str:
    body = base64.urlsafe_b64encode(json.dumps({"t": token, "m": mode, "iat": int(time.time())}, separators=(",", ":")).encode()).decode().rstrip("=")
    sig = hmac.new(secret.encode(), body.encode(), hashlib.sha256).hexdigest()[:32]
    return f"{body}.{sig}"


def check_receipt(secret: str, receipt: str, token: str) -> dict | None:
    try:
        body, sig = receipt.rsplit(".", 1)
        if not hmac.compare_digest(sig, hmac.new(secret.encode(), body.encode(), hashlib.sha256).hexdigest()[:32]):
            return None
        data = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
    except (ValueError, binascii.Error, json.JSONDecodeError):
        return None
    return data if data.get("t") == token else None


def _usage(db, key: ApiKey, endpoint: str, mode: str | None, status: int, milli: int, token: str | None) -> None:
    db.add(ApiUsage(user_id=key.user_id, api_key_id=key.id, endpoint=endpoint, mode=mode, status_code=status, credits_milli=milli, image_token=token))


async def _form(request: Request):
    try:
        return await request.form(max_files=2, max_fields=200, max_part_size=MAX_BASE64_BYTES * 2)
    except Exception as exc:  # noqa: BLE001 - malformed multipart bodies
        raise ApiError("invalid_request", f"Could not parse multipart form: {exc}") from exc


def _field(form, name: str) -> str | None:
    v = form.get(name)
    if v is None or isinstance(v, UploadFile):
        return None
    return str(v)


def _export_opts(form, *, fmt_default: str = "svg") -> ExportOptions:
    params = {k: _field(form, k) for k in form.keys() if k.startswith("output.")}
    params.setdefault("output.file_format", fmt_default)
    try:
        return parse_export_public(params)
    except ExportError as exc:
        raise ApiError("invalid_output_option", str(exc)) from exc


def _preview_scale(g: VectorGraph) -> float:
    w = g.width / g.scale if g.scale else g.width
    h = g.height / g.scale if g.scale else g.height
    return max(0.25, min(4.0, (PREVIEW_MAX_PIXELS / max(1.0, w * h)) ** 0.5))


def _render(g: VectorGraph, mode: str, eopts: ExportOptions) -> tuple[bytes, str]:
    if mode in ("preview", "test_preview"):
        eopts = ExportOptions.from_dict({**eopts.__dict__, "file_format": "png", "png_scale": _preview_scale(g), "watermark": "preview" if mode == "preview" else "test"})
    elif mode == "test":
        eopts = ExportOptions.from_dict({**eopts.__dict__, "watermark": "test"})
    try:
        return export(g, eopts), eopts.file_format
    except RasterTooLarge as exc:
        raise ApiError("output_too_large", str(exc)) from exc


async def _read_image(form) -> tuple[bytes | None, str, str | None]:
    """Returns (data, filename, token) – exactly one source must be present."""
    up = form.get("image")
    url = _field(form, "image.url")
    b64 = _field(form, "image.base64")
    tok = _field(form, "image.token")
    given = [x for x in (isinstance(up, UploadFile) or None, url, b64, tok) if x]
    if not given:
        raise ApiError("missing_image")
    if len(given) > 1:
        raise ApiError("multiple_images")
    if isinstance(up, UploadFile):
        data = await up.read(MAX_FILE_BYTES + 1)
        if len(data) > MAX_FILE_BYTES:
            raise ApiError("file_too_large")
        return data, up.filename or "image", None
    if b64:
        raw = b64.split(",", 1)[1] if b64.startswith("data:") else b64
        if len(raw) > MAX_BASE64_BYTES * 4 // 3 + 8:
            raise ApiError("invalid_base64")
        try:
            data = base64.b64decode(re.sub(r"\s+", "", raw), validate=True)
        except (binascii.Error, ValueError) as exc:
            raise ApiError("invalid_base64") from exc
        if len(data) > MAX_BASE64_BYTES:
            raise ApiError("invalid_base64")
        return data, "image", None
    if url:
        return None, url, None
    return None, "", tok


@router.post("/vectorize")
async def vectorize_endpoint(request: Request):
    st = _st(request)
    form = await _form(request)
    started = time.time()
    with st.db.session() as db:
        key = authenticate(request, db)
        key_id, user_id = key.id, key.user_id
    mode = _field(form, "mode") or "production"
    if mode not in MODES:
        raise ApiError("invalid_mode")
    try:
        opts = parse_public({k: _field(form, k) for k in form.keys() if k.startswith(("input.", "processing."))})
    except OptionError as exc:
        raise ApiError("invalid_option", str(exc)) from exc
    eopts = _export_opts(form)
    try:
        retention = int(_field(form, "policy.retention_days") or 0)
    except ValueError as exc:
        raise ApiError("invalid_option", "policy.retention_days must be an integer") from exc
    if not 0 <= retention <= 30:
        raise ApiError("invalid_option", "policy.retention_days must be between 0 and 30")
    cost = PRICE_MILLI[mode] + (retention_cost_milli(retention) if mode in ("production", "preview") else 0)

    data, name, reuse_token = await _read_image(form)
    if data is None and reuse_token is None:  # URL input
        from backend.fetch import FetchError, fetch_image

        try:
            fetched = await fetch_image(name, max_bytes=MAX_FILE_BYTES, allow_private=st.settings.allow_private_urls)
        except FetchError as exc:
            raise ApiError(exc.code, exc.message) from exc
        data, name = fetched.data, fetched.filename

    with st.db.session() as db:
        try:
            credits.ensure_available(db, user_id, cost)
        except credits.InsufficientCredits as exc:
            raise ApiError("insufficient_credits", f"This request needs {fmt_credits(exc.needed)} credits; balance is {fmt_credits(exc.balance)}.") from exc
        if reuse_token:
            img = db.scalar(select(Image).where(Image.token == reuse_token, Image.origin == "api", Image.user_id == user_id))
            if img is None or img.expires_at < utcnow() or not st.storage.source_path(reuse_token).exists():
                raise ApiError("image_not_found")
            token = img.token
        else:
            try:
                fmt, w, h = probe_size(data)
            except ImageDecodeError as exc:
                raise ApiError(exc.code if exc.code in ("unsupported_format", "corrupt_image", "empty_file") else "corrupt_image", exc.message) from exc
            from backend.storage import new_token

            token = new_token()
            st.storage.write_source(token, data)
            img = Image(token=token, user_id=user_id, api_key_id=key_id, origin="api", filename=re.sub(r"[^\w.\- ]+", "_", name)[:120] or "image", source_format=fmt, width=w, height=h, size_bytes=len(data), options={}, expires_at=utcnow() + dt.timedelta(days=max(retention, 0), minutes=10))
            db.add(img)
        img.api_mode = mode
        img.upgraded = False
        img.retention_days = retention
        if reuse_token:
            img.expires_at = utcnow() + dt.timedelta(days=max(retention, 0), minutes=10)
        job = Job(id=str(uuid.uuid4()), image_token=token, options=opts.to_dict(), status="queued")
        db.add(job)
        img.options = opts.to_dict()
        job_id = job.id
    try:
        st.jobs.submit(job_id, token, opts.to_dict(), None)
    except Overloaded as exc:
        raise ApiError("overloaded", headers={"Retry-After": "30"}) from exc
    try:
        live = await st.jobs.wait(job_id, st.settings.job_timeout + 60)
    except TimeoutError as exc:
        st.jobs.cancel(job_id)
        raise ApiError("internal_timeout") from exc
    if live.status != "completed":
        code = live.error_code or "processing_error"
        from .errors import ERRORS

        raise ApiError(code if code in ERRORS else "processing_error", live.error_message)

    g = VectorGraph.from_json(st.storage.load_graph_json(token))
    body, fmt = _render(g, mode, eopts)
    with st.db.session() as db:
        try:
            tx = credits.charge(db, user_id, cost, f"api_{mode}", image_token=token, reference=job_id)
        except credits.InsufficientCredits as exc:
            raise ApiError("insufficient_credits") from exc
        key = db.get(ApiKey, key_id)
        _usage(db, key, "vectorize", mode, 200, cost, token)
        del tx
    headers = {
        "X-Credits-Charged": fmt_credits(cost),
        "X-Credits-Calculated": fmt_credits(cost),
        "X-Processing-Seconds": f"{time.time() - started:.2f}",
        "Content-Disposition": f'attachment; filename="result.{fmt}"',
    }
    background = None
    if retention > 0:
        headers["X-Image-Token"] = token
        headers["X-Receipt"] = make_receipt(st.settings.secret_key, token, mode)
    else:
        background = BackgroundTask(_purge, st, token)
    return Response(body, media_type=MIME[fmt], headers=headers, background=background)


def _purge(st, token: str) -> None:
    with st.db.session() as db:
        img = db.scalar(select(Image).where(Image.token == token))
        if img is not None:
            for j in db.scalars(select(Job).where(Job.image_token == token)):
                db.delete(j)
            db.delete(img)
    st.storage.delete(token)


def _api_image(st, db, user_id: int, token: str | None) -> Image:
    if not token:
        raise ApiError("missing_image", "image.token is required.")
    img = db.scalar(select(Image).where(Image.token == token, Image.origin == "api", Image.user_id == user_id))
    if img is None or img.expires_at < utcnow() or not st.storage.has_graph(token):
        raise ApiError("image_not_found")
    return img


@router.post("/download")
async def download_endpoint(request: Request):
    st = _st(request)
    form = await _form(request)
    eopts = _export_opts(form)
    token = _field(form, "image.token")
    receipt = _field(form, "receipt")
    with st.db.session() as db:
        key = authenticate(request, db)
        img = _api_image(st, db, key.user_id, token)
        mode = img.api_mode or "production"
        if mode in ("test", "test_preview"):
            cost, render_mode, reason = 0, "test", "api_download_test"
        elif mode == "preview" and not img.upgraded:
            if not receipt or check_receipt(st.settings.secret_key, receipt, img.token) is None:
                raise ApiError("invalid_receipt", "Upgrading a preview needs the X-Receipt value returned by /vectorize.")
            cost, render_mode, reason = PRICE_MILLI["upgrade_preview"], "production", "api_upgrade_preview"
        else:
            cost, render_mode, reason = PRICE_MILLI["extra_format"], "production", "api_extra_format"
        try:
            credits.ensure_available(db, key.user_id, cost)
        except credits.InsufficientCredits as exc:
            raise ApiError("insufficient_credits", f"This download needs {fmt_credits(exc.needed)} credits.") from exc
        user_id, key_id = key.user_id, key.id
    g = VectorGraph.from_json(st.storage.load_graph_json(token))
    body, fmt = _render(g, render_mode, eopts)
    with st.db.session() as db:
        credits.charge(db, user_id, cost, reason, image_token=token)
        img = db.scalar(select(Image).where(Image.token == token))
        if reason == "api_upgrade_preview":
            img.upgraded = True
        _usage(db, db.get(ApiKey, key_id), "download", img.api_mode, 200, cost, token)
    return Response(body, media_type=MIME[fmt], headers={"X-Credits-Charged": fmt_credits(cost), "X-Credits-Calculated": fmt_credits(cost), "X-Image-Token": token, "Content-Disposition": f'attachment; filename="result.{fmt}"'})


@router.post("/delete")
async def delete_endpoint(request: Request):
    st = _st(request)
    form = await _form(request)
    token = _field(form, "image.token")
    with st.db.session() as db:
        key = authenticate(request, db)
        img = db.scalar(select(Image).where(Image.token == (token or ""), Image.origin == "api", Image.user_id == key.user_id))
        if img is None:
            raise ApiError("image_not_found")
        _usage(db, key, "delete", None, 200, 0, token)
    _purge(st, token)
    return {"success": True}


@router.get("/account")
def account_endpoint(request: Request):
    st = _st(request)
    with st.db.session() as db:
        key = authenticate(request, db)
        summary = account_summary(db, key.user)
        _usage(db, key, "account", None, 200, 0, None)
    return JSONResponse({"subscriptionPlan": summary["apiPlan"] or "none", "subscriptionState": summary["apiState"], "credits": summary["credits"]})
