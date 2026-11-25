"""Async subprocess wrapper + SSE event generator.

A "job" is one subprocess invocation (a bash function, systemctl, etc.). Jobs
live in an in-memory dict keyed by a random id; a short record of each finished
job is also appended to a JSONL history file, so the Jobs screen survives a
restart (the output itself does not).

Guarantees:
- every job ends with a status, an exit code and a finish time, whatever fails;
- a job runs in its own process group, so cancel and timeout stop the whole tree;
- "exclusive" jobs (package installs) run one at a time instead of fighting
  over the dpkg lock;
- output is capped per job; the oldest lines are dropped first.
"""
import asyncio
import contextlib
import json
import os
import re
import signal
import time
import uuid
from collections import OrderedDict

import config
from config import JOB_TIMEOUT_SECONDS, MAX_JOB_LINES, MAX_JOBS

# Environment variables of the panel process that jobs must not inherit.
_PRIVATE_ENV = frozenset({"PANEL_PASSWORD"})

# Strip terminal escape sequences except SGR (colors/formatting) sequences.
# SGR sequences end with 'm' (e.g. \x1b[0m, \x1b[1;31m).
# CSI sequences end with a letter from @ to ~ (0x40 to 0x7E).
# We match CSI sequences ending with letters in [@-l] or [n-~], thus preserving 'm'.
_ANSI_STRIP = re.compile(
    r"\x1b\[[0-9;?]*[ -/]*[@-ln-~]"      # CSI except SGR (m)
    r"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"  # OSC
    r"|\x1b[a-ln-zB-Z]"                   # lone ESC followed by non-m, non-[ characters
)

FINISHED = ("done", "failed")
# Lines dropped at once when a job's buffer is full (amortises the list shift).
_TRIM_CHUNK = 1000
# Seconds between SIGTERM and SIGKILL when stopping a job.
_KILL_GRACE = 10
# SSE comment sent when a stream has been quiet this long, so proxies and VPNs
# do not drop an idle connection mid-job.
_SSE_PING_SECONDS = 15

# job_id -> job dict. Insertion-ordered and capped at MAX_JOBS: the oldest
# finished job is dropped when a new one starts.
_jobs: OrderedDict[str, dict] = OrderedDict()
_loop: asyncio.AbstractEventLoop | None = None
# Strong references to running job tasks: asyncio keeps only weak ones, and a
# task collected mid-run would leave its job "running" forever.
_tasks: set[asyncio.Task] = set()
_procs: dict[str, asyncio.subprocess.Process] = {}
_exclusive_lock: asyncio.Lock | None = None
_finish_callbacks: list = []


def on_job_finished(callback) -> None:
    """Call `callback()` whenever a job ends (e.g. to drop cached status probes)."""
    _finish_callbacks.append(callback)


def _evict_old_jobs() -> None:
    """Drop the oldest finished jobs once the store is over capacity."""
    while len(_jobs) > MAX_JOBS:
        for job_id, job in _jobs.items():
            if job["status"] in FINISHED:
                del _jobs[job_id]
                break
        else:
            # Everything still running — nothing safe to drop.
            return


def set_event_loop(loop: asyncio.AbstractEventLoop) -> None:
    global _loop
    _loop = loop


def create_job(
    cmd: list[str],
    label: str = "",
    env: dict[str, str] | None = None,
    *,
    exclusive: bool = False,
    timeout: int = JOB_TIMEOUT_SECONDS,
) -> str:
    job_id = uuid.uuid4().hex
    _jobs[job_id] = {
        "cmd": [str(c) for c in cmd],
        "label": label,
        "status": "pending",  # pending | running | done | failed
        "exit_code": None,
        # Epoch seconds; lets a client that reconnects (reload, Jobs screen)
        # show how long the job has been running.
        "created_at": time.time(),
        "started_at": None,
        "finished_at": None,
        "lines": [],
        # Lines dropped from the front of `lines` once it hit MAX_JOB_LINES.
        "dropped": 0,
        "exclusive": exclusive,
        "timeout": timeout,
        "cancel_requested": False,
        # Extra environment variables merged into the subprocess env. Used to pass
        # secrets (DB_PASSWORD) and config (ALLOWED_SUBNETS) without leaking them
        # into the displayed command line.
        "env": {str(k): str(v) for k, v in (env or {}).items()},
    }
    _evict_old_jobs()
    return job_id


