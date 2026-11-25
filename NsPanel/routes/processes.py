"""FastAPI router for system processes."""
import os
import re
import signal
import threading
from typing import Annotated, Any

import psutil
from fastapi import APIRouter, Form, HTTPException, status

from core import audit
from core.schemas import DataResponse, MessageResponse

router = APIRouter(prefix="/api/v1/processes")

# Flags whose next argument is a secret, and inline `key=value` secrets.
_SECRET_FLAGS = {"--token", "-P", "--password", "--pass", "-password"}
_SECRET_INLINE = re.compile(r"(?i)((?:--)?(?:token|password|passwd|pass|secret|api[-_]?key)=)\S+")


def _redact(cmdline: list[str]) -> str:
    """Join argv for display, masking anything that looks like a credential."""
    out: list[str] = []
    hide_next = False
    for arg in cmdline:
        if hide_next:
            out.append("***")
            hide_next = False
            continue
        if arg in _SECRET_FLAGS:
            hide_next = True
        out.append(_SECRET_INLINE.sub(r"\1***", arg))
    return " ".join(out)


# Cache to store Process objects for accurate, non-blocking CPU percentage measurement
_process_cache: dict[int, psutil.Process] = {}
# Sync handlers run in a threadpool: two refreshes can overlap.
_cache_lock = threading.Lock()


@router.get("")
def list_processes(q: str = "") -> DataResponse[list[dict[str, Any]]]:
    with _cache_lock:
        return _list_processes(q)


# Killing these takes the host or the operator's access down with it.
_CRITICAL_NAMES = {"systemd", "init", "sshd", "systemd-journald", "systemd-logind", "dbus-daemon"}


def _list_processes(q: str) -> DataResponse[list[dict[str, Any]]]:
    global _process_cache
    protected = _protected_pids()
    current_pids = set()
    all_processes = []

    for p in psutil.process_iter():
        try:
            pid = p.pid
            current_pids.add(pid)

            if pid in _process_cache:
                proc = _process_cache[pid]
            else:
                proc = p
                _process_cache[pid] = proc
                # Call cpu_percent once to initialize the counter
                try:
                    proc.cpu_percent()
                except Exception:
                    pass

            try:
                name = proc.name()
            except Exception:
                name = "unknown"

            try:
                cmdline = proc.cmdline()
                arguments = _redact(cmdline) if cmdline else name
            except Exception:
                arguments = name

            try:
                threads = proc.num_threads()
            except Exception:
                threads = 1

            try:
                user = proc.username()
            except Exception:
                user = "unknown"

            try:
                mem_info = proc.memory_info()
                ram_gb = round(mem_info.rss / (1024 ** 3), 3)
            except Exception:
                ram_gb = 0.0

            try:
                cpu_pct = round(proc.cpu_percent(), 1)
            except Exception:
                cpu_pct = 0.0

            all_processes.append({
                "protected": pid in protected or name in _CRITICAL_NAMES,
                "pid": pid,
                "name": name,
                "arguments": arguments,
                "threads": threads,
                "user": user,
                "ram_gb": ram_gb,
                "cpu_percent": cpu_pct
            })
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            continue
        except Exception:
            continue

    # Clean up the cache to prevent memory leaks by keeping only active PIDs
    _process_cache = {pid: proc for pid, proc in _process_cache.items() if pid in current_pids}

    def _top_pids(rows: list[dict], key: str, limit: int = 100) -> set[int]:
        return {p["pid"] for p in sorted(rows, key=lambda x: x[key], reverse=True)[:limit]}

    # Without a query the list shows the union of the busiest processes.
    top_cpu_pids = _top_pids(all_processes, "cpu_percent")
    top_ram_pids = _top_pids(all_processes, "ram_gb")
    top_thread_pids = _top_pids([p for p in all_processes if p["threads"] > 1], "threads")

    # Apply filtering
    q_clean = q.strip().lower()
    filtered_processes = []

    for p in all_processes:
        # Check matching conditions
        matches_q = False
        if q_clean:
            matches_q = (
                q_clean in str(p["pid"]) or
                q_clean in p["name"].lower() or
                q_clean in p["arguments"].lower() or
                q_clean in p["user"].lower()
            )

        in_top_cpu = p["pid"] in top_cpu_pids
        in_top_ram = p["pid"] in top_ram_pids
        in_top_thread = p["pid"] in top_thread_pids

        # If search query is provided, only return matches to the query.
        # Otherwise, return the union of the top 100 subsets.
        if q_clean:
            if matches_q:
                filtered_processes.append(p)
        else:
            if in_top_cpu or in_top_ram or in_top_thread:
                filtered_processes.append(p)

    return DataResponse(data=filtered_processes)


# SIGKILL does not exist on Windows, where the panel is developed and tested.
_SIGNALS = {"TERM": signal.SIGTERM, "KILL": getattr(signal, "SIGKILL", 9)}


def _protected_pids() -> set[int]:
    """PIDs the panel must never signal: init, itself, and its own ancestors."""
    protected = {0, 1, os.getpid()}
    try:
        protected.update(parent.pid for parent in psutil.Process().parents())
    except psutil.Error:
        pass
    return protected


@router.post("/kill")
def kill_process(
    pid: Annotated[int, Form()],
    sig: Annotated[str, Form()] = "KILL",
) -> MessageResponse:
    sig_name = sig.strip().upper()
    if sig_name not in _SIGNALS:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "signal must be TERM or KILL")
    # pid <= 0 would make kill(2) target a process group, or every process on the host.
    if pid <= 1 or pid in _protected_pids():
        raise HTTPException(status.HTTP_403_FORBIDDEN, f"PID {pid} is protected and cannot be signalled")

    try:
        psutil.Process(pid).send_signal(_SIGNALS[sig_name])
    except psutil.NoSuchProcess as exc:
        audit.log("process.kill", f"pid={pid} sig={sig_name} success=False")
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"No process with PID {pid}") from exc
    except psutil.Error as exc:
        audit.log("process.kill", f"pid={pid} sig={sig_name} success=False")
        raise HTTPException(
            status.HTTP_500_INTERNAL_SERVER_ERROR, f"Could not signal PID {pid}: {exc}"
        ) from exc

    audit.log("process.kill", f"pid={pid} sig={sig_name} success=True")
    return MessageResponse(message=f"Sent SIG{sig_name} to process {pid}.")
