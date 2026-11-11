"""FastAPI application factory."""
from __future__ import annotations

import asyncio
import contextlib
import logging
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.openapi.docs import get_swagger_ui_html
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from sqlalchemy import select
from starlette.exceptions import HTTPException as StarletteHTTPException

from api import v1
from api.errors import ApiError
from api.openapi import build_openapi
from database import Image, Job, utcnow

from .config import Settings
from .deps import AppState
from .routers import accounts, images, jobs, meta
from .routers.images import EXAMPLES_DIR
from .security import SecurityMiddleware

log = logging.getLogger("vectorize")
SWEEP_SECONDS = 600


def sweep_expired(st: AppState) -> int:
    """Delete expired images (and their files) that are not being processed."""
    removed = 0
    with st.db.session() as db:
        for img in db.scalars(select(Image).where(Image.expires_at < utcnow()).limit(500)).all():
            busy = db.scalar(select(Job).where(Job.image_token == img.token, Job.status.notin_(("completed", "failed", "cancelled"))))
            if busy is not None:
                continue
            for j in db.scalars(select(Job).where(Job.image_token == img.token)):
                db.delete(j)
            db.delete(img)
            st.storage.delete(img.token)
            removed += 1
    return removed


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    st = AppState.build(settings)

    @contextlib.asynccontextmanager
    async def lifespan(app: FastAPI):
        await st.jobs.start()

        async def sweeper():
            while True:
                try:
                    n = await asyncio.to_thread(sweep_expired, st)
                    if n:
                        log.info("retention sweep removed %d images", n)
                except Exception:  # noqa: BLE001
                    log.exception("retention sweep failed")
                await asyncio.sleep(SWEEP_SECONDS)

        task = asyncio.create_task(sweeper())
        try:
            yield
        finally:
            task.cancel()
            await st.jobs.stop()

    app = FastAPI(
        title="Vectorize AI (internal web API)",
        version="1.0.0",
        lifespan=lifespan,
        docs_url=None,
        redoc_url=None,
        openapi_url="/api/internal/openapi.json",
    )
    app.state.vz = st

    @app.exception_handler(ApiError)
    async def _api_error(request: Request, exc: ApiError):
        return exc.response(numeric=request.url.path.startswith("/api/v1/"))

    @app.exception_handler(RequestValidationError)
    async def _validation(request: Request, exc: RequestValidationError):
        first = exc.errors()[0] if exc.errors() else {}
        msg = f"{'.'.join(str(p) for p in first.get('loc', [])[1:])}: {first.get('msg', 'invalid request')}"
        return ApiError("invalid_request", msg).response(numeric=request.url.path.startswith("/api/v1/"))

    @app.exception_handler(StarletteHTTPException)
    async def _http(request: Request, exc: StarletteHTTPException):
        key = "not_found" if exc.status_code == 404 else "invalid_request"
        return ApiError(key, str(exc.detail), exc.status_code).response(numeric=request.url.path.startswith("/api/v1/"))

    app.add_middleware(SecurityMiddleware, rate_limits=settings.rate_limits_enabled)
    if settings.cors_origins:
        app.add_middleware(CORSMiddleware, allow_origins=settings.cors_origins, allow_credentials=True, allow_methods=["*"], allow_headers=["*"])

    app.include_router(meta.router)
    app.include_router(accounts.router)
    app.include_router(images.router)
    app.include_router(jobs.router)
    app.include_router(v1.router)

    spec_cache: dict = {}

    @app.get("/api/openapi.json", include_in_schema=False)
    def public_openapi():
        if "spec" not in spec_cache:
            spec_cache["spec"] = build_openapi(settings.public_url)
        return JSONResponse(spec_cache["spec"])

    @app.get("/api/docs", include_in_schema=False)
    def swagger():
        return get_swagger_ui_html(openapi_url="/api/openapi.json", title="Vectorize AI API – Swagger UI")

    if EXAMPLES_DIR.exists():
        app.mount("/examples", StaticFiles(directory=EXAMPLES_DIR), name="examples")

    dist = Path(settings.frontend_dist)
    if dist.exists() and (dist / "index.html").exists():
        if (dist / "assets").exists():
            app.mount("/assets", StaticFiles(directory=dist / "assets"), name="assets")

        @app.get("/{path:path}", include_in_schema=False)
        def spa(path: str):
            if path.startswith("api/"):
                return ApiError("not_found").response(numeric=False)
            target = (dist / path).resolve()
            if path and target.is_file() and dist.resolve() in target.parents:
                return FileResponse(target)
            return FileResponse(dist / "index.html", headers={"Cache-Control": "no-cache"})
    else:

        @app.get("/", include_in_schema=False)
        def no_frontend():
            return HTMLResponse("<h1>Vectorize AI API</h1><p>The web frontend is not built. Run <code>npm run build</code> in <code>frontend/</code>. API docs: <a href='/api/docs'>/api/docs</a></p>")

    return app
