#!/usr/bin/env bash
# firewall.sh — UFW firewall management

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


# Open a TCP port to a chosen set of subnets.
# Usage: _ufw_allow_port <port> <comment>
#
# The caller (the web panel) selects which subnets to expose the port to via the
# ALLOWED_SUBNETS environment variable — a space-separated list of CIDRs, e.g.
#   ALLOWED_SUBNETS="10.0.0.0/8 192.168.0.0/16"
# Special value "0.0.0.0/0" opens the port to every IP (no source restriction).
# When ALLOWED_SUBNETS is unset/empty we fall back to the standard private +
# loopback subnets, matching the previous default.
_ufw_allow_port() {
    local port="$1"
    local comment="$2"

    # Resolve the effective subnet list (env override → default private subnets).
    local subnets
    if [ -n "${ALLOWED_SUBNETS// /}" ]; then
        read -r -a subnets <<< "$ALLOWED_SUBNETS"
    else
        subnets=("127.0.0.0/8" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16")
    fi
    # Export the effective list so install scripts' "Allow:" summary lines reflect
    # what was actually applied.
    ALLOWED_SUBNETS="${subnets[*]}"

    command -v ufw >/dev/null 2>&1 || {
        echo "▶  Installing UFW..."
        apt-get install -y ufw
    }

    if ufw status | grep -q "inactive"; then
        echo "▶  Enabling UFW..."
        ufw allow OpenSSH >/dev/null
        ufw --force enable
    fi

    # 0.0.0.0/0 means "any source" — express it as a plain port rule rather than
    # a from-rule so it reads as an unrestricted allow.
    local cidr
    for cidr in "${subnets[@]}"; do
        if [ "$cidr" = "0.0.0.0/0" ]; then
            if ufw status | grep -F "${port}/tcp" | grep -q -i "Anywhere"; then
                echo "▶  UFW: any → tcp/${port} already allowed, skipping."
            else
                echo "▶  UFW: allow any → tcp/${port} (${comment})"
                ufw allow "${port}/tcp" comment "$comment" >/dev/null
            fi
            continue
        fi

        if ufw status | grep -F "${port}/tcp" | grep -F "$cidr" | grep -q -i "allow"; then
            echo "▶  UFW: ${cidr} → tcp/${port} already allowed, skipping."
        else
            echo "▶  UFW: allow ${cidr} → tcp/${port} (${comment})"
            ufw allow from "$cidr" to any port "$port" proto tcp comment "$comment" >/dev/null
        fi
    done

    ufw reload >/dev/null
}

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
