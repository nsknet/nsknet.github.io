#!/usr/bin/env bash
# openobserve.sh — OpenObserve on Ubuntu 24.04
# Docs: https://openobserve.ai/docs/quickstart/

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


OPENOBSERVE_DIR="/opt/openobserve"
OPENOBSERVE_DATA="/var/lib/openobserve"
OPENOBSERVE_SERVICE="/var/www/services/openobserve.service"
OPENOBSERVE_CRED_FILE="${OPENOBSERVE_DIR}/credentials.yml"

install_openobserve() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing OpenObserve"
    echo "════════════════════════════════════════════════════════════"

    apt-get install -y curl tar
    # Get latest version from https://openobserve.ai/downloads/
    version="0.80.3"
    
    # ── Download binary ───────────────────────────────────────────
    local url="https://downloads.openobserve.ai/releases/openobserve/v${version}/openobserve-v${version}-linux-amd64-musl.tar.gz"

    echo "▶  Downloading ${tarball}..."
    mkdir -p "$OPENOBSERVE_DIR" "$OPENOBSERVE_DATA" /var/www/services

    curl -fsSL "$url" -o /tmp/openobserve.tar.gz
    tar -xzf /tmp/openobserve.tar.gz -C "$OPENOBSERVE_DIR"
    rm -f /tmp/openobserve.tar.gz

    chmod +x "${OPENOBSERVE_DIR}/openobserve"

    # ── Dedicated system user ─────────────────────────────────────
    if ! id openobserve &>/dev/null; then
        useradd --system --no-create-home --shell /sbin/nologin openobserve
    fi
    chown -R openobserve:openobserve "$OPENOBSERVE_DIR" "$OPENOBSERVE_DATA"

    # ── Credentials: use the password supplied by the panel, else generate ──
    local admin_email="admin@localhost.local"
    local admin_pass
    admin_pass="${DB_PASSWORD:-$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 28)}"

    # ── systemd service ───────────────────────────────────────────
    echo "▶  Writing systemd service..."
    cat > "$OPENOBSERVE_SERVICE" <<UNIT
[Unit]
Description=OpenObserve — observability platform
Documentation=https://openobserve.ai/docs/
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=openobserve
Group=openobserve
WorkingDirectory=${OPENOBSERVE_DIR}
ExecStart=${OPENOBSERVE_DIR}/openobserve

Restart=always
RestartSec=10
KillSignal=SIGTERM
TimeoutStopSec=30

# Listen on all interfaces; UFW restricts access to private subnets only.
Environment=ZO_HTTP_ADDR=0.0.0.0
Environment=ZO_HTTP_PORT=5080
Environment=ZO_DATA_DIR=${OPENOBSERVE_DATA}

Environment=ZO_ROOT_USER_EMAIL=${admin_email}
Environment=ZO_ROOT_USER_PASSWORD=${admin_pass}

# Production-grade settings
Environment=ZO_TELEMETRY=false
Environment=RUST_LOG=warn

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable "$OPENOBSERVE_SERVICE"
    systemctl start openobserve

    # Wait a moment for startup
    sleep 3
    systemctl status openobserve --no-pager

    # ── Save credentials ──────────────────────────────────────────
    echo "▶  Saving credentials to ${OPENOBSERVE_CRED_FILE}..."
    cat > "$OPENOBSERVE_CRED_FILE" <<CRED
# OpenObserve credentials
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
service: openobserve
version: "${version}"

admin_email: "${admin_email}"
admin_password: "${admin_pass}"

http_port: 5080
ui_url: "http://<server-ip>:5080"

data_dir: "${OPENOBSERVE_DATA}"
install_dir: "${OPENOBSERVE_DIR}"

notes: "Bound to 0.0.0.0; UFW restricts access to private subnets only."
CRED
    chmod 600 "$OPENOBSERVE_CRED_FILE"

    # ── Firewall: allow only private subnets, deny everything else ───────────
    _ufw_allow_port 5080 "OpenObserve"

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  OpenObserve ${version} installed."
    echo "   UI       : http://<server-ip>:5080"
    echo "   Allow    : ${ALLOWED_SUBNETS[*]}"
    echo "   Email    : ${admin_email}"
    echo "   Password : ${admin_pass}"
    echo ""
    echo "   Credentials saved to: ${OPENOBSERVE_CRED_FILE}"
    echo "   Data dir  : ${OPENOBSERVE_DATA}"
    echo "════════════════════════════════════════════════════════════"
}

uninstall_openobserve() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Removing OpenObserve"
    echo "════════════════════════════════════════════════════════════"
    systemctl disable --now openobserve 2>/dev/null || true
    rm -f /etc/systemd/system/openobserve.service "$OPENOBSERVE_SERVICE"
    systemctl daemon-reload || true
    rm -rf "$OPENOBSERVE_DIR" "$OPENOBSERVE_DATA"
    userdel openobserve 2>/dev/null || true
    _unregister_panel_service openobserve
    echo "✔  OpenObserve removed (data in ${OPENOBSERVE_DATA} deleted)."
}
