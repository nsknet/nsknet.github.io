#!/usr/bin/env bash
# mssql.sh — Microsoft SQL Server 2025 (Ubuntu 24.04) via APT
# Installs onto the package default data dir /var/opt/mssql on the existing
# filesystem — no separate disk/XFS provisioning (a VPS usually has one disk).

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


MSSQL_PORT=1433
MSSQL_DATA_DIR="/var/opt/mssql"
MSSQL_CRED_FILE="/var/opt/mssql/credentials.yml"
MSSQL_TOOLS_BIN="/opt/mssql-tools18/bin"

install_mssql() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing SQL Server 2025"
    echo "════════════════════════════════════════════════════════════"

    export DEBIAN_FRONTEND=noninteractive

    # SA password from the panel; edition from the install dialog (default developer).
    local sa_password="${DB_PASSWORD:?DB_PASSWORD env var required (SA password)}"
    local edition="${MSSQL_PID:-developer}"

    # ── Pre-flight ────────────────────────────────────────────────
    local total_ram_mb
    total_ram_mb="$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo)"
    if [ "$total_ram_mb" -lt 2048 ]; then
        echo "✗  Insufficient RAM (${total_ram_mb} MB; SQL Server needs ≥ 2048 MB)."
        return 1
    fi
    echo "▶  RAM: ${total_ram_mb} MB — OK"

    # Memory limit: panel override (MSSQL_MEMORY_MB) or ~80% of total RAM.
    # SQL Server refuses to start if memory.memorylimitmb is below its ~2 GB
    # floor, so on a small VPS (e.g. 2 GB RAM → 80% = 1638 MB) the computed value
    # would produce an engine that never comes up and a `systemctl restart` that
    # blocks until timeout. Clamp to the documented minimum.
    local mem_limit="${MSSQL_MEMORY_MB:-$(( total_ram_mb * 80 / 100 ))}"
    if [ "$mem_limit" -lt 2048 ]; then
        mem_limit=2048
    fi

    curl -fsSL --max-time 10 https://packages.microsoft.com >/dev/null 2>&1 \
        || { echo "✗  Cannot reach packages.microsoft.com"; return 1; }
    echo "▶  Network: OK"

    # ── Dependencies ──────────────────────────────────────────────
    echo "▶  Installing system dependencies..."
    apt-get update -q
    apt-get install -y curl wget gnupg2 gpg apt-transport-https \
        software-properties-common lsb-release ca-certificates \
        libssl-dev unixodbc-dev

    # ── Microsoft SQL Server 2025 repository ──────────────────────
    echo "▶  Adding Microsoft SQL Server 2025 repository..."
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor --yes -o /usr/share/keyrings/microsoft-prod.gpg
    curl -fsSL https://packages.microsoft.com/config/ubuntu/24.04/mssql-server-2025.list \
        > /etc/apt/sources.list.d/mssql-server-2025.list
    curl -fsSL https://packages.microsoft.com/config/ubuntu/24.04/prod.list \
        > /etc/apt/sources.list.d/mssql-release.list

    apt-get update -q
    # The mssql-server engine is a few hundred MB from packages.microsoft.com.
    # apt batches its output when not on a TTY, so the panel goes quiet during the
    # download/unpack — warn up front so it doesn't look frozen.
    echo "▶  Downloading & installing mssql-server (~300 MB, may take several minutes)..."
    apt-get install -y mssql-server

    # ── Configure the instance ────────────────────────────────────
    echo "▶  Configuring instance (edition: ${edition})..."
    ACCEPT_EULA=Y \
        MSSQL_PID="$edition" \
        MSSQL_SA_PASSWORD="$sa_password" \
        /opt/mssql/bin/mssql-conf -n setup

    /opt/mssql/bin/mssql-conf set memory.memorylimitmb "$mem_limit"
    /opt/mssql/bin/mssql-conf set sqlagent.enabled true
    /opt/mssql/bin/mssql-conf set telemetry.customerfeedback false

    systemctl enable mssql-server

    # Apply the pending config changes. SQL Server's first start after setup does
    # one-time work (initialising the system databases, then bringing SQL Agent
    # online because sqlagent.enabled was just turned on); on slower disks or with
    # DNS-resolution stalls this can take several minutes. A plain blocking
    # `systemctl restart` would go silent the whole time and look frozen in the
    # panel — and buffered child output only flushes at the end, making it worse.
    #
    # Kick the restart off non-blocking, then poll `is-active`, printing a
    # heartbeat each tick so the job streams progress instead of stalling. Bound
    # the total wait generously (override with MSSQL_START_TIMEOUT) and surface the
    # journal if it genuinely never comes up.
    echo "▶  Restarting mssql-server to apply settings (first start may take a few minutes)..."
    systemctl restart --no-block mssql-server </dev/null
    sleep 5   # let the stop phase begin before we trust is-active

    local waited=5
    local max_wait="${MSSQL_START_TIMEOUT:-3600}"
    until systemctl is-active --quiet mssql-server; do
        if [ "$waited" -ge "$max_wait" ]; then
            echo "✗  mssql-server still not active after ${max_wait}s. Recent log:"
            journalctl -u mssql-server --no-pager -n 40 || true
            return 1
        fi
        sleep 10
        waited=$(( waited + 10 ))
        echo "   …waiting for mssql-server to become active (${waited}s)"
    done
    echo "▶  mssql-server is active (took ~${waited}s)."
    _register_panel_service mssql-server

    # ── Command-line tools (sqlcmd, bcp) ──────────────────────────
    echo "▶  Installing mssql-tools18..."
    ACCEPT_EULA=Y apt-get install -y mssql-tools18 unixodbc-dev
    echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' > /etc/profile.d/mssql-tools.sh
    chmod +x /etc/profile.d/mssql-tools.sh

    # ── Firewall: allow only the chosen subnets ───────────────────
    _ufw_allow_port "$MSSQL_PORT" "SQL Server"

    # ── Save credentials ──────────────────────────────────────────
    echo "▶  Saving credentials to ${MSSQL_CRED_FILE}..."
    mkdir -p "$(dirname "$MSSQL_CRED_FILE")"
    cat > "$MSSQL_CRED_FILE" <<CRED
