"""Operator CLI (not reachable from the web app).

Used for support cases and local testing, e.g. after a manual refund or to
give a developer test credits:

    python -m billing.admin grant-credits --email you@example.com --credits 25
    python -m billing.admin set-plan --email you@example.com --plan web_pro
    python -m billing.admin show --email you@example.com
"""
from __future__ import annotations

import argparse
import datetime as dt
import sys

from sqlalchemy import select


def main(argv: list[str] | None = None) -> int:
    from backend.config import Settings
    from database import Database, User, utcnow

    from . import credits
    from .plans import PLANS
    from .service import account_summary, set_subscription

    ap = argparse.ArgumentParser(prog="billing.admin")
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("grant-credits")
    g.add_argument("--email", required=True)
    g.add_argument("--credits", type=float, required=True)
    g.add_argument("--reason", default="admin_grant")
    p = sub.add_parser("set-plan")
    p.add_argument("--email", required=True)
    p.add_argument("--plan", required=True, choices=sorted(PLANS))
    p.add_argument("--days", type=int, default=31)
    p.add_argument("--status", default="active", choices=["active", "canceled"])
    s = sub.add_parser("show")
    s.add_argument("--email", required=True)
    args = ap.parse_args(argv)

    settings = Settings.from_env()
    db = Database(settings.database_url)
    db.create_all()
    with db.session() as session:
        user = session.scalar(select(User).where(User.email == args.email.strip().lower()))
        if user is None:
            print(f"no user {args.email}", file=sys.stderr)
            return 1
        if args.cmd == "grant-credits":
            credits.add(session, user.id, int(round(args.credits * 1000)), args.reason, reference=f"admin:{utcnow().isoformat()}")
        elif args.cmd == "set-plan":
            set_subscription(session, user.id, args.plan, status=args.status, provider="admin", period_end=utcnow() + dt.timedelta(days=args.days))
        print(account_summary(session, user))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
