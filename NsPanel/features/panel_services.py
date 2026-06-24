"""Business logic for panel-managed custom systemd services.

Service files are stored in SERVICES_DIR (/var/www/services/) and registered
with systemd via `systemctl enable <path>`. This module handles reading,
writing, and querying those service files.
"""
import subprocess
from datetime import datetime
from pathlib import Path

import psutil

from config import SERVICES_DIR
from features.services import main_pid, get_process_stats


def _svc_path(name: str) -> Path:
    return SERVICES_DIR / f"{name}.service"


def _run_silent(cmd: list[str], timeout: int = 5) -> str:
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception:
        return "unknown"


def list_services() -> list[dict]:
    SERVICES_DIR.mkdir(parents=True, exist_ok=True)
    result = []
    for f in sorted(SERVICES_DIR.glob("*.service")):
        svc = get_service(f.stem)
        if svc:
            result.append(svc)
    return result


def service_exists(name: str) -> bool:
    return _svc_path(name).exists()


def svc_path(name: str) -> Path:
    return _svc_path(name)


def write_service(
    name: str,
    description: str,
    working_dir: str,
    command: str,
    user: str,
    env_vars: list[str],
) -> Path:
    SERVICES_DIR.mkdir(parents=True, exist_ok=True)
    path = _svc_path(name)
    lines = [
        "[Unit]",
        f"Description={description or name}",
        "",
        "[Service]",
        f"WorkingDirectory={working_dir}",
        f"ExecStart={command}",
        "Restart=always",
        "RestartSec=10",
        "KillSignal=SIGINT",
        f"SyslogIdentifier={name}",
        f"User={user or 'root'}",
    ]
    for ev in env_vars:
        ev = ev.strip()
        if ev:
            lines.append(f"Environment={ev}")
    lines += ["", "[Install]", "WantedBy=multi-user.target", ""]
    path.write_text("\n".join(lines))
    return path


def read_service(name: str) -> str:
    return _svc_path(name).read_text()


def write_service_raw(name: str, content: str) -> None:
    _svc_path(name).write_text(content)


def get_status_output(name: str) -> str:
    try:
        r = subprocess.run(
            ["systemctl", "status", "--no-pager", name],
            capture_output=True, text=True, timeout=10,
        )
        return (r.stdout + r.stderr).strip() or "(no output)"
    except Exception as exc:
        return str(exc)


def get_journal_logs(name: str, lines: int = 60) -> str:
    try:
        r = subprocess.run(
            ["journalctl", "-u", name, "-n", str(lines), "--no-pager", "--output=short-iso"],
            capture_output=True, text=True, timeout=10,
        )
        return (r.stdout + r.stderr).strip() or "(no output)"
    except Exception as exc:
        return str(exc)


def _parse_service_file(content: str) -> dict:
    fields: dict = {
        "description": None,
        "working_dir": None,
        "exec_start": None,
        "user": None,
        "restart": None,
        "restart_sec": None,
        "syslog_id": None,
        "env_vars": [],
    }
    for line in content.splitlines():
        line = line.strip()
        if line.startswith("Description="):
            fields["description"] = line[len("Description="):]
        elif line.startswith("WorkingDirectory="):
            fields["working_dir"] = line[len("WorkingDirectory="):]
        elif line.startswith("ExecStart="):
            fields["exec_start"] = line[len("ExecStart="):]
        elif line.startswith("User="):
            fields["user"] = line[len("User="):]
        elif line.startswith("Restart="):
            fields["restart"] = line[len("Restart="):]
        elif line.startswith("RestartSec="):
            fields["restart_sec"] = line[len("RestartSec="):]
        elif line.startswith("SyslogIdentifier="):
            fields["syslog_id"] = line[len("SyslogIdentifier="):]
        elif line.startswith("Environment="):
            fields["env_vars"].append(line[len("Environment="):])
    return fields


def get_service(name: str) -> dict | None:
    path = _svc_path(name)
    if not path.exists():
        return None
    content = path.read_text()
    mtime = datetime.fromtimestamp(path.stat().st_mtime).strftime("%Y-%m-%d %H:%M")
    state = _run_silent(["systemctl", "is-active", name]) or "unknown"
    enabled = _run_silent(["systemctl", "is-enabled", name]) or "unknown"
    memory_mb = None
    cpu_percent = None
    pid = None
    if state == "active":
        pid = main_pid(name)
        if pid:
            memory_mb, cpu_percent = get_process_stats(pid)
    parsed = _parse_service_file(content)
    return {
        "name": name,
        "path": str(path),
        "last_edit": mtime,
        "state": state,
        "enabled": enabled,
        "memory_mb": memory_mb,
        "cpu_percent": cpu_percent,
        "pid": pid,
        "content": content,
        **parsed,
    }
