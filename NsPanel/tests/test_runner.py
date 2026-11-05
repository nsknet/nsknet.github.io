"""The job runner against a real (tiny) subprocess."""
import asyncio
import sys

from core import runner


def _run(cmd: list[str]) -> dict:
    job_id = runner.create_job(cmd, label="test")
    asyncio.run(runner._run(job_id))
    return runner.get_job(job_id)


def test_jobs_get_an_empty_stdin_and_noninteractive_env():
    probe = (
        "import os, sys; "
        "print('stdin=' + repr(sys.stdin.read())); "
        "print('frontend=' + os.environ.get('DEBIAN_FRONTEND', ''))"
    )
    job = _run([sys.executable, "-c", probe])
    assert job["status"] == "done"
    assert "stdin=''" in job["lines"]
    assert "frontend=noninteractive" in job["lines"]


def test_finished_job_has_timestamps_and_exit_code():
    job = _run([sys.executable, "-c", "raise SystemExit(3)"])
    assert job["status"] == "failed"
    assert job["exit_code"] == 3
    assert job["started_at"] is not None
    assert job["finished_at"] >= job["started_at"]