# SQL Server 2025 credentials
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
service: mssql
edition: "${edition}"

admin_user: "SA"
admin_password: "${sa_password}"

port: ${MSSQL_PORT}
host: "127.0.0.1"
connection_string: "Server=127.0.0.1,${MSSQL_PORT};User Id=SA;Password=${sa_password};TrustServerCertificate=True"

data_dir: "${MSSQL_DATA_DIR}"
notes: "Bound to all interfaces; UFW restricts access. Change SA password after first login."
CRED
    chmod 600 "$MSSQL_CRED_FILE"

    # ── Smoke test (best-effort; the service may still be warming up) ─────────
    echo "▶  Smoke test..."
    sleep 8
    "${MSSQL_TOOLS_BIN}/sqlcmd" -S "localhost,${MSSQL_PORT}" -U SA -P "$sa_password" -C -h -1 -W \
        -Q "SET NOCOUNT ON; PRINT @@VERSION;" \
        || echo "⚠  Smoke test did not return yet — the service may still be starting."

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  SQL Server 2025 installed."
    echo "   Edition  : ${edition}"
    echo "   Host     : <server-ip>:${MSSQL_PORT}"
    echo "   User     : SA"
    echo "   Password : ${sa_password}"
    echo "   Memory   : ${mem_limit} MB"
    echo "   Data dir : ${MSSQL_DATA_DIR}"
    echo "   Allow    : ${ALLOWED_SUBNETS[*]}"
    echo ""
    echo "   Credentials saved to: ${MSSQL_CRED_FILE}"
    echo "   sqlcmd on PATH after re-login, or: source /etc/profile.d/mssql-tools.sh"
    echo "════════════════════════════════════════════════════════════"
}

uninstall_mssql() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Removing SQL Server 2025"
    echo "════════════════════════════════════════════════════════════"
    systemctl disable --now mssql-server 2>/dev/null || true
    apt-get purge -y mssql-server mssql-tools18 2>/dev/null || true
    apt-get autoremove -y || true
    rm -rf "$MSSQL_DATA_DIR"
    rm -f /etc/apt/sources.list.d/mssql-server-2025.list \
          /etc/apt/sources.list.d/mssql-release.list \
          /usr/share/keyrings/microsoft-prod.gpg \
          /etc/profile.d/mssql-tools.sh
    _unregister_panel_service mssql-server
    echo "✔  SQL Server removed (data in ${MSSQL_DATA_DIR} deleted)."
}

# Change the SA password. New password comes from DB_PASSWORD.
set_mssql_password() {
    local sa_password="${DB_PASSWORD:?DB_PASSWORD env var required}"
    echo "▶  Updating SQL Server SA password..."
    systemctl stop mssql-server
    MSSQL_SA_PASSWORD="$sa_password" /opt/mssql/bin/mssql-conf set-sa-password
    systemctl start mssql-server

    if [ -f "$MSSQL_CRED_FILE" ]; then
        echo "▶  Updating ${MSSQL_CRED_FILE}..."
        sed -i -E "s|^admin_password:.*|admin_password: \"${sa_password}\"|" "$MSSQL_CRED_FILE"
        sed -i -E "s|^connection_string:.*|connection_string: \"Server=127.0.0.1,${MSSQL_PORT};User Id=SA;Password=${sa_password};TrustServerCertificate=True\"|" "$MSSQL_CRED_FILE"
    fi
    echo "✔  SQL Server SA password updated."
}
