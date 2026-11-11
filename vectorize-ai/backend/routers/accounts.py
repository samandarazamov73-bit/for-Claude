"""Authentication, profile, API keys, usage, credits and billing endpoints."""
from __future__ import annotations

import datetime as dt

from fastapi import APIRouter, Depends, Request, Response
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session as DbSession

import auth
from api.errors import ApiError
from billing import credits
from billing.plans import API_PLANS, PLANS, WEB_PLANS, fmt_credits
from billing.provider import PaymentsNotConfigured, WebhookVerificationError
from billing.service import account_summary, handle_event
from database import ApiKey, ApiUsage, Image, Subscription, User, utcnow

from ..deps import ANON_COOKIE, SESSION_COOKIE, current_user, get_db, require_user, set_session_cookie, state

router = APIRouter(prefix="/api", tags=["account"])


def _user_json(u: User) -> dict:
    return {"id": u.id, "email": u.email, "name": u.name, "createdAt": u.created_at.isoformat() + "Z"}


class Credentials(BaseModel):
    email: str = Field(..., max_length=320)
    password: str = Field(..., max_length=256)
    name: str = Field("", max_length=120)


def _auth_error(exc: auth.AuthError) -> ApiError:
    key = {401: "not_authenticated", 403: "forbidden", 409: "invalid_request"}.get(exc.status, "invalid_request")
    return ApiError(key, exc.message, exc.status)


@router.post("/auth/register")
def register(body: Credentials, request: Request, response: Response, db: DbSession = Depends(get_db)):
    try:
        user = auth.register(db, body.email, body.password, body.name)
    except auth.AuthError as exc:
        raise _auth_error(exc) from exc
    token = auth.create_session(db, user, request.headers.get("user-agent", ""))
    auth.claim_anonymous_images(db, user, request.cookies.get(ANON_COOKIE))
    set_session_cookie(response, token, state(request).settings)
    return {"user": _user_json(user)}


@router.post("/auth/login")
def login(body: Credentials, request: Request, response: Response, db: DbSession = Depends(get_db)):
    try:
        user = auth.authenticate(db, body.email, body.password)
    except auth.AuthError as exc:
        raise _auth_error(exc) from exc
    token = auth.create_session(db, user, request.headers.get("user-agent", ""))
    auth.claim_anonymous_images(db, user, request.cookies.get(ANON_COOKIE))
    set_session_cookie(response, token, state(request).settings)
    return {"user": _user_json(user)}


@router.post("/auth/logout")
def logout(request: Request, response: Response, db: DbSession = Depends(get_db)):
    auth.end_session(db, request.cookies.get(SESSION_COOKIE))
    response.delete_cookie(SESSION_COOKIE, path="/")
    return {"ok": True}


@router.get("/auth/me")
def me(user: User | None = Depends(current_user), db: DbSession = Depends(get_db)):
    if user is None:
        return {"user": None}
    return {"user": _user_json(user), "account": account_summary(db, user)}


class ProfileIn(BaseModel):
    name: str = Field("", max_length=120)


@router.patch("/auth/me")
def update_profile(body: ProfileIn, user: User = Depends(require_user)):
    user.name = body.name.strip()
    return {"user": _user_json(user)}


class PasswordIn(BaseModel):
    current: str = Field(..., max_length=256)
    new: str = Field(..., max_length=256)


@router.post("/auth/password")
def change_password(body: PasswordIn, request: Request, response: Response, user: User = Depends(require_user), db: DbSession = Depends(get_db)):
    try:
        auth.change_password(db, user, body.current, body.new)
    except auth.AuthError as exc:
        raise _auth_error(exc) from exc
    token = auth.create_session(db, user, request.headers.get("user-agent", ""))
    set_session_cookie(response, token, state(request).settings)
    return {"ok": True}


class DeleteIn(BaseModel):
    password: str = Field(..., max_length=256)


@router.post("/auth/delete-account")
def delete_account(body: DeleteIn, request: Request, response: Response, user: User = Depends(require_user), db: DbSession = Depends(get_db)):
    if not auth.verify_password(body.password, user.password_hash):
        raise ApiError("forbidden", "Password is incorrect.")
    st = state(request)
    for img in db.scalars(select(Image).where(Image.user_id == user.id)):
        st.storage.delete(img.token)
    db.delete(user)
    response.delete_cookie(SESSION_COOKIE, path="/")
    return {"ok": True}


# ---------------------------------------------------------------- API keys
@router.get("/account/api-keys")
def list_keys(user: User = Depends(require_user), db: DbSession = Depends(get_db)):
    keys = db.scalars(select(ApiKey).where(ApiKey.user_id == user.id, ApiKey.revoked.is_(False)).order_by(ApiKey.created_at.desc())).all()
    return [{"id": k.id, "apiId": k.api_id, "label": k.label, "createdAt": k.created_at.isoformat() + "Z", "lastUsedAt": k.last_used_at.isoformat() + "Z" if k.last_used_at else None} for k in keys]


class KeyIn(BaseModel):
    label: str = Field("", max_length=80)


