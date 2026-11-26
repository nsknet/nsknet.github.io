"""Jobs listing and the stream's opening `meta` event."""

import asyncio
import json

import pytest

from core import runner


@pytest.fixture
def jobs(monkeypatch):
    """A clean in-memory job table with one finished and one running job."""
    table = runner.OrderedDict()
    monkeypatch.setattr(runner, "_jobs", table)
    table["old"] = {
        "cmd": ["true"],
        "label": "Old job",
        "status": "done",
        "exit_code": 0,
        "created_at": 100.0,
        "started_at": 100.0,
        "finished_at": 104.5,
        "lines": ["a", "b"],
        "env": {"DB_PASSWORD": "secret"},
    }
    table["new"] = {
        "cmd": ["sleep", "9"],
        "label": "New job",
        "status": "running",
        "exit_code": None,
        "created_at": 200.0,
        "started_at": 200.0,
        "finished_at": None,
        "lines": [],
        "env": {},
    }
    return table


def test_jobs_are_listed_newest_first_without_argv_env_or_output(client, jobs):
    body = client.get("/api/v1/jobs").json()
    assert body["status"] == "success"
    ids = [job["id"] for job in body["data"]]
    assert ids == ["new", "old"]
    old = body["data"][1]
    assert old["label"] == "Old job"
    assert old["line_count"] == 2
    assert old["finished_at"] == 104.5
    text = json.dumps(body)
    assert "secret" not in text and "sleep" not in text


def test_stream_opens_with_meta_carrying_the_elapsed_time(jobs):
    async def first_two():
        gen = runner.stream_job("old")
        return [await gen.__anext__(), await gen.__anext__()]

    meta, line = asyncio.run(first_two())
    assert meta.startswith("event: meta\n")
    payload = json.loads(meta.split("data: ", 1)[1])
    assert payload == {"status": "done", "elapsed": 4.5}
    assert line == "event: line\ndata: a\n\n"


def test_create_job_records_timestamps(monkeypatch):
    monkeypatch.setattr(runner, "_jobs", runner.OrderedDict())
    job_id = runner.create_job(["true"], label="x")
    job = runner.get_job(job_id)
    assert job["created_at"] > 0
    assert job["started_at"] is None and job["finished_at"] is None


def test_cancel_stops_a_running_job_and_is_audited(client, jobs, monkeypatch, audit_log):
    cancelled = []
    monkeypatch.setattr(runner, "cancel", lambda job_id: cancelled.append(job_id) or True)
    response = client.post("/api/v1/jobs/new/cancel")
    assert response.status_code == 200
    assert cancelled == ["new"]
    assert audit_log and audit_log[0][0] == "job.cancel"


def test_cancel_reports_unknown_and_finished_jobs(client, jobs, monkeypatch):
    monkeypatch.setattr(runner, "cancel", lambda job_id: False)
    assert client.post("/api/v1/jobs/nope/cancel").status_code == 404
    assert client.post("/api/v1/jobs/old/cancel").status_code == 409


def test_stream_needs_a_session(anon, jobs):
    assert anon.get("/stream/old").status_code == 401
