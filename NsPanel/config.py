"""Paths and constants for the VPS admin panel.

Everything filesystem-related lives here so the rest of the code never
hardcodes a path. The bind host/port are intentionally fixed — see README.
"""
from pathlib import Path

# --- Network: localhost only, never 0.0.0.0. Not configurable by design. ---
HOST = "127.0.0.1"
PORT = 7777
USERNAME = "admin"

# --- Panel install location ---
BASE_DIR = Path(__file__).resolve().parent
UBUNTU_SH = BASE_DIR / "ubuntu.sh"
AUDIT_LOG = BASE_DIR / "audit.log"
STATIC_DIR = BASE_DIR / "static"

# --- Server filesystem conventions (must match ubuntu.sh) ---
SITES_DIR = Path("/var/www/nginx/sites")
NGINX_CONF_DIR = Path("/var/www/nginx/conf.d")
SERVICES_DIR = Path("/var/www/services")
NGINX_LOG_DIR = Path("/var/www/nginx/log")

# --- Misc ---
PORT_MIN = 5000
PORT_MAX = 50000
AUDIT_TAIL_LINES = 200
SITE_LOG_TAIL_LINES = 100