def get_job(job_id: str) -> dict | None:
    return _jobs.get(job_id)


def summarize(job_id: str, job: dict) -> dict:
    """The public view of a job: everything except argv, env and the output."""
    return {
        "id": job_id,
        "label": job["label"],
        "status": job["status"],
        "exit_code": job["exit_code"],
        "created_at": job["created_at"],
        "started_at": job["started_at"],
        "finished_at": job["finished_at"],
        "line_count": job.get("dropped", 0) + len(job["lines"]),
        "cancelled": bool(job.get("cancel_requested")),
    }


def list_jobs() -> list[dict]:
    """Every job still in memory, newest first."""
    return [summarize(job_id, job) for job_id, job in reversed(_jobs.items())]


def running_count() -> int:
    return sum(1 for job in _jobs.values() if job["status"] not in FINISHED)


def start_job(job_id: str) -> None:
    """Schedule the subprocess on the running event loop."""
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        # Called from a sync route handler running in a threadpool — no event
        # loop in this thread, so schedule on the main loop captured at startup.
        assert _loop is not None, "runner.set_event_loop() was never called"
        asyncio.run_coroutine_threadsafe(_spawn(job_id), _loop)
        return
    _track(loop.create_task(_run(job_id)))


async def _spawn(job_id: str) -> None:
    _track(asyncio.get_running_loop().create_task(_run(job_id)))


def _track(task: asyncio.Task) -> None:
    _tasks.add(task)
    task.add_done_callback(_tasks.discard)


def _append(job: dict, line: str) -> None:
    lines = job["lines"]
    lines.append(line)
    if len(lines) > MAX_JOB_LINES:
        del lines[:_TRIM_CHUNK]
        job["dropped"] = job.get("dropped", 0) + _TRIM_CHUNK


def _display_cmd(cmd: list[str]) -> str:
    if len(cmd) >= 6 and cmd[0] == "bash" and cmd[1] == "-c":
        # Sourced execution format: ["bash", "-c", "...", "--", script_path, function_name, *args]
        script_name = os.path.basename(cmd[4])
        return f"bash {script_name} {cmd[5]} {' '.join(cmd[6:])}".strip()
    return " ".join(cmd)


def _job_env(job: dict) -> dict[str, str]:
    # The panel's own secrets never reach a job: apt hooks and third-party
    # installers run in these children. A job that needs a secret gets it
    # explicitly through job["env"].
    env = {k: v for k, v in os.environ.items() if k not in _PRIVATE_ENV}
    # Force color output in systemd and common CLI utilities.
    env["FORCE_COLOR"] = "1"
    env["CLICOLOR_FORCE"] = "1"
    env["SYSTEMD_COLORS"] = "1"
    env["TERM"] = "xterm-256color"
    # Jobs are unattended: apt/debconf and needrestart must never stop to ask.
    env["DEBIAN_FRONTEND"] = "noninteractive"
    env["NEEDRESTART_MODE"] = "a"
    env.update(job.get("env") or {})
    return env


def _finish(job_id: str, job: dict, code: int) -> None:
    job["exit_code"] = code
    job["finished_at"] = time.time()
    job["status"] = "done" if code == 0 else "failed"
    _record_history(job_id, job)
    for callback in _finish_callbacks:
        with contextlib.suppress(Exception):
            callback()


async def _run(job_id: str) -> None:
    global _exclusive_lock
    job = _jobs[job_id]
    code = 1
    try:
        if job["exclusive"]:
            if _exclusive_lock is None:
                _exclusive_lock = asyncio.Lock()
            if _exclusive_lock.locked():
                _append(job, "\x1b[2m⏳ Waiting for another install to finish…\x1b[0m")
            async with _exclusive_lock:
                code = await _execute(job_id, job)
        else:
            code = await _execute(job_id, job)
    except asyncio.CancelledError:
        _append(job, "\x1b[1;31m✗ Interrupted: the panel is shutting down\x1b[0m")
        code = 130
        raise
    except Exception as exc:  # never leave a job "running" forever
        _append(job, f"\x1b[1;31m✗ Internal error while running the job: {exc}\x1b[0m")
        code = 1
    finally:
        _procs.pop(job_id, None)
        _finish(job_id, job, code)


