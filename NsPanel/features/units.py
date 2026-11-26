"""Panel-managed systemd units (the Services screen).

Service files are stored in SERVICES_DIR (/var/www/services/) and registered
with systemd via `systemctl enable <path>`. This module handles reading,
writing, and querying those service files.
"""

import os
import re
import shutil
import subprocess
import tempfile
from datetime import datetime
from pathlib import Path

from config import SERVICES_DIR, TUNNEL_ENV_DIR
from features.systemctl import get_process_stats, main_pid, service_enabled, service_state


def _svc_path(name: str) -> Path:
    return SERVICES_DIR / f"{name}.service"


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
    env_file: Path | None = None,
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
    if env_file is not None:
        lines.append(f"EnvironmentFile={env_file.as_posix()}")
    for ev in env_vars:
        ev = ev.strip()
        if ev:
            lines.append(f"Environment={ev}")
    lines += ["", "[Install]", "WantedBy=multi-user.target", ""]
    path.write_text("\n".join(lines))
    return path


def tunnel_env_path(name: str) -> Path:
    return TUNNEL_ENV_DIR / f"{name}.env"


def write_tunnel_env(name: str, token: str) -> Path:
    """Store a tunnel token in a root-only EnvironmentFile; return its path.

    cloudflared reads TUNNEL_TOKEN from the environment, so the token never
    appears in the unit file, in argv, or in `ps`/`systemctl status` output.
    """
    TUNNEL_ENV_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(TUNNEL_ENV_DIR, 0o700)
    path = tunnel_env_path(name)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(f"TUNNEL_TOKEN={token}\n")
    return path


# Legacy tunnel units carry the token inline as `--token <value>`.
_INLINE_TOKEN = re.compile(r"(--token[= ])(\S+)")
REDACTED = "***"


def redact(text: str) -> str:
    """Mask inline tunnel tokens before unit content or status leaves the server."""
    return _INLINE_TOKEN.sub(rf"\g<1>{REDACTED}", text)


class UnitInvalid(ValueError):
    """`systemd-analyze verify` rejected an edited unit; the message is its output."""


def _unit_problems(name: str, output: str) -> str | None:
    """The lines of `systemd-analyze verify` output about this unit.

    verify also loads the host's other units and reports their warnings (for
    example a stock unit using a deprecated option); those are not the user's to
    fix and must not block saving this one.
    """
    prefix = f"{name}.service"
    own = [line for line in output.splitlines() if line.strip().startswith(prefix)]
    return "\n".join(own) or None


def _verify_unit(name: str, content: str) -> str | None:
    """systemd-analyze's complaints about `content`, or None when it is clean
    (or when systemd-analyze is unavailable, e.g. off-Linux)."""
    if not shutil.which("systemd-analyze"):
        return None
    with tempfile.TemporaryDirectory(prefix="nspanel-verify-") as tmp:
        candidate = Path(tmp) / f"{name}.service"
        candidate.write_text(content)
        try:
            result = subprocess.run(
                ["systemd-analyze", "verify", "--man=no", str(candidate)],
                capture_output=True,
                text=True,
                timeout=20,
            )
        except (OSError, subprocess.SubprocessError):
            return None
        if result.returncode == 0:
            return None
        output = (result.stdout + result.stderr).replace(str(candidate), f"{name}.service")
        return _unit_problems(name, output)


def write_service_raw(name: str, content: str, *, verify: bool = True) -> None:
    """Save an edited unit: verified, backed up to `<unit>.bak`, then swapped in atomically.

    A redacted inline token is put back from the file on disk, so editing a
    legacy tunnel unit in the UI does not break it. Raises UnitInvalid when
    `systemd-analyze verify` rejects the content (unless `verify` is False).
    """
    path = _svc_path(name)
    if f"--token {REDACTED}" in content or f"--token={REDACTED}" in content:
        match = _INLINE_TOKEN.search(path.read_text()) if path.exists() else None
        if match:
            content = content.replace(f"{match.group(1)}{REDACTED}", match.group(0))
    if not content.endswith("\n"):
        content += "\n"
    if verify:
        problems = _verify_unit(name, content)
        if problems:
            raise UnitInvalid(problems)
    if path.exists():
        shutil.copy2(path, path.with_name(path.name + ".bak"))
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(content)
    os.replace(tmp, path)


def get_status_output(name: str) -> str:
    try:
        r = subprocess.run(
            ["systemctl", "status", "--no-pager", name],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return redact((r.stdout + r.stderr).strip()) or "(no output)"
    except Exception as exc:
        return str(exc)


def get_journal_logs(name: str, lines: int = 60) -> str:
    try:
        r = subprocess.run(
            ["journalctl", "-u", name, "-n", str(lines), "--no-pager", "--output=short-iso"],
            capture_output=True,
            text=True,
            timeout=10,
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
        "tunnel": None,  # {hostname, service_url, tunnel_id, tunnel_name, zone, public_url}
    }
    tunnel: dict = {}
    for line in content.splitlines():
        line = line.strip()
        if line.startswith("Description="):
            fields["description"] = line[len("Description=") :]
        elif line.startswith("WorkingDirectory="):
            fields["working_dir"] = line[len("WorkingDirectory=") :]
        elif line.startswith("ExecStart="):
            fields["exec_start"] = line[len("ExecStart=") :]
        elif line.startswith("User="):
            fields["user"] = line[len("User=") :]
        elif line.startswith("Restart="):
            fields["restart"] = line[len("Restart=") :]
        elif line.startswith("RestartSec="):
            fields["restart_sec"] = line[len("RestartSec=") :]
        elif line.startswith("SyslogIdentifier="):
            fields["syslog_id"] = line[len("SyslogIdentifier=") :]
        elif line.startswith("Environment="):
            fields["env_vars"].append(line[len("Environment=") :])
        elif line.startswith(TUNNEL_KEY_PREFIX):
            key, _, val = line[len(TUNNEL_KEY_PREFIX) :].partition("=")
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
    content = redact(path.read_text())
    mtime = datetime.fromtimestamp(path.stat().st_mtime).strftime("%Y-%m-%d %H:%M")
    state = service_state(name)
    enabled = service_enabled(name)
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
