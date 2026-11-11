import base64
import io
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest
from fastapi.testclient import TestClient
from PIL import Image as PILImage

from synthetic import logo_scene, png_bytes, transparent_scene

H = {"X-Requested-With": "vectorize"}


@pytest.fixture()
def app_client(tmp_path):
    from backend.config import Settings
    from backend.main import create_app

    settings = Settings.from_env(data_dir=tmp_path, database_url=f"sqlite:///{tmp_path}/t.sqlite3", worker_mode="thread", workers=2, rate_limits_enabled=False, secret_key="test-secret", stripe_secret_key="sk_test", stripe_webhook_secret="whsec_test", stripe_prices={"web_pro": "price_1"})
    app = create_app(settings)
    with TestClient(app) as c:
        yield c


def wait_job(c, job_id, timeout=60):
    t0 = time.time()
    while time.time() - t0 < timeout:
        j = c.get(f"/api/jobs/{job_id}").json()
        if j["status"] in ("completed", "failed", "cancelled"):
            return j
        time.sleep(0.05)
    raise AssertionError("job did not finish")


def upload(c, img=None, **fields):
    files = {"file": ("logo.png", png_bytes(img if img is not None else logo_scene()), "image/png")}
    r = c.post("/api/images", files=files, data=fields, headers=H)
    assert r.status_code == 200, r.text
    return r.json()


def register(c, email="a@example.com", password="correct horse"):
    r = c.post("/api/auth/register", json={"email": email, "password": password, "name": "Ann"}, headers=H)
    assert r.status_code == 200, r.text
    return r.json()


def test_health_options_and_security_headers(app_client):
    r = app_client.get("/api/health")
    assert r.json()["ok"] and r.headers["x-content-type-options"] == "nosniff"
    opts = app_client.get("/api/meta/options").json()
    assert any(o["name"] == "processing.max_colors" for o in opts["processing"])
    assert any(o["name"] == "output.file_format" for o in opts["export"])


def test_csrf_header_required(app_client):
    r = app_client.post("/api/images", files={"file": ("a.png", png_bytes(logo_scene()), "image/png")})
    assert r.status_code == 403 and r.json()["error"]["code"] == "csrf"


def test_upload_process_and_results(app_client):
    c = app_client
    up = upload(c)
    job = wait_job(c, up["jobId"])
    assert job["status"] == "completed" and job["progress"] == 1.0
    info = c.get(f"/api/images/{up['token']}").json()
    assert info["hasResult"] and info["stats"]["primitives"] == 4
    g = c.get(f"/api/images/{up['token']}/graph").json()
    assert len(g["shapes"]) == 5 and g["width"] == 320
    src = c.get(f"/api/images/{up['token']}/source.png")
    assert src.status_code == 200 and src.headers["content-type"] == "image/png"
    events = c.get(f"/api/jobs/{up['jobId']}/events").text
    assert "event: progress" in events and '"completed"' in events
    hist = c.get("/api/images").json()
    assert hist[0]["token"] == up["token"]


def test_invalid_uploads(app_client):
    r = app_client.post("/api/images", files={"file": ("a.svg", b"<svg/>", "image/png")}, headers=H)
    assert r.status_code == 415 and r.json()["error"]["code"] == "unsupported_format"
    r = app_client.post("/api/images", files={"file": ("a.png", png_bytes(logo_scene()), "image/png")}, data={"options": json.dumps({"max_colors": 999})}, headers=H)
    assert r.status_code == 400 and r.json()["error"]["code"] == "invalid_option"
    r = app_client.post("/api/images", files={"file": ("a.png", png_bytes(logo_scene()), "image/png")}, data={"crop": "[0,0,1,1]"}, headers=H)
    assert r.json()["error"]["code"] == "invalid_crop"


