"""Login, sessions, lockout and password change."""

import json
import os
import time

import pytest
from conftest import TEST_PASSWORD

import config
from core import audit, passwords, session
from routes import auth as auth_routes


@pytest.fixture(autouse=True)
def no_failure_delay(monkeypatch):
    monkeypatch.setattr(auth_routes, "_FAILURE_DELAY", 0)


def _login(anon, password=TEST_PASSWORD, username="admin"):
    return anon.post("/api/v1/auth/login", data={"username": username, "password": password})


def _audit_actions() -> list[str]:
    return [json.loads(line)["action"] for line in audit.log_path().read_text().splitlines()]


# ── Hashing ───────────────────────────────────────────────────────────────────


def test_password_is_stored_as_a_scrypt_hash_only():
    record = passwords.load()
    assert record["hash"].startswith("scrypt$")
    assert TEST_PASSWORD not in config.auth_file_path().read_text()
    if os.name == "posix":
        assert config.auth_file_path().stat().st_mode & 0o777 == 0o600


def test_verify_rejects_garbage_hashes():
    assert not passwords.verify_password("x", "not-a-hash")
    assert not passwords.verify_password("x", "bcrypt$1$2$3$4$5")


def test_cli_ensure_does_not_replace_an_existing_password(capsys):
    before = passwords.load()["hash"]
    assert passwords._main(["ensure"]) == 0
    assert passwords.load()["hash"] == before
    assert capsys.readouterr().out == ""


def test_cli_ensure_creates_and_prints_one_when_missing(capsys):
    config.auth_file_path().unlink()
    assert passwords._main(["ensure"]) == 0
    printed = capsys.readouterr().out.strip()
    assert printed and passwords.check("admin", printed)


def test_cli_ensure_honours_a_pinned_password(monkeypatch):
    monkeypatch.setenv("PANEL_PASSWORD", "pinned-password-123")
    assert passwords._main(["ensure"]) == 0
    assert passwords.check("admin", "pinned-password-123")


def test_cli_set_validates_length(monkeypatch):
    monkeypatch.setenv("NSPANEL_NEW_PASSWORD", "short")
    assert passwords._main(["set"]) == 1
    assert passwords.check("admin", TEST_PASSWORD)


# ── Login ─────────────────────────────────────────────────────────────────────


def test_api_needs_a_session(anon):
    response = anon.get("/api/v1/system")
    assert response.status_code == 401
    body = response.json()
    assert (body["status"], body["code"], body["message"]) == ("error", 401, "Not signed in")


def test_spa_shell_and_health_are_public(anon):
    assert anon.get("/healthz").json()["ok"] is True
    assert anon.get("/").status_code in (200, 503)  # 503 when the bundle is not built


def test_login_sets_an_httponly_strict_cookie(anon):
    response = _login(anon)
    assert response.status_code == 200
    assert response.json()["data"]["username"] == "admin"
    cookie = response.headers["set-cookie"].lower()
    assert "httponly" in cookie and "samesite=strict" in cookie
    assert anon.get("/api/v1/auth/me").status_code == 200
    assert "auth.login" in _audit_actions()


@pytest.mark.parametrize(("username", "password"), [("admin", "wrong-password"), ("root", TEST_PASSWORD)])
def test_wrong_credentials_are_refused_and_audited(anon, username, password):
    response = _login(anon, password=password, username=username)
    assert response.status_code == 401
    assert anon.get("/api/v1/auth/me").status_code == 401
    assert "auth.login_failed" in _audit_actions()


def test_login_needs_the_csrf_header():
    from fastapi.testclient import TestClient

    import app as app_module

    bare = TestClient(app_module.app)
    response = bare.post("/api/v1/auth/login", data={"username": "admin", "password": TEST_PASSWORD})
    assert response.status_code == 403


def test_repeated_failures_lock_the_ip_out(anon):
    for _ in range(config.LOGIN_MAX_FAILURES):
        assert _login(anon, password="nope-nope-nope").status_code == 401
    # Locked: even the right password is refused until the lockout expires.
    response = _login(anon)
    assert response.status_code == 429
    assert "Retry-After" in response.headers


