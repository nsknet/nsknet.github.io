"""Synchronous system-status probes: systemctl, dpkg, which, nginx -t.

All status checks happen here in Python (per the architecture rules) — the
bash script is only used for *actions*, never for status.
"""

import shutil
import subprocess
import threading
import time

import psutil

from core import runner

# Read-only probes are cached briefly: the Tools and Services lists run several
# per item, and a dashboard poll would otherwise spawn dozens of processes. The
# cache is dropped whenever a job finishes, so a start/stop shows up at once.
_CACHE_SECONDS = 3.0
_cache: dict[tuple[str, ...], tuple[float, tuple[int, str]]] = {}
_cache_lock = threading.Lock()


def invalidate() -> None:
    with _cache_lock:
        _cache.clear()


runner.on_job_finished(invalidate)


def cached_run(cmd: list[str], timeout: int = 10) -> tuple[int, str]:
    """`run`, memoised for a few seconds. Only for commands that change nothing."""
    key = tuple(cmd)
    now = time.monotonic()
    with _cache_lock:
        hit = _cache.get(key)
        if hit and now - hit[0] < _CACHE_SECONDS:
            return hit[1]
    result = run(cmd, timeout=timeout)
    with _cache_lock:
        _cache[key] = (now, result)
    return result


def run(cmd: list[str], timeout: int = 10) -> tuple[int, str]:
    """Run a command, return (exit_code, combined stdout+stderr)."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout + p.stderr).strip()
    except FileNotFoundError:
        return 127, f"{cmd[0]}: not found"
    except subprocess.TimeoutExpired:
        return 124, f"{cmd[0]}: timed out"
    except Exception as exc:  # pragma: no cover - defensive
        return 1, str(exc)


def which(name: str) -> str | None:
    return shutil.which(name)


def dpkg_installed(pkg: str) -> bool:
    code, out = cached_run(["dpkg", "-l", pkg])
    if code != 0:
        return False
    return any(line.startswith("ii") for line in out.splitlines())


def service_state(service: str) -> str:
    """Returns systemctl's word: active | inactive | failed | unknown ..."""
    _, out = cached_run(["systemctl", "is-active", service])
    return out.strip() or "unknown"


def is_active(service: str) -> bool:
    return service_state(service) == "active"


def service_enabled(service: str) -> str:
    """Returns systemctl's word: enabled | disabled | static | unknown ..."""
    _, out = cached_run(["systemctl", "is-enabled", service])
    return first_line(out) or "unknown"


def main_pid(service: str) -> int | None:
    _, out = cached_run(["systemctl", "show", "-p", "MainPID", "--value", service])
    try:
        pid = int(out.strip())
    except ValueError:
        return None
    return pid if pid > 0 else None


def nginx_test() -> tuple[bool, str]:
    code, out = run(["nginx", "-t"])
    return code == 0, out


def first_line(text: str) -> str | None:
    for line in text.splitlines():
        line = line.strip()
        if line:
            return line
    return None


def tool_status(
    binary: str | None = None,
    pkg: str | None = None,
    service: str | None = None,
    version_cmd: list[str] | None = None,
    ports: list[int] | None = None,
) -> dict:
    """Shared status probe used by Module.get_status() implementations.

    Returns the dict shape the Module interface promises:
    {installed, version, service_state, ports, extra}
    """
    installed = bool((binary and which(binary)) or (pkg and dpkg_installed(pkg)))

    state = "n/a"
    if service:
        state = service_state(service) if installed else "not installed"

    version = None
    if installed and version_cmd:
        _, out = cached_run(version_cmd)
        version = first_line(out)

    return {
        "installed": installed,
        "version": version,
        "service_state": state,
        "ports": ports or [],
        "extra": {},
    }


# psutil measures CPU between two calls on the same Process object; keeping the
# objects lets each call return immediately instead of sleeping to sample.
_procs: dict[int, psutil.Process] = {}


def get_process_stats(pid: int) -> tuple[float | None, float | None]:
    """(memory_mb, cpu_percent) without blocking. CPU is None on the first sample of a PID."""
    try:
        proc = _procs.get(pid)
        first = proc is None
        if first:
            proc = _procs[pid] = psutil.Process(pid)
        memory_mb = round(proc.memory_info().rss / 1e6, 1)
        cpu = proc.cpu_percent(None)
        if len(_procs) > 512:
            for stale in [p for p, obj in _procs.items() if not obj.is_running()]:
                _procs.pop(stale, None)
        return memory_mb, (None if first else round(cpu, 1))
    except (psutil.Error, ValueError, ProcessLookupError):
        _procs.pop(pid, None)
        return None, None
