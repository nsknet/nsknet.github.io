#!/usr/bin/env bash
# Launch NsPanel. Run as root, on the server it manages:  sudo ./run.sh
#
# Options:
#   --reset-password   generate a new admin password, print it, then start
#
# Environment overrides:
#   NSPANEL_HOST     bind address        (default 127.0.0.1 — reach it over an SSH tunnel)
#   NSPANEL_PORT     bind port           (default 7777)
#   NSPANEL_DEV=1    uvicorn --reload    (development only)
#   PANEL_PASSWORD   pin the admin password (re-applied on every start while set)
#
# The admin password is stored only as a scrypt hash in /etc/nspanel/auth.json,
# shared with the NsPanel service if one is installed. It is generated and
# printed once, on the first start.
set -euo pipefail

cd "$(dirname "$0")"

BOLD='\033[1m'; CYAN='\033[1;96m'; GREEN='\033[1;92m'
YELLOW='\033[1;93m'; DIM='\033[2m'; NC='\033[0m'

HOST="${NSPANEL_HOST:-127.0.0.1}"
PORT="${NSPANEL_PORT:-7777}"
RESET_PASSWORD=0
for arg in "$@"; do
    case "$arg" in
        --reset-password) RESET_PASSWORD=1 ;;
    esac
done

# --- Must be root.
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}ERROR:${NC} run as root (sudo ./run.sh) — the panel manages system services."
    exit 1
fi

# --- Python 3.12+ required (Ubuntu 24.04 ships it; 22.04 needs the deadsnakes PPA).
if ! command -v python3 >/dev/null 2>&1; then
    echo -e "${YELLOW}ERROR:${NC} python3 not found. Install Python 3.12+ first."
    exit 1
fi
if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 12))'; then
    echo -e "${YELLOW}ERROR:${NC} Python $(python3 -c 'import platform; print(platform.python_version())') found; NsPanel needs 3.12+."
    echo -e "       Supported: Ubuntu 24.04 or newer. On 22.04: add-apt-repository ppa:deadsnakes/ppa && apt install python3.12-venv"
    exit 1
fi

# --- Frontend must be built (dist/ is committed; rebuild after changing frontend/).
if [ ! -f "static/dist/index.html" ]; then
    echo -e "${YELLOW}ERROR:${NC} frontend build missing (static/dist/index.html)."
    echo -e "       Build it with: ${CYAN}cd frontend && npm ci && npm run build${NC}"
    exit 1
fi

# --- Set up virtualenv.
if [ ! -x ".venv/bin/pip" ]; then
    echo -e "${DIM}Creating virtual environment...${NC}"
    rm -rf .venv
    if ! python3 -m venv .venv 2>/dev/null; then
        echo -e "${YELLOW}WARNING:${NC} Failed to create virtual environment."
        if command -v apt-get >/dev/null 2>&1; then
            echo -e "${CYAN}Installing python3-venv...${NC}"
            DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 update -q
            DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y python3-venv python3-pip
            python3 -m venv .venv
        else
            echo -e "${YELLOW}ERROR:${NC} apt-get not found. Install python3-venv manually."
            exit 1
        fi
    fi
fi

# --- Dependencies: pinned and hash-checked from requirements.lock, reinstalled
# only when the lock (or pyproject.toml) changes — not on every launch.
deps_stamp=".venv/.nspanel-deps"
deps_hash="$(cat requirements.lock pyproject.toml | sha256sum | cut -d' ' -f1)"
if [ "$(cat "$deps_stamp" 2>/dev/null || true)" != "$deps_hash" ]; then
    echo -e "${DIM}Installing dependencies from requirements.lock...${NC}"
    .venv/bin/pip install --quiet --require-hashes -r requirements.lock
    .venv/bin/pip install --quiet --no-deps --no-build-isolation -e . 2>/dev/null \
        || .venv/bin/pip install --quiet --no-deps -e .
    echo "$deps_hash" > "$deps_stamp"
fi

# --- Normalize shell scripts once (a checkout on Windows can introduce CRLF).
if grep -rlq $'\r' scripts 2>/dev/null; then
    find scripts -name '*.sh' -exec sed -i 's/\r$//' {} +
fi

# --- Admin password: stored as a hash; printed only when it was just created.
if [ "$RESET_PASSWORD" = "1" ]; then
    NEW_PASSWORD="$(.venv/bin/python -m core.passwords reset)"
else
    NEW_PASSWORD="$(.venv/bin/python -m core.passwords ensure)"
fi
export NSPANEL_HOST="$HOST" NSPANEL_PORT="$PORT"

# --- Banner.
echo ""
echo -e "${BOLD}+------------------------------------------------------------+${NC}"
echo -e "${BOLD}|                        NsPanel                             |${NC}"
echo -e "${BOLD}+------------------------------------------------------------+${NC}"
echo -e "${BOLD}|${NC}  URL       : ${GREEN}http://${HOST}:${PORT}${NC}"
echo -e "${BOLD}|${NC}  Username  : ${CYAN}admin${NC}"
if [ -n "$NEW_PASSWORD" ]; then
    echo -e "${BOLD}|${NC}  Password  : ${YELLOW}${BOLD}${NEW_PASSWORD}${NC}"
    echo -e "${BOLD}|${NC}  ${DIM}Shown once. Change it in the panel, or: sudo ./run.sh --reset-password${NC}"
elif [ -n "${PANEL_PASSWORD:-}" ]; then
    echo -e "${BOLD}|${NC}  Password  : ${DIM}from PANEL_PASSWORD${NC}"
else
    echo -e "${BOLD}|${NC}  Password  : ${DIM}unchanged (forgot it? sudo ./run.sh --reset-password)${NC}"
fi
echo -e "${BOLD}|${NC}"
echo -e "${BOLD}|${NC}  ${DIM}Bound to ${HOST}. Tunnel in from your machine:${NC}"
echo -e "${BOLD}|${NC}    ${DIM}ssh -L ${PORT}:localhost:${PORT} user@server${NC}"
echo -e "${BOLD}|${NC}    ${DIM}then open http://localhost:${PORT} in your browser.${NC}"
echo -e "${BOLD}|${NC}"
echo -e "${BOLD}|${NC}  ${DIM}Port already in use? fuser -k ${PORT}/tcp${NC}"
echo -e "${BOLD}+------------------------------------------------------------+${NC}"
echo ""
unset NEW_PASSWORD

# --- Run.
if [ "${NSPANEL_DEV:-}" = "1" ]; then
    echo -e "${CYAN}Development mode (auto-reload enabled).${NC}"
    exec .venv/bin/uvicorn app:app --host "$HOST" --port "$PORT" --reload
fi
exec .venv/bin/uvicorn app:app --host "$HOST" --port "$PORT" --timeout-graceful-shutdown 15
