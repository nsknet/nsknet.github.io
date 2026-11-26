"""Paths and constants for the NsPanel VPS admin panel.

Everything filesystem-related lives here so the rest of the code never
hardcodes a path. Network settings read from the environment (set by run.sh)
with safe localhost defaults — see docs/ARCHITECTURE.md.
"""

import os
from pathlib import Path


def _env_port(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    if not raw.isdigit() or not 1 <= int(raw) <= 65535:
        raise SystemExit(f"{name}={raw!r} is not a valid TCP port (1-65535).")
    return int(raw)


# --- Network -----------------------------------------------------------------
# Defaults to localhost: the panel is meant to be reached over an SSH tunnel.
# Override with NSPANEL_HOST / NSPANEL_PORT only if you know what you expose.
HOST = os.environ.get("NSPANEL_HOST", "127.0.0.1")
PORT = _env_port("NSPANEL_PORT", 7777)
USERNAME = os.environ.get("PANEL_USERNAME", "admin")

# --- Panel install location ---------------------------------------------------
BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"
DIST_DIR = STATIC_DIR / "dist"
LOGO_DIR = STATIC_DIR / "logo"
SCRIPTS_DIR = BASE_DIR / "scripts"
SCRIPTS_LIB_DIR = SCRIPTS_DIR / "lib"

# Off-Linux (development) and when the system dirs are not writable, state goes
# here instead, next to the code (gitignored).
DEV_STATE_DIR = BASE_DIR / ".nspanel-dev"


def _writable_dir(system_dir: Path) -> Path:
    """`system_dir` when the panel can write there (it runs as root), else DEV_STATE_DIR."""
    if os.name == "posix":
        try:
            system_dir.mkdir(parents=True, exist_ok=True)
            probe = system_dir / ".write-test"
            probe.touch()
            probe.unlink()
            return system_dir
        except OSError:
            pass
    DEV_STATE_DIR.mkdir(parents=True, exist_ok=True)
    return DEV_STATE_DIR


def audit_log_path() -> Path:
    """Resolved on first use, not at import: tests and the smoke test must not touch /var/log."""
    override = os.environ.get("NSPANEL_AUDIT_LOG")
    return Path(override) if override else _writable_dir(Path("/var/log/nspanel")) / "audit.log"


def auth_file_path() -> Path:
    """The admin password hash (scrypt). Shared by every panel on the host."""
    override = os.environ.get("NSPANEL_AUTH_FILE")
    return Path(override) if override else _writable_dir(SERVICE_CONF_DIR) / "auth.json"


def state_dir() -> Path:
    """Persistent runtime state (job history)."""
    override = os.environ.get("NSPANEL_STATE_DIR")
    return Path(override) if override else _writable_dir(Path("/var/lib/nspanel"))


# --- Auth ---------------------------------------------------------------------
SESSION_COOKIE = "nspanel_session"
SESSION_IDLE_SECONDS = 30 * 60
SESSION_MAX_SECONDS = 12 * 60 * 60
# Per client IP: this many failed logins within the window locks it out.
LOGIN_MAX_FAILURES = 5
LOGIN_WINDOW_SECONDS = 15 * 60
LOGIN_LOCKOUT_SECONDS = 15 * 60
PASSWORD_MIN_LENGTH = 12

# --- Server filesystem conventions (must match scripts/*.sh) ------------------
SITES_DIR = Path("/var/www/nginx/sites")
NGINX_CONF_DIR = Path("/var/www/nginx/conf.d")
SERVICES_DIR = Path("/var/www/services")
NGINX_LOG_DIR = Path("/var/www/nginx/log")

# --- Panel as a systemd service (scripts/panel_service.sh) -------------------
# The service runs from its own sparse clone, so the checkout run.sh uses can be
# pulled or edited without changing what the service runs until it restarts.
REPO_URL = "https://github.com/nsknet/nsknet.github.io.git"
REPO_BRANCH = "main"
SERVICE_NAME = "nspanel"
SERVICE_REPO_DIR = Path("/opt/nspanel")
# Symlink to the release the service runs (releases/<sha>/NsPanel).
SERVICE_CURRENT_LINK = SERVICE_REPO_DIR / "current"
# Installs made before release directories ran the clone's own NsPanel/.
SERVICE_LEGACY_PANEL_DIR = SERVICE_REPO_DIR / "NsPanel"
SERVICE_CONF_DIR = Path("/etc/nspanel")
SERVICE_STATE_FILE = SERVICE_CONF_DIR / "state.json"
# Root-only EnvironmentFiles that hold Cloudflare tunnel tokens (TUNNEL_TOKEN=…).
TUNNEL_ENV_DIR = SERVICE_CONF_DIR / "tunnels"
SERVICE_PORT_DEFAULT = 7778
# GitHub repository whose CI results gate an update (owner/name).
GITHUB_REPO = "nsknet/nsknet.github.io"
# Repo paths whose changes count as a panel update (others, e.g. sample-site
# tarballs, do not need a restart).
SERVICE_UPDATE_PATHS = ("NsPanel", "nspanel.sh")

# --- Audit log ----------------------------------------------------------------
AUDIT_TAIL_LINES = 200
AUDIT_MAX_BYTES = 5 * 1024 * 1024
AUDIT_BACKUPS = 3

# --- Jobs ---------------------------------------------------------------------
# Finished jobs kept in memory for the Task/overlay views; oldest are evicted.
MAX_JOBS = 200
# Output lines kept per job; older lines are dropped (a noisy install can print
# hundreds of thousands).
MAX_JOB_LINES = 20_000
# A job still running after this long is killed. Generous: some installers
# (SQL Server, Elasticsearch) legitimately take a long time.
JOB_TIMEOUT_SECONDS = 3 * 60 * 60
# Finished jobs kept in the on-disk history.
JOB_HISTORY_KEEP = 500

SITE_LOG_TAIL_LINES = 100
