"""What code is running: package version plus the git commit it was started from.

Releases track commits on `main`, so the commit is the real identity; the
package version only moves on breaking changes. Read once at import — the
checkout does not change under a running process (updates restart it).
"""
import json
import subprocess
from functools import lru_cache
from importlib import metadata

import config


def _git(*args: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(config.BASE_DIR), *args], capture_output=True, text=True, timeout=5
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


def _package_version() -> str:
    try:
        return metadata.version("nspanel")
    except metadata.PackageNotFoundError:
        return "0.0.0"


def _dist_source() -> str:
    """Last commit touching frontend/ when static/dist was built (static/dist/version.json)."""
    try:
        data = json.loads((config.DIST_DIR / "version.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    return str(data.get("frontend_commit", ""))


@lru_cache(maxsize=1)
def info() -> dict[str, str]:
    """Version, commit and whether static/dist matches frontend/ (see `bundle_stale`)."""
    commit = _git("rev-parse", "--short=12", "HEAD")
    return {
        "version": _package_version(),
        "commit": commit,
        "commit_date": _git("log", "-1", "--format=%cI") if commit else "",
        "branch": _git("rev-parse", "--abbrev-ref", "HEAD") if commit else "",
        "dirty": "1" if commit and _git("status", "--porcelain", "--untracked-files=no") else "",
        # The bundle is stale when frontend/ has commits newer than the ones it
        # was built from (both sides are "last commit touching frontend/").
        "frontend_commit": _git("log", "-1", "--format=%H", "--", "frontend") if commit else "",
        "dist_frontend_commit": _dist_source(),
    }


def label() -> str:
    """`0.3.0+a1b2c3d` — short form for logs and the UI footer."""
    data = info()
    return f"{data['version']}+{data['commit'][:7]}" if data["commit"] else data["version"]


def bundle_stale() -> bool:
    data = info()
    return bool(data["frontend_commit"] and data["dist_frontend_commit"]) and (
        data["frontend_commit"] != data["dist_frontend_commit"]
    )
