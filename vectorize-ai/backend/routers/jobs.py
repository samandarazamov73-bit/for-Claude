"""Job status, live progress (Server-Sent Events), cancel and retry."""
from __future__ import annotations

import asyncio
import json

from fastapi import APIRouter, Depends, Request
from fastapi.responses import StreamingResponse
from sqlalchemy.orm import Session as DbSession

from api.errors import ApiError
from database import Image, Job, User
from workers import TERMINAL

from ..deps import current_user, get_db, owned_image, start_job, state

router = APIRouter(prefix="/api/jobs", tags=["web"])


def _job(db: DbSession, job_id: str, request: Request, user: User | None) -> Job:
    job = db.get(Job, job_id)
    if job is None:
        raise ApiError("not_found")
    owned_image(db, job.image_token, user, request.cookies.get("vz_anon"))
    return job


def _row(job: Job) -> dict:
    return {"id": job.id, "token": job.image_token, "status": job.status, "stage": job.stage, "progress": job.progress, "message": job.message, "error_code": job.error_code, "error_message": job.error_message, "attempts": job.attempts, "queue_position": 0}


@router.get("/{job_id}")
def get_job(job_id: str, request: Request, db: DbSession = Depends(get_db), user: User | None = Depends(current_user)):
    job = _job(db, job_id, request, user)
    live = state(request).jobs.get(job_id)
    return live.public() if live else _row(job)


@router.get("/{job_id}/events")
async def job_events(job_id: str, request: Request, db: DbSession = Depends(get_db), user: User | None = Depends(current_user)):
    job = _job(db, job_id, request, user)
    jobs = state(request).jobs
    live = jobs.get(job_id)
    initial = live.public() if live else _row(job)
    db.close()

    async def stream():
        q = jobs.subscribe(job_id)
        try:
            yield f"event: progress\ndata: {json.dumps(initial)}\n\n"
            if initial["status"] in TERMINAL:
                return
            while True:
                if await request.is_disconnected():
                    return
                try:
                    payload = await asyncio.wait_for(q.get(), 15)
                except asyncio.TimeoutError:
                    yield ": keep-alive\n\n"
                    continue
                yield f"event: progress\ndata: {json.dumps(payload)}\n\n"
                if payload["status"] in TERMINAL:
                    return
        finally:
            jobs.unsubscribe(job_id, q)

    return StreamingResponse(stream(), media_type="text/event-stream", headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"})


@router.post("/{job_id}/cancel")
def cancel(job_id: str, request: Request, db: DbSession = Depends(get_db), user: User | None = Depends(current_user)):
    _job(db, job_id, request, user)
    return {"cancelled": state(request).jobs.cancel(job_id)}


@router.post("/{job_id}/retry")
def retry(job_id: str, request: Request, db: DbSession = Depends(get_db), user: User | None = Depends(current_user)):
    job = _job(db, job_id, request, user)
    if job.status not in ("failed", "cancelled"):
        raise ApiError("invalid_request", "Only failed or cancelled jobs can be retried.")
    img = db.query(Image).filter(Image.token == job.image_token).one()
    new = start_job(state(request), db, img, job.options or img.options)
    return {"token": img.token, "jobId": new.id}
