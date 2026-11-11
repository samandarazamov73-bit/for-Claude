"""Append-only credit ledger with atomic balance checks."""
from __future__ import annotations

import datetime as dt

from sqlalchemy import func, select
from sqlalchemy.orm import Session as DbSession

from database import CreditTransaction, Subscription, User, utcnow

from .plans import PLANS, ROLLOVER_FACTOR


class InsufficientCredits(Exception):
    def __init__(self, needed: int, balance: int):
        super().__init__("insufficient credits")
        self.needed, self.balance = needed, balance


def balance_milli(db: DbSession, user_id: int) -> int:
    last = db.scalar(select(CreditTransaction).where(CreditTransaction.user_id == user_id).order_by(CreditTransaction.id.desc()).limit(1))
    return int(last.balance_after_milli) if last else 0


def _lock_user(db: DbSession, user_id: int) -> None:
    # Serialises balance updates per user (row lock on Postgres; SQLite
    # serialises writers anyway).
    db.execute(select(User.id).where(User.id == user_id).with_for_update())


def add(db: DbSession, user_id: int, delta_milli: int, reason: str, *, image_token: str | None = None, reference: str | None = None) -> CreditTransaction:
    _lock_user(db, user_id)
    bal = balance_milli(db, user_id)
    tx = CreditTransaction(user_id=user_id, delta_milli=int(delta_milli), balance_after_milli=bal + int(delta_milli), reason=reason, image_token=image_token, reference=reference)
    db.add(tx)
    db.flush()
    return tx


def charge(db: DbSession, user_id: int, amount_milli: int, reason: str, *, image_token: str | None = None, reference: str | None = None) -> CreditTransaction | None:
    if amount_milli <= 0:
        return None
    _lock_user(db, user_id)
    bal = balance_milli(db, user_id)
    if bal < amount_milli:
        raise InsufficientCredits(amount_milli, bal)
    return add(db, user_id, -amount_milli, reason, image_token=image_token, reference=reference)


def ensure_available(db: DbSession, user_id: int, amount_milli: int) -> None:
    bal = balance_milli(db, user_id)
    if amount_milli > 0 and bal < amount_milli:
        raise InsufficientCredits(amount_milli, bal)


def grant_monthly(db: DbSession, user_id: int, plan_id: str, reference: str) -> CreditTransaction | None:
    """Monthly grant honouring the rollover cap (5x the monthly amount)."""
    plan = PLANS[plan_id]
    if not plan.credits:
        return None
    if db.scalar(select(CreditTransaction).where(CreditTransaction.reference == reference)):
        return None  # idempotent per invoice / event
    cap = plan.credits * 1000 * ROLLOVER_FACTOR
    bal = balance_milli(db, user_id)
    if bal > cap - plan.credits * 1000:
        expired = bal - max(0, cap - plan.credits * 1000)
        add(db, user_id, -expired, "rollover_cap", reference=reference + ":cap")
    return add(db, user_id, plan.credits * 1000, "plan_grant", reference=reference)


def history(db: DbSession, user_id: int, limit: int = 100) -> list[CreditTransaction]:
    return list(db.scalars(select(CreditTransaction).where(CreditTransaction.user_id == user_id).order_by(CreditTransaction.id.desc()).limit(limit)))


def usage_since(db: DbSession, user_id: int, since: dt.datetime) -> int:
    v = db.scalar(select(func.coalesce(func.sum(CreditTransaction.delta_milli), 0)).where(CreditTransaction.user_id == user_id, CreditTransaction.delta_milli < 0, CreditTransaction.created_at >= since))
    return -int(v or 0)


def active_subscription(db: DbSession, user_id: int, kind: str) -> Subscription | None:
    sub = db.scalar(select(Subscription).where(Subscription.user_id == user_id, Subscription.kind == kind))
    if sub is None or sub.status not in ("active", "past_due"):
        return None
    if sub.current_period_end and sub.current_period_end < utcnow() - dt.timedelta(days=3):
        return None
    return sub
