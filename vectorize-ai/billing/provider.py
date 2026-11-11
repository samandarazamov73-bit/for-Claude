"""Payment provider integration.

``PaymentProvider`` is the seam for any processor. ``StripeProvider`` talks
to the Stripe REST API directly (no SDK) and verifies webhook signatures
(``Stripe-Signature`` HMAC-SHA256 with timestamp tolerance). Nothing in this
module ever marks a payment as successful on its own: subscriptions and
credits change only in response to a verified provider event."""
from __future__ import annotations

import hashlib
import hmac
import json
import time
from dataclasses import dataclass
from typing import Protocol

import httpx


class PaymentsNotConfigured(Exception):
    pass


class WebhookVerificationError(Exception):
    pass


@dataclass
class ProviderEvent:
    id: str
    type: str
    data: dict


class PaymentProvider(Protocol):
    name: str

    def create_checkout(self, *, plan_id: str, user_id: int, email: str, success_url: str, cancel_url: str, customer_id: str | None) -> str: ...

    def create_portal(self, *, customer_id: str, return_url: str) -> str: ...

    def parse_webhook(self, payload: bytes, signature_header: str | None) -> ProviderEvent: ...


class StripeProvider:
    name = "stripe"
    api = "https://api.stripe.com/v1"

    def __init__(self, secret_key: str, webhook_secret: str, prices: dict[str, str], tolerance: int = 300, transport: httpx.BaseTransport | None = None):
        self.secret_key = secret_key
        self.webhook_secret = webhook_secret
        self.prices = prices
        self.tolerance = tolerance
        self.transport = transport

    def _post(self, path: str, data: dict) -> dict:
        with httpx.Client(timeout=20, transport=self.transport) as c:
            r = c.post(f"{self.api}{path}", data=data, auth=(self.secret_key, ""))
        if r.status_code >= 400:
            raise RuntimeError(f"Stripe error {r.status_code}: {r.text[:300]}")
        return r.json()

    def create_checkout(self, *, plan_id, user_id, email, success_url, cancel_url, customer_id):
        price = self.prices.get(plan_id)
        if not price:
            raise PaymentsNotConfigured(f"No Stripe price configured for plan {plan_id}.")
        data = {
            "mode": "subscription",
            "line_items[0][price]": price,
            "line_items[0][quantity]": "1",
            "success_url": success_url,
            "cancel_url": cancel_url,
            "client_reference_id": str(user_id),
            "metadata[user_id]": str(user_id),
            "metadata[plan_id]": plan_id,
            "subscription_data[metadata][user_id]": str(user_id),
            "subscription_data[metadata][plan_id]": plan_id,
        }
        if customer_id:
            data["customer"] = customer_id
        else:
            data["customer_email"] = email
        return self._post("/checkout/sessions", data)["url"]

    def create_portal(self, *, customer_id, return_url):
        return self._post("/billing_portal/sessions", {"customer": customer_id, "return_url": return_url})["url"]

    def parse_webhook(self, payload: bytes, signature_header: str | None) -> ProviderEvent:
        verify_stripe_signature(payload, signature_header, self.webhook_secret, self.tolerance)
        try:
            evt = json.loads(payload)
        except json.JSONDecodeError as exc:
            raise WebhookVerificationError("invalid JSON") from exc
        return ProviderEvent(id=evt["id"], type=evt["type"], data=evt.get("data", {}).get("object", {}))


def verify_stripe_signature(payload: bytes, header: str | None, secret: str, tolerance: int = 300, now: float | None = None) -> None:
    if not header or not secret:
        raise WebhookVerificationError("missing signature")
    parts: dict[str, list[str]] = {}
    for item in header.split(","):
        if "=" in item:
            k, v = item.split("=", 1)
            parts.setdefault(k.strip(), []).append(v.strip())
    try:
        ts = int(parts["t"][0])
    except (KeyError, ValueError, IndexError) as exc:
        raise WebhookVerificationError("missing timestamp") from exc
    if abs((now or time.time()) - ts) > tolerance:
        raise WebhookVerificationError("timestamp outside tolerance")
    expected = hmac.new(secret.encode(), f"{ts}.".encode() + payload, hashlib.sha256).hexdigest()
    if not any(hmac.compare_digest(expected, sig) for sig in parts.get("v1", [])):
        raise WebhookVerificationError("signature mismatch")


def sign_stripe_payload(payload: bytes, secret: str, ts: int | None = None) -> str:
    """Produce a valid Stripe-Signature header (used by tests and tooling)."""
    ts = int(ts or time.time())
    sig = hmac.new(secret.encode(), f"{ts}.".encode() + payload, hashlib.sha256).hexdigest()
    return f"t={ts},v1={sig}"
