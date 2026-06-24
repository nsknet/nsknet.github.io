#!/usr/bin/env bash
# samba.sh — Samba SMB/CIFS file sharing (Ubuntu 24.04+)
# Authenticated share: one Samba user with a password (works on modern Windows
# 10/11, which block unauthenticated guest access by default). Access:
#   Windows : \\<server-ip>\<share>   (then enter the username + password)
#   macOS   : smb://<server-ip>/<share>

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


SAMBA_CONF="/etc/samba/smb.conf"
SAMBA_CRED_FILE="/var/opt/samba/credentials.yml"

# Normalise a requested share name to a safe Samba section name: keep only
# [A-Za-z0-9_-], fall back to "public" when empty.
_samba_sanitize_share() {
    local clean
    clean="$(printf '%s' "${1:-public}" | tr -cd 'A-Za-z0-9_-')"
    printf '%s' "${clean:-public}"
}

# Normalise a requested login to a valid Unix/Samba username: lowercase, keep
# only [a-z0-9_-], must start with a letter or underscore, max 32 chars. Falls
# back to "smbuser".
_samba_sanitize_user() {
    local clean
    clean="$(printf '%s' "${1:-smbuser}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
    # Strip leading characters that aren't a letter or underscore.
    clean="$(printf '%s' "$clean" | sed -E 's/^[^a-z_]+//')"
    clean="${clean:0:32}"
    printf '%s' "${clean:-smbuser}"
}

install_samba() {
    local share share_dir user password begin end
    share="$(_samba_sanitize_share "${SAMBA_SHARE:-public}")"
    user="$(_samba_sanitize_user "${SAMBA_USER:-smbuser}")"
    password="${DB_PASSWORD:?DB_PASSWORD env var required (Samba password)}"
    share_dir="/srv/${share}"
    begin="# >>> panel-samba:${share} >>>"
    end="# <<< panel-samba:${share} <<<"

    echo "════════════════════════════════════════════════════════════"
    echo "  Installing Samba"
    echo "  Share: [${share}]  →  ${share_dir}"
    echo "  User : ${user} (password authentication)"
    echo "════════════════════════════════════════════════════════════"

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y samba

    # ── System user (no login shell, no home) ─────────────────────
    if id -u "$user" >/dev/null 2>&1; then
        echo "▶  System user '${user}' already exists, reusing."
    else
        echo "▶  Creating system user '${user}' (nologin, no home)..."
        useradd --no-create-home --shell /usr/sbin/nologin "$user"
    fi

    # ── Samba password for that user (add + enable) ───────────────
    echo "▶  Setting Samba password for '${user}'..."
    printf '%s\n%s\n' "$password" "$password" | smbpasswd -s -a "$user"
    smbpasswd -e "$user" >/dev/null

    # ── Shared folder (owned by the share user) ───────────────────
    echo "▶  Creating ${share_dir} (owned by ${user})..."
    mkdir -p "$share_dir"
    chown "$user":"$user" "$share_dir"
    chmod 2770 "$share_dir"

    # ── Panel-managed share block (idempotent: remove old, append fresh) ──
    if grep -qF "$begin" "$SAMBA_CONF"; then
        echo "▶  Replacing existing panel-managed [${share}] block..."
        sed -i "\|${begin}|,\|${end}|d" "$SAMBA_CONF"
    fi
    echo "▶  Adding [${share}] share to ${SAMBA_CONF}..."
    cat >> "$SAMBA_CONF" <<EOF
${begin}
[${share}]
   path = ${share_dir}
   browseable = yes
   read only = no
   guest ok = no
   valid users = ${user}
   force user = ${user}
   force group = ${user}
   create mask = 0664
   directory mask = 2775
${end}
EOF

    # ── Validate config before restarting ─────────────────────────
    echo "▶  Validating config (testparm)..."
    testparm -s "$SAMBA_CONF" >/dev/null

    systemctl enable smbd
    systemctl restart smbd
    _register_panel_service smbd

    # ── Firewall: SMB over TCP (445 modern, 139 NetBIOS session) ──
    _ufw_allow_port 445 "Samba SMB"
    _ufw_allow_port 139 "Samba NetBIOS"

    # ── Save credentials (read back by set_samba_password) ────────
    echo "▶  Saving credentials to ${SAMBA_CRED_FILE}..."
    mkdir -p "$(dirname "$SAMBA_CRED_FILE")"
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    ip="${ip:-<server-ip>}"
    cat > "$SAMBA_CRED_FILE" <<CRED
# Samba credentials (panel-managed)
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
service: samba
share: "${share}"
path: "${share_dir}"
username: "${user}"
password: "${password}"
windows_unc: "\\\\\\\\${ip}\\\\${share}"
windows_map: "net use Z: \\\\\\\\${ip}\\\\${share} /user:${user} *   # run in a NON-admin terminal"
macos_url: "smb://${ip}/${share}"
CRED
    chmod 600 "$SAMBA_CRED_FILE"

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  Samba installed."
    echo "   Share    : [${share}]"
    echo "   Path     : ${share_dir}"
    echo "   Login    : ${user} / (the password you set)"
    echo "   Access   : Windows  \\\\${ip}\\${share}"
    echo "              macOS    smb://${ip}/${share}"
    echo "   Allow    : ${ALLOWED_SUBNETS[*]}"
    echo ""
    echo "   Map a drive on Windows (run in a NON-admin terminal, else"
    echo "   the drive won't show in Explorer):"
    echo "     net use Z: \\\\${ip}\\${share} /user:${user} *"
    echo ""
    echo "   Credentials saved to: ${SAMBA_CRED_FILE}"
    echo "   On Windows, enter '${user}' and the password when prompted."
    echo "════════════════════════════════════════════════════════════"
}

# Change the Samba password for the panel-managed user. New password comes from
# DB_PASSWORD; the username is read back from the saved credentials file.
set_samba_password() {
    local password user
    password="${DB_PASSWORD:?DB_PASSWORD env var required}"
    if [ ! -f "$SAMBA_CRED_FILE" ]; then
        echo "✗  ${SAMBA_CRED_FILE} not found — cannot determine which user to update."
        return 1
    fi
    user="$(sed -nE 's/^username:[[:space:]]*"?([^"]+)"?[[:space:]]*$/\1/p' "$SAMBA_CRED_FILE")"
    if [ -z "$user" ]; then
        echo "✗  No username recorded in ${SAMBA_CRED_FILE}."
        return 1
    fi

    echo "▶  Updating Samba password for '${user}'..."
    printf '%s\n%s\n' "$password" "$password" | smbpasswd -s "$user"

    echo "▶  Updating ${SAMBA_CRED_FILE}..."
    sed -i -E "s|^password:.*|password: \"${password}\"|" "$SAMBA_CRED_FILE"
    echo "✔  Samba password updated for '${user}'."
}

uninstall_samba() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Removing Samba"
    echo "════════════════════════════════════════════════════════════"
    systemctl disable --now smbd nmbd 2>/dev/null || true

    # Strip any panel-managed share blocks from smb.conf (data left in place).
    if [ -f "$SAMBA_CONF" ]; then
        sed -i '\|# >>> panel-samba:|,\|# <<< panel-samba:|d' "$SAMBA_CONF" || true
    fi
    rm -f "$SAMBA_CRED_FILE"

    apt-get purge -y samba samba-common-bin 2>/dev/null || true
    apt-get autoremove -y || true
    _unregister_panel_service smbd
    echo "✔  Samba removed. Shared folders under /srv/ and the system user were left untouched."
}
