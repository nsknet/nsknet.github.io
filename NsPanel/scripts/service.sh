#!/usr/bin/env bash
# service.sh — Panel service registry helpers

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


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
