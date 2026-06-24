#!/usr/bin/env bash
# redis.sh — Redis server on Ubuntu 24.04 (Noble)
# Official method: Redis Inc. APT repo (packages.redis.io), falls back to the
# distro package if the repo cannot be added.
# Docs: https://redis.io/docs/latest/operate/oss_and_stack/install/install-redis/install-redis-on-linux/

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


REDIS_PORT=6379
REDIS_CONF="/etc/redis/redis.conf"
REDIS_CRED_FILE="/etc/redis/credentials.yml"
REDIS_MARKER_BEGIN="# >>> NsPanel managed >>>"
REDIS_MARKER_END="# <<< NsPanel managed <<<"

# Replace the NsPanel-managed block in redis.conf (idempotent — removes any
# previous block first so re-installs don't accumulate duplicates). Redis applies
# the *last* occurrence of these directives, so appending a managed block at the
# end deterministically overrides whatever the package shipped.
_redis_write_managed_block() {
    local password="$1"

    # Drop a prior managed block if present.
    sed -i "/^${REDIS_MARKER_BEGIN}$/,/^${REDIS_MARKER_END}$/d" "$REDIS_CONF"

    cat >> "$REDIS_CONF" <<CONF
${REDIS_MARKER_BEGIN}
# Bound to all interfaces; UFW restricts access to the chosen private subnets.
bind 0.0.0.0
protected-mode no
port ${REDIS_PORT}
requirepass "${password}"
${REDIS_MARKER_END}
CONF
}

install_redis() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing Redis"
    echo "════════════════════════════════════════════════════════════"

    apt-get install -y curl gpg lsb-release

    # ── APT repository (official Redis Inc. build) ────────────────────────────
    # If anything about adding the repo fails, fall back to the distro package so
    # the install still succeeds on a current Ubuntu.
    local use_official=true
    echo "▶  Adding Redis APT repository..."
    if curl -fsSL https://packages.redis.io/gpg \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg; then
        chmod 644 /usr/share/keyrings/redis-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" \
            > /etc/apt/sources.list.d/redis.list
    else
        echo "⚠  Could not import Redis signing key — falling back to the Ubuntu package."
        use_official=false
        rm -f /etc/apt/sources.list.d/redis.list
    fi

    if ! apt-get update -q; then
        if [ "$use_official" = true ]; then
            echo "⚠  apt-get update failed with the Redis repo — removing it and using the Ubuntu package."
            rm -f /etc/apt/sources.list.d/redis.list
            apt-get update -q
        else
            return 1
        fi
    fi

    echo "▶  Installing redis-server..."
    apt-get install -y redis-server redis-tools

    # ── Password: use the panel-supplied value, else generate one ─────────────
    local password
    password="${DB_PASSWORD:-$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 28)}"

    echo "▶  Configuring ${REDIS_CONF} (bind 0.0.0.0, requirepass, port ${REDIS_PORT})..."
    _redis_write_managed_block "$password"

    # ── Save credentials ──────────────────────────────────────────────────────
    echo "▶  Saving credentials to ${REDIS_CRED_FILE}..."
    mkdir -p "$(dirname "$REDIS_CRED_FILE")"
    cat > "$REDIS_CRED_FILE" <<CRED
# Redis credentials
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
service: redis

host: "<server-ip>"
port: ${REDIS_PORT}
password: "${password}"

# StackExchange.Redis connection string (.NET)
dotnet_connection: "<server-ip>:${REDIS_PORT},password=${password}"

notes: "Bound to 0.0.0.0 with requirepass; UFW restricts access to private subnets only."
CRED
    chmod 600 "$REDIS_CRED_FILE"

    # ── Service ───────────────────────────────────────────────────────────────
    /bin/systemctl daemon-reload
    systemctl enable redis-server
    systemctl restart redis-server
    _register_panel_service redis-server

    # ── Firewall: allow only the chosen subnets, deny everything else ─────────
    _ufw_allow_port "${REDIS_PORT}" "Redis"

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  Redis installed."
    echo "   Port     : ${REDIS_PORT}  (bound to 0.0.0.0)"
    echo "   Password : ${password}"
    echo "   Conf     : ${REDIS_CONF}"
    echo "   Data     : /var/lib/redis"
    echo "   Allow    : ${ALLOWED_SUBNETS[*]}"
    echo ""
    echo "   .NET     : <server-ip>:${REDIS_PORT},password=${password}"
    echo "   Test     : redis-cli -a '${password}' ping   → PONG"
    echo "   Credentials saved to: ${REDIS_CRED_FILE}"
    echo "════════════════════════════════════════════════════════════"
}

# Change the Redis password. New password comes from DB_PASSWORD.
# Rewrites requirepass in redis.conf and restarts (a restart avoids needing the
# old password that a live CONFIG SET would require).
set_redis_password() {
    local password="${DB_PASSWORD:?DB_PASSWORD env var required}"
    echo "▶  Updating Redis password..."

    _redis_write_managed_block "$password"
    systemctl restart redis-server

    if [ -f "$REDIS_CRED_FILE" ]; then
        echo "▶  Updating ${REDIS_CRED_FILE}..."
        sed -i -E "s|^password:.*|password: \"${password}\"|" "$REDIS_CRED_FILE"
        sed -i -E "s|^dotnet_connection:.*|dotnet_connection: \"<server-ip>:${REDIS_PORT},password=${password}\"|" "$REDIS_CRED_FILE"
    fi
    echo "✔  Redis password updated."
}

uninstall_redis() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Removing Redis"
    echo "════════════════════════════════════════════════════════════"
    systemctl disable --now redis-server 2>/dev/null || true
    apt-get purge -y redis-server redis-tools 2>/dev/null || true
    apt-get autoremove -y || true
    rm -rf /var/lib/redis /etc/redis /var/log/redis
    rm -f /etc/apt/sources.list.d/redis.list
    rm -f /usr/share/keyrings/redis-archive-keyring.gpg
    _unregister_panel_service redis-server
    echo "✔  Redis removed (data in /var/lib/redis deleted)."
}
