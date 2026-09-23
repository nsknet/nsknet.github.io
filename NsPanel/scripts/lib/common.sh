#!/usr/bin/env bash
# lib/common.sh — helpers every install script may call.
#
# core/bash_invoker.py sources everything in scripts/lib/ before the target
# script, so these functions are always defined. Do not put tool-specific logic
# here; that belongs in the tool's own script.

# ── Console output ────────────────────────────────────────────────────────────

# A boxed section title. Use once at the top of an install/uninstall function.
log_header() {
    echo "════════════════════════════════════════════════════════════"
    echo "  $*"
    echo "════════════════════════════════════════════════════════════"
}

# One step within a function.
log_step() {
    echo "▶  $*"
}

log_done() {
    echo ""
    echo "✓  $*"
}

log_warn() {
    echo "⚠  $*" >&2
}


# ── UFW ───────────────────────────────────────────────────────────────────────
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

# ── Panel service registry ────────────────────────────────────────────────────
# Creates a symlink in /var/www/services/ pointing to the real systemd unit file.
# Called after installing APT-based services so the panel can see and manage them.
_register_panel_service() {
    local name="$1"
    local unit_path
    mkdir -p /var/www/services
    unit_path=$(systemctl show -p FragmentPath --value "$name" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$unit_path" && -f "$unit_path" ]]; then
        ln -sf "$unit_path" "/var/www/services/${name}.service"
        echo "▶  Panel: registered ${name} → /var/www/services/${name}.service"
    else
        echo "▶  Panel: could not find unit file for ${name}, skipping registration."
    fi
}

# Removes the panel's symlink for a service. Called from uninstall functions.
_unregister_panel_service() {
    local name="$1"
    if [ -L "/var/www/services/${name}.service" ] || [ -f "/var/www/services/${name}.service" ]; then
        rm -f "/var/www/services/${name}.service"
        echo "▶  Panel: unregistered ${name}"
    fi
}
