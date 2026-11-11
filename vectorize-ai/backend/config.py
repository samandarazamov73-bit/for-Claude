"""Runtime configuration (environment variables, ``VZ_`` prefix)."""
from __future__ import annotations

import os
import secrets
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _bool(v: str | None, default: bool) -> bool:
    if v is None:
        return default
    return v.strip().lower() in ("1", "true", "yes", "on")


@dataclass
class Settings:
    data_dir: Path = ROOT / "storage"
    database_url: str = ""
    secret_key: str = ""
    public_url: str = "http://localhost:8000"
    workers: int = max(1, min(4, (os.cpu_count() or 2) - 1))
    worker_mode: str = "process"  # process | thread
    job_timeout: float = 180.0
    max_queue: int = 200
    anon_retention_hours: int = 24
    user_retention_days: int = 30
    allow_private_urls: bool = False  # tests only - disables SSRF IP checks
    cookie_secure: bool = False
    cors_origins: list[str] = field(default_factory=list)
    frontend_dist: Path = ROOT / "frontend" / "dist"
    stripe_secret_key: str = ""
    stripe_webhook_secret: str = ""
    stripe_prices: dict[str, str] = field(default_factory=dict)
    rate_limits_enabled: bool = True

    @classmethod
    def from_env(cls, **overrides) -> "Settings":
        e = os.environ.get
        data_dir = Path(e("VZ_DATA_DIR", str(ROOT / "storage")))
        s = cls(
            data_dir=data_dir,
            database_url=e("VZ_DATABASE_URL", ""),
            secret_key=e("VZ_SECRET_KEY", ""),
            public_url=e("VZ_PUBLIC_URL", "http://localhost:8000").rstrip("/"),
            workers=int(e("VZ_WORKERS", str(cls.workers))),
            worker_mode=e("VZ_WORKER_MODE", "process"),
            job_timeout=float(e("VZ_JOB_TIMEOUT", "180")),
            max_queue=int(e("VZ_MAX_QUEUE", "200")),
            anon_retention_hours=int(e("VZ_ANON_RETENTION_HOURS", "24")),
            user_retention_days=int(e("VZ_USER_RETENTION_DAYS", "30")),
            allow_private_urls=_bool(e("VZ_ALLOW_PRIVATE_URLS"), False),
            cookie_secure=_bool(e("VZ_COOKIE_SECURE"), e("VZ_PUBLIC_URL", "").startswith("https://")),
            cors_origins=[o.strip() for o in e("VZ_CORS_ORIGINS", "").split(",") if o.strip()],
            frontend_dist=Path(e("VZ_FRONTEND_DIST", str(ROOT / "frontend" / "dist"))),
            stripe_secret_key=e("VZ_STRIPE_SECRET_KEY", ""),
            stripe_webhook_secret=e("VZ_STRIPE_WEBHOOK_SECRET", ""),
            stripe_prices={k[len("VZ_STRIPE_PRICE_"):].lower(): v for k, v in os.environ.items() if k.startswith("VZ_STRIPE_PRICE_")},
            rate_limits_enabled=_bool(e("VZ_RATE_LIMITS"), True),
        )
        for k, v in overrides.items():
            setattr(s, k, v)
        s.finalize()
        return s

    def finalize(self) -> None:
        self.data_dir = Path(self.data_dir)
        self.data_dir.mkdir(parents=True, exist_ok=True)
        if not self.database_url:
            self.database_url = f"sqlite:///{self.data_dir / 'vectorize.sqlite3'}"
        if not self.secret_key:
            # generated once and persisted, so sessions/receipts survive restarts
            key_file = self.data_dir / ".secret_key"
            if key_file.exists():
                self.secret_key = key_file.read_text().strip()
            else:
                self.secret_key = secrets.token_urlsafe(48)
                key_file.write_text(self.secret_key)
                try:
                    key_file.chmod(0o600)
                except OSError:
                    pass

    @property
    def payments_configured(self) -> bool:
        return bool(self.stripe_secret_key and self.stripe_webhook_secret)
