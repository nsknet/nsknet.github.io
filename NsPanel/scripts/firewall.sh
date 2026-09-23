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

    # Allow SSH before enabling, or enabling locks the operator out.
    log_step "Allowing OpenSSH (port 22)..."
    ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null

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
    echo "▶  Deleting rule #${rule_num}..."
    echo "y" | ufw delete "$rule_num"
    echo ""
    ufw status numbered
    echo "✔  Rule #${rule_num} deleted."
}
