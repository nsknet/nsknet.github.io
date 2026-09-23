"""Shared fixtures.

Nothing here touches the real system: the job runner is faked so tests record
the command a route *would* run, and the status probes are stubbed. That keeps
the suite runnable on any OS, which is where the panel is developed.
"""
import base64
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import app as app_module  # noqa: E402
from core import auth, runner  # noqa: E402


@pytest.fixture(autouse=True)
def isolated_audit_log(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Keep every test's audit writes out of the checkout."""
    from core import audit

    path = tmp_path / "audit.log"
    monkeypatch.setattr(audit, "AUDIT_LOG", path)
    return path


@pytest.fixture
def client() -> TestClient:
    """Authenticated client — Basic Auth header is attached to every request."""
    token = base64.b64encode(f"admin:{auth.get_password()}".encode()).decode()
    return TestClient(app_module.app, headers={"Authorization": f"Basic {token}"})


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

    def create_job(cmd, label="", env=None):
        job_id = f"job{len(recorder.jobs)}"
        recorder.jobs.append({"id": job_id, "cmd": [str(c) for c in cmd], "label": label, "env": env or {}})
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