def test_lockout_expires(anon, monkeypatch):
    for _ in range(config.LOGIN_MAX_FAILURES):
        _login(anon, password="nope-nope-nope")
    real_time = time.time
    monkeypatch.setattr(session.time, "time", lambda: real_time() + config.LOGIN_LOCKOUT_SECONDS + 1)
    assert _login(anon).status_code == 200


def test_logout_ends_the_session(anon):
    _login(anon)
    assert anon.post("/api/v1/auth/logout").status_code == 200
    assert anon.get("/api/v1/auth/me").status_code == 401


def test_idle_sessions_expire(client, monkeypatch):
    real_time = time.time
    monkeypatch.setattr(session.time, "time", lambda: real_time() + config.SESSION_IDLE_SECONDS + 5)
    assert client.get("/api/v1/auth/me").status_code == 401


# ── Password change ───────────────────────────────────────────────────────────


def test_password_change_needs_the_current_password(client):
    response = client.post(
        "/api/v1/auth/password",
        data={"current_password": "wrong", "new_password": "another-long-password"},
    )
    assert response.status_code == 400
    assert passwords.check("admin", TEST_PASSWORD)


def test_password_change_enforces_length(client):
    response = client.post(
        "/api/v1/auth/password", data={"current_password": TEST_PASSWORD, "new_password": "short"}
    )
    assert response.status_code == 400


def test_password_change_signs_out_other_sessions(client):
    from conftest import signed_in

    other = signed_in()
    response = client.post(
        "/api/v1/auth/password",
        data={"current_password": TEST_PASSWORD, "new_password": "another-long-password"},
    )
    assert response.status_code == 200
    assert passwords.check("admin", "another-long-password")
    assert other.get("/api/v1/auth/me").status_code == 401
    assert client.get("/api/v1/auth/me").status_code == 200


# ── Headers and envelope ──────────────────────────────────────────────────────


def test_security_headers_are_set(anon):
    response = anon.get("/healthz")
    assert response.headers["X-Frame-Options"] == "DENY"
    assert "frame-ancestors 'none'" in response.headers["Content-Security-Policy"]
    assert response.headers["X-Content-Type-Options"] == "nosniff"


def test_validation_errors_use_the_error_envelope(client):
    body = client.post("/api/v1/processes/kill", data={}).json()
    assert body["status"] == "error"
    assert body["code"] == 422
    assert "pid" in body["message"]


def test_audit_entries_carry_user_and_ip(client, fake_runner):
    client.post("/api/v1/system/install-utils")
    entry = json.loads(audit.log_path().read_text().splitlines()[-1])
    assert entry["user"] == "admin"
    assert entry["ip"]


def test_audit_detail_cannot_forge_lines():
    audit.log("test.action", "value\n2026-01-01T00:00:00Z | auth.login | forged")
    lines = audit.log_path().read_text().splitlines()
    assert len(lines) == 1
    assert audit.entries()[0]["action"] == "test.action"


def test_audit_reads_legacy_lines():
    audit.log_path().write_text("2026-01-01T00:00:00Z | service.start | name=demo\n")
    assert audit.entries() == [
        {"ts": "2026-01-01T00:00:00Z", "action": "service.start", "detail": "name=demo", "user": "", "ip": ""}
    ]


def test_logs_endpoint_filters_and_pages(client):
    for i in range(5):
        audit.log("service.start", f"name=svc{i}")
    audit.log("site.create", "name=blog")
    rows = client.get("/api/v1/logs", params={"q": "site."}).json()["data"]
    assert [r["detail"] for r in rows] == ["name=blog"]
    page = client.get("/api/v1/logs", params={"limit": 2, "offset": 1}).json()["data"]
    assert [r["detail"] for r in page] == ["name=svc4", "name=svc3"]


def test_version_endpoint(client):
    data = client.get("/api/v1/version").json()["data"]
    assert {"version", "commit", "bundle_stale"} <= data.keys()
