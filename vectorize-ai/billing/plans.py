"""Plan catalogue and credit prices.

Web subscriptions unlock unlimited downloads in the web app; API plans add
monthly credits (unused credits roll over up to 5x the monthly amount)."""
from __future__ import annotations

from dataclasses import dataclass

MILLI = 1000


@dataclass(frozen=True)
class Plan:
    id: str
    kind: str  # web | api
    name: str
    price_cents: int
    interval: str  # month
    credits: int = 0  # monthly credits (API plans)
    description: str = ""

    @property
    def price(self) -> str:
        return f"{self.price_cents / 100:,.2f}"

    @property
    def per_credit_cents(self) -> float:
        return self.price_cents / self.credits if self.credits else 0.0

    def to_json(self) -> dict:
        d = {"id": self.id, "kind": self.kind, "name": self.name, "priceCents": self.price_cents, "price": self.price, "interval": self.interval, "description": self.description}
        if self.credits:
            d["credits"] = self.credits
            d["perCredit"] = round(self.per_credit_cents / 100, 4)
            d["rolloverCap"] = self.credits * 5
        return d


WEB_PLANS = (
    Plan("web_free", "web", "Free", 0, "month", description="Upload, vectorise, edit and preview without limits."),
    Plan("web_pro", "web", "Pro", 999, "month", description="Unlimited downloads in SVG, PDF, EPS, DXF and PNG. No API access."),
)

API_PLANS = (
    Plan("api_50", "api", "API 50", 999, "month", 50),
    Plan("api_500", "api", "API 500", 4999, "month", 500),
    Plan("api_2500", "api", "API 2,500", 19999, "month", 2500),
    Plan("api_10000", "api", "API 10,000", 69999, "month", 10000),
    Plan("api_30000", "api", "API 30,000", 179999, "month", 30000),
    Plan("api_100000", "api", "API 100,000", 499999, "month", 100000),
)

PLANS = {p.id: p for p in WEB_PLANS + API_PLANS}

# Credit prices of API operations (milli-credits)
PRICE_MILLI = {
    "production": 1000,
    "preview": 200,
    "test": 0,
    "test_preview": 0,
    "upgrade_preview": 900,
    "extra_format": 100,
    "retention_day": 10,
}
ROLLOVER_FACTOR = 5


def retention_cost_milli(days: int) -> int:
    """The first day of storage is free."""
    return max(0, int(days) - 1) * PRICE_MILLI["retention_day"]


def fmt_credits(milli: int) -> str:
    v = milli / MILLI
    return f"{v:.3f}".rstrip("0").rstrip(".") if v != int(v) else str(int(v))