def test_crop_and_reprocess(app_client):
    c = app_client
    up = upload(c, crop="[150, 50, 140, 140]")
    wait_job(c, up["jobId"])
    g = c.get(f"/api/images/{up['token']}/graph").json()
    assert g["width"] == 140
    r = c.post(f"/api/images/{up['token']}/reprocess", json={"options": {"shapes_enabled": False, "max_colors": 2}}, headers=H)
    job = wait_job(c, r.json()["jobId"])
    assert job["status"] == "completed"
    g2 = c.get(f"/api/images/{up['token']}/graph").json()
    assert len(g2["palette"]) <= 2 and not any("primitive" in s for s in g2["shapes"])


def test_download_requires_subscription_and_examples_are_free(app_client):
    c = app_client
    up = upload(c)
    wait_job(c, up["jobId"])
    r = c.get(f"/api/images/{up['token']}/download?format=svg")
    assert r.status_code == 402 and r.json()["error"]["code"] == "subscription_required"
    ex = c.get("/api/examples").json()
    assert len(ex) >= 3
    r = c.post(f"/api/examples/{ex[0]['name']}", headers=H)
    tok = r.json()["token"]
    wait_job(c, r.json()["jobId"])
    for fmt in ("svg", "pdf", "eps", "dxf", "png"):
        d = c.get(f"/api/images/{tok}/download?format={fmt}")
        assert d.status_code == 200, d.text
        assert "attachment" in d.headers["content-disposition"]
    d = c.get(f"/api/images/{tok}/download?format=svg&output.svg.version=svg_tiny_1_2&output.shape_stacking=stacked")
    assert b'baseProfile="tiny"' in d.content


def test_subscriber_downloads_with_edits(app_client):
    from billing.service import set_subscription
    from database import User

    c = app_client
    register(c)
    st = c.app.state.vz
    with st.db.session() as db:
        u = db.query(User).one()
        set_subscription(db, u.id, "web_pro", provider="test")
    up = upload(c)
    wait_job(c, up["jobId"])
    bg = c.post(f"/api/images/{up['token']}/background", json={"method": "color"}, headers=H).json()
    assert len(bg["shapes"]) == 1
    r = c.put(f"/api/images/{up['token']}/edits", content=json.dumps({"backgroundShapes": bg["shapes"]}), headers=H)
    assert r.status_code == 200
    png = c.get(f"/api/images/{up['token']}/download?format=png").content
    im = PILImage.open(io.BytesIO(png))
    assert im.getpixel((2, 2))[3] == 0  # background removed in the export
    assert c.put(f"/api/images/{up['token']}/edits", content=b'{"paletteOverrides": {"0": [1,2]}}', headers=H).status_code == 400


def test_cancel_retry_delete(app_client):
    c = app_client
    up = upload(c)
    c.post(f"/api/jobs/{up['jobId']}/cancel", headers=H)
    job = wait_job(c, up["jobId"])
    assert job["status"] in ("cancelled", "completed")
    if job["status"] == "cancelled":
        r = c.post(f"/api/jobs/{up['jobId']}/retry", headers=H)
        assert wait_job(c, r.json()["jobId"])["status"] == "completed"
    assert c.delete(f"/api/images/{up['token']}", headers=H).json()["ok"]
    assert c.get(f"/api/images/{up['token']}").status_code == 404


def test_images_are_private(app_client, tmp_path):
    c = app_client
    up = upload(c)
    wait_job(c, up["jobId"])
    other = TestClient(c.app)
    assert other.get(f"/api/images/{up['token']}").status_code == 404
    assert other.get(f"/api/images/{up['token']}/graph").status_code == 404