@router.post("/account/api-keys")
def create_key(body: KeyIn, user: User = Depends(require_user), db: DbSession = Depends(get_db)):
    if db.scalar(select(func.count(ApiKey.id)).where(ApiKey.user_id == user.id, ApiKey.revoked.is_(False))) >= 10:
        raise ApiError("invalid_request", "At most 10 active API keys are allowed.")
    key, secret = auth.create_api_key(db, user, body.label)
    return {"id": key.id, "apiId": key.api_id, "apiSecret": secret, "label": key.label, "note": "Store the secret now - it is shown only once."}


@router.delete("/account/api-keys/{key_id}")
def revoke_key(key_id: int, user: User = Depends(require_user), db: DbSession = Depends(get_db)):
    key = db.get(ApiKey, key_id)
    if key is None or key.user_id != user.id:
        raise ApiError("not_found")
    key.revoked = True
    return {"ok": True}


# ---------------------------------------------------------------- usage / credits
@router.get("/account/usage")
def usage(days: int = 30, user: User = Depends(require_user), db: DbSession = Depends(get_db)):
    days = max(1, min(days, 365))
    since = utcnow() - dt.timedelta(days=days)
    rows = db.execute(
        select(func.date(ApiUsage.created_at), ApiUsage.endpoint, ApiUsage.mode, func.count(ApiUsage.id), func.sum(ApiUsage.credits_milli))
        .where(ApiUsage.user_id == user.id, ApiUsage.created_at >= since)
        .group_by(func.date(ApiUsage.created_at), ApiUsage.endpoint, ApiUsage.mode)
    ).all()
    errors = db.scalar(select(func.count(ApiUsage.id)).where(ApiUsage.user_id == user.id, ApiUsage.created_at >= since, ApiUsage.status_code >= 400)) or 0
    web_images = db.scalar(select(func.count(Image.id)).where(Image.user_id == user.id, Image.origin == "web")) or 0
    return {
        "days": days,
        "rows": [{"date": str(d), "endpoint": e, "mode": m, "calls": int(c), "credits": (s or 0) / 1000} for d, e, m, c, s in rows],
        "totalCalls": sum(int(r[3]) for r in rows),
        "creditsUsed": credits.usage_since(db, user.id, since) / 1000,
        "errors": int(errors),
        "webImages": int(web_images),
    }


@router.get("/account/credits")
def credit_history(user: User = Depends(require_user), db: DbSession = Depends(get_db)):
    return {
        "balance": credits.balance_milli(db, user.id) / 1000,
        "transactions": [
            {"id": t.id, "delta": fmt_credits(t.delta_milli), "balance": fmt_credits(t.balance_after_milli), "reason": t.reason, "imageToken": t.image_token, "createdAt": t.created_at.isoformat() + "Z"}
            for t in credits.history(db, user.id)
        ],
    }


# ---------------------------------------------------------------- billing
@router.get("/billing/plans")
def plans(request: Request):
    return {"web": [p.to_json() for p in WEB_PLANS], "api": [p.to_json() for p in API_PLANS], "paymentsConfigured": state(request).payments is not None, "creditPrices": {"production": 1, "preview": 0.2, "upgradePreview": 0.9, "additionalFormat": 0.1, "retentionPerDay": 0.01, "test": 0}}


class CheckoutIn(BaseModel):
    plan: str


@router.post("/billing/checkout")
def checkout(body: CheckoutIn, request: Request, user: User = Depends(require_user), db: DbSession = Depends(get_db)):
    st = state(request)
    plan = PLANS.get(body.plan)
    if plan is None or plan.price_cents == 0:
        raise ApiError("invalid_request", "Unknown or free plan.")
    if st.payments is None:
        raise ApiError("payments_not_configured", "Online payments are not configured on this server yet. No charge was made.")
    sub = db.scalar(select(Subscription).where(Subscription.user_id == user.id, Subscription.kind == plan.kind))
    try:
        url = st.payments.create_checkout(
            plan_id=plan.id,
            user_id=user.id,
            email=user.email,
            success_url=f"{st.settings.public_url}/account?checkout=success",
            cancel_url=f"{st.settings.public_url}/pricing?checkout=cancelled",
            customer_id=sub.provider_customer_id if sub else None,
        )
    except PaymentsNotConfigured as exc:
        raise ApiError("payments_not_configured", str(exc)) from exc
    except RuntimeError as exc:
        raise ApiError("internal_error", "The payment provider rejected the request.") from exc
    return {"url": url}


@router.post("/billing/portal")
def portal(request: Request, user: User = Depends(require_user), db: DbSession = Depends(get_db)):
    st = state(request)
    if st.payments is None:
        raise ApiError("payments_not_configured")
    sub = db.scalar(select(Subscription).where(Subscription.user_id == user.id, Subscription.provider_customer_id.is_not(None)))
    if sub is None:
        raise ApiError("invalid_request", "No billing account exists yet.")
    return {"url": st.payments.create_portal(customer_id=sub.provider_customer_id, return_url=f"{st.settings.public_url}/account")}


@router.post("/billing/webhook/stripe")
async def stripe_webhook(request: Request):
    st = state(request)
    if st.payments is None:
        raise ApiError("payments_not_configured")
    payload = await request.body()
    try:
        evt = st.payments.parse_webhook(payload, request.headers.get("stripe-signature"))
    except WebhookVerificationError as exc:
        raise ApiError("forbidden", f"Webhook verification failed: {exc}") from exc
    with st.db.session() as db:
        outcome = handle_event(db, "stripe", evt)
    return {"received": True, "outcome": outcome}
