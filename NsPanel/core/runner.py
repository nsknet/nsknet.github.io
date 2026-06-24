"""Async subprocess wrapper + SSE event generator.

A "job" is one subprocess invocation (a bash function, systemctl, etc.).
Jobs live in an in-memory dict, keyed by a random id. State is lost on panel
restart — acceptable for a single-user, manually-launched panel.
"""
import asyncio
import os
import re
import uuid

# Strip terminal escape sequences except SGR (colors/formatting) sequences.
# SGR sequences end with 'm' (e.g. \x1b[0m, \x1b[1;31m).
# CSI sequences end with a letter from @ to ~ (0x40 to 0x7E).
# We match CSI sequences ending with letters in [@-l] or [n-~], thus preserving 'm'.
_ANSI_STRIP = re.compile(
    r"\x1b\[[0-9;?]*[ -/]*[@-ln-~]"      # CSI except SGR (m)
    r"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"  # OSC
    r"|\x1b[a-ln-zB-Z]"                   # lone ESC followed by non-m, non-[ characters
)

# job_id -> {cmd, label, status, exit_code, lines}
_jobs: dict[str, dict] = {}
_loop: asyncio.AbstractEventLoop | None = None


def set_event_loop(loop: asyncio.AbstractEventLoop) -> None:
    global _loop
    _loop = loop


def create_job(cmd: list[str], label: str = "", env: dict[str, str] | None = None) -> str:
    job_id = uuid.uuid4().hex
    _jobs[job_id] = {
        "cmd": [str(c) for c in cmd],
        "label": label,
        "status": "pending",   # pending | running | done | failed
        "exit_code": None,
        "lines": [],
        # Extra environment variables merged into the subprocess env. Used to pass
        # secrets (DB_PASSWORD) and config (ALLOWED_SUBNETS) without leaking them
        # into the displayed command line.
        "env": {str(k): str(v) for k, v in (env or {}).items()},
    }
    return job_id


def get_job(job_id: str) -> dict | None:
    return _jobs.get(job_id)


def start_job(job_id: str) -> None:
    """Schedule the subprocess on the running event loop."""
    try:
        asyncio.get_running_loop().create_task(_run(job_id))
    except RuntimeError:
        # Called from a sync route handler running in a threadpool — no event
        # loop in this thread, so schedule on the main loop captured at startup.
        assert _loop is not None, "runner.set_event_loop() was never called"
        asyncio.run_coroutine_threadsafe(_run(job_id), _loop)


async def _run(job_id: str) -> None:
    job = _jobs[job_id]
    job["status"] = "running"
    
    # Format and prepend the running command as the first line of output
    cmd_parts = list(job["cmd"])
    if len(cmd_parts) >= 2 and cmd_parts[0] == "bash":
        if cmd_parts[1] == "-c" and len(cmd_parts) >= 6:
            # Sourced execution format: ["bash", "-c", "...", "--", script_path, function_name, *args]
            script_name = os.path.basename(cmd_parts[4])
            func_name = cmd_parts[5]
            func_args = cmd_parts[6:]
            display_cmd = f"bash {script_name} {func_name} {' '.join(func_args)}".strip()
        elif cmd_parts[1].endswith(".sh"):
            cmd_parts[1] = os.path.basename(cmd_parts[1])
            display_cmd = " ".join(cmd_parts)
        else:
            display_cmd = " ".join(cmd_parts)
    else:
        display_cmd = " ".join(cmd_parts)
    job["lines"].append(f"\x1b[1;36m$ {display_cmd}\x1b[0m")

    
    try:
        # Force color outputs in systemd and common CLI utilities
        env = os.environ.copy()
        env["FORCE_COLOR"] = "1"
        env["CLICOLOR_FORCE"] = "1"
        env["SYSTEMD_COLORS"] = "1"
        env["TERM"] = "xterm-256color"
        env.update(job.get("env") or {})

        proc = await asyncio.create_subprocess_exec(
            *job["cmd"],
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            env=env,
        )
    except Exception as exc:  # command not found, etc.
        job["lines"].append(f"\x1b[1;31mfailed to start process: {exc}\x1b[0m")
        job["exit_code"] = 127
        job["status"] = "failed"
        return

    assert proc.stdout is not None

    async def _drain() -> None:
        async for raw in proc.stdout:
            line = _ANSI_STRIP.sub("", raw.decode("utf-8", "replace").rstrip("\r\n"))
            job["lines"].append(line)

    # Read output concurrently (so the pipe never back-pressures the process),
    # then wait for the process itself to exit — keyed on its PID, not on the
    # pipe reaching EOF.
    drain_task = asyncio.create_task(_drain())
    code = await proc.wait()

    # The process is gone, but a forked daemon may have inherited the stdout pipe
    # and kept its write end open (FUSE mount helpers such as ntfs-3g do exactly
    # this). Waiting for EOF would then hang forever. Give the drain a short grace
    # period to flush buffered output, then stop reading and abandon the pipe.
    try:
        await asyncio.wait_for(drain_task, timeout=2.0)
    except asyncio.TimeoutError:
        job["lines"].append(
            "\x1b[2m(output stream left open by a background process — continuing)\x1b[0m"
        )
    except asyncio.CancelledError:
        pass

    job["exit_code"] = code
    
    # Append final exit status line
    if code == 0:
        job["lines"].append("\x1b[1;32m✓ Success: exit 0\x1b[0m")
    else:
        job["lines"].append(f"\x1b[1;31m✗ Failed: exit {code}\x1b[0m")
        
    job["status"] = "done" if code == 0 else "failed"


def _sse(event: str, data: str) -> str:
    out = f"event: {event}\n"
    for chunk in str(data).split("\n"):
        out += f"data: {chunk}\n"
    return out + "\n"


async def stream_job(job_id: str):
    """Async generator of SSE-formatted strings for GET /stream/{job_id}.

    Streams every captured line then a final `done` event with the exit code.
    Polls the job's line buffer — trivial cost for a single-user panel and
    avoids races between late-connecting clients and the producer.
    """
    job = _jobs.get(job_id)
    if job is None:
        yield _sse("error", "unknown job")
        return

    idx = 0
    while True:
        while idx < len(job["lines"]):
            yield _sse("line", job["lines"][idx])
            idx += 1
        if job["status"] in ("done", "failed"):
            yield _sse("done", job["exit_code"])
            return
        await asyncio.sleep(0.25)