def test_auth_flow_and_anonymous_claim(app_client):
    c = app_client
    up = upload(c)
    me = register(c)
    assert me["user"]["email"] == "a@example.com"
    assert c.get("/api/images").json()[0]["token"] == up["token"]  # claimed
    assert c.post("/api/auth/register", json={"email": "a@example.com", "password": "another one"}, headers=H).status_code == 409
    c.post("/api/auth/logout", headers=H)
    assert c.get("/api/auth/me").json()["user"] is None
    assert c.post("/api/auth/login", json={"email": "a@example.com", "password": "wrong pass"}, headers=H).status_code == 401
    assert c.post("/api/auth/login", json={"email": "a@example.com", "password": "correct horse"}, headers=H).status_code == 200
    assert c.post("/api/auth/register", json={"email": "bad", "password": "short"}, headers=H).status_code == 400


class _ImgHandler(BaseHTTPRequestHandler):
    body = png_bytes(logo_scene())

    def do_GET(self):  # noqa: N802
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/logo.png")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(self.body)))
        self.end_headers()
        self.wfile.write(self.body)

    def log_message(self, *a):
        pass


def test_url_import_blocks_private_networks(app_client):
    c = app_client
    for url in ("http://127.0.0.1:8080/a.png", "http://169.254.169.254/latest/meta-data", "http://[::1]/a.png", "http://10.0.0.1/x.png", "file:///etc/passwd", "http://localhost:22/x"):
        r = c.post("/api/images/from-url", json={"url": url}, headers=H)
        assert r.status_code == 400, url
        assert r.json()["error"]["code"] in ("url_not_allowed", "invalid_url", "url_unresolvable")


def test_url_import_works_when_allowed(tmp_path):
    from backend.config import Settings
    from backend.main import create_app

    srv = HTTPServer(("127.0.0.1", 8080), _ImgHandler)
    th = threading.Thread(target=srv.serve_forever, daemon=True)
    th.start()
    try:
        s = Settings.from_env(data_dir=tmp_path, worker_mode="thread", allow_private_urls=True, rate_limits_enabled=False, secret_key="x")
        with TestClient(create_app(s)) as c:
            r = c.post("/api/images/from-url", json={"url": "http://127.0.0.1:8080/redirect"}, headers=H)
            assert r.status_code == 200, r.text
            assert wait_job(c, r.json()["jobId"])["status"] == "completed"
    finally:
        srv.shutdown()


def test_ip_filter():
    from backend.fetch import ip_allowed

    assert ip_allowed("8.8.8.8") and ip_allowed("2606:4700:4700::1111")
    for ip in ("127.0.0.1", "10.1.2.3", "192.168.1.1", "172.16.0.1", "169.254.169.254", "100.64.0.1", "::1", "fc00::1", "::ffff:10.0.0.1", "0.0.0.0", "224.0.0.1"):
        assert not ip_allowed(ip), ip


# ------------------------------------------------------------- billing
def test_checkout_and_webhooks(app_client):
    from billing.provider import sign_stripe_payload

    c = app_client
    register(c)
    plans = c.get("/api/billing/plans").json()
    assert any(p["id"] == "web_pro" and p["price"] == "9.99" for p in plans["web"])
    assert any(p["credits"] == 100000 and p["price"] == "4,999.99" for p in plans["api"])
    uid = c.get("/api/auth/me").json()["user"]["id"]
    evt = {"id": "evt_1", "type": "checkout.session.completed", "data": {"object": {"payment_status": "paid", "metadata": {"user_id": str(uid), "plan_id": "api_50"}, "customer": "cus_1", "subscription": "sub_1"}}}
    payload = json.dumps(evt).encode()
    bad = c.post("/api/billing/webhook/stripe", content=payload, headers={"Stripe-Signature": "t=1,v1=deadbeef"})
    assert bad.status_code == 403
    assert c.get("/api/auth/me").json()["account"]["credits"] == 0  # nothing granted
    ok = c.post("/api/billing/webhook/stripe", content=payload, headers={"Stripe-Signature": sign_stripe_payload(payload, "whsec_test")})
    assert ok.json()["outcome"] == "activated"
    dup = c.post("/api/billing/webhook/stripe", content=payload, headers={"Stripe-Signature": sign_stripe_payload(payload, "whsec_test")})
    assert dup.json()["outcome"] == "duplicate"
    acc = c.get("/api/auth/me").json()["account"]
    assert acc["credits"] == 50 and acc["apiPlan"] == "api_50"
    cancel = {"id": "evt_2", "type": "customer.subscription.deleted", "data": {"object": {"id": "sub_1", "status": "canceled"}}}
    p2 = json.dumps(cancel).encode()
    c.post("/api/billing/webhook/stripe", content=p2, headers={"Stripe-Signature": sign_stripe_payload(p2, "whsec_test")})
    acc = c.get("/api/auth/me").json()["account"]
    assert acc["credits"] == 0 and acc["apiState"] == "canceled"


