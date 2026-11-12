"""Job queue and worker pool.

* An ``asyncio.Queue`` feeds ``N`` consumers; each consumer runs one job at a
  time in a ``ProcessPoolExecutor`` (spawned interpreters, so a crash or
  out-of-memory kill never takes the web server down).
* Workers stream progress through a multiprocessing queue; a pump thread
  forwards updates to the event loop, where subscribers (SSE streams,
  synchronous API calls) are notified.
* Cancellation sets a shared flag the pipeline polls at every progress
  report. Jobs exceeding the time budget are cancelled the same way.
* Broken worker pools are rebuilt and the job retried (up to ``MAX_ATTEMPTS``).
"""
from __future__ import annotations

import asyncio
import concurrent.futures as cf
import logging
import multiprocessing as mp
import queue as queue_mod
import threading
import time
from dataclasses import asdict, dataclass, field
from typing import Callable

from database import Database, Image, Job, utcnow

from .tasks import run_vectorize_job

log = logging.getLogger("vectorize.workers")

TERMINAL = ("completed", "failed", "cancelled")
MAX_ATTEMPTS = 3


@dataclass
class LiveJob:
    id: str
    token: str
    status: str = "queued"
    stage: str = ""
    progress: float = 0.0
    message: str = "Waiting for a worker"
    error_code: str | None = None
    error_message: str | None = None
    attempts: int = 0
    queue_position: int = 0
    created: float = field(default_factory=time.time)
    started: float | None = None
    finished: float | None = None
    stats: dict | None = None

    def public(self) -> dict:
        d = asdict(self)
        d.pop("stats", None)
        d["progress"] = round(self.progress, 4)
        d["elapsed"] = round((self.finished or time.time()) - (self.started or self.created), 2)
        return d


class Overloaded(Exception):
    pass


