#!/usr/bin/env bash
# rabbitmq.sh — RabbitMQ 4.x on Ubuntu 22.04 (Jammy) / 24.04 (Noble), amd64
# Official method: Team RabbitMQ Cloudsmith repos
# Docs: https://www.rabbitmq.com/docs/install-debian

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


RABBITMQ_CRED_FILE="/etc/rabbitmq/credentials.yml"

install_rabbitmq() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing RabbitMQ"
    echo "════════════════════════════════════════════════════════════"

    # Team RabbitMQ's modern Erlang builds (RabbitMQ 4.x needs Erlang 26+, newer
    # than Ubuntu ships) are published for jammy and noble on amd64. arm64 is
    # left out until verified against the Erlang repository.
    _require_platform "RabbitMQ" "22.04 24.04" "amd64"
    local codename arch
    codename="$(_os_codename)"
    arch="$(_os_arch)"

    apt-get update -q
    apt-get install -y curl gnupg apt-transport-https

    # ── Signing keys ──────────────────────────────────────────────
    echo "▶  Importing signing keys..."

    # Team RabbitMQ main key
    curl -1sLf --max-time 60 --retry 3 "https://keys.openpgp.org/vks/v1/by-fingerprint/0A9AF2115F4687BD29803A206B73A36E6026DFCA" \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/com.rabbitmq.team.gpg

    # Cloudsmith: Erlang repo key
    curl -1sLf --max-time 60 --retry 3 "https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E495BB49CC4BBE5B.key" \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/rabbitmq.E495BB49CC4BBE5B.gpg

    # Cloudsmith: RabbitMQ server repo key
    curl -1sLf --max-time 60 --retry 3 "https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F4587F226208342.key" \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/rabbitmq.9F4587F226208342.gpg

    # ── APT repositories ──────────────────────────────────────────
    echo "▶  Adding Erlang + RabbitMQ repositories (${codename}, ${arch})..."
    cat > /etc/apt/sources.list.d/rabbitmq.list <<SOURCES
## Erlang (Team RabbitMQ modern Erlang builds)
deb [arch=${arch} signed-by=/usr/share/keyrings/rabbitmq.E495BB49CC4BBE5B.gpg] https://ppa1.rabbitmq.com/rabbitmq/rabbitmq-erlang/deb/ubuntu ${codename} main

## RabbitMQ server
deb [arch=${arch} signed-by=/usr/share/keyrings/rabbitmq.9F4587F226208342.gpg] https://ppa1.rabbitmq.com/rabbitmq/rabbitmq-server/deb/ubuntu ${codename} main
SOURCES

    apt-get update -q

    # ── Install Erlang + RabbitMQ ─────────────────────────────────
    echo "▶  Installing Erlang packages..."
    apt-get install -y \
        erlang-base erlang-asn1 erlang-crypto erlang-eldap \
        erlang-ftp erlang-inets erlang-mnesia erlang-os-mon \
        erlang-parsetools erlang-public-key erlang-runtime-tools \
        erlang-snmp erlang-ssl erlang-syntax-tools erlang-tftp \
        erlang-tools erlang-xmerl

    echo "▶  Installing RabbitMQ server..."
    apt-get install -y rabbitmq-server

    systemctl enable rabbitmq-server
    systemctl start rabbitmq-server
    _register_panel_service rabbitmq-server

    # ── Management plugin ─────────────────────────────────────────
    echo "▶  Enabling management plugin..."
    rabbitmq-plugins enable rabbitmq_management

    # ── Credentials: use the password supplied by the panel, else generate ──
    local admin_user="admin"
    local admin_pass
    admin_pass="${DB_PASSWORD:-$(gen_password)}"

    # ── Remove default guest user ─────────────────────────────────
    echo "▶  Removing default guest account..."
    rabbitmqctl delete_user guest 2>/dev/null || true

    # ── Create admin user ─────────────────────────────────────────
    # Re-install safe: add_user and add_vhost fail on existing entries.
    # (grep without -q: under pipefail, -q's early exit can fail the pipeline.)
    if rabbitmqctl list_users --quiet | awk '{print $1}' | grep -Fx "$admin_user" >/dev/null; then
        echo "▶  User '${admin_user}' exists — updating its password..."
        # Password on stdin (RabbitMQ 3.11+ reads it there when omitted), not argv.
        printf '%s\n' "$admin_pass" | rabbitmqctl change_password "$admin_user"
    else
        echo "▶  Creating admin user '${admin_user}'..."
        # Password on stdin, not argv, so it never shows up in `ps`.
        printf '%s\n' "$admin_pass" | rabbitmqctl add_user "$admin_user"
    fi
    rabbitmqctl set_user_tags "$admin_user" administrator

    # ── Default vhost permissions ─────────────────────────────────
    echo "▶  Setting permissions on default vhost..."
    rabbitmqctl set_permissions -p "/" "$admin_user" ".*" ".*" ".*"

    # ── Extra vhosts ──────────────────────────────────────────────
    echo "▶  Creating vhosts: /prod /dev /staging..."
    for vhost in /prod /dev /staging; do
        rabbitmqctl list_vhosts --quiet | grep -Fx -- "$vhost" >/dev/null \
            || rabbitmqctl add_vhost "$vhost"
        rabbitmqctl set_permissions -p "$vhost" "$admin_user" ".*" ".*" ".*"
    done

    # ── rabbitmq.conf — bind all interfaces; UFW restricts access ────────────
    echo "▶  Writing /etc/rabbitmq/rabbitmq.conf..."
    cat > /etc/rabbitmq/rabbitmq.conf <<'CONF'