def test_checkout_without_provider_does_not_fake_payment(tmp_path):
    from backend.config import Settings
    from backend.main import create_app

    s = Settings.from_env(data_dir=tmp_path, worker_mode="thread", rate_limits_enabled=False, secret_key="x", stripe_secret_key="", stripe_webhook_secret="")
    with TestClient(create_app(s)) as c:
        register(c)
        r = c.post("/api/billing/checkout", json={"plan": "web_pro"}, headers=H)
        assert r.status_code == 503 and r.json()["error"]["code"] == "payments_not_configured"
        assert c.get("/api/auth/me").json()["account"]["webPlan"] == "web_free"


# ------------------------------------------------------------- public API
def _api_key(c):
    register(c)
    k = c.post("/api/account/api-keys", json={"label": "ci"}, headers=H).json()
    return (k["apiId"], k["apiSecret"])


def _grant(c, credits_amount):
    from billing import credits
    from database import User

    st = c.app.state.vz
    with st.db.session() as db:
        u = db.query(User).one()
        credits.add(db, u.id, int(credits_amount * 1000), "test_grant")


def test_api_auth_and_account(app_client):
    c = app_client
    r = c.get("/api/v1/account")
    assert r.status_code == 401 and r.json()["error"]["code"] == 1001
    assert "Basic" in r.headers["www-authenticate"]
    key = _api_key(c)
    assert c.get("/api/v1/account", auth=("vk_nope", "x")).status_code == 401
    acc = c.get("/api/v1/account", auth=key).json()
    assert acc["credits"] == 0


def test_api_vectorize_credit_flow(app_client):
    c = app_client
    key = _api_key(c)
    img = ("logo.png", png_bytes(logo_scene()), "image/png")
    r = c.post("/api/v1/vectorize", auth=key, files={"image": img})
    assert r.status_code == 402 and r.json()["error"]["code"] == 1003
    r = c.post("/api/v1/vectorize", auth=key, files={"image": img}, data={"mode": "test"})
    assert r.status_code == 200 and r.headers["x-credits-charged"] == "0"
    assert r.headers["content-type"].startswith("image/svg+xml") and b"<svg" in r.content
    _grant(c, 5)
    r = c.post("/api/v1/vectorize", auth=key, files={"image": img}, data={"output.file_format": "pdf", "policy.retention_days": "2", "processing.max_colors": "4"})
    assert r.status_code == 200, r.text
    assert r.content.startswith(b"%PDF") and r.headers["x-credits-charged"] == "1.01"
    token, receipt = r.headers["x-image-token"], r.headers["x-receipt"]
    d = c.post("/api/v1/download", auth=key, data={"image.token": token, "output.file_format": "dxf"})
    assert d.status_code == 200 and d.headers["x-credits-charged"] == "0.1"
    assert c.get("/api/v1/account", auth=key).json()["credits"] == pytest.approx(5 - 1.01 - 0.1)
    # reuse the stored image with other options
    r2 = c.post("/api/v1/vectorize", auth=key, data={"image.token": token, "mode": "preview", "policy.retention_days": "1"})
    assert r2.status_code == 200 and r2.headers["content-type"] == "image/png" and r2.headers["x-credits-charged"] == "0.2"
    bad = c.post("/api/v1/download", auth=key, data={"image.token": token})
    assert bad.status_code == 400 and bad.json()["error"]["code"] == 2011
    up = c.post("/api/v1/download", auth=key, data={"image.token": token, "receipt": r2.headers["x-receipt"], "output.file_format": "svg"})
    assert up.status_code == 200 and up.headers["x-credits-charged"] == "0.9"
    assert c.post("/api/v1/delete", auth=key, data={"image.token": token}).json() == {"success": True}
    assert c.post("/api/v1/download", auth=key, data={"image.token": token}).json()["error"]["code"] == 2010
    usage = c.get("/api/account/usage").json()
    assert usage["totalCalls"] >= 5
    ledger = c.get("/api/account/credits").json()
    assert ledger["transactions"][0]["reason"] == "api_upgrade_preview"


