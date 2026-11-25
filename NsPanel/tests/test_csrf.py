"""CSRF guard: a session alone must not be enough to change state."""
from conftest import signed_in


def test_post_without_the_header_is_refused_before_anything_runs(fake_runner):
    response = signed_in(csrf=False).post("/api/v1/system/install-utils")
    assert response.status_code == 403
    assert "X-NsPanel" in response.json()["message"]
    assert fake_runner.jobs == []


def test_cross_site_post_is_refused_even_with_the_header(client, fake_runner):
    response = client.post("/api/v1/system/install-utils", headers={"Sec-Fetch-Site": "cross-site"})
    assert response.status_code == 403
    assert fake_runner.jobs == []


def test_foreign_origin_is_refused(client, fake_runner):
    response = client.post("/api/v1/system/install-utils", headers={"Origin": "http://evil.example"})
    assert response.status_code == 403
    assert fake_runner.jobs == []


def test_same_origin_post_goes_through(client, fake_runner):
    response = client.post("/api/v1/system/install-utils", headers={"Origin": "http://testserver"})
    assert response.status_code == 200
    assert fake_runner.jobs


def test_reads_do_not_need_the_header():
    assert signed_in(csrf=False).get("/api/v1/logs").status_code == 200
