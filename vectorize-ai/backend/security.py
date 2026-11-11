"""HTTP hardening: security headers, rate limiting, CSRF guard, body limits."""
from __future__ import annotations

import threading
import time

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse, Response

from image_processing import MAX_FILE_BYTES

MAX_BODY = MAX_FILE_BYTES + 2 * 1024 * 1024  # multipart overhead + fields

CSP = (
    "default-src 'self'; img-src 'self' data: blob:; media-src 'self' blob:; "
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://cdn.jsdelivr.net; "
    "font-src 'self' https://fonts.gstatic.com data:; script-src 'self' https://cdn.jsdelivr.net; "
    "connect-src 'self'; worker-src 'self' blob:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
)


class TokenBucket:
    """In-memory token bucket per key (per process)."""

    def __init__(self, rate_per_min: float, burst: float):
        self.rate = rate_per_min / 60.0
        self.burst = burst
        self.state: dict[str, tuple[float, float]] = {}
        self.lock = threading.Lock()

    def take(self, key: str, cost: float = 1.0) -> float:
        """Returns 0 if allowed, otherwise seconds to wait."""
        now = time.monotonic()
        with self.lock:
            tokens, ts = self.state.get(key, (self.burst, now))
            tokens = min(self.burst, tokens + (now - ts) * self.rate)
            if tokens >= cost:
                self.state[key] = (tokens - cost, now)
                if len(self.state) > 50_000:
                    self._gc(now)
                return 0.0
            self.state[key] = (tokens, now)
            return (cost - tokens) / self.rate

    def _gc(self, now: float) -> None:
        for k, (tok, ts) in list(self.state.items()):
            if now - ts > 3600:
                del self.state[k]


LIMITS = {
    "auth": TokenBucket(12, 8),
    "upload": TokenBucket(40, 15),
    "api": TokenBucket(300, 60),
    "default": TokenBucket(1200, 300),
}


def _group(path: str, method: str) -> str | None:
    if path.startswith("/api/auth/") and method == "POST":
        return "auth"
    if path.startswith("/api/v1/"):
        return "api"
    if method == "POST" and (path == "/api/images" or path.startswith("/api/images/from-url") or path.endswith("/reprocess") or path.startswith("/api/examples/")):
        return "upload"
    if path.startswith("/api/"):
        return "default"
    return None


def client_ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"


class SecurityMiddleware(BaseHTTPMiddleware):
    def __init__(self, app, rate_limits: bool = True):
        super().__init__(app)
        self.rate_limits = rate_limits

    async def dispatch(self, request: Request, call_next):
        path, method = request.url.path, request.method
        cl = request.headers.get("content-length")
        if cl and cl.isdigit() and int(cl) > MAX_BODY:
            return _err(413, "payload_too_large", "Request body exceeds the 30 MiB limit.", 1006 if path.startswith("/api/v1/") else None)
        # CSRF: cookie-authenticated state changes must carry a custom header,
        # which cross-site forms cannot set without a CORS preflight.
        if method in ("POST", "PUT", "PATCH", "DELETE") and path.startswith("/api/") and not path.startswith("/api/v1/") and not path.startswith("/api/billing/webhook"):
            if request.headers.get("x-requested-with") != "vectorize":
                return _err(403, "csrf", "Missing X-Requested-With header.")
        if self.rate_limits:
            group = _group(path, method)
            if group:
                key = request.headers.get("authorization", "")[:80] if group == "api" and request.headers.get("authorization") else client_ip(request)
                wait = LIMITS[group].take(f"{group}:{key}")
                if wait > 0:
                    r = _err(429, "rate_limited", "Too many requests. Please slow down.", 1005 if group == "api" else None)
                    r.headers["Retry-After"] = str(max(1, int(wait + 0.999)))
                    return r
        response: Response = await call_next(request)
        h = response.headers
        h.setdefault("X-Content-Type-Options", "nosniff")
        h.setdefault("Referrer-Policy", "strict-origin-when-cross-origin")
        h.setdefault("X-Frame-Options", "DENY")
        h.setdefault("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        h.setdefault("Cross-Origin-Opener-Policy", "same-origin")
        if h.get("content-type", "").startswith("text/html"):
            h.setdefault("Content-Security-Policy", CSP)
        if path.startswith("/api/") and "cache-control" not in h:
            h["Cache-Control"] = "no-store"
        return response


def _err(status: int, code: str, message: str, numeric: int | None = None) -> JSONResponse:
    return JSONResponse({"error": {"status": status, "code": numeric if numeric is not None else code, "message": message}}, status_code=status)
