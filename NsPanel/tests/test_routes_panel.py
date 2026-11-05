"""Panel service routes, and the update check against real (temporary) git repos."""
import shutil
import subprocess
from pathlib import Path

import pytest

import config
from features import panel_service

_SUBNETS = [
    {"cidr": "192.168.1.0/24", "label": "This LAN (eth0)", "default": False},
    {"cidr": "10.0.0.0/8", "label": "Class A — private", "default": True},
    {"cidr": "192.168.0.0/16", "label": "Class C — private", "default": True},
    {"cidr": "0.0.0.0/0", "label": "Any IP — public", "default": False},
]


@pytest.fixture
def svc(monkeypatch):
    """Not installed, not self, the host on 192.168.1.0/24."""
    flags = {"installed": False, "self": False}
    monkeypatch.setattr(panel_service, "is_installed", lambda: flags["installed"])
    monkeypatch.setattr(panel_service, "is_self", lambda: flags["self"])
    monkeypatch.setattr(panel_service, "lan_subnet_choices", lambda: _SUBNETS)
    return flags


def _install(client, **fields):
    form = {"password": "Str0ng-pass-123", "port": "7778", "allowed_subnets": "192.168.1.0/24,10.0.0.0/8"}
    form.update(fields)
    return client.post("/api/v1/panel/install", data=form)


def test_status_has_the_fields_the_page_reads(client, svc, monkeypatch):
    monkeypatch.setattr(panel_service, "_read_state", lambda: {})
    data = client.get("/api/v1/panel").json()["data"]
    for key in (
        "installed", "active", "enabled", "port", "urls", "installed_commit",
        "running_commit", "update", "is_self", "subnet_choices", "default_port",
    ):
        assert key in data
    assert data["installed"] is False
    assert data["default_port"] == 7778


def test_install_passes_the_password_through_env_not_argv(client, svc, fake_runner):
    response = _install(client)
    assert response.status_code == 200, response.text
    job = fake_runner.last
    assert "panel_service_install" in job["cmd"]
    assert job["cmd"][-1] == "panel_service_install"
    assert "Str0ng-pass-123" not in " ".join(job["cmd"])
    assert job["env"]["SVC_PASSWORD"] == "Str0ng-pass-123"
    assert job["env"]["SVC_PORT"] == "7778"
    assert job["env"]["ALLOWED_SUBNETS"] == "192.168.1.0/24 10.0.0.0/8"
    assert job["env"]["SVC_REPO_DIR"] == config.SERVICE_REPO_DIR.as_posix()
    assert job["env"]["SVC_SELF"] == "0"


def test_password_not_in_audit_log(client, svc, fake_runner, audit_log):
    _install(client)
    assert audit_log and all("Str0ng-pass-123" not in detail for _, detail in audit_log)


@pytest.mark.parametrize(
    ("fields", "message"),
    [
        ({"password": ""}, "required"),
        ({"password": "short1"}, "at least 8"),
        ({"password": "only-eleven"}, "12 characters"),
        ({"password": 'has"quote-12345'}, "may only contain"),
        ({"port": "80"}, "between 1024"),
        ({"port": "abc"}, "number"),
        ({"port": str(config.PORT)}, "used by the panel"),
        ({"allowed_subnets": ""}, "at least one subnet"),
        ({"allowed_subnets": "8.8.8.0/24"}, "Invalid subnet"),
    ],
)
def test_install_validation(client, svc, fake_runner, fields, message):
    response = _install(client, **fields)
    assert response.status_code == 400
    assert message in response.json()["detail"]
    assert fake_runner.jobs == []


def test_any_ip_collapses_the_other_subnets(client, svc, fake_runner):
    _install(client, allowed_subnets="10.0.0.0/8,0.0.0.0/0")
    assert fake_runner.last["env"]["ALLOWED_SUBNETS"] == "0.0.0.0/0"


