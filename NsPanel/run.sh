#!/bin/bash
# Launch the VPS admin panel. Run as root, on the server it manages.
#   sudo ./run.sh
set -e

cd "$(dirname "$0")"

BOLD='\033[1m'
CYAN='\033[1;96m'
GREEN='\033[1;92m'
YELLOW='\033[1;93m'
DIM='\033[2m'
NC='\033[0m'

# --- Must be root.
if [ "$EUID" -ne 0 ]; then
    echo -e "${YELLOW}ERROR:${NC} run as root (sudo ./run.sh) — the panel manages system services."
    exit 1
fi

# --- Python 3 required.
if ! command -v python3 >/dev/null 2>&1; then
    echo -e "${YELLOW}ERROR:${NC} python3 not found. Please install Python 3 first."
    exit 1
fi

# --- Set up virtualenv.
if [ ! -d ".venv" ] || [ ! -f ".venv/bin/pip" ]; then
    echo -e "${DIM}Creating virtual environment...${NC}"
    rm -rf .venv
    if ! python3 -m venv .venv 2>/dev/null; then
        echo -e "${YELLOW}WARNING:${NC} Failed to create virtual environment."
        if command -v apt-get >/dev/null 2>&1; then
            echo -e "${CYAN}Attempting to install python3-venv and python3-pip automatically...${NC}"
            apt-get update && apt-get install -y python3-venv python3-pip
            echo -e "${DIM}Retrying virtual environment creation...${NC}"
            if ! python3 -m venv .venv; then
                echo -e "${YELLOW}ERROR:${NC} Failed to create virtual environment after installing packages."
                exit 1
            fi
        else
            echo -e "${YELLOW}ERROR:${NC} apt-get not found. Please install python3-venv and python3-pip manually."
            exit 1
        fi
    fi
fi

# --- Sync dependencies.
echo -e "${DIM}Installing dependencies...${NC}"
.venv/bin/pip install --upgrade pip --quiet
.venv/bin/pip install -r requirements.txt --quiet

# --- Generate the session password (regenerated every launch).
#export PANEL_PASSWORD="$(.venv/bin/python -c 'import secrets; print(secrets.token_urlsafe(16))')"
export PANEL_PASSWORD="admin"

# --- Banner.
echo ""
echo -e "${BOLD}+------------------------------------------------------------+${NC}"
echo -e "${BOLD}|                   VPS ADMIN PANEL                         |${NC}"
echo -e "${BOLD}+------------------------------------------------------------+${NC}"
echo -e "${BOLD}|${NC}  URL       : ${GREEN}http://127.0.0.1:7777${NC}"
echo -e "${BOLD}|${NC}  Username  : ${CYAN}admin${NC}"
echo -e "${BOLD}|${NC}  Password  : ${YELLOW}${BOLD}${PANEL_PASSWORD}${NC}"
echo -e "${BOLD}|${NC}"
echo -e "${BOLD}|${NC}  ${DIM}Bound to localhost only. Tunnel in from your machine:${NC}"
echo -e "${BOLD}|${NC}    ${DIM}ssh -L 7777:localhost:7777 user@server${NC}"
echo -e "${BOLD}|${NC}    ${DIM}then open http://localhost:7777 in your browser.${NC}"
echo -e "${BOLD}+------------------------------------------------------------+${NC}"
echo ""

# --- Run.
echo -e "${CYAN}Running in development mode (auto-reload enabled)...${NC}"
exec .venv/bin/uvicorn app:app --host 0.0.0.0 --port 7777 --reload

