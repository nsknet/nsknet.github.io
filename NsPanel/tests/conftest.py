"""Shared fixtures.

Nothing here touches the real system: the job runner is faked so tests record
the command a route *would* run, and the status probes are stubbed. That keeps
the suite runnable on any OS, which is where the panel is developed.
"""

import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import app as app_module  # noqa: E402
import config  # noqa: E402
from core import audit, auth, passwords, runner, session  # noqa: E402

TEST_PASSWORD = "correct-horse-battery"


@pytest.fixture(autouse=True)
def isolated_state(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Audit log, password hash and job history live in tmp_path, never the checkout."""
    path = tmp_path / "audit.log"
    audit.set_path(path)
    monkeypatch.setenv("NSPANEL_AUTH_FILE", str(tmp_path / "auth.json"))
    monkeypatch.setenv("NSPANEL_STATE_DIR", str(tmp_path))
    monkeypatch.delenv("PANEL_PASSWORD", raising=False)
    session.reset()
    passwords.save(TEST_PASSWORD, "admin")
    yield path
    audit.set_path(None)
    session.reset()


def signed_in(*, csrf: bool = True) -> TestClient:
    """A client holding a live session cookie; `csrf=False` omits the X-NsPanel header."""
    headers = {auth.CSRF_HEADER: "1"} if csrf else {}
    test_client = TestClient(app_module.app, headers=headers)
    test_client.cookies.set(config.SESSION_COOKIE, session.create("admin", "testclient"))
    return test_client


@pytest.fixture
def client() -> TestClient:
    """Signed-in client that also sends the CSRF header."""
    return signed_in()


@pytest.fixture
def anon() -> TestClient:
    """No session, CSRF header set — for the login flow."""
    return TestClient(app_module.app, headers={auth.CSRF_HEADER: "1"})


class FakeRunner:
    """Records launched jobs instead of spawning subprocesses."""

    def __init__(self) -> None:
        self.jobs: list[dict] = []

    @property
    def last(self) -> dict:
        assert self.jobs, "no job was launched"
        return self.jobs[-1]

    @property
    def last_cmd(self) -> list[str]:
        return self.last["cmd"]


@pytest.fixture
def fake_runner(monkeypatch: pytest.MonkeyPatch) -> FakeRunner:
    recorder = FakeRunner()

    def create_job(cmd, label="", env=None, **kwargs):
        job_id = f"job{len(recorder.jobs)}"
        recorder.jobs.append(
            {"id": job_id, "cmd": [str(c) for c in cmd], "label": label, "env": env or {}, **kwargs}
        )
        return job_id

    monkeypatch.setattr(runner, "create_job", create_job)
    monkeypatch.setattr(runner, "start_job", lambda job_id: None)
    return recorder


@pytest.fixture
def audit_log(monkeypatch: pytest.MonkeyPatch) -> list[tuple[str, str]]:
    """Captures audit entries instead of appending to the real log file."""
    from core import audit

    entries: list[tuple[str, str]] = []
    monkeypatch.setattr(audit, "log", lambda action, detail="": entries.append((action, detail)))
    return entries
