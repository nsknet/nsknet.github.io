"""CSRF guard: Basic Auth alone must not be enough to change state."""
import base64

from fastapi.testclient import TestClient

import app as app_module
from core import auth


def _basic_only() -> TestClient:
    token = base64.b64encode(f"admin:{auth.get_password()}".encode()).decode()
    return TestClient(app_module.app, headers={"Authorization": f"Basic {token}"})


def test_post_without_the_header_is_refused_before_anything_runs(fake_runner):
    response = _basic_only().post("/api/v1/system/install-utils")
    assert response.status_code == 403
    assert "X-NsPanel" in response.json()["detail"]
    assert fake_runner.jobs == []


def test_cross_site_post_is_refused_even_with_the_header(client, fake_runner):
    response = client.post(
        "/api/v1/system/install-utils", headers={"Sec-Fetch-Site": "cross-site"}
    )
    assert response.status_code == 403
    assert fake_runner.jobs == []


def test_post_with_the_header_goes_through(client, fake_runner):
    response = client.post("/api/v1/system/install-utils")
    assert response.status_code == 200
    assert fake_runner.jobs


def test_reads_do_not_need_the_header():
    assert _basic_only().get("/api/v1/logs").status_code == 200
