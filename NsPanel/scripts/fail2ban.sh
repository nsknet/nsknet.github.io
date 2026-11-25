#!/usr/bin/env bash
# fail2ban.sh — SSH brute-force protection (Ubuntu 22.04+)

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


install_fail2ban() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing Fail2ban"
    echo "════════════════════════════════════════════════════════════"

    apt-get update -q
    # python3-systemd lets fail2ban read the journal (backend = systemd), so
    # the jail works without rsyslog / /var/log/auth.log.
    apt-get install -y fail2ban python3-systemd

    # Watch the port(s) sshd really listens on, not just "ssh" (22).
    local ssh_ports
    ssh_ports="$(_ssh_ports | paste -sd, -)"
    ssh_ports="${ssh_ports:-22}"

    echo "▶  Writing /etc/fail2ban/jail.local (sshd on port ${ssh_ports})..."
    cat > /etc/fail2ban/jail.local <<JAIL
# Managed by NsPanel (fail2ban.sh) — rewritten on every install.
[DEFAULT]
# Ban for 1 hour after 3 failures within 10 minutes
bantime  = 3600
findtime = 600
maxretry = 3

# Never ban localhost
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ${ssh_ports}
filter   = sshd
backend  = systemd
maxretry = 3
bantime  = 3600
findtime = 600
JAIL

    echo "▶  Validating the configuration..."
    fail2ban-client -t >/dev/null

    systemctl enable fail2ban
    systemctl restart fail2ban
    _register_panel_service fail2ban

    echo ""
    echo "▶  Fail2ban status:"
    systemctl status fail2ban --no-pager || true

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  Fail2ban installed."
    echo "   Config  : /etc/fail2ban/jail.local"
    echo "   SSH     : port ${ssh_ports}, 3 attempts → 1 hour ban"
    echo ""
    echo "  Useful commands:"
    echo "   fail2ban-client status sshd"
    echo "   fail2ban-client set sshd unbanip <IP>"
    echo "════════════════════════════════════════════════════════════"
}

uninstall_fail2ban() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Removing Fail2ban"
    echo "════════════════════════════════════════════════════════════"
    systemctl disable --now fail2ban 2>/dev/null || true
    apt-get purge -y fail2ban 2>/dev/null || true
    apt-get autoremove -y || true
    rm -f /etc/fail2ban/jail.local
    _unregister_panel_service fail2ban
    echo "✔  Fail2ban removed."
}