async def _execute(job_id: str, job: dict) -> int:
    if job["cancel_requested"]:
        _append(job, "\x1b[1;33m✗ Cancelled before it started\x1b[0m")
        return 130

    job["status"] = "running"
    job["started_at"] = time.time()
    _append(job, f"\x1b[1;36m$ {_display_cmd(job['cmd'])}\x1b[0m")

    try:
        proc = await asyncio.create_subprocess_exec(
            *job["cmd"],
            # No stdin: a stray `read` or password prompt gets EOF and fails fast
            # instead of reading the panel's terminal or hanging the job forever.
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            env=_job_env(job),
            # Own process group: cancel/timeout/shutdown signal the whole tree.
            start_new_session=os.name == "posix",
        )
    except Exception as exc:  # command not found, etc.
        _append(job, f"\x1b[1;31mfailed to start process: {exc}\x1b[0m")
        return 127
    _procs[job_id] = proc

    assert proc.stdout is not None

    async def _drain() -> None:
        async for raw in proc.stdout:
            _append(job, _ANSI_STRIP.sub("", raw.decode("utf-8", "replace").rstrip("\r\n")))

    # Read output concurrently (so the pipe never back-pressures the process),
    # then wait for the process itself to exit — keyed on its PID, not on the
    # pipe reaching EOF.
    drain_task = asyncio.create_task(_drain())
    try:
        code = await asyncio.wait_for(proc.wait(), timeout=job["timeout"])
    except TimeoutError:
        _append(job, f"\x1b[1;31m✗ Timed out after {job['timeout'] // 60} min — stopping it\x1b[0m")
        await _terminate(proc)
        code = 124
    except asyncio.CancelledError:
        await _terminate(proc)
        drain_task.cancel()
        raise

    # The process is gone, but a forked daemon may have inherited the stdout pipe
    # and kept its write end open (FUSE mount helpers such as ntfs-3g do exactly
    # this). Waiting for EOF would then hang forever. Give the drain a short grace
    # period to flush buffered output, then stop reading and abandon the pipe.
    try:
        await asyncio.wait_for(drain_task, timeout=2.0)
    except TimeoutError:
        _append(job, "\x1b[2m(output stream left open by a background process — continuing)\x1b[0m")

    if job["cancel_requested"] and code != 0:
        _append(job, "\x1b[1;33m✗ Cancelled\x1b[0m")
    elif code == 0:
        _append(job, "\x1b[1;32m✓ Success: exit 0\x1b[0m")
    else:
        _append(job, f"\x1b[1;31m✗ Failed: exit {code}\x1b[0m")
    return code


def _signal_group(proc: asyncio.subprocess.Process, sig: int) -> None:
    with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
        if os.name == "posix":
            os.killpg(proc.pid, sig)
        elif sig == signal.SIGTERM:
            proc.terminate()
        else:
            proc.kill()


async def _terminate(proc: asyncio.subprocess.Process) -> None:
    """SIGTERM the job's process group, then SIGKILL it if it lingers."""
    if proc.returncode is not None:
        return
    _signal_group(proc, signal.SIGTERM)
    try:
        await asyncio.wait_for(proc.wait(), timeout=_KILL_GRACE)
    except TimeoutError:
        _signal_group(proc, getattr(signal, "SIGKILL", signal.SIGTERM))
        with contextlib.suppress(TimeoutError):
            await asyncio.wait_for(proc.wait(), timeout=5)


def cancel(job_id: str) -> bool:
    """Ask a pending or running job to stop. False when it already finished."""
    job = _jobs.get(job_id)
    if job is None or job["status"] in FINISHED:
        return False
    job["cancel_requested"] = True
    _append(job, "\x1b[1;33m■ Cancel requested\x1b[0m")
    proc = _procs.get(job_id)
    if proc is not None and _loop is not None:
        if _on_loop():
            _track(_loop.create_task(_terminate(proc)))
        else:  # sync route handler in the threadpool
            asyncio.run_coroutine_threadsafe(_terminate(proc), _loop)
    return True