# AMQP — all interfaces; UFW allows only private subnets
listeners.tcp.default = 5672

# Management UI — all interfaces; UFW allows only private subnets
management.tcp.ip   = 0.0.0.0
management.tcp.port = 15672

# Limits
vm_memory_high_watermark.relative = 0.6
disk_free_limit.relative           = 1.5
CONF

    systemctl restart rabbitmq-server

    # ── Save credentials ──────────────────────────────────────────
    echo "▶  Saving credentials to ${RABBITMQ_CRED_FILE}..."
    mkdir -p "$(dirname "$RABBITMQ_CRED_FILE")"
    # Create it 0600 first: a later chmod leaves a window where the file is world-readable.
    install -m 600 /dev/null "$RABBITMQ_CRED_FILE"
    cat > "$RABBITMQ_CRED_FILE" <<CRED
# RabbitMQ credentials
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
service: rabbitmq

admin_user: "${admin_user}"
admin_password: "${admin_pass}"

amqp_port: 5672
management_port: 15672
management_url: "http://<server-ip>:15672"
amqp_url: "amqp://${admin_user}:${admin_pass}@<server-ip>:5672/"

vhosts:
  - /
  - /prod
  - /dev
  - /staging

notes: "Bound to 0.0.0.0; UFW restricts access to private subnets only."
CRED
    chmod 600 "$RABBITMQ_CRED_FILE"

    # ── Firewall: allow only private subnets, deny everything else ───────────
    _ufw_allow_port 5672  "RabbitMQ AMQP"
    _ufw_allow_port 15672 "RabbitMQ Management"

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  RabbitMQ installed."
    echo "   Management : http://<server-ip>:15672"
    echo "   AMQP       : amqp://<server-ip>:5672"
    echo "   Allow      : ${ALLOWED_SUBNETS[*]}"
    echo "   User       : ${admin_user}"
    echo "   Password   : saved in ${RABBITMQ_CRED_FILE} (mode 600)"
    echo "   Vhosts     : / /prod /dev /staging"
    echo ""
    echo "   Credentials saved to: ${RABBITMQ_CRED_FILE}"
    echo "════════════════════════════════════════════════════════════"
}

uninstall_rabbitmq() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Removing RabbitMQ"
    echo "════════════════════════════════════════════════════════════"
    systemctl disable --now rabbitmq-server 2>/dev/null || true
    apt-get purge -y rabbitmq-server 2>/dev/null || true
    apt-get autoremove -y || true
    rm -rf /var/lib/rabbitmq /etc/rabbitmq /var/log/rabbitmq
    rm -f /etc/apt/sources.list.d/rabbitmq.list
    _unregister_panel_service rabbitmq-server
    echo "✔  RabbitMQ removed."
}

# Change the RabbitMQ admin password. New password comes from DB_PASSWORD.
set_rabbitmq_password() {
    local admin_user="admin"
    local admin_pass="${DB_PASSWORD:?DB_PASSWORD env var required}"
    echo "▶  Updating RabbitMQ password for '${admin_user}'..."
    # Password on stdin (RabbitMQ 3.11+ reads it there when omitted), not argv.
    printf '%s\n' "$admin_pass" | rabbitmqctl change_password "$admin_user"

    if [ -f "$RABBITMQ_CRED_FILE" ]; then
        echo "▶  Updating ${RABBITMQ_CRED_FILE}..."
        cred_set "$RABBITMQ_CRED_FILE" admin_password "${admin_pass}"
        cred_set "$RABBITMQ_CRED_FILE" amqp_url "amqp://${admin_user}:${admin_pass}@<server-ip>:5672/"
    fi
    echo "✔  RabbitMQ password updated."
}
