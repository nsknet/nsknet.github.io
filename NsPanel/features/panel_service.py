"""Status of the panel's own systemd service, and the update check.

The service runs from a dedicated sparse clone (config.SERVICE_REPO_DIR); its
install, update and removal are bash jobs in scripts/panel_service.sh. Here we
only read: systemctl state, the clone's commit, and `state.json`, which both
the script (install/update times, port, subnets) and :func:`check_updates`
(the last update check) write into.
"""
import ipaddress
import json
import os
import socket
import time
from pathlib import Path
from typing import Any

import psutil

import config
from core.validators import ALLOWED_SUBNET_CHOICES
from features import systemctl

UNIT_FILE = Path("/etc/systemd/system") / f"{config.SERVICE_NAME}.service"
_FIELD_SEP = "\x1f"
_LOG_FORMAT = _FIELD_SEP.join(["%H", "%h", "%cI", "%s"])
_MAX_COMMITS = 10
_FETCH_TIMEOUT = 45

_STATIC_SUBNET_LABELS = {
    "10.0.0.0/8": "Class A — private",
    "172.16.0.0/12": "Class B — private",
    "192.168.0.0/16": "Class C — private",
    "127.0.0.0/8": "Loopback (local)",
    "0.0.0.0/0": "Any IP — public",
}


# ── git ───────────────────────────────────────────────────────────────────────


def _git(repo: Path, *args: str, timeout: int = 10) -> tuple[int, str]:
    return systemctl.run(["git", "-C", str(repo), *args], timeout=timeout)


def _parse_commit(line: str) -> dict[str, str] | None:
    parts = line.split(_FIELD_SEP)
    if len(parts) != 4:
        return None
    full, short, date, subject = parts
    return {"hash": full, "short": short, "date": date, "subject": subject}


def commit_info(repo: Path, rev: str = "HEAD") -> dict[str, str] | None:
    """Hash, short hash, committer date (ISO) and subject of `rev`, or None."""
    code, out = _git(repo, "log", "-1", f"--format={_LOG_FORMAT}", rev, "--")
    if code != 0:
        return None
    return _parse_commit(out.strip())


def _is_repo(repo: Path) -> bool:
    return (repo / ".git").exists()


# The commit this process was started from — compared with what is on disk so
# the page can tell that an update was pulled but not restarted yet.
_RUNNING_COMMIT = commit_info(config.BASE_DIR) if _is_repo(config.BASE_DIR.parent) else None


# ── state.json ───────────────────────────────────────────────────────────────


def _read_state() -> dict[str, Any]:
    try:
        data = json.loads(config.SERVICE_STATE_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _write_state(state: dict[str, Any]) -> None:
    path = config.SERVICE_STATE_FILE
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(state, indent=2), encoding="utf-8")
    os.replace(tmp, path)


# ── network ──────────────────────────────────────────────────────────────────


def _host_ipv4() -> list[tuple[str, str, int | None]]:
    """(iface, address, prefix) for every non-loopback IPv4 address."""
    found: list[tuple[str, str, int | None]] = []
    for iface, addrs in psutil.net_if_addrs().items():
        for addr in addrs:
            if addr.family != socket.AF_INET:
                continue
            ip = ipaddress.ip_address(addr.address)
            if ip.is_loopback or ip.is_link_local:
                continue
            prefix = None
            if addr.netmask:
                try:
                    prefix = ipaddress.IPv4Network(f"0.0.0.0/{addr.netmask}").prefixlen
                except ValueError:
                    prefix = None
            found.append((iface, addr.address, prefix))
    return found


def lan_subnet_choices() -> list[dict[str, Any]]:
    """Subnets the install form offers: this host's own LANs, then the fixed choices.

    `default` marks what is ticked initially — the private ranges, never "any".
    """
    choices: list[dict[str, Any]] = []
    seen: set[str] = set()
    for iface, address, prefix in _host_ipv4():
        if prefix is None or prefix >= 32:
            continue
        network = str(ipaddress.ip_interface(f"{address}/{prefix}").network)
        if network in seen or network in ALLOWED_SUBNET_CHOICES:
            continue
        seen.add(network)
        choices.append({"cidr": network, "label": f"This LAN ({iface})", "default": False})
    for cidr, label in _STATIC_SUBNET_LABELS.items():
        choices.append({"cidr": cidr, "label": label, "default": cidr != "0.0.0.0/0"})
    return choices


