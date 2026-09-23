"""Services API: validation, the job it launches, and the response envelope."""
import pytest

from features import units


@pytest.fixture
def stub_units(monkeypatch, tmp_path):
    """Pretend 'demo' exists and keep unit files inside tmp_path."""
    existing = {"demo"}

    monkeypatch.setattr(units, "service_exists", lambda name: name in existing)
    monkeypatch.setattr(units, "svc_path", lambda name: tmp_path / f"{name}.service")
    monkeypatch.setattr(
        units,
        "list_services",
        lambda: [{"name": "demo", "state": "active", "enabled": "enabled"}],
    )
    monkeypatch.setattr(
        units, "get_service", lambda name: {"name": name} if name in existing else None
    )
    monkeypatch.setattr(units, "get_status_output", lambda name: f"● {name} running")
    monkeypatch.setattr(units, "get_journal_logs", lambda name, lines=60: "log line")
    monkeypatch.setattr(units, "write_service_raw", lambda name, content: None)

    def write_service(name, description, working_dir, command, user, env_vars, unit_extra=None):
        path = tmp_path / f"{name}.service"
        path.write_text("[Unit]\n")
        existing.add(name)
        return path

    monkeypatch.setattr(units, "write_service", write_service)
    return existing


def test_list_services_uses_the_data_envelope(client, stub_units):
    body = client.get("/api/v1/services").json()
    assert body["status"] == "success"
    assert body["data"][0]["name"] == "demo"


def test_unknown_service_is_404(client, stub_units):
    assert client.get("/api/v1/services/ghost").status_code == 404


def test_status_and_logs_return_text_under_data(client, stub_units):
    assert client.get("/api/v1/services/demo/status").json()["data"] == "● demo running"
    assert client.get("/api/v1/services/demo/logs").json()["data"] == "log line"


def test_start_launches_systemctl_and_audits(client, stub_units, fake_runner, audit_log):
    body = client.post("/api/v1/services/demo/start").json()
    assert body["job_id"] == fake_runner.last["id"]
    assert body["title"] == "Starting 'demo'"
    assert fake_runner.last_cmd == ["systemctl", "start", "demo"]
    assert audit_log[0][0] == "service.start"


def test_lifecycle_actions_on_missing_service_are_404(client, stub_units, fake_runner):
    for verb in ("start", "stop", "restart", "enable", "disable", "delete"):
        assert client.post(f"/api/v1/services/ghost/{verb}").status_code == 404, verb
    assert not fake_runner.jobs


def test_delete_never_splices_the_name_into_the_shell_script(client, stub_units, fake_runner, audit_log):
    client.post("/api/v1/services/demo/delete")
    cmd = fake_runner.last_cmd
    assert cmd[:2] == ["bash", "-c"]
    assert "demo" not in cmd[2]
    assert "demo" in cmd[4:]


@pytest.mark.parametrize("name", ["bad name", "../escape", "semi;colon", ""])
def test_create_rejects_unsafe_names(client, stub_units, fake_runner, name):
    response = client.post(
        "/api/v1/services/create",
        data={"name": name, "working_dir": "/srv/app", "command": "/srv/app/run"},
    )
    assert response.status_code in (400, 422)
    assert not fake_runner.jobs


def test_create_requires_working_dir_and_command(client, stub_units, fake_runner):
    response = client.post("/api/v1/services/create", data={"name": "newapp"})
    assert response.status_code == 422
    assert not fake_runner.jobs


def test_create_refuses_duplicates(client, stub_units, fake_runner):
    response = client.post(
        "/api/v1/services/create",
        data={"name": "demo", "working_dir": "/srv/demo", "command": "/srv/demo/run"},
    )
    assert response.status_code == 400
    assert not fake_runner.jobs


def test_create_writes_the_unit_then_enables_and_starts_it(client, stub_units, fake_runner, audit_log):
    body = client.post(
        "/api/v1/services/create",
        data={
            "name": "newapp",
            "working_dir": "/srv/newapp",
            "command": "/srv/newapp/run",
            "env_vars": "A=1\n\nB=2\n",
        },
    ).json()
    assert body["title"] == "Starting service 'newapp'"
    script = fake_runner.last_cmd[2]
    assert script.count("&&") == 3  # daemon-reload && enable && start && echo
    assert audit_log[0][0] == "service.create"
