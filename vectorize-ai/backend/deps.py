"""Application state and FastAPI dependencies."""
from __future__ import annotations

import datetime as dt
import secrets
import uuid
from dataclasses import dataclass
from typing import Iterator

from fastapi import Depends, Request, Response
from sqlalchemy import select
from sqlalchemy.orm import Session as DbSession

import auth
from api.errors import ApiError
from billing.provider import PaymentProvider, StripeProvider
from database import Database, Image, Job, User, utcnow
from workers import JobManager, Overloaded

from .config import Settings
from .storage import Storage

SESSION_COOKIE = "vz_session"
ANON_COOKIE = "vz_anon"


@dataclass
class AppState:
    settings: Settings
    db: Database
    storage: Storage
    jobs: JobManager
    payments: PaymentProvider | None

    @classmethod
    def build(cls, settings: Settings) -> "AppState":
        db = Database(settings.database_url)
        db.create_all()
        storage = Storage(settings.data_dir)
        jobs = JobManager(db, str(settings.data_dir), settings.workers, settings.worker_mode, settings.job_timeout, settings.max_queue)
        payments = None
        if settings.payments_configured:
            payments = StripeProvider(settings.stripe_secret_key, settings.stripe_webhook_secret, settings.stripe_prices)
        return cls(settings, db, storage, jobs, payments)


def state(request: Request) -> AppState:
    return request.app.state.vz


def get_db(request: Request) -> Iterator[DbSession]:
    with state(request).db.session() as s:
        yield s


def current_user(request: Request, db: DbSession = Depends(get_db)) -> User | None:
    return auth.session_user(db, request.cookies.get(SESSION_COOKIE))


def require_user(user: User | None = Depends(current_user)) -> User:
    if user is None:
        raise ApiError("not_authenticated")
    return user


def anon_id(request: Request, response: Response) -> str:
    """Stable anonymous visitor id (HttpOnly cookie) so visitors can return
    to their images without an account."""
    aid = request.cookies.get(ANON_COOKIE)
    if not aid or len(aid) > 64:
        aid = secrets.token_urlsafe(24)
        s = state(request).settings
        response.set_cookie(ANON_COOKIE, aid, max_age=60 * 60 * 24 * 30, httponly=True, samesite="lax", secure=s.cookie_secure)
    return aid


def set_session_cookie(response: Response, token: str, settings: Settings) -> None:
    response.set_cookie(SESSION_COOKIE, token, max_age=60 * 60 * 24 * auth.SESSION_DAYS, httponly=True, samesite="lax", secure=settings.cookie_secure, path="/")


def owned_image(db: DbSession, token: str, user: User | None, anon: str | None) -> Image:
    img = db.scalar(select(Image).where(Image.token == token))
    if img is None or img.origin != "web":
        raise ApiError("image_not_found")
    if img.user_id is not None:
        if user is None or img.user_id != user.id:
            raise ApiError("image_not_found")
    elif img.anon_id != anon:
        raise ApiError("image_not_found")
    return img


def image_expiry(settings: Settings, user: User | None) -> dt.datetime:
    if user is not None:
        return utcnow() + dt.timedelta(days=settings.user_retention_days)
    return utcnow() + dt.timedelta(hours=settings.anon_retention_hours)


def start_job(st: AppState, db: DbSession, img: Image, options: dict) -> Job:
    """Create the job row and enqueue it (cancelling a running job of the
    same image – its result would be stale)."""
    for old in db.scalars(select(Job).where(Job.image_token == img.token, Job.status.notin_(("completed", "failed", "cancelled")))):
        st.jobs.cancel(old.id)
    job = Job(id=str(uuid.uuid4()), image_token=img.token, options=options, status="queued")
    db.add(job)
    img.options = options
    img.status = "queued"
    db.flush()
    db.commit()
    try:
        st.jobs.submit(job.id, img.token, options, img.crop)
    except Overloaded as exc:
        job.status = "failed"
        job.error_code = "overloaded"
        raise ApiError("overloaded", headers={"Retry-After": "30"}) from exc
    return job
