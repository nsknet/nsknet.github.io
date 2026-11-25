#!/usr/bin/env bash
# openobserve.sh — OpenObserve on Ubuntu 22.04 / 24.04 (amd64, arm64)
# Docs: https://openobserve.ai/docs/quickstart/
#
# Root credentials live in /etc/openobserve/env (0600, EnvironmentFile), never
# in the unit. There is no change-password action: OpenObserve only reads them
# to create the root user on first start; change the password in its UI.

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

    # Static release binaries: amd64 (musl) and arm64.
    _require_platform "OpenObserve" "22.04 24.04" "amd64 arm64"

    # Pin a release; override with OPENOBSERVE_VERSION (see https://openobserve.ai/downloads/).
    local version="${OPENOBSERVE_VERSION:-0.80.3}"
    version="${version#v}"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$ ]]; then
        echo "❌  OPENOBSERVE_VERSION must look like 0.80.3 (got '${version}')."
        return 1
    fi

    local asset
    case "$(_os_arch)" in
        amd64) asset="openobserve-v${version}-linux-amd64-musl.tar.gz" ;;
        arm64) asset="openobserve-v${version}-linux-arm64.tar.gz" ;;
    esac

    apt-get update -q
    apt-get install -y curl tar

    # ── Download and verify ───────────────────────────────────────
    local url="https://downloads.openobserve.ai/releases/openobserve/v${version}/${asset}"
    local tmp
    tmp="$(mktemp -d)"
    echo "▶  Downloading ${url}..."
    if ! curl -fsSL --max-time 600 --retry 3 "$url" -o "${tmp}/${asset}"; then
        rm -rf "$tmp"
        echo "❌  Download failed: ${url}"
        return 1
    fi

    # Checksum: OPENOBSERVE_SHA256 pins one; otherwise use the .sha256sum the
    # vendor publishes next to each asset (tried under both common names). It
    # comes from the same server, so it guards against corruption and truncated
    # downloads, not against a compromised release. No checksum → no install.
    local expected="${OPENOBSERVE_SHA256:-}" sum_name
    if [ -z "$expected" ]; then
        for sum_name in "${asset}.sha256sum" "${asset}.sha256"; do
            expected="$(curl -fsSL --max-time 60 --retry 3 \
                "https://downloads.openobserve.ai/releases/openobserve/v${version}/${sum_name}" 2>/dev/null \
                | grep -oE '[0-9a-fA-F]{64}' | head -n1 || true)"
            [ -n "$expected" ] && break
        done
    fi
    if [ -z "$expected" ]; then
        rm -rf "$tmp"
        echo "❌  No published SHA-256 found for ${asset}."
        echo "    Set OPENOBSERVE_SHA256 to the checksum from the release page and retry."
        return 1
    fi
    _verify_sha256 "${tmp}/${asset}" "$expected" || { rm -rf "$tmp"; return 1; }

    mkdir -p "${tmp}/x"
    tar -xzf "${tmp}/${asset}" -C "${tmp}/x"
    if [ ! -f "${tmp}/x/openobserve" ]; then
        rm -rf "$tmp"
        echo "❌  ${asset} does not contain an 'openobserve' binary."
        return 1
    fi

    # ── Dedicated system user ─────────────────────────────────────
    if ! id openobserve &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin openobserve
    fi

    # Root owns the binary (the service cannot rewrite it); swap it in with a
    # rename so a re-install never writes into a running executable.
    mkdir -p "$OPENOBSERVE_DIR" "$OPENOBSERVE_DATA" /var/www/services
    install -m 755 -o root -g root "${tmp}/x/openobserve" "${OPENOBSERVE_DIR}/openobserve.new"
    mv -f "${OPENOBSERVE_DIR}/openobserve.new" "${OPENOBSERVE_DIR}/openobserve"
    rm -rf "$tmp"
    chown openobserve:openobserve "$OPENOBSERVE_DIR"
    chown -R openobserve:openobserve "$OPENOBSERVE_DATA"

    # ── Credentials: use the password supplied by the panel, else generate ──
    local admin_email="admin@localhost.local"
    local admin_pass
    admin_pass="${DB_PASSWORD:-$(gen_password)}"

    # OpenObserve reads ZO_ROOT_USER_* only to create the root user on first
    # start. With existing data the stored password stays in force, so keep the
    # saved one rather than write a password into the files that does not work.
    if [ -n "$(ls -A "$OPENOBSERVE_DATA" 2>/dev/null)" ]; then
        local saved=""
        if [ -f "$OPENOBSERVE_CRED_FILE" ]; then
            saved="$(sed -n 's/^admin_password: "\(.*\)"$/\1/p' "$OPENOBSERVE_CRED_FILE")"
        fi
        if [ -n "$saved" ]; then
            if [ "$saved" != "$admin_pass" ]; then
                log_warn "Existing data in ${OPENOBSERVE_DATA}: the root password is unchanged (change it in the OpenObserve UI)."
            fi
            admin_pass="$saved"
        else
            log_warn "Existing data in ${OPENOBSERVE_DATA}: the new password only applies if no root user exists yet."
        fi
    fi

    # ── Root credentials ─────────────────────────────────────────
    # Kept in a root-only EnvironmentFile: Environment= lines in the unit are
    # world-readable (and visible via `systemctl show`).
    mkdir -p /etc/openobserve
    chmod 700 /etc/openobserve
    install -m 600 /dev/null /etc/openobserve/env
    printf 'ZO_ROOT_USER_EMAIL=%s\nZO_ROOT_USER_PASSWORD=%s\n' "$admin_email" "$admin_pass" \
        > /etc/openobserve/env

    # ── systemd service ───────────────────────────────────────────
    echo "▶  Writing systemd service..."
    cat > "$OPENOBSERVE_SERVICE" <<UNIT
[Unit]
Description=OpenObserve — observability platform
Documentation=https://openobserve.ai/docs/
After=network-online.target
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

EnvironmentFile=/etc/openobserve/env

# Production-grade settings
Environment=ZO_TELEMETRY=false
Environment=RUST_LOG=warn

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable "$OPENOBSERVE_SERVICE"
    # restart, not start: a re-install must pick up the new binary and env file.
    systemctl restart openobserve

    # Wait a moment for startup
    sleep 3
    systemctl status openobserve --no-pager

    # ── Save credentials ──────────────────────────────────────────
    echo "▶  Saving credentials to ${OPENOBSERVE_CRED_FILE}..."
    # Create it 0600 first: a later chmod leaves a window where the file is world-readable.
    install -m 600 /dev/null "$OPENOBSERVE_CRED_FILE"
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
    echo "   Password : saved in ${OPENOBSERVE_CRED_FILE} (mode 600)"
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
    rm -rf "$OPENOBSERVE_DIR" "$OPENOBSERVE_DATA" /etc/openobserve
    userdel openobserve 2>/dev/null || true
    _unregister_panel_service openobserve
    echo "✔  OpenObserve removed (data in ${OPENOBSERVE_DATA} deleted)."
}
