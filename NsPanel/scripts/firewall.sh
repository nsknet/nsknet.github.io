#!/usr/bin/env bash
# firewall.sh — UFW firewall management

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


# ── Install and enable UFW ─────────────────────────────────────────────────────
# Called from the Firewall screen and from common_configs in system.sh.
install_ufw() {
    log_header "Installing UFW firewall"

    if ! command -v ufw >/dev/null 2>&1; then
        log_step "Installing the ufw package..."
        apt-get update -q
        apt-get install -y ufw
    else
        log_step "UFW is already installed."
    fi

    # Allow SSH (on its real port) and the panel before enabling, or enabling
    # locks the operator out.
    local ssh_port
    for ssh_port in $(_ssh_ports); do
        log_step "Allowing SSH on tcp/${ssh_port}..."
        ufw allow "${ssh_port}/tcp" comment "SSH" >/dev/null
    done
    if [ -n "${NSPANEL_PORT:-}" ]; then
        log_step "Allowing the panel on tcp/${NSPANEL_PORT}..."
        ufw allow "${NSPANEL_PORT}/tcp" comment "NsPanel" >/dev/null
    fi

    log_step "Setting defaults: deny incoming, allow outgoing..."
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null

    if ufw status | grep -q "inactive"; then
        log_step "Enabling UFW..."
        ufw --force enable
    else
        log_step "UFW is already active."
        ufw reload >/dev/null
    fi

    echo ""
    ufw status numbered

    log_done "UFW is installed and active."
}
# Open a TCP port (UFW rule from the Firewall screen).
ufw_allow_port() {
    local port="${1:?Port required}"
    local action="${2:-allow}"
    local source="${3:-any}"
    local comment="$4"

    # Normalize case (bash lowercase expansion — no subprocess needed)
    action="${action,,}"
    source="${source,,}"

    if [ "$source" = "anywhere" ]; then
        source="any"
    fi

    # Split port and protocol if specified as port/proto (e.g. 443/tcp)
    local proto=""
    if [[ "$port" == */* ]]; then
        proto="${port##*/}"
        port="${port%/*}"
    fi

    echo "▶  Configuring firewall rule..."
    echo "   Action : $action"
    echo "   Port   : $port${proto:+/}$proto"
    echo "   Source : $source"
    [ -n "$comment" ] && echo "   Comment: $comment"

    # Build the UFW command
    local cmd=("ufw" "$action")
    if [ "$source" = "any" ]; then
        if [ -n "$proto" ]; then
            cmd+=("$port/$proto")
        else
            cmd+=("$port")
        fi
    else
        cmd+=("from" "$source" "to" "any" "port" "$port")
        if [ -n "$proto" ]; then
            cmd+=("proto" "$proto")
        fi
    fi

    if [ -n "$comment" ]; then
        cmd+=("comment" "$comment")
    fi

    # Execute the command
    echo "▶  Running: ${cmd[*]}"
    "${cmd[@]}"

    echo ""
    ufw status numbered
    echo "✔  Firewall rule updated."
}

ufw_delete_port() {
    local rule_num="${1:?Rule number required}"
    local expected_to="${2:?Rule target required}"

    # Re-check right before deleting: UFW renumbers rules after every delete.
    local line
    line="$(ufw status numbered | grep -E "^\[ *${rule_num}\] " || true)"
    if [ -z "$line" ] || [[ "$line" != *"$expected_to"* ]]; then
        echo "❌  Rule #${rule_num} is no longer '${expected_to}'. Nothing was deleted; reload and retry."
        return 1
    fi

    echo "▶  Deleting rule #${rule_num}: ${line#*] }"
    ufw --force delete "$rule_num"
    echo ""
    ufw status numbered
    echo "✔  Rule #${rule_num} deleted."
}