def test_the_service_may_be_reconfigured_on_its_own_port(client, svc, fake_runner):
    svc.update(installed=True, self=True)
    response = _install(client, port=str(config.PORT))
    assert response.status_code == 200
    assert fake_runner.last["env"]["SVC_SELF"] == "1"
    assert fake_runner.last["label"].startswith("Reconfigure")


@pytest.mark.parametrize("action", ["update", "restart", "uninstall", "check"])
def test_actions_need_an_installed_service(client, svc, fake_runner, action):
    response = client.post(f"/api/v1/panel/{action}")
    assert response.status_code == 400
    assert "not installed" in response.json()["detail"]


@pytest.mark.parametrize(("action", "function"), [
    ("update", "panel_service_update"),
    ("restart", "panel_service_restart"),
    ("uninstall", "panel_service_uninstall"),
])
def test_actions_run_their_script_function(client, svc, fake_runner, action, function):
    svc["installed"] = True
    assert client.post(f"/api/v1/panel/{action}").status_code == 200
    assert fake_runner.last_cmd[-1] == function


def test_the_service_cannot_uninstall_itself(client, svc, fake_runner):
    svc.update(installed=True, self=True)
    response = client.post("/api/v1/panel/uninstall")
    assert response.status_code == 400
    assert fake_runner.jobs == []


def test_actions_need_the_csrf_header(svc, fake_runner):
    import base64

    from fastapi.testclient import TestClient

    import app as app_module
    from core import auth

    token = base64.b64encode(f"admin:{auth.get_password()}".encode()).decode()
    bare = TestClient(app_module.app, headers={"Authorization": f"Basic {token}"})
    assert bare.post("/api/v1/panel/install", data={"password": "Str0ng-pass-123"}).status_code == 403
    assert fake_runner.jobs == []


# ── check_updates against real repos ─────────────────────────────────────────

_git_missing = shutil.which("git") is None


def _git(cwd: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", *args],
        cwd=cwd, check=True, capture_output=True, text=True,
    ).stdout.strip()


def _commit(repo: Path, path: str, message: str) -> None:
    file = repo / path
    file.parent.mkdir(parents=True, exist_ok=True)
    file.write_text(message, encoding="utf-8")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", message)


@pytest.mark.skipif(_git_missing, reason="git not installed")
def test_check_updates_counts_only_panel_commits(tmp_path, monkeypatch):
    upstream = tmp_path / "upstream"
    upstream.mkdir()
    _git(upstream, "init", "-q", "-b", "main")
    _commit(upstream, "NsPanel/app.py", "initial")
    clone = tmp_path / "clone"
    _git(tmp_path, "clone", "-q", str(upstream), str(clone))

    _commit(upstream, "NsPanel/app.py", "panel change")
    _commit(upstream, "SampleBlankSite/site.tar", "rebuild sample")

    conf = tmp_path / "etc"
    conf.mkdir()
    monkeypatch.setattr(config, "SERVICE_REPO_DIR", clone)
    monkeypatch.setattr(config, "SERVICE_STATE_FILE", conf / "state.json")

    result = panel_service.check_updates()
    assert result["error"] is None
    assert result["behind"] == 1
    assert result["total_behind"] == 2
    assert [c["subject"] for c in result["commits"]] == ["panel change"]
    assert result["base"] == _git(clone, "rev-parse", "HEAD")
    assert panel_service._read_state()["update"]["behind"] == 1


@pytest.mark.skipif(_git_missing, reason="git not installed")
def test_check_updates_reports_a_failed_fetch(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    _commit(repo, "NsPanel/app.py", "initial")
    _git(repo, "remote", "add", "origin", str(tmp_path / "missing"))
    monkeypatch.setattr(config, "SERVICE_REPO_DIR", repo)
    monkeypatch.setattr(config, "SERVICE_STATE_FILE", tmp_path / "nope" / "state.json")

    result = panel_service.check_updates()
    assert result["error"] and "fetch failed" in result["error"]
    assert result["behind"] == 0
