#!/usr/bin/env bash
# postgres.sh — PostgreSQL 16 via PGDG (Ubuntu 24.04+)

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


PG_VERSION="16"
PG_CRED_FILE="/etc/postgresql/credentials.yml"

install_postgres() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing PostgreSQL ${PG_VERSION}"
    echo "════════════════════════════════════════════════════════════"

    local conf_dir="/etc/postgresql/${PG_VERSION}/main"

    # ── PGDG repository ───────────────────────────────────────────
    echo "▶  Adding PGDG APT repository..."
    apt-get install -y curl ca-certificates
    install -d /usr/share/postgresql-common/pgdg
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc

    # shellcheck disable=SC1091
    . /etc/os-release
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list

    apt-get update -q
    apt-get install -y "postgresql-${PG_VERSION}"

    systemctl enable postgresql
    systemctl start postgresql
    _register_panel_service postgresql

    # ── Password: use the one supplied by the panel, else generate one ──────
    local db_password
    db_password="${DB_PASSWORD:-$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 28)}"

    echo "▶  Setting postgres user password..."
    su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '${db_password}';\""

    # ── Optimised postgresql.conf ─────────────────────────────────
    echo "▶  Writing postgresql.conf..."
    cp "${conf_dir}/postgresql.conf" "${conf_dir}/postgresql.conf.bak"
    cat > "${conf_dir}/postgresql.conf" <<PGCONF
# Ubuntu package paths
data_directory    = '/var/lib/postgresql/${PG_VERSION}/main'
hba_file          = '${conf_dir}/pg_hba.conf'
ident_file        = '${conf_dir}/pg_ident.conf'
external_pid_file = '/var/run/postgresql/${PG_VERSION}-main.pid'
include_dir       = 'conf.d'

# Connections
listen_addresses = '*'
max_connections  = 200

# Memory
shared_buffers             = 256MB
work_mem                   = 4MB
dynamic_shared_memory_type = posix

# WAL
max_wal_size = 2GB
min_wal_size = 80MB

# Logging
log_destination          = 'stderr'
logging_collector        = on
log_directory            = 'log'
log_filename             = 'postgresql-%a.log'
log_truncate_on_rotation = on
log_rotation_age         = 1d
log_rotation_size        = 0
log_line_prefix          = '%m [%p] '
log_timezone             = 'Asia/Ho_Chi_Minh'

# Locale
datestyle                  = 'iso, mdy'
timezone                   = 'Asia/Ho_Chi_Minh'
lc_messages                = 'en_US.UTF-8'
lc_monetary                = 'en_US.UTF-8'
lc_numeric                 = 'en_US.UTF-8'
lc_time                    = 'en_US.UTF-8'
default_text_search_config = 'pg_catalog.english'
PGCONF

    # ── pg_hba.conf ───────────────────────────────────────────────
    echo "▶  Writing pg_hba.conf..."
    cp "${conf_dir}/pg_hba.conf" "${conf_dir}/pg_hba.conf.bak"
    cat > "${conf_dir}/pg_hba.conf" <<HBACONF
# TYPE  DATABASE  USER  ADDRESS        METHOD
local   all       all                  md5
host    all       all   127.0.0.1/32   md5
host    all       all   ::1/128        md5
# Allow remote (restrict via firewall)
host    all       all   0.0.0.0/0      md5
HBACONF

    systemctl restart postgresql
    systemctl status postgresql --no-pager

    # ── Firewall: allow only private subnets, deny everything else ───────────
    _ufw_allow_port 5432 "PostgreSQL"

    # ── Save credentials ──────────────────────────────────────────
    echo "▶  Saving credentials to ${PG_CRED_FILE}..."
    mkdir -p "$(dirname "$PG_CRED_FILE")"
    cat > "$PG_CRED_FILE" <<CRED
# PostgreSQL credentials
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
service: postgresql
version: "${PG_VERSION}"

admin_user: "postgres"
admin_password: "${db_password}"

port: 5432
host: "127.0.0.1"
connection_string: "postgresql://postgres:${db_password}@127.0.0.1:5432/postgres"

config_dir: "${conf_dir}"
data_dir: "/var/lib/postgresql/${PG_VERSION}/main"

notes: "Remote access allowed; secure with firewall or SSH tunnel."
CRED
    chmod 600 "$PG_CRED_FILE"

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  PostgreSQL ${PG_VERSION} installed."
    echo "   Host     : <server-ip>:5432"
    echo "   User     : postgres"
    echo "   Password : ${db_password}"
    echo "   Allow    : ${ALLOWED_SUBNETS[*]}"
    echo ""
    echo "   Credentials saved to: ${PG_CRED_FILE}"
    echo "════════════════════════════════════════════════════════════"
}

# Backwards-compatible aliases
install_postgres_remote()      { install_postgres; }
install_postgres_remote_auto() { install_postgres; }

uninstall_postgres() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Removing PostgreSQL ${PG_VERSION}"
    echo "════════════════════════════════════════════════════════════"
    systemctl disable --now postgresql 2>/dev/null || true
    apt-get purge -y "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}" postgresql-common 2>/dev/null || true
    apt-get autoremove -y || true
    rm -rf "/var/lib/postgresql/${PG_VERSION}" /etc/postgresql
    rm -f /etc/apt/sources.list.d/pgdg.list "$PG_CRED_FILE"
    _unregister_panel_service postgresql
    echo "✔  PostgreSQL removed (data in /var/lib/postgresql deleted)."
}

# Change the postgres superuser password. New password comes from DB_PASSWORD.
set_postgres_password() {
    local db_password="${DB_PASSWORD:?DB_PASSWORD env var required}"
    echo "▶  Updating postgres user password..."
    su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '${db_password}';\""

    if [ -f "$PG_CRED_FILE" ]; then
        echo "▶  Updating ${PG_CRED_FILE}..."
        sed -i -E "s|^admin_password:.*|admin_password: \"${db_password}\"|" "$PG_CRED_FILE"
        sed -i -E "s|^connection_string:.*|connection_string: \"postgresql://postgres:${db_password}@127.0.0.1:5432/postgres\"|" "$PG_CRED_FILE"
    fi
    echo "✔  PostgreSQL password updated."
}
