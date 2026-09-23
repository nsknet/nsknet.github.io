#!/usr/bin/env bash
# Launch NsPanel. Run as root, on the server it manages:  sudo ./run.sh
#
# Environment overrides:
#   NSPANEL_HOST     bind address        (default 127.0.0.1 — reach it over an SSH tunnel)
#   NSPANEL_PORT     bind port           (default 7777)
#   NSPANEL_DEV=1    uvicorn --reload    (development only)
#   PANEL_PASSWORD   fixed password      (default: random, regenerated every launch)
set -euo pipefail

cd "$(dirname "$0")"

BOLD='\033[1m'; CYAN='\033[1;96m'; GREEN='\033[1;92m'
YELLOW='\033[1;93m'; DIM='\033[2m'; NC='\033[0m'

HOST="${NSPANEL_HOST:-127.0.0.1}"
PORT="${NSPANEL_PORT:-7777}"

# --- Must be root.
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}ERROR:${NC} run as root (sudo ./run.sh) — the panel manages system services."
    exit 1
fi

# --- Python 3 required.
if ! command -v python3 >/dev/null 2>&1; then
    echo -e "${YELLOW}ERROR:${NC} python3 not found. Please install Python 3.12+ first."
    exit 1
fi

# --- Frontend must be built (dist/ is committed; rebuild after changing frontend/).
if [ ! -f "static/dist/index.html" ]; then
    echo -e "${YELLOW}ERROR:${NC} frontend build missing (static/dist/index.html)."
    echo -e "       Build it with: ${CYAN}cd frontend && npm ci && npm run build${NC}"
    exit 1
fi

# --- Set up virtualenv.
if [ ! -d ".venv" ] || [ ! -f ".venv/bin/pip" ]; then
    echo -e "${DIM}Creating virtual environment...${NC}"
    rm -rf .venv
    if ! python3 -m venv .venv 2>/dev/null; then
        echo -e "${YELLOW}WARNING:${NC} Failed to create virtual environment."
        if command -v apt-get >/dev/null 2>&1; then
            echo -e "${CYAN}Installing python3-venv and python3-pip...${NC}"
            apt-get update -q && apt-get install -y python3-venv python3-pip
            python3 -m venv .venv
        else
            echo -e "${YELLOW}ERROR:${NC} apt-get not found. Install python3-venv and python3-pip manually."
            exit 1
        fi
    fi
fi

# --- Sync dependencies.
echo -e "${DIM}Installing dependencies...${NC}"
.venv/bin/pip install --upgrade pip --quiet
.venv/bin/pip install -e . --quiet

# --- Normalize shell scripts once (a checkout on Windows can introduce CRLF).
find scripts -name '*.sh' -exec sed -i 's/\r$//' {} +

# --- Session password: random unless the operator pinned one.
if [ -z "${PANEL_PASSWORD:-}" ]; then
    PANEL_PASSWORD="$(.venv/bin/python -c 'import secrets; print(secrets.token_urlsafe(16))')"
fi
export PANEL_PASSWORD NSPANEL_HOST="$HOST" NSPANEL_PORT="$PORT"

# --- Banner.
echo ""
echo -e "${BOLD}+------------------------------------------------------------+${NC}"
echo -e "${BOLD}|                        NsPanel                             |${NC}"
echo -e "${BOLD}+------------------------------------------------------------+${NC}"
echo -e "${BOLD}|${NC}  URL       : ${GREEN}http://${HOST}:${PORT}${NC}"
echo -e "${BOLD}|${NC}  Username  : ${CYAN}admin${NC}"
echo -e "${BOLD}|${NC}  Password  : ${YELLOW}${BOLD}${PANEL_PASSWORD}${NC}"
echo -e "${BOLD}|${NC}"
echo -e "${BOLD}|${NC}  ${DIM}Bound to ${HOST}. Tunnel in from your machine:${NC}"
echo -e "${BOLD}|${NC}    ${DIM}ssh -L ${PORT}:localhost:${PORT} user@server${NC}"
echo -e "${BOLD}|${NC}    ${DIM}then open http://localhost:${PORT} in your browser.${NC}"
echo -e "${BOLD}|${NC}"
echo -e "${BOLD}|${NC}  ${DIM}Port already in use? fuser -k ${PORT}/tcp${NC}"
echo -e "${BOLD}+------------------------------------------------------------+${NC}"
echo ""

# --- Run.
if [ "${NSPANEL_DEV:-}" = "1" ]; then
    echo -e "${CYAN}Development mode (auto-reload enabled).${NC}"
    exec .venv/bin/uvicorn app:app --host "$HOST" --port "$PORT" --reload
fi
exec .venv/bin/uvicorn app:app --host "$HOST" --port "$PORT"
