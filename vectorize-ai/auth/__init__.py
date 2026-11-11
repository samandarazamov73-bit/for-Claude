"""Authentication: password hashing, browser sessions and API keys."""
from __future__ import annotations

import base64
import datetime as dt
import hashlib
import hmac
import re
import secrets

from sqlalchemy import select
from sqlalchemy.orm import Session as DbSession

from database import ApiKey, Image, Session, User, utcnow

SESSION_DAYS = 30
_EMAIL_RE = re.compile(r"^[^@\s]{1,64}@[^@\s]{1,255}\.[^@\s]{2,}$")

# scrypt parameters (OWASP: N=2^15, r=8, p=1 ~ 32 MiB)
_N, _R, _P = 2**15, 8, 1


class AuthError(Exception):
    def __init__(self, code: str, message: str, status: int = 400):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    dk = hashlib.scrypt(password.encode(), salt=salt, n=_N, r=_R, p=_P, maxmem=64 * 1024 * 1024, dklen=32)
    return "scrypt$%d$%d$%d$%s$%s" % (_N, _R, _P, base64.b64encode(salt).decode(), base64.b64encode(dk).decode())


def verify_password(password: str, stored: str) -> bool:
    try:
        algo, n, r, p, salt_b64, dk_b64 = stored.split("$")
        if algo != "scrypt":
            return False
        salt, dk = base64.b64decode(salt_b64), base64.b64decode(dk_b64)
        test = hashlib.scrypt(password.encode(), salt=salt, n=int(n), r=int(r), p=int(p), maxmem=64 * 1024 * 1024, dklen=len(dk))
        return hmac.compare_digest(test, dk)
    except (ValueError, TypeError):
        return False


def _sha256(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def validate_credentials(email: str, password: str) -> str:
    email = (email or "").strip().lower()
    if not _EMAIL_RE.match(email):
        raise AuthError("invalid_email", "Enter a valid email address.")
    if len(password or "") < 8:
        raise AuthError("weak_password", "Password must be at least 8 characters.")
    if len(password) > 256:
        raise AuthError("weak_password", "Password is too long.")
    return email


def register(db: DbSession, email: str, password: str, name: str = "") -> User:
    email = validate_credentials(email, password)
    if db.scalar(select(User).where(User.email == email)):
        raise AuthError("email_taken", "An account with this email already exists.", 409)
    user = User(email=email, name=(name or "").strip()[:120], password_hash=hash_password(password))
    db.add(user)
    db.flush()
    return user


def authenticate(db: DbSession, email: str, password: str) -> User:
    email = (email or "").strip().lower()
    user = db.scalar(select(User).where(User.email == email))
    if user is None:
        # equalise timing with a dummy verification
        verify_password(password or "", "scrypt$32768$8$1$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
        raise AuthError("invalid_login", "Incorrect email or password.", 401)
    if not user.is_active or not verify_password(password or "", user.password_hash):
        raise AuthError("invalid_login", "Incorrect email or password.", 401)
    return user


def create_session(db: DbSession, user: User, user_agent: str = "") -> str:
    token = secrets.token_urlsafe(32)
    db.add(Session(token_hash=_sha256(token), user_id=user.id, expires_at=utcnow() + dt.timedelta(days=SESSION_DAYS), user_agent=(user_agent or "")[:255]))
    return token


def session_user(db: DbSession, token: str | None) -> User | None:
    if not token or len(token) > 128:
        return None
    s = db.scalar(select(Session).where(Session.token_hash == _sha256(token)))
    if s is None or s.expires_at < utcnow():
        return None
    return s.user if s.user.is_active else None


def end_session(db: DbSession, token: str | None) -> None:
    if token:
        s = db.scalar(select(Session).where(Session.token_hash == _sha256(token)))
        if s:
            db.delete(s)


def change_password(db: DbSession, user: User, current: str, new: str) -> None:
    if not verify_password(current or "", user.password_hash):
        raise AuthError("invalid_password", "Current password is incorrect.", 403)
    validate_credentials(user.email, new)
    user.password_hash = hash_password(new)
    for s in list(user.sessions):
        db.delete(s)


def claim_anonymous_images(db: DbSession, user: User, anon_id: str | None) -> int:
    if not anon_id:
        return 0
    imgs = db.scalars(select(Image).where(Image.anon_id == anon_id, Image.user_id.is_(None))).all()
    for img in imgs:
        img.user_id = user.id
        img.anon_id = None
    return len(imgs)


# --------------------------------------------------------------------------
# API keys (HTTP Basic: API Id / API Secret)
# --------------------------------------------------------------------------

def create_api_key(db: DbSession, user: User, label: str = "") -> tuple[ApiKey, str]:
    api_id = "vk_" + secrets.token_hex(8)
    secret = secrets.token_urlsafe(30)
    key = ApiKey(user_id=user.id, api_id=api_id, secret_hash=_sha256(secret), label=(label or "")[:80])
    db.add(key)
    db.flush()
    return key, secret


def verify_api_key(db: DbSession, api_id: str, secret: str) -> ApiKey | None:
    if not api_id or not secret or len(api_id) > 40 or len(secret) > 128:
        return None
    key = db.scalar(select(ApiKey).where(ApiKey.api_id == api_id))
    if key is None or key.revoked or not key.user.is_active:
        return None
    if not hmac.compare_digest(key.secret_hash, _sha256(secret)):
        return None
    key.last_used_at = utcnow()
    return key


def parse_basic(header: str | None) -> tuple[str, str] | None:
    if not header or not header.lower().startswith("basic "):
        return None
    try:
        raw = base64.b64decode(header[6:].strip(), validate=True).decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        return None
    if ":" not in raw:
        return None
    a, b = raw.split(":", 1)
    return a, b
