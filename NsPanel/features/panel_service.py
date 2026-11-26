"""Status of the panel's own systemd service, and the update check.

The service runs from a release directory (`config.SERVICE_CURRENT_LINK` ->
releases/<sha>/NsPanel, a git worktree of the clone in SERVICE_REPO_DIR); its
install, update, rollback and removal are bash jobs in scripts/panel_service.sh.
Here we only read: systemctl state, the commits of the current and previous
release, and `state.json`, which both the script (releases, times, port,
subnets) and :func:`check_updates` (the last update check) write into.
"""

import contextlib
import ipaddress
import json
import os
import socket
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

import psutil

import config
from core import version
from core.validators import ALLOWED_SUBNET_CHOICES
from features import systemctl

UNIT_FILE = Path("/etc/systemd/system") / f"{config.SERVICE_NAME}.service"
_FIELD_SEP = "\x1f"
_LOG_FORMAT = _FIELD_SEP.join(["%H", "%h", "%cI", "%s"])
_MAX_COMMITS = 10
_FETCH_TIMEOUT = 45
_GITHUB_TIMEOUT = 10
# Commits walked back from the branch tip to find one CI actually ran on (the
# frontend bot's "rebuild static/dist [skip ci]" commits have no runs).
_CI_LOOKBACK = 4
_CI_FAILED = {"failure", "timed_out", "cancelled", "action_required", "startup_failure"}

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
    # A worktree has a `.git` file, a clone a `.git` directory.
    return (repo / ".git").exists()


def _running_commit() -> dict[str, str] | None:
    """The commit this process was started from (read once, at import)."""
    info = version.info()
    if not info["commit"]:
        return None
    return commit_info(config.BASE_DIR) or {
        "hash": info["commit"],
        "short": info["commit"][:7],
        "date": info["commit_date"],
        "subject": "",
    }


# Compared with the installed release so the page can tell that an update was
# installed but the process has not restarted onto it yet.
_RUNNING_COMMIT = _running_commit()


# ── state.json ───────────────────────────────────────────────────────────────


