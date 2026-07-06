"""Site discovery: scan SITES_DIR, read each info.yml, attach live status.

Filesystem is the source of truth — there is no site database. A directory
under SITES_DIR with a readable info.yml is a site.
"""
import datetime
from pathlib import Path

import psutil
import yaml

from config import SITES_DIR, SITE_LOG_TAIL_LINES
from features import services


def _mtime(path: Path) -> str:
    ts = datetime.datetime.fromtimestamp(path.stat().st_mtime)
    return ts.strftime("%Y-%m-%d %H:%M")


def read_info(name: str) -> dict | None:
    """Parsed info.yml for one site, or None if missing/unreadable."""
    info_path = SITES_DIR / name / "info.yml"
    if not info_path.exists():
        return None
    try:
        data = yaml.safe_load(info_path.read_text(encoding="utf-8")) or {}
    except (yaml.YAMLError, OSError):
        return None
    if not isinstance(data, dict):
        return None
    data["_dir"] = str(SITES_DIR / name)
    data["last_modified"] = _mtime(info_path)
    return data


def list_sites() -> list[dict]:
    """All sites (info.yml only), sorted by name. No status attached."""
    if not SITES_DIR.exists():
        return []
    sites = []
    for entry in sorted(SITES_DIR.iterdir()):
        if not entry.is_dir():
            continue
        info = read_info(entry.name)
        if info:
            sites.append(info)
    return sites


def get_site_status(info: dict, nginx_ok: bool | None = None) -> dict:
    """Live status for one site: {state, badge, pid, memory_mb}.

    badge is one of: running | ok | failed | stopped | configured | unknown
    (mapped to colours by the _status_badge.html partial).
    """
    stype = info.get("type")
    name = info.get("name")

    if stype == "dotnet":
        state = services.service_state(name)
        pid = services.main_pid(name)
        memory_mb, cpu_percent = None, None
        if pid:
            memory_mb, cpu_percent = services.get_process_stats(pid)
        badge = {
            "active": "running",
            "failed": "failed",
            "inactive": "stopped",
        }.get(state, "unknown")
        return {"state": state, "badge": badge, "pid": pid,
                "enabled": services.service_enabled(name),
                "memory_mb": memory_mb, "cpu_percent": cpu_percent}

    # static / proxy: OK if the nginx conf exists and nginx -t passes globally.
    conf = (info.get("paths") or {}).get("nginx_conf")
    if not conf or not Path(conf).exists():
        return {"state": "missing config", "badge": "configured",
                "pid": None, "memory_mb": None}
    if nginx_ok is None:
        nginx_ok = services.nginx_test()[0]
    if nginx_ok:
        return {"state": "ok", "badge": "ok", "pid": None, "memory_mb": None}
    return {"state": "config error", "badge": "failed",
            "pid": None, "memory_mb": None}


def list_sites_with_status() -> list[dict]:
    """All sites with a `status` key attached. Runs `nginx -t` at most once."""
    sites = list_sites()
    nginx_ok = None
    if any(s.get("type") in ("static", "proxy") for s in sites):
        nginx_ok = services.nginx_test()[0]
    for site in sites:
        site["status"] = get_site_status(site, nginx_ok)
    return sites


def get_site(name: str) -> dict | None:
    """One site with status attached, or None."""
    info = read_info(name)
    if info is None:
        return None
    info["status"] = get_site_status(info)
    return info


def read_config(info: dict) -> str:
    conf = (info.get("paths") or {}).get("nginx_conf")
    if conf and Path(conf).exists():
        return Path(conf).read_text(encoding="utf-8", errors="replace")
    return "(nginx config file not found)"


def _tail_file(path: Path, n: int) -> str:
    if not path.exists():
        return f"(no file: {path})"
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        return f"(could not read {path}: {exc})"
    return "\n".join(lines[-n:]) or "(empty)"


def tail_logs(info: dict, n: int = SITE_LOG_TAIL_LINES) -> dict:
    """Last n lines of each relevant log, keyed by a human label."""
    name = info.get("name")
    log_dir = Path((info.get("paths") or {}).get("log_dir", "/var/www/nginx/log"))
    out = {
        "nginx access": _tail_file(log_dir / f"{name}-access.log", n),
        "nginx error": _tail_file(log_dir / f"{name}-error.log", n),
    }
    if info.get("type") == "dotnet":
        code, journal = services.run(
            ["journalctl", "-u", name, "-n", str(n), "--no-pager"]
        )
        out["systemd journal"] = journal or "(no journal output)"
    return out
