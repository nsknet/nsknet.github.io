"""Panel-managed systemd units (the Services screen).

Service files are stored in SERVICES_DIR (/var/www/services/) and registered
with systemd via `systemctl enable <path>`. This module handles reading,
writing, and querying those service files.
"""
import subprocess
from datetime import datetime
from pathlib import Path

from config import SERVICES_DIR
from features.systemctl import get_process_stats, main_pid


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
    unit_extra: list[str] | None = None,
) -> Path:
    """Write a unit file. `unit_extra` lines are appended to the [Unit]
    section verbatim (e.g. After=…, or X-NsPanel-* metadata keys)."""
    SERVICES_DIR.mkdir(parents=True, exist_ok=True)
    path = _svc_path(name)
    lines = [
        "[Unit]",
        f"Description={description or name}",
        *[ln.strip() for ln in (unit_extra or []) if ln.strip()],
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


# Tunnel metadata is kept in the unit file itself as X-NsPanel-Tunnel-* keys
# (systemd ignores X- prefixed settings), so no separate store is needed.
TUNNEL_KEY_PREFIX = "X-NsPanel-Tunnel-"
_TUNNEL_KEYS = {
    "Hostname": "hostname",
    "ServiceUrl": "service_url",
    "Id": "tunnel_id",
    "Name": "tunnel_name",
    "Zone": "zone",
}


def tunnel_unit_lines(
    hostname: str, service_url: str, tunnel_id: str, tunnel_name: str, zone: str
) -> list[str]:
    return [
        f"{TUNNEL_KEY_PREFIX}Hostname={hostname}",
        f"{TUNNEL_KEY_PREFIX}ServiceUrl={service_url}",
        f"{TUNNEL_KEY_PREFIX}Id={tunnel_id}",
        f"{TUNNEL_KEY_PREFIX}Name={tunnel_name}",
        f"{TUNNEL_KEY_PREFIX}Zone={zone}",
    ]


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
        "tunnel": None,   # {hostname, service_url, tunnel_id, tunnel_name, zone, public_url}
    }
    tunnel: dict = {}
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
        elif line.startswith(TUNNEL_KEY_PREFIX):
            key, _, val = line[len(TUNNEL_KEY_PREFIX):].partition("=")
            if key in _TUNNEL_KEYS:
                tunnel[_TUNNEL_KEYS[key]] = val.strip()
    if tunnel.get("hostname") and tunnel.get("tunnel_id"):
        fields["tunnel"] = {
            "hostname": tunnel["hostname"],
            "service_url": tunnel.get("service_url", ""),
            "tunnel_id": tunnel["tunnel_id"],
            "tunnel_name": tunnel.get("tunnel_name", ""),
            "zone": tunnel.get("zone", ""),
            "public_url": f"https://{tunnel['hostname']}",
        }
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