def test_api_inputs_and_errors(app_client):
    c = app_client
    key = _api_key(c)
    small = png_bytes(transparent_scene())
    r = c.post("/api/v1/vectorize", auth=key, data={"mode": "test", "image.base64": base64.b64encode(small).decode(), "output.file_format": "png"})
    assert r.status_code == 200 and r.content.startswith(b"\x89PNG")
    r = c.post("/api/v1/vectorize", auth=key, data={"mode": "test"})
    assert r.json()["error"]["code"] == 2001
    r = c.post("/api/v1/vectorize", auth=key, files={"image": ("a.png", small, "image/png")}, data={"mode": "test", "image.base64": "AAAA"})
    assert r.json()["error"]["code"] == 2002
    r = c.post("/api/v1/vectorize", auth=key, data={"mode": "test", "image.base64": "!!!notbase64"})
    assert r.json()["error"]["code"] == 2009
    r = c.post("/api/v1/vectorize", auth=key, data={"mode": "test", "image.url": "http://127.0.0.1/a.png"})
    assert r.json()["error"]["code"] == 2008
    r = c.post("/api/v1/vectorize", auth=key, files={"image": ("a.png", small, "image/png")}, data={"mode": "test", "processing.max_colors": "1000"})
    assert r.status_code == 400 and r.json()["error"]["code"] == 3001
    r = c.post("/api/v1/vectorize", auth=key, files={"image": ("a.png", small, "image/png")}, data={"mode": "fast"})
    assert r.json()["error"]["code"] == 3003


def test_openapi_document_is_valid(app_client):
    from openapi_spec_validator import validate

    spec = app_client.get("/api/openapi.json").json()
    assert spec["openapi"] == "3.0.3"
    validate(spec)
    props = spec["paths"]["/api/v1/vectorize"]["post"]["requestBody"]["content"]["multipart/form-data"]["schema"]["properties"]
    assert "processing.max_colors" in props and "output.svg.version" in props
    assert app_client.get("/api/docs").status_code == 200


def test_rate_limit(tmp_path):
    from backend.config import Settings
    from backend.main import create_app
    from backend.security import LIMITS

    LIMITS["auth"].state.clear()
    s = Settings.from_env(data_dir=tmp_path, worker_mode="thread", secret_key="x")
    with TestClient(create_app(s)) as c:
        codes = [c.post("/api/auth/login", json={"email": "x@example.com", "password": "whatever1"}, headers=H).status_code for _ in range(12)]
        assert 429 in codes
    LIMITS["auth"].state.clear()


def test_retention_sweep(app_client):
    import datetime as dt

    from backend.main import sweep_expired
    from database import Image

    c = app_client
    up = upload(c)
    wait_job(c, up["jobId"])
    st = c.app.state.vz
    with st.db.session() as db:
        img = db.query(Image).filter(Image.token == up["token"]).one()
        img.expires_at = dt.datetime(2000, 1, 1)
    assert sweep_expired(st) == 1
    assert not st.storage.dir(up["token"]).exists()