def _on_loop() -> bool:
    try:
        return asyncio.get_running_loop() is _loop
    except RuntimeError:
        return False


async def shutdown() -> None:
    """Stop every running job's process group (panel restart or stop)."""
    procs = list(_procs.values())
    await asyncio.gather(*(_terminate(proc) for proc in procs), return_exceptions=True)
    for task in list(_tasks):
        task.cancel()
    await asyncio.gather(*_tasks, return_exceptions=True)


# ── History ───────────────────────────────────────────────────────────────────


def _history_path():
    return config.state_dir() / "jobs.jsonl"


def _record_history(job_id: str, job: dict) -> None:
    record = {"id": job_id, **{k: v for k, v in summarize(job_id, job).items() if k != "id"}}
    try:
        path = _history_path()
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record) + "\n")
        if path.stat().st_size > 512 * 1024:
            _compact_history(path)
    except OSError:
        pass  # history is a convenience; never fail a job over it


def _compact_history(path) -> None:
    lines = path.read_text(encoding="utf-8").splitlines()[-config.JOB_HISTORY_KEEP :]
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    os.replace(tmp, path)


def load_history() -> None:
    """Put finished jobs from before the last restart back in the list (without output)."""
    try:
        lines = _history_path().read_text(encoding="utf-8").splitlines()[-MAX_JOBS:]
    except OSError:
        return
    for line in lines:
        try:
            record = json.loads(line)
        except ValueError:
            continue
        job_id = record.get("id")
        if not job_id or job_id in _jobs:
            continue
        _jobs[job_id] = {
            "cmd": [],
            "label": record.get("label", ""),
            "status": record.get("status", "failed"),
            "exit_code": record.get("exit_code"),
            "created_at": record.get("created_at", 0),
            "started_at": record.get("started_at"),
            "finished_at": record.get("finished_at"),
            "lines": ["\x1b[2m(output is not kept across panel restarts)\x1b[0m"],
            "dropped": 0,
            "exclusive": False,
            "timeout": 0,
            "cancel_requested": record.get("cancelled", False),
            "env": {},
        }
    _evict_old_jobs()


# ── SSE ───────────────────────────────────────────────────────────────────────


def _sse(event: str, data: str) -> str:
    out = f"event: {event}\n"
    for chunk in str(data).split("\n"):
        out += f"data: {chunk}\n"
    return out + "\n"


async def stream_job(job_id: str):
    """Async generator of SSE-formatted strings for GET /stream/{job_id}.

    Opens with a `meta` event (JSON: status and elapsed seconds, so a client that
    reconnects mid-job shows the real duration), then every captured line, then
    a final `done` event with the exit code. Sends a `: ping` comment when idle.

    Polls the job's line buffer — trivial cost for a single-user panel and
    avoids races between late-connecting clients and the producer.
    """
    job = _jobs.get(job_id)
    if job is None:
        yield _sse("error", "unknown job")
        return
    started = job["started_at"] or time.time()
    elapsed = (job["finished_at"] or time.time()) - started
    yield _sse("meta", json.dumps({"status": job["status"], "elapsed": round(elapsed, 2)}))
    idx = 0  # absolute line number, including dropped lines
    last_sent = time.monotonic()
    while True:
        dropped = job.get("dropped", 0)
        if idx < dropped:
            yield _sse("line", f"\x1b[2m… {dropped - idx} earlier line(s) dropped …\x1b[0m")
            idx = dropped
        lines = job["lines"]
        while idx - dropped < len(lines):
            yield _sse("line", lines[idx - dropped])
            idx += 1
            last_sent = time.monotonic()
        if job["status"] in FINISHED:
            yield _sse("done", job["exit_code"])
            return
        if time.monotonic() - last_sent > _SSE_PING_SECONDS:
            yield ": ping\n\n"
            last_sent = time.monotonic()
        await asyncio.sleep(0.25)
