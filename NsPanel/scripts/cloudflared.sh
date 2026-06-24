#!/usr/bin/env bash
# cloudflared.sh — Cloudflare Tunnel client installation

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


install_cloudflared() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing cloudflared"
    echo "════════════════════════════════════════════════════════════"
    wget -q -O /tmp/cloudflared.deb \
        https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i /tmp/cloudflared.deb
    rm -f /tmp/cloudflared.deb
    cloudflared --version
    echo "✔  cloudflared installed."
}

uninstall_cloudflared() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Removing cloudflared"
    echo "════════════════════════════════════════════════════════════"
    apt-get purge -y cloudflared 2>/dev/null || dpkg -r cloudflared 2>/dev/null || true
    apt-get autoremove -y || true
    echo "✔  cloudflared removed."
}
