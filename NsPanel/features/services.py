"""Synchronous system-status helpers: systemctl, dpkg, which, nginx -t.

All status checks happen here in Python (per the architecture rules) — the
bash script is only used for *actions*, never for status.
"""
import shutil
import subprocess

import psutil


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
    code, out = run(["dpkg", "-l", pkg])
    if code != 0:
        return False
    return any(line.startswith("ii") for line in out.splitlines())


def service_state(service: str) -> str:
    """Returns systemctl's word: active | inactive | failed | unknown ..."""
    _, out = run(["systemctl", "is-active", service])
    return out.strip() or "unknown"


def is_active(service: str) -> bool:
    return service_state(service) == "active"


def main_pid(service: str) -> int | None:
    _, out = run(["systemctl", "show", "-p", "MainPID", "--value", service])
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
        _, out = run(version_cmd)
        version = first_line(out)

    return {
        "installed": installed,
        "version": version,
        "service_state": state,
        "ports": ports or [],
        "extra": {},
    }


def get_process_stats(pid: int) -> tuple[float | None, float | None]:
    """Returns (memory_mb, cpu_percent) by blocking for 0.5s to measure CPU utilization."""
    try:
        proc = psutil.Process(pid)
        memory_mb = round(proc.memory_info().rss / 1e6, 1)
        cpu_percent = proc.cpu_percent(interval=0.5)
        return memory_mb, cpu_percent
    except (psutil.Error, ValueError, ProcessLookupError):
        return None, None