class JobManager:
    def __init__(self, db: Database, data_dir: str, workers: int = 2, mode: str = "process", timeout: float = 180.0, max_queue: int = 200):
        self.db = db
        self.data_dir = str(data_dir)
        self.workers = max(1, workers)
        self.mode = mode
        self.timeout = timeout
        self.max_queue = max_queue
        self.jobs: dict[str, LiveJob] = {}
        self.specs: dict[str, dict] = {}
        self.subscribers: dict[str, set[asyncio.Queue]] = {}
        self.done_events: dict[str, asyncio.Event] = {}
        self.order: list[str] = []
        self.on_complete: list[Callable[[LiveJob], None]] = []
        self._queue: asyncio.Queue | None = None
        self._tasks: list[asyncio.Task] = []
        self._loop: asyncio.AbstractEventLoop | None = None
        self._executor: cf.Executor | None = None
        self._mp_manager = None
        self._stop = threading.Event()
        self._pump: threading.Thread | None = None

    # ------------------------------------------------------------------
    def _make_executor(self) -> cf.Executor:
        if self.mode == "thread":
            return cf.ThreadPoolExecutor(max_workers=self.workers, thread_name_prefix="vz-worker")
        return cf.ProcessPoolExecutor(max_workers=self.workers, mp_context=mp.get_context("spawn"))

    async def start(self) -> None:
        self._loop = asyncio.get_running_loop()
        self._queue = asyncio.Queue()
        if self.mode == "thread":
            self.progress_q = queue_mod.Queue()
            self.cancel_flags: dict = {}
        else:
            self._mp_manager = mp.get_context("spawn").Manager()
            self.progress_q = self._mp_manager.Queue()
            self.cancel_flags = self._mp_manager.dict()
        self._executor = self._make_executor()
        self._recover_interrupted()
        self._pump = threading.Thread(target=self._pump_progress, name="vz-progress", daemon=True)
        self._pump.start()
        self._tasks = [asyncio.create_task(self._consumer(i)) for i in range(self.workers)]

    async def stop(self) -> None:
        self._stop.set()
        for t in self._tasks:
            t.cancel()
        await asyncio.gather(*self._tasks, return_exceptions=True)
        if self._executor:
            self._executor.shutdown(wait=False, cancel_futures=True)
        if self._mp_manager:
            try:
                self._mp_manager.shutdown()
            except Exception:  # noqa: BLE001
                pass

    def _recover_interrupted(self) -> None:
        with self.db.session() as s:
            for job in s.query(Job).filter(Job.status.notin_(TERMINAL)).all():
                job.status = "failed"
                job.error_code = "interrupted"
                job.error_message = "The server restarted while this job was running. Retry to process it again."
                job.finished_at = utcnow()

    # ------------------------------------------------------------------
    def submit(self, job_id: str, token: str, options: dict, crop: list | None) -> LiveJob:
        if self._queue is None:
            raise RuntimeError("job manager not started")
        if self._queue.qsize() >= self.max_queue:
            raise Overloaded()
        live = LiveJob(job_id, token)
        self.jobs[job_id] = live
        self.specs[job_id] = {"job_id": job_id, "token": token, "options": options, "crop": crop, "data_dir": self.data_dir}
        self.done_events[job_id] = asyncio.Event()
        self.order.append(job_id)
        self._queue.put_nowait(job_id)
        self._update_positions()
        return live

    def cancel(self, job_id: str) -> bool:
        live = self.jobs.get(job_id)
        if live is None or live.status in TERMINAL:
            return False
        self.cancel_flags[job_id] = True
        if live.status == "queued":
            self._finish(live, "cancelled", "cancelled", "Processing was cancelled.")
        return True

    def get(self, job_id: str) -> LiveJob | None:
        return self.jobs.get(job_id)

    def subscribe(self, job_id: str) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue()
        self.subscribers.setdefault(job_id, set()).add(q)
        return q

    def unsubscribe(self, job_id: str, q: asyncio.Queue) -> None:
        self.subscribers.get(job_id, set()).discard(q)

    async def wait(self, job_id: str, timeout: float | None = None) -> LiveJob:
        ev = self.done_events.get(job_id)
        if ev is not None:
            await asyncio.wait_for(ev.wait(), timeout)
        return self.jobs[job_id]

    @property
    def queue_length(self) -> int:
        return self._queue.qsize() if self._queue else 0

    # ------------------------------------------------------------------
    def _notify(self, live: LiveJob) -> None:
        payload = live.public()
        for q in list(self.subscribers.get(live.id, ())):
            q.put_nowait(payload)

    def _update_positions(self) -> None:
        pos = 0
        for jid in list(self.order):
            j = self.jobs.get(jid)
            if j is None or j.status != "queued":
                continue
            pos += 1
            if j.queue_position != pos:
                j.queue_position = pos
                j.message = f"Waiting for a worker (position {pos})"
                self._notify(j)

    def _pump_progress(self) -> None:
        while not self._stop.is_set():
            try:
                item = self.progress_q.get(timeout=0.25)
            except queue_mod.Empty:
                continue
            except (EOFError, OSError, BrokenPipeError):
                break
            if self._loop and not self._loop.is_closed():
                self._loop.call_soon_threadsafe(self._apply_progress, item)

    def _apply_progress(self, item) -> None:
        job_id, phase, stage, frac, msg = item
        live = self.jobs.get(job_id)
        if live is None or live.status in TERMINAL:
            return
        changed_phase = live.status != phase
        live.status, live.stage, live.message = phase, stage, msg
        live.progress = max(live.progress, frac)
        if changed_phase:
            self._db_job(live)
        self._notify(live)

    def _db_job(self, live: LiveJob, result: dict | None = None) -> None:
        try:
            with self.db.session() as s:
                job = s.get(Job, live.id)
                if job is None:
                    return
                job.status, job.stage, job.progress, job.message = live.status, live.stage, live.progress, live.message[:255]
                job.error_code, job.error_message, job.attempts = live.error_code, live.error_message, live.attempts
                if live.started and job.started_at is None:
                    job.started_at = utcnow()
                if live.status in TERMINAL:
                    job.finished_at = utcnow()
                img = s.query(Image).filter(Image.token == live.token).one_or_none()
                if img is not None:
                    img.status = live.status
                    if result and result.get("ok"):
                        img.stats = result.get("stats") or {}
        except Exception:  # noqa: BLE001 - status persistence must not kill the queue
            log.exception("failed to persist job %s", live.id)

    def _finish(self, live: LiveJob, status: str, code: str | None = None, message: str | None = None, result: dict | None = None) -> None:
        live.status = status
        live.finished = time.time()
        live.queue_position = 0
        if status == "completed":
            live.progress, live.stage, live.message = 1.0, "done", "Completed"
            live.stats = (result or {}).get("stats")
        else:
            live.error_code, live.error_message = code, message
            live.message = message or status
        self._db_job(live, result)
        self._notify(live)
        ev = self.done_events.get(live.id)
        if ev:
            ev.set()
        self.cancel_flags.pop(live.id, None)
        if live.id in self.order:
            self.order.remove(live.id)
        self.specs.pop(live.id, None)
        for cb in self.on_complete:
            try:
                cb(live)
            except Exception:  # noqa: BLE001
                log.exception("on_complete callback failed")
        self._update_positions()

    async def _consumer(self, idx: int) -> None:
        assert self._queue is not None
        while True:
            job_id = await self._queue.get()
            try:
                await self._run(job_id)
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001
                log.exception("job %s crashed the consumer", job_id)
                live = self.jobs.get(job_id)
                if live and live.status not in TERMINAL:
                    self._finish(live, "failed", "internal_error", "Unexpected server error.")
            finally:
                self._queue.task_done()

    async def _run(self, job_id: str) -> None:
        live = self.jobs.get(job_id)
        spec = self.specs.get(job_id)
        if live is None or spec is None or live.status in TERMINAL:
            return
        loop = asyncio.get_running_loop()
        while True:
            live.attempts += 1
            live.status, live.stage, live.message = "preparing", "decode", "Starting"
            live.started = live.started or time.time()
            live.queue_position = 0
            self._db_job(live)
            self._notify(live)
            self._update_positions()
            fut = loop.run_in_executor(self._executor, run_vectorize_job, spec, self.progress_q, self.cancel_flags)
            # higher detail levels legitimately take longer
            detail = str((spec.get("options") or {}).get("detail", "normal"))
            budget = self.timeout * {"high": 1.5, "max": 3.0}.get(detail, 1.0)
            try:
                result = await asyncio.wait_for(asyncio.shield(fut), budget)
            except asyncio.TimeoutError:
                self.cancel_flags[job_id] = True
                try:
                    await asyncio.wait_for(fut, 30)
                except Exception:  # noqa: BLE001
                    pass
                self._finish(live, "failed", "timeout", f"Processing exceeded the {int(budget)} s time budget.")
                return
            except cf.process.BrokenProcessPool:
                log.warning("worker pool broke while running %s (attempt %d)", job_id, live.attempts)
                self._executor = self._make_executor()
                if live.attempts < MAX_ATTEMPTS:
                    await asyncio.sleep(0.5 * live.attempts)
                    continue
                self._finish(live, "failed", "worker_crashed", "The worker process crashed repeatedly while processing this image.")
                return
            if result.get("ok"):
                self._finish(live, "completed", result=result)
                return
            code = result.get("code", "processing_error")
            if code == "cancelled":
                self._finish(live, "cancelled", code, result.get("message"))
                return
            if result.get("retryable") and live.attempts < MAX_ATTEMPTS and code == "out_of_memory":
                await asyncio.sleep(0.5 * live.attempts)
                continue
            if result.get("trace"):
                log.error("job %s failed: %s", job_id, result["trace"])
            self._finish(live, "failed", code, result.get("message"))
            return
