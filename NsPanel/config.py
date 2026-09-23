"""Paths and constants for the NsPanel VPS admin panel.

Everything filesystem-related lives here so the rest of the code never
hardcodes a path. Network settings read from the environment (set by run.sh)
with safe localhost defaults — see docs/ARCHITECTURE.md.
"""
import os
from pathlib import Path

# --- Network -----------------------------------------------------------------
# Defaults to localhost: the panel is meant to be reached over an SSH tunnel.
# Override with NSPANEL_HOST / NSPANEL_PORT only if you know what you expose.
HOST = os.environ.get("NSPANEL_HOST", "127.0.0.1")
PORT = int(os.environ.get("NSPANEL_PORT", "7777"))
DEV = os.environ.get("NSPANEL_DEV") == "1"
USERNAME = os.environ.get("PANEL_USERNAME", "admin")

# --- Panel install location ---------------------------------------------------
BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"
DIST_DIR = STATIC_DIR / "dist"
LOGO_DIR = STATIC_DIR / "logo"
SCRIPTS_DIR = BASE_DIR / "scripts"
SCRIPTS_LIB_DIR = SCRIPTS_DIR / "lib"


def _resolve_audit_log() -> Path:
    """System log dir when writable (the panel runs as root), else next to the code."""
    override = os.environ.get("NSPANEL_AUDIT_LOG")
    if override:
        return Path(override)
    if os.name != "posix":
        # Dev machines (Windows/macOS sandboxes) keep the log beside the code.
        return BASE_DIR / "audit.log"
    system_dir = Path("/var/log/nspanel")
    try:
        system_dir.mkdir(parents=True, exist_ok=True)
        probe = system_dir / ".write-test"
        probe.touch()
        probe.unlink()
        return system_dir / "audit.log"
    except OSError:
        return BASE_DIR / "audit.log"


AUDIT_LOG = _resolve_audit_log()

# --- Server filesystem conventions (must match scripts/*.sh) ------------------
SITES_DIR = Path("/var/www/nginx/sites")
NGINX_CONF_DIR = Path("/var/www/nginx/conf.d")
SERVICES_DIR = Path("/var/www/services")
NGINX_LOG_DIR = Path("/var/www/nginx/log")

# --- Misc ---------------------------------------------------------------------
PORT_MIN = 5000
PORT_MAX = 50000
AUDIT_TAIL_LINES = 200
SITE_LOG_TAIL_LINES = 100
# Finished jobs kept in memory for the Task/overlay views; oldest are evicted.
MAX_JOBS = 200
