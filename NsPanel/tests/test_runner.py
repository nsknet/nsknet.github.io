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


def test_panel_password_is_not_passed_to_jobs(monkeypatch):
    monkeypatch.setenv("PANEL_PASSWORD", "s3cret-value")
    job = _run([sys.executable, "-c", "import os; print('pw=' + os.environ.get('PANEL_PASSWORD', ''))"])
    assert "pw=" in job["lines"]


def test_output_is_capped(monkeypatch):
    monkeypatch.setattr(runner, "MAX_JOB_LINES", 50)
    monkeypatch.setattr(runner, "_TRIM_CHUNK", 10)
    job = _run([sys.executable, "-c", "for i in range(200): print(i)"])
    assert len(job["lines"]) <= 50
    assert job["dropped"] > 0
    assert "Success: exit 0" in job["lines"][-1]


def test_a_job_that_cannot_start_still_finishes():
    job = _run(["definitely-not-a-real-command-xyz"])
    assert job["status"] == "failed"
    assert job["exit_code"] == 127
    assert job["finished_at"] is not None


def test_timeout_stops_the_job(monkeypatch):
    monkeypatch.setattr(runner, "_KILL_GRACE", 1)
    job_id = runner.create_job([sys.executable, "-c", "import time; time.sleep(30)"], timeout=1)
    asyncio.run(runner._run(job_id))
    job = runner.get_job(job_id)
    assert job["status"] == "failed"
    assert job["exit_code"] == 124


def test_cancel_stops_a_running_job(monkeypatch):
    monkeypatch.setattr(runner, "_KILL_GRACE", 1)

    async def scenario():
        runner.set_event_loop(asyncio.get_running_loop())
        job_id = runner.create_job([sys.executable, "-c", "import time; time.sleep(30)"])
        task = asyncio.create_task(runner._run(job_id))
        for _ in range(100):
            if job_id in runner._procs:
                break
            await asyncio.sleep(0.05)
        assert runner.cancel(job_id)
        await asyncio.wait_for(task, timeout=20)
        return runner.get_job(job_id)

    job = asyncio.run(scenario())
    assert job["status"] == "failed"
    assert job["cancel_requested"]
    assert not runner.cancel("no-such-job")


def test_exclusive_jobs_run_one_at_a_time():
    async def scenario():
        runner._exclusive_lock = None
        code = "import time; print('start', time.time()); time.sleep(0.4); print('end', time.time())"
        first = runner.create_job([sys.executable, "-c", code], exclusive=True)
        second = runner.create_job([sys.executable, "-c", code], exclusive=True)
        await asyncio.gather(runner._run(first), runner._run(second))
        return runner.get_job(first), runner.get_job(second)

    a, b = asyncio.run(scenario())

    def stamp(job, word):
        return float(next(line for line in job["lines"] if line.startswith(word)).split()[1])

    assert stamp(b, "start") >= stamp(a, "end") or stamp(a, "start") >= stamp(b, "end")


def test_finished_jobs_survive_a_restart_in_history():
    job_id = runner.create_job([sys.executable, "-c", "print('hi')"], label="history-test")
    asyncio.run(runner._run(job_id))
    del runner._jobs[job_id]
    runner.load_history()
    restored = runner.get_job(job_id)
    assert restored["label"] == "history-test"
    assert restored["status"] == "done"


def test_stream_replays_dropped_line_notice():
    job_id = runner.create_job(["x"], label="t")
    job = runner.get_job(job_id)
    job.update(status="done", exit_code=0, started_at=1.0, finished_at=2.0, lines=["last"], dropped=5)

    async def collect():
        return [chunk async for chunk in runner.stream_job(job_id)]

    chunks = asyncio.run(collect())
    assert any("5 earlier line(s) dropped" in c for c in chunks)
    assert chunks[-1].startswith("event: done")