def _read_state() -> dict[str, Any]:
    try:
        data = json.loads(config.SERVICE_STATE_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


@contextlib.contextmanager
def _state_lock():
    """Same lock file as scripts/panel_service.sh, so the two never interleave."""
    path = config.SERVICE_STATE_FILE.with_name(config.SERVICE_STATE_FILE.name + ".lock")
    try:
        import fcntl
    except ImportError:  # not POSIX (development): nothing else writes the file
        yield
        return
    with open(path, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def _update_state(**changes: Any) -> None:
    path = config.SERVICE_STATE_FILE
    with _state_lock():
        state = {**_read_state(), **changes}
        tmp = path.with_name(path.name + ".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(state, fh, indent=2)
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


# ── releases ─────────────────────────────────────────────────────────────────


def installed_panel_dir() -> Path | None:
    """The panel directory the service runs (current release, or a legacy clone)."""
    repo = config.SERVICE_REPO_DIR
    link = repo / config.SERVICE_CURRENT_LINK.name
    if link.is_symlink() or link.exists():
        with contextlib.suppress(OSError):
            return link.resolve()
    legacy = repo / config.SERVICE_LEGACY_PANEL_DIR.name
    if _is_repo(repo) and (legacy / "app.py").exists():
        return legacy
    return None


def _release_ok(path: str | None) -> bool:
    return bool(path) and Path(path, "app.py").exists()


# ── status ───────────────────────────────────────────────────────────────────


def is_installed() -> bool:
    return UNIT_FILE.exists() and _is_repo(config.SERVICE_REPO_DIR)


def is_self() -> bool:
    """True when this process *is* the service (so it must not stop itself)."""
    if os.environ.get("NSPANEL_SERVICE") == "1":
        return True
    try:
        return config.BASE_DIR.resolve().is_relative_to(config.SERVICE_REPO_DIR.resolve())
    except OSError:
        return False


def branch() -> str:
    return str(_read_state().get("branch") or config.REPO_BRANCH)


def _int(value: Any, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _tls_enabled(state: dict[str, Any]) -> bool:
    return str(state.get("tls", "")) == "1"


def get_status() -> dict[str, Any]:
    state = _read_state()
    installed = is_installed()
    port = _int(state.get("port"), config.SERVICE_PORT_DEFAULT)
    panel_dir = installed_panel_dir() if installed else None
    installed_commit = commit_info(panel_dir) if panel_dir else None
    tls = _tls_enabled(state)
    scheme = "https" if tls else "http"

    update = state.get("update") if installed else None
    if isinstance(update, dict) and installed_commit:
        # A check made against an older release (before an update) no longer applies.
        update = {**update, "stale": update.get("base") != installed_commit["hash"]}
    else:
        update = None

    previous_release = state.get("previous_release")
    previous_commit = None
    if installed and _release_ok(previous_release) and previous_release != str(panel_dir):
        previous_commit = commit_info(Path(previous_release))

    last_rollback = None
    if installed and state.get("last_rollback_at"):
        last_rollback = {
            "at": state.get("last_rollback_at"),
            "from": state.get("last_rollback_from", ""),
            "reason": state.get("last_rollback_reason", ""),
        }

    return {
        "installed": installed,
        "active": systemctl.service_state(config.SERVICE_NAME) if installed else "inactive",
        "enabled": systemctl.service_enabled(config.SERVICE_NAME) if installed else "disabled",
        "port": port,
        "tls": tls,
        "branch": branch(),
        "repo_url": config.REPO_URL,
        "repo_dir": config.SERVICE_REPO_DIR.as_posix(),
        "release_dir": panel_dir.as_posix() if panel_dir else None,
        "subnets": str(state.get("subnets") or "").split(),
        "urls": [f"{scheme}://{address}:{port}" for _, address, _ in _host_ipv4()] if installed else [],
        "installed_commit": installed_commit,
        "running_commit": _RUNNING_COMMIT,
        "previous_commit": previous_commit,
        "can_rollback": previous_commit is not None,
        "last_rollback": last_rollback,
        "installed_at": state.get("installed_at"),
        "updated_at": state.get("updated_at"),
        "update": update,
        "is_self": is_self(),
        "current_port": config.PORT,
        "default_port": config.SERVICE_PORT_DEFAULT,
        "subnet_choices": lan_subnet_choices(),
    }


# ── CI ───────────────────────────────────────────────────────────────────────


def _github_json(path: str) -> Any:
    request = urllib.request.Request(
        f"https://api.github.com/repos/{config.GITHUB_REPO}/{path}",
        headers={"Accept": "application/vnd.github+json", "User-Agent": "NsPanel-update-check"},
    )
    with urllib.request.urlopen(request, timeout=_GITHUB_TIMEOUT) as response:  # noqa: S310 - fixed https URL
        return json.loads(response.read().decode("utf-8"))


def _summarize_runs(runs: list[dict[str, Any]]) -> str:
    if any(run.get("status") != "completed" for run in runs):
        return "pending"
    if any(run.get("conclusion") in _CI_FAILED for run in runs):
        return "failure"
    return "success"


def ci_status(repo: Path, ref: str) -> dict[str, Any]:
    """GitHub check runs for `ref`, walking back past commits CI skipped.

    `state` is success | failure | pending | none (no runs found nearby) |
    unknown (GitHub unreachable or rate limited).
    """
    code, out = _git(repo, "rev-list", f"--max-count={_CI_LOOKBACK}", "--first-parent", ref)
    shas = out.split() if code == 0 else []
    if not shas:
        return {"state": "unknown", "commit": None, "url": None, "error": "commit not found"}
    for sha in shas:
        try:
            data = _github_json(f"commits/{sha}/check-runs?per_page=100")
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
            return {"state": "unknown", "commit": sha, "url": None, "error": str(exc)}
        runs = data.get("check_runs") or []
        if runs:
            return {
                "state": _summarize_runs(runs),
                "commit": sha,
                "url": f"https://github.com/{config.GITHUB_REPO}/commit/{sha}",
                "error": None,
            }
    return {"state": "none", "commit": shas[0], "url": None, "error": None}


# ── update check ─────────────────────────────────────────────────────────────


def check_updates(*, with_ci: bool = True) -> dict[str, Any]:
    """Fetch the public repo and record how far the installed release is behind.

    Only commits touching config.SERVICE_UPDATE_PATHS count as an update; the
    total is kept too so the page can say why "N commits" are not offered.
    """
    repo = config.SERVICE_REPO_DIR
    remote_ref = f"origin/{branch()}"
    result: dict[str, Any] = {
        "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "base": None,
        "remote_commit": None,
        "behind": 0,
        "total_behind": 0,
        "commits": [],
        "ci": None,
        "error": None,
    }

    panel_dir = installed_panel_dir() or repo
    head = commit_info(panel_dir)
    if head is None:
        result["error"] = f"{panel_dir} is not a git checkout."
        return result
    base = head["hash"]
    result["base"] = base

    code, out = _git(repo, "fetch", "--quiet", "origin", branch(), timeout=_FETCH_TIMEOUT)
    if code != 0:
        result["error"] = f"git fetch failed: {out or f'exit {code}'}"
    else:
        span = f"{base}..{remote_ref}"
        result["remote_commit"] = commit_info(repo, remote_ref)
        _, total = _git(repo, "rev-list", "--count", span)
        _, behind = _git(repo, "rev-list", "--count", span, "--", *config.SERVICE_UPDATE_PATHS)
        result["total_behind"] = _int(total.strip(), 0)
        result["behind"] = _int(behind.strip(), 0)
        _, log = _git(
            repo,
            "log",
            f"--format={_LOG_FORMAT}",
            f"-n{_MAX_COMMITS}",
            span,
            "--",
            *config.SERVICE_UPDATE_PATHS,
        )
        result["commits"] = [c for c in map(_parse_commit, log.splitlines()) if c]
        if with_ci and result["behind"]:
            result["ci"] = ci_status(repo, remote_ref)

    if config.SERVICE_STATE_FILE.parent.is_dir():
        with contextlib.suppress(OSError):
            _update_state(update=result)
    return result
