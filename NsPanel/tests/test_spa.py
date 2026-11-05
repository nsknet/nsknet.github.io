"""SPA fallback: client routes get index.html, server paths get real 404s, and
cache headers keep a reload from pinning a bundle that a `git pull` removed."""
import pytest

import app as app_module


@pytest.fixture
def dist(tmp_path, monkeypatch):
    (tmp_path / "assets").mkdir()
    (tmp_path / "index.html").write_text("<!doctype html><div id=app></div>")
    (tmp_path / "assets" / "index-abc123.js").write_text("console.log(1)")
    monkeypatch.setattr(app_module, "DIST_DIR", tmp_path)
    return tmp_path


def test_root_and_client_routes_serve_index_without_caching(client, dist):
    for path in ("/", "/sites/demo", "/anything/else"):
        response = client.get(path)
        assert response.status_code == 200
        assert "id=app" in response.text
        assert response.headers["cache-control"] == "no-cache"


def test_hashed_assets_are_immutable(client, dist):
    response = client.get("/assets/index-abc123.js")
    assert response.status_code == 200
    assert "immutable" in response.headers["cache-control"]


@pytest.mark.parametrize(
    "path", ["/api/v1/does-not-exist", "/stream", "/stream/", "/assets/index-old.js"]
)
def test_unknown_server_paths_are_404_not_index_html(client, dist, path):
    response = client.get(path)
    assert response.status_code == 404
    assert response.headers["content-type"].startswith("application/json")


def test_path_traversal_falls_back_to_index(client, dist):
    response = client.get("/..%2f..%2fetc/passwd")
    assert response.status_code in (200, 404)
    assert "root:" not in response.text
