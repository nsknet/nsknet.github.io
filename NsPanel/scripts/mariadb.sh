#!/usr/bin/env bash
# mariadb.sh — MariaDB server (Ubuntu 22.04 / 24.04) via APT

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


MARIADB_CRED_FILE="/etc/mysql/credentials.yml"

install_mariadb() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing MariaDB"
    echo "════════════════════════════════════════════════════════════"

    export DEBIAN_FRONTEND=noninteractive

    echo "▶  Installing mariadb-server..."
    apt-get update -q
    apt-get install -y mariadb-server mariadb-client

    systemctl enable mariadb
    systemctl start mariadb
    _register_panel_service mariadb

    # ── Password: use the one supplied by the panel, else generate one ───────
    local db_password
    db_password="${DB_PASSWORD:-$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 28)}"

    # On a fresh install root authenticates via the unix_socket plugin (we are
    # running as root, so this works without a password). Set a password and a
    # remote-capable root user, drop the anonymous/test leftovers.
    echo "▶  Securing server and setting root password..."
    mariadb <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED BY '${db_password}';
DELETE FROM mysql.global_priv WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '${db_password}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
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
    cat > "$MARIADB_CRED_FILE" <<CRED
# MariaDB credentials
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
service: mariadb

admin_user: "root"
admin_password: "${db_password}"

port: 3306
host: "127.0.0.1"
connection_string: "mysql://root:${db_password}@127.0.0.1:3306/"

notes: "Remote access allowed; secure with firewall or SSH tunnel."
CRED
    chmod 600 "$MARIADB_CRED_FILE"

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  MariaDB installed."
    mariadb --version | head -n1 || true
    echo "   Host     : <server-ip>:3306"
    echo "   User     : root"
    echo "   Password : ${db_password}"
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

# Change the MariaDB root password. New password comes from DB_PASSWORD.
set_mariadb_password() {
    local db_password="${DB_PASSWORD:?DB_PASSWORD env var required}"
    echo "▶  Updating MariaDB root password..."
    mariadb <<SQL
ALTER USER IF EXISTS 'root'@'localhost' IDENTIFIED BY '${db_password}';
ALTER USER IF EXISTS 'root'@'%' IDENTIFIED BY '${db_password}';
FLUSH PRIVILEGES;
SQL

    if [ -f "$MARIADB_CRED_FILE" ]; then
        echo "▶  Updating ${MARIADB_CRED_FILE}..."
        sed -i -E "s|^admin_password:.*|admin_password: \"${db_password}\"|" "$MARIADB_CRED_FILE"
        sed -i -E "s|^connection_string:.*|connection_string: \"mysql://root:${db_password}@127.0.0.1:3306/\"|" "$MARIADB_CRED_FILE"
    fi
    echo "✔  MariaDB password updated."
}
