#!/bin/bash
set -e

[ "$EUID" -eq 0 ] && SUDO="" || SUDO="sudo"

# Ensure git is installed
command -v git >/dev/null 2>&1 || { $SUDO apt-get update -y && $SUDO apt-get install -y git; }

# Clone or navigate to NsPanel
if [ -f "NsPanel/run.sh" ]; then
    cd NsPanel
elif [ ! -f "run.sh" ]; then
    if [ -d "nsknet.github.io" ]; then
        git -C nsknet.github.io pull --quiet 2>/dev/null || true
    else
        git clone --depth=1 https://github.com/nsknet/nsknet.github.io.git
    fi
    cd nsknet.github.io/NsPanel
fi

chmod +x run.sh 2>/dev/null || true
$SUDO ./run.sh "$@"
