"""Things the operator should look at, for the Overview screen.

Each alert is `{level, title, detail, link}`; level is `danger` or `warn`.
Every probe is best-effort: one that cannot run (off-Linux, missing tool)
contributes nothing rather than failing the dashboard.
"""

import json
import time
from typing import Any

import psutil

import config
from core import runner, version
from features import systemctl, units

_DISK_WARN = 85
_DISK_DANGER = 95
_RAM_WARN = 90
_FAILED_JOB_WINDOW = 24 * 60 * 60


def _alert(level: str, title: str, detail: str = "", link: str = "") -> dict[str, str]:
    return {"level": level, "title": title, "detail": detail, "link": link}


def _disk_alerts() -> list[dict[str, str]]:
    alerts = []
    seen: set[str] = set()
    for part in psutil.disk_partitions(all=False):
        if part.mountpoint in seen or part.fstype in ("squashfs", "tmpfs", "overlay"):
            continue
        seen.add(part.mountpoint)
        try:
            usage = psutil.disk_usage(part.mountpoint)
        except OSError:
            continue
        if usage.percent >= _DISK_WARN:
            level = "danger" if usage.percent >= _DISK_DANGER else "warn"
            free_gb = usage.free / 1e9
            alerts.append(
                _alert(
                    level,
                    f"Disk {part.mountpoint} is {usage.percent:.0f}% full",
                    f"{free_gb:.1f} GB free",
                    "/system/storage",
                )
            )
    return alerts


def _memory_alerts() -> list[dict[str, str]]:
    vm = psutil.virtual_memory()
    if vm.percent >= _RAM_WARN:
        return [
            _alert(
                "warn",
                f"Memory is {vm.percent:.0f}% used",
                f"{vm.available / 1e9:.1f} GB available",
                "/system/processes",
            )
        ]
    return []


def _failed_units() -> list[dict[str, str]]:
    alerts = []
    try:
        services = units.list_services()
    except OSError:
        return []
    for svc in services:
        if svc.get("state") == "failed":
            alerts.append(
                _alert(
                    "danger",
                    f"Service {svc['name']} has failed",
                    "It stopped with an error.",
                    f"/apps/service/{svc['name']}",
                )
            )
    return alerts


def _failed_jobs() -> list[dict[str, str]]:
    cutoff = time.time() - _FAILED_JOB_WINDOW
    failed = [
        job
        for job in runner.list_jobs()
        if job["status"] == "failed" and (job["finished_at"] or 0) >= cutoff and not job.get("cancelled")
    ]
    if not failed:
        return []
    latest = failed[0]["label"]
    more = f" and {len(failed) - 1} more" if len(failed) > 1 else ""
    return [
        _alert("warn", f"{len(failed)} job(s) failed in the last 24 h", f"{latest}{more}", "/activity/jobs")
    ]


def _panel_alerts() -> list[dict[str, str]]:
    alerts = []
    if version.bundle_stale():
        alerts.append(
            _alert(
                "warn",
                "The UI bundle is older than the code",
                "static/dist was not rebuilt after a frontend change.",
                "",
            )
        )
    try:
        state = json.loads(config.SERVICE_STATE_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return alerts
    update = state.get("update") if isinstance(state, dict) else None
    if isinstance(update, dict) and update.get("behind") and not update.get("error"):
        alerts.append(
            _alert("warn", f"Panel update available ({update['behind']} commit(s))", "", "/settings/panel")
        )
    if isinstance(state, dict) and state.get("last_rollback_at"):
        alerts.append(
            _alert(
                "danger",
                "The panel service rolled back an update",
                str(state.get("last_rollback_reason", "")),
                "/settings/panel",
            )
        )
    return alerts


def _firewall_alerts() -> list[dict[str, str]]:
    if not systemctl.which("ufw"):
        return [_alert("warn", "No firewall installed", "UFW is not installed.", "/network/firewall")]
    return []


def collect() -> list[dict[str, Any]]:
    alerts: list[dict[str, Any]] = []
    for probe in (_disk_alerts, _memory_alerts, _failed_units, _failed_jobs, _panel_alerts, _firewall_alerts):
        try:
            alerts.extend(probe())
        except Exception:  # noqa: BLE001 - one broken probe must not hide the others
            continue
    order = {"danger": 0, "warn": 1}
    return sorted(alerts, key=lambda a: order.get(a["level"], 2))
