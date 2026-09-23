"""Sites API: which bash function each backend type reaches, and what is refused."""
import pytest

from features import sites as sites_feature


@pytest.fixture
def stub_sites(monkeypatch):
    known = {"existing.com": {"type": "static"}, "app": {"type": "dotnet", "paths": {}}}
    monkeypatch.setattr(sites_feature, "read_info", lambda name: known.get(name))
    monkeypatch.setattr(sites_feature, "get_site", lambda name: known.get(name))
    monkeypatch.setattr(sites_feature, "list_sites_with_status", lambda: [{"name": "app"}])
    monkeypatch.setattr(sites_feature, "read_config", lambda info: "server { }")
    monkeypatch.setattr(sites_feature, "tail_logs", lambda info: {"access": "hit"})
    return known


def _bash_function(cmd: list[str]) -> str:
    """build_cmd puts the function name right after the script path."""
    return cmd[5]


def test_list_sites_uses_the_data_envelope(client, stub_sites):
    assert client.get("/api/v1/sites").json()["data"] == [{"name": "app"}]


def test_config_and_logs_return_text_under_data(client, stub_sites):
    assert client.get("/api/v1/sites/existing.com/config").json()["data"] == "server { }"
    assert "access" in client.get("/api/v1/sites/app/logs").json()["data"]


def test_create_static_site_calls_add_static_site(client, stub_sites, fake_runner, audit_log):
    body = client.post(
        "/api/v1/sites/create",
        data={"access_kind": "port", "access_value": "8080", "backend_type": "static", "name": "demo"},
    ).json()
    assert body["title"] == "Creating site 'demo'"
    assert _bash_function(fake_runner.last_cmd) == "add_static_site"


def test_create_domain_site_is_named_after_the_domain(client, stub_sites, fake_runner, audit_log):
    client.post(
        "/api/v1/sites/create",
        data={
            "access_kind": "domain",
            "access_value": "shop.example.com",
            "backend_type": "proxy",
            "proxy_target": "http://127.0.0.1:5000",
            "auto_ssl": "true",
        },
    )
    args = fake_runner.last_cmd[6:]
    assert args[0] == "shop.example.com"
    assert args[-1] == "ssl"


def test_ssl_is_ignored_for_port_bound_sites(client, stub_sites, fake_runner, audit_log):
    client.post(
        "/api/v1/sites/create",
        data={
            "access_kind": "port",
            "access_value": "8080",
            "backend_type": "static",
            "name": "demo",
            "auto_ssl": "true",
        },
    )
    assert "ssl" not in fake_runner.last_cmd


def test_create_dotnet_site_strips_the_dll_suffix(client, stub_sites, fake_runner, audit_log):
    client.post(
        "/api/v1/sites/create",
        data={
            "access_kind": "port",
            "access_value": "8080",
            "backend_type": "dotnet",
            "name": "api",
            "dll_name": "MyApp.dll",
            "internal_port": "5123",
        },
    )
    args = fake_runner.last_cmd[6:]
    assert _bash_function(fake_runner.last_cmd) == "add_dotnet_site"
    assert "MyApp" in args and "MyApp.dll" not in args


@pytest.mark.parametrize(
    "payload",
    [
        {"access_kind": "nonsense", "access_value": "8080", "backend_type": "static", "name": "x"},
        {"access_kind": "port", "access_value": "8080", "backend_type": "nonsense", "name": "x"},
        {"access_kind": "port", "access_value": "notaport", "backend_type": "static", "name": "x"},
        {"access_kind": "domain", "access_value": "bad domain", "backend_type": "static"},
        {"access_kind": "port", "access_value": "8080", "backend_type": "proxy", "name": "x",
         "proxy_target": "file:///etc/passwd"},
        {"access_kind": "port", "access_value": "8080", "backend_type": "dotnet", "name": "x",
         "dll_name": "App", "internal_port": "abc"},
    ],
)
def test_create_rejects_bad_input(client, stub_sites, fake_runner, payload):
    response = client.post("/api/v1/sites/create", data=payload)
    assert response.status_code in (400, 422)
    assert not fake_runner.jobs


def test_create_refuses_duplicates(client, stub_sites, fake_runner):
    response = client.post(
        "/api/v1/sites/create",
        data={"access_kind": "domain", "access_value": "existing.com", "backend_type": "static"},
    )
    assert response.status_code == 400
    assert not fake_runner.jobs


def test_service_actions_only_apply_to_dotnet_sites(client, stub_sites, fake_runner):
    assert client.post("/api/v1/sites/existing.com/restart").status_code == 400
    assert client.post("/api/v1/sites/ghost/restart").status_code == 404
    assert client.post("/api/v1/sites/app/restart").json()["title"] == "Restarting 'app'"
    assert fake_runner.last_cmd == ["systemctl", "restart", "app"]