# ── status ───────────────────────────────────────────────────────────────────


def is_installed() -> bool:
    return UNIT_FILE.exists() and _is_repo(config.SERVICE_REPO_DIR)


def is_self() -> bool:
    """True when this process *is* the service (so it must not stop itself)."""
    if os.environ.get("NSPANEL_SERVICE") == "1":
        return True
    try:
        return config.BASE_DIR.resolve() == config.SERVICE_PANEL_DIR.resolve()
    except OSError:
        return False


def _int(value: Any, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def get_status() -> dict[str, Any]:
    state = _read_state()
    installed = is_installed()
    port = _int(state.get("port"), config.SERVICE_PORT_DEFAULT)
    installed_commit = commit_info(config.SERVICE_REPO_DIR) if installed else None

    update = state.get("update") if installed else None
    if isinstance(update, dict) and installed_commit:
        # A check made against an older HEAD (before an update) no longer applies.
        update = {**update, "stale": update.get("base") != installed_commit["hash"]}
    else:
        update = None

    return {
        "installed": installed,
        "active": systemctl.service_state(config.SERVICE_NAME) if installed else "inactive",
        "enabled": systemctl.service_enabled(config.SERVICE_NAME) if installed else "disabled",
        "port": port,
        "branch": state.get("branch") or config.REPO_BRANCH,
        "repo_url": config.REPO_URL,
        "repo_dir": config.SERVICE_REPO_DIR.as_posix(),
        "subnets": str(state.get("subnets") or "").split(),
        "urls": [f"http://{address}:{port}" for _, address, _ in _host_ipv4()] if installed else [],
        "installed_commit": installed_commit,
        "running_commit": _RUNNING_COMMIT,
        "installed_at": state.get("installed_at"),
        "updated_at": state.get("updated_at"),
        "update": update,
        "is_self": is_self(),
        "current_port": config.PORT,
        "default_port": config.SERVICE_PORT_DEFAULT,
        "subnet_choices": lan_subnet_choices(),
    }


def check_updates() -> dict[str, Any]:
    """Fetch the public repo and record how far the service's clone is behind.

    Only commits touching config.SERVICE_UPDATE_PATHS count as an update; the
    total is kept too so the page can say why "N commits" are not offered.
    """
    repo = config.SERVICE_REPO_DIR
    branch = _read_state().get("branch") or config.REPO_BRANCH
    remote_ref = f"origin/{branch}"
    result: dict[str, Any] = {
        "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "base": None,
        "remote_commit": None,
        "behind": 0,
        "total_behind": 0,
        "commits": [],
        "error": None,
    }

    head = commit_info(repo)
    if head is None:
        result["error"] = f"{repo} is not a git checkout."
        return result
    result["base"] = head["hash"]

    code, out = _git(repo, "fetch", "--quiet", "origin", branch, timeout=_FETCH_TIMEOUT)
    if code != 0:
        result["error"] = f"git fetch failed: {out or f'exit {code}'}"
    else:
        span = f"HEAD..{remote_ref}"
        result["remote_commit"] = commit_info(repo, remote_ref)
        _, total = _git(repo, "rev-list", "--count", span)
        _, behind = _git(repo, "rev-list", "--count", span, "--", *config.SERVICE_UPDATE_PATHS)
        result["total_behind"] = _int(total.strip(), 0)
        result["behind"] = _int(behind.strip(), 0)
        _, log = _git(
            repo, "log", f"--format={_LOG_FORMAT}", f"-n{_MAX_COMMITS}", span,
            "--", *config.SERVICE_UPDATE_PATHS,
        )
        result["commits"] = [c for c in map(_parse_commit, log.splitlines()) if c]

    if config.SERVICE_STATE_FILE.parent.is_dir():
        try:
            _write_state({**_read_state(), "update": result})
        except OSError:
            pass  # a status page that cannot cache the check still shows it
    return result
