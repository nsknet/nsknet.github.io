"""Tools API: install guards, secret handling and firewall scoping."""
import pytest

from modules import registry


@pytest.fixture
def stub_tools(monkeypatch):
    """postgres reports 'not installed' so the install guard does not trip."""
    postgres = registry.get_module("postgres")
    nginx = registry.get_module("nginx")
    monkeypatch.setattr(type(postgres), "is_installed", lambda self: False)
    monkeypatch.setattr(type(nginx), "is_installed", lambda self: True)
    return {"postgres": postgres, "nginx": nginx}


def test_list_tools_returns_metadata_and_status(client, stub_tools, monkeypatch):
    monkeypatch.setattr(
        registry,
        "serialize_all",
        lambda: [registry.serialize(stub_tools["postgres"])],
    )
    body = client.get("/api/v1/tools").json()
    tool = body["data"][0]
    assert tool["module"]["name"] == "postgres"
    assert tool["module"]["requires_password"] is True
    assert "installed" in tool["status"]


def test_unknown_tool_is_404(client, fake_runner):
    assert client.post("/api/v1/tools/nope/install").status_code == 404


def test_install_refuses_when_already_installed(client, stub_tools, fake_runner, audit_log):
    response = client.post("/api/v1/tools/nginx/install")
    assert response.status_code == 400
    assert not fake_runner.jobs
    assert audit_log[0][0] == "tool.install_refused"


def test_reinstall_bypasses_the_installed_guard(client, stub_tools, fake_runner, audit_log):
    body = client.post("/api/v1/tools/nginx/install", data={"reinstall": "true"}).json()
    assert body["title"] == "Re-installing NGINX Web Server"
    assert audit_log[0][0] == "tool.reinstall"


def test_install_requires_a_password_when_the_module_asks_for_one(client, stub_tools, fake_runner):
    assert client.post("/api/v1/tools/postgres/install").status_code == 400
    assert client.post("/api/v1/tools/postgres/install", data={"db_password": "short"}).status_code == 400
    assert not fake_runner.jobs


def test_password_travels_by_env_not_argv(client, stub_tools, fake_runner, audit_log):
    client.post("/api/v1/tools/postgres/install", data={"db_password": "Str0ngPass-1"})
    assert fake_runner.last["env"]["DB_PASSWORD"] == "Str0ngPass-1"
    assert "Str0ngPass-1" not in " ".join(fake_runner.last_cmd)
    assert all("Str0ngPass-1" not in detail for _, detail in audit_log)


def test_invalid_subnets_are_rejected(client, stub_tools, fake_runner):
    response = client.post(
        "/api/v1/tools/postgres/install",
        data={"db_password": "Str0ngPass-1", "allowed_subnets": "10.0.0.0/8,evil.example.com"},
    )
    assert response.status_code == 400
    assert not fake_runner.jobs


def test_any_subnet_collapses_the_others(client, stub_tools, fake_runner, audit_log):
    client.post(
        "/api/v1/tools/postgres/install",
        data={"db_password": "Str0ngPass-1", "allowed_subnets": "10.0.0.0/8,0.0.0.0/0"},
    )
    assert fake_runner.last["env"]["ALLOWED_SUBNETS"] == "0.0.0.0/0"


def test_install_params_are_validated_against_their_options(client, fake_runner, monkeypatch):
    mssql = registry.get_module("mssql")
    monkeypatch.setattr(type(mssql), "is_installed", lambda self: False)
    bad = client.post(
        "/api/v1/tools/mssql/install",
        data={"db_password": "Str0ngPass-1", "edition": "pirate"},
    )
    assert bad.status_code == 400
    assert not fake_runner.jobs


def test_install_params_reach_the_job_environment(client, fake_runner, audit_log, monkeypatch):
    mssql = registry.get_module("mssql")
    monkeypatch.setattr(type(mssql), "is_installed", lambda self: False)
    client.post(
        "/api/v1/tools/mssql/install",
        data={"db_password": "Str0ngPass-1", "edition": "express"},
    )
    assert fake_runner.last["env"]["MSSQL_PID"] == "express"


def test_uninstall_is_refused_when_the_module_has_no_uninstaller(client, fake_runner, monkeypatch):
    nginx = registry.get_module("nginx")
    monkeypatch.setattr(type(nginx), "uninstall_function", None)
    assert client.post("/api/v1/tools/nginx/uninstall").status_code == 400
    assert not fake_runner.jobs


def test_change_password_is_refused_when_unsupported(client, fake_runner):
    assert client.post(
        "/api/v1/tools/nginx/change-password", data={"db_password": "Str0ngPass-1"}
    ).status_code == 400
    assert not fake_runner.jobs
