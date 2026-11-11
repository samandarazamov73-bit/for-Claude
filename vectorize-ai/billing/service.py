"""Billing state machine driven by verified provider events."""
from __future__ import annotations

import datetime as dt

from sqlalchemy import select
from sqlalchemy.orm import Session as DbSession

from database import PaymentEvent, Subscription, User, utcnow

from . import credits
from .plans import PLANS
from .provider import ProviderEvent


def _ts(v) -> dt.datetime | None:
    if not v:
        return None
    return dt.datetime.fromtimestamp(int(v), dt.timezone.utc).replace(tzinfo=None)


def set_subscription(db: DbSession, user_id: int, plan_id: str, *, status: str = "active", provider: str = "", customer_id: str | None = None, subscription_id: str | None = None, period_end: dt.datetime | None = None) -> Subscription:
    plan = PLANS[plan_id]
    sub = db.scalar(select(Subscription).where(Subscription.user_id == user_id, Subscription.kind == plan.kind))
    if sub is None:
        sub = Subscription(user_id=user_id, kind=plan.kind, plan=plan_id)
        db.add(sub)
    sub.plan = plan_id
    sub.status = status
    sub.provider = provider or sub.provider
    sub.provider_customer_id = customer_id or sub.provider_customer_id
    sub.provider_subscription_id = subscription_id or sub.provider_subscription_id
    sub.current_period_end = period_end or sub.current_period_end
    db.flush()
    return sub


def handle_event(db: DbSession, provider: str, evt: ProviderEvent) -> str:
    """Apply a verified event exactly once. Returns a short outcome string."""
    if db.scalar(select(PaymentEvent).where(PaymentEvent.event_id == evt.id)):
        return "duplicate"
    db.add(PaymentEvent(provider=provider, event_id=evt.id, type=evt.type))
    obj = evt.data
    meta = obj.get("metadata") or {}
    if evt.type == "checkout.session.completed":
        if obj.get("payment_status") not in ("paid", "no_payment_required"):
            return "ignored_unpaid"
        user_id = int(meta.get("user_id") or obj.get("client_reference_id") or 0)
        plan_id = meta.get("plan_id", "")
        if not user_id or plan_id not in PLANS or db.get(User, user_id) is None:
            return "ignored_unknown"
        set_subscription(db, user_id, plan_id, provider=provider, customer_id=obj.get("customer"), subscription_id=obj.get("subscription"), period_end=utcnow() + dt.timedelta(days=31))
        if PLANS[plan_id].credits:
            credits.grant_monthly(db, user_id, plan_id, reference=f"{provider}:{obj.get('subscription') or evt.id}:initial")
        return "activated"
    if evt.type == "invoice.paid":
        sub_id = obj.get("subscription")
        sub = db.scalar(select(Subscription).where(Subscription.provider_subscription_id == sub_id)) if sub_id else None
        if sub is None:
            return "ignored_unknown"
        lines = (obj.get("lines") or {}).get("data") or []
        period_end = _ts(lines[0].get("period", {}).get("end")) if lines else None
        sub.status = "active"
        sub.current_period_end = period_end or sub.current_period_end
        if obj.get("billing_reason") == "subscription_cycle" and PLANS[sub.plan].credits:
            credits.grant_monthly(db, sub.user_id, sub.plan, reference=f"{provider}:invoice:{obj.get('id')}")
        return "renewed"
    if evt.type in ("customer.subscription.updated", "customer.subscription.deleted"):
        sub = db.scalar(select(Subscription).where(Subscription.provider_subscription_id == obj.get("id")))
        if sub is None:
            return "ignored_unknown"
        status = obj.get("status", "canceled")
        sub.status = {"active": "active", "trialing": "active", "past_due": "past_due"}.get(status, "canceled")
        if evt.type.endswith("deleted"):
            sub.status = "canceled"
            if PLANS[sub.plan].credits:
                bal = credits.balance_milli(db, sub.user_id)
                if bal > 0:  # unused credits expire on cancellation
                    credits.add(db, sub.user_id, -bal, "subscription_canceled", reference=f"{provider}:{obj.get('id')}:cancel")
        sub.current_period_end = _ts(obj.get("current_period_end")) or sub.current_period_end
        return sub.status
    return "ignored_type"


def account_summary(db: DbSession, user: User) -> dict:
    web = credits.active_subscription(db, user.id, "web")
    api = credits.active_subscription(db, user.id, "api")
    raw_api = db.scalar(select(Subscription).where(Subscription.user_id == user.id, Subscription.kind == "api"))
    return {
        "webPlan": web.plan if web else "web_free",
        "webState": web.status if web else "none",
        "apiPlan": api.plan if api else None,
        "apiState": api.status if api else (raw_api.status if raw_api else "none"),
        "creditsMilli": credits.balance_milli(db, user.id),
        "credits": credits.balance_milli(db, user.id) / 1000,
        "periodEnd": (web or api).current_period_end.isoformat() if (web or api) and (web or api).current_period_end else None,
        "canManage": bool((web or raw_api) and (web or raw_api).provider_customer_id),
    }
