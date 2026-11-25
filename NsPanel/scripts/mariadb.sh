#!/usr/bin/env bash
# mariadb.sh — MariaDB server (Ubuntu 22.04 / 24.04) via APT

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


MARIADB_CRED_FILE="/etc/mysql/credentials.yml"
# Remote administrator. root stays local-only (unix_socket): a password-less,
# network-unreachable superuser is what Debian's maintenance scripts expect, and
# a leaked panel password then never grants root.
MARIADB_ADMIN_USER="panel_admin"

# Run SQL as a MariaDB superuser. Root normally logs in over the unix socket (we
# are root), but servers installed by an older panel lost that, so fall back to
# the saved admin account, its password passed via MYSQL_PWD (never argv).
_mariadb_root() {
    if mariadb -e 'SELECT 1' </dev/null >/dev/null 2>&1; then
        mariadb "$@"
        return
    fi
    local saved="" user=""
    if [ -f "$MARIADB_CRED_FILE" ]; then
        saved="$(sed -n 's/^admin_password: "\(.*\)"$/\1/p' "$MARIADB_CRED_FILE")"
        user="$(sed -n 's/^admin_user: "\(.*\)"$/\1/p' "$MARIADB_CRED_FILE")"
    fi
    MYSQL_PWD="$saved" mariadb -u"${user:-root}" "$@"
}

# Create (or update) the remote admin account with the given password. SQL goes
# over stdin; validators keep quotes and backslashes out of panel passwords.
_mariadb_set_admin() {
    _mariadb_root <<SQL
CREATE USER IF NOT EXISTS '${MARIADB_ADMIN_USER}'@'%' IDENTIFIED BY '${1}';
ALTER USER '${MARIADB_ADMIN_USER}'@'%' IDENTIFIED BY '${1}';
GRANT ALL PRIVILEGES ON *.* TO '${MARIADB_ADMIN_USER}'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
}

install_mariadb() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing MariaDB"
    echo "════════════════════════════════════════════════════════════"

    # Ubuntu's own mariadb-server package (10.6 on 22.04, 10.11 on 24.04).
    _require_platform "MariaDB" "22.04 24.04" "amd64 arm64 ppc64el s390x"

    export DEBIAN_FRONTEND=noninteractive

    echo "▶  Installing mariadb-server..."
    apt-get update -q
    apt-get install -y mariadb-server mariadb-client

    systemctl enable mariadb
    systemctl start mariadb
    _register_panel_service mariadb

    # ── Password: use the one supplied by the panel, else generate one ───────
    local db_password
    db_password="${DB_PASSWORD:-$(gen_password)}"

    # Remote administration goes through a dedicated account; create it first,
    # while whatever login _mariadb_root found still works.
    echo "▶  Creating remote admin '${MARIADB_ADMIN_USER}'@'%'..."
    _mariadb_set_admin "$db_password"

    # On a fresh install root authenticates via the unix_socket plugin (we are
    # running as root, so this works without a password). Pin it to exactly
    # that, drop the remote root an older panel created and the anonymous/test
    # leftovers. Re-install is safe: every statement is idempotent.
    echo "▶  Securing server (root: local unix_socket only)..."
    _mariadb_root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket;
DROP USER IF EXISTS 'root'@'%';
DELETE FROM mysql.global_priv WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

    # ── Listen on all interfaces (firewall restricts who can reach it) ───────
    echo "▶  Writing bind-address override..."
    cat > /etc/mysql/mariadb.conf.d/60-panel.cnf <<CNF
[mysqld]
bind-address = 0.0.0.0
CNF

    systemctl restart mariadb
    systemctl status mariadb --no-pager || true

    # ── Firewall: allow only the chosen subnets ──────────────────────────────
    _ufw_allow_port 3306 "MariaDB"

    # ── Save credentials ─────────────────────────────────────────────────────
    echo "▶  Saving credentials to ${MARIADB_CRED_FILE}..."
    mkdir -p "$(dirname "$MARIADB_CRED_FILE")"
    # Create it 0600 first: a later chmod leaves a window where the file is world-readable.
    install -m 600 /dev/null "$MARIADB_CRED_FILE"
    cat > "$MARIADB_CRED_FILE" <<CRED
# MariaDB credentials
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
service: mariadb

admin_user: "${MARIADB_ADMIN_USER}"
admin_password: "${db_password}"

port: 3306
host: "127.0.0.1"
connection_string: "mysql://${MARIADB_ADMIN_USER}:${db_password}@127.0.0.1:3306/"

root_login: "local only, no password: run 'sudo mariadb' on the server (unix_socket)"
notes: "Remote access allowed for ${MARIADB_ADMIN_USER}; secure with firewall or SSH tunnel."
CRED
    chmod 600 "$MARIADB_CRED_FILE"

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  MariaDB installed."
    mariadb --version | head -n1 || true
    echo "   Host     : <server-ip>:3306"
    echo "   User     : ${MARIADB_ADMIN_USER}  (root: local 'sudo mariadb' only)"
    echo "   Password : saved in ${MARIADB_CRED_FILE} (mode 600)"
    echo "   Allow    : ${ALLOWED_SUBNETS[*]}"
    echo ""
    echo "   Credentials saved to: ${MARIADB_CRED_FILE}"
    echo "════════════════════════════════════════════════════════════"
}

uninstall_mariadb() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Removing MariaDB"
    echo "════════════════════════════════════════════════════════════"
    systemctl disable --now mariadb 2>/dev/null || true
    apt-get purge -y mariadb-server mariadb-client mariadb-common 2>/dev/null || true
    apt-get autoremove -y || true
    rm -rf /var/lib/mysql /etc/mysql
    _unregister_panel_service mariadb
    echo "✔  MariaDB removed (data in /var/lib/mysql deleted)."
}

# Change the remote admin password. New password comes from DB_PASSWORD.
# root keeps its unix_socket-only login and has no password to change.
set_mariadb_password() {
    local db_password="${DB_PASSWORD:?DB_PASSWORD env var required}"
    echo "▶  Updating MariaDB password for '${MARIADB_ADMIN_USER}'@'%'..."
    _mariadb_set_admin "$db_password"

    if [ -f "$MARIADB_CRED_FILE" ]; then
        echo "▶  Updating ${MARIADB_CRED_FILE}..."
        cred_set "$MARIADB_CRED_FILE" admin_user "${MARIADB_ADMIN_USER}"
        cred_set "$MARIADB_CRED_FILE" admin_password "${db_password}"
        cred_set "$MARIADB_CRED_FILE" connection_string "mysql://${MARIADB_ADMIN_USER}:${db_password}@127.0.0.1:3306/"
    fi

    # Servers installed by an older panel still have a remote root; re-install
    # removes it (after moving clients to the admin account above).
    local legacy_root
    legacy_root="$(_mariadb_root -N -B -e "SELECT COUNT(*) FROM mysql.global_priv WHERE User='root' AND Host='%'" </dev/null || echo 0)"
    if [ "${legacy_root:-0}" != "0" ]; then
        log_warn "Legacy account root@'%' still exists with its old password. Re-install MariaDB from the panel to remove it."
    fi
    echo "✔  MariaDB password updated."
}
