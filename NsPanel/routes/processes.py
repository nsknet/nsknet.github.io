"""FastAPI router for system processes."""
import os
import signal
import subprocess
from typing import Annotated, Any

import psutil
from fastapi import APIRouter, Form, HTTPException, status

from core import audit
from core.schemas import DataResponse, MessageResponse

router = APIRouter(prefix="/api/v1/processes")

# Cache to store Process objects for accurate, non-blocking CPU percentage measurement
_process_cache = {}


@router.get("")
def list_processes(q: str = "") -> DataResponse[list[dict[str, Any]]]:
    global _process_cache
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
                arguments = " ".join(cmdline) if cmdline else name
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


@router.post("/kill")
def kill_process(pid: Annotated[int, Form()]) -> MessageResponse:
    success = False

    # Escalation Strategy 1: psutil kill
    try:
        proc = psutil.Process(pid)
        proc.kill()
        success = True
    except Exception:
        pass

    # Escalation Strategy 2: os.kill
    if not success:
        try:
            os.kill(pid, signal.SIGKILL)
            success = True
        except Exception:
            pass

    # Escalation Strategy 3: Subprocess kill command
    if not success:
        try:
            subprocess.run(["kill", "-9", str(pid)], check=True)
            success = True
        except Exception:
            pass

    audit.log("process.kill", f"pid={pid} success={success}")

    if not success:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to kill process with PID {pid}. Access Denied or process no longer exists."
        )

    return MessageResponse(message=f"Process {pid} has been terminated successfully.")
