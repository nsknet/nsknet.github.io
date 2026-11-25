#!/usr/bin/env bash
# postgres.sh — PostgreSQL (default 16) via PGDG (Ubuntu 22.04 / 24.04)

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail

# Major version from PGDG; override with POSTGRES_VERSION (e.g. 17). The panel's
# module detects the default package name, so keep 16 unless you also update it.
PG_VERSION="${POSTGRES_VERSION:-16}"
PG_CRED_FILE="/etc/postgresql/credentials.yml"

# ALTER USER over stdin, never argv: argv shows up in `ps` and in the job log.
# Validators keep quotes out of panel passwords; gen_password is hex.
_pg_set_password() {
    local sql saved=""
    sql="$(printf "ALTER USER postgres PASSWORD '%s';" "$1")"
    if printf '%s\n' "$sql" \
        | (cd /tmp && runuser -u postgres -- psql -q -v ON_ERROR_STOP=1) 2>/dev/null; then
        return 0
    fi
    # Servers installed by an older panel have `local all all md5`, which also
    # covers postgres: authenticate with the saved password instead.
    echo "▶  Peer login refused — using the saved password..."
    if [ -f "$PG_CRED_FILE" ]; then
        saved="$(sed -n 's/^admin_password: "\(.*\)"$/\1/p' "$PG_CRED_FILE")"
    fi
    printf '%s\n' "$sql" | PGPASSWORD="$saved" \
        psql -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -U postgres -d postgres
}

install_postgres() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing PostgreSQL ${PG_VERSION}"
    echo "════════════════════════════════════════════════════════════"

    if [[ ! "$PG_VERSION" =~ ^[0-9]{2}$ ]]; then
        echo "❌  POSTGRES_VERSION must be a major version such as 16 or 17 (got '${PG_VERSION}')."
        return 1
    fi
    # PGDG publishes every supported Ubuntu LTS for these architectures.
    _require_platform "PostgreSQL" "22.04 24.04" "amd64 arm64 ppc64el"

    local conf_dir="/etc/postgresql/${PG_VERSION}/main"

    # ── PGDG repository ───────────────────────────────────────────
    echo "▶  Adding PGDG APT repository..."
    apt-get update -q
    apt-get install -y curl ca-certificates
    install -d /usr/share/postgresql-common/pgdg
    curl -fsSL --max-time 60 --retry 3 https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc

    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt $(_os_codename)-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list

    apt-get update -q
    apt-get install -y "postgresql-${PG_VERSION}"

    systemctl enable postgresql
    systemctl start postgresql
    _register_panel_service postgresql

    # ── Password: use the one supplied by the panel, else generate one ──────
    local db_password
    db_password="${DB_PASSWORD:-$(gen_password)}"

    echo "▶  Setting postgres user password..."
    _pg_set_password "$db_password"

    # ── Server timezone and locale ────────────────────────────────
    # Follow the host's timezone (UTC when it cannot be read, e.g. in a container
    # without systemd). The value lands inside a quoted config string, so accept
    # only tz-database characters.
    local tz
    tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    if [[ ! "$tz" =~ ^[A-Za-z0-9/_+-]+$ ]]; then
        tz="UTC"
    fi
    # A minimal VPS image may lack en_US.UTF-8; an unknown lc_* value stops the
    # server from starting, so fall back to C.UTF-8, which always exists.
    local pg_locale="C.UTF-8"
    if locale -a 2>/dev/null | grep -Fix 'en_US.utf8' >/dev/null; then
        pg_locale="en_US.UTF-8"
    fi

    # ── Optimised postgresql.conf ─────────────────────────────────
    echo "▶  Writing postgresql.conf (timezone ${tz}, locale ${pg_locale})..."
    # Keep the package's original on re-install instead of backing up our own copy.
    [ -e "${conf_dir}/postgresql.conf.bak" ] || cp "${conf_dir}/postgresql.conf" "${conf_dir}/postgresql.conf.bak"
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
log_timezone             = '${tz}'

# Locale
datestyle                  = 'iso, mdy'
timezone                   = '${tz}'
lc_messages                = '${pg_locale}'
lc_monetary                = '${pg_locale}'
lc_numeric                 = '${pg_locale}'
lc_time                    = '${pg_locale}'
default_text_search_config = 'pg_catalog.english'
PGCONF

    # ── pg_hba.conf ───────────────────────────────────────────────
    echo "▶  Writing pg_hba.conf..."
    [ -e "${conf_dir}/pg_hba.conf.bak" ] || cp "${conf_dir}/pg_hba.conf" "${conf_dir}/pg_hba.conf.bak"
    # The first line keeps OS-user `postgres` on peer auth: the panel's own psql
    # calls (re-install, set_postgres_password) run that way, without a password.
    cat > "${conf_dir}/pg_hba.conf" <<HBACONF
# TYPE  DATABASE  USER      ADDRESS        METHOD
local   all       postgres                 peer
local   all       all                      md5
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
    # Create it 0600 first: a later chmod leaves a window where the file is world-readable.
    install -m 600 /dev/null "$PG_CRED_FILE"
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
    echo "   Password : saved in ${PG_CRED_FILE} (mode 600)"
    echo "   Allow    : ${ALLOWED_SUBNETS[*]}"
    echo ""
    echo "   Credentials saved to: ${PG_CRED_FILE}"
    echo "════════════════════════════════════════════════════════════"
}

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
    _pg_set_password "$db_password"

    if [ -f "$PG_CRED_FILE" ]; then
        echo "▶  Updating ${PG_CRED_FILE}..."
        cred_set "$PG_CRED_FILE" admin_password "${db_password}"
        cred_set "$PG_CRED_FILE" connection_string "postgresql://postgres:${db_password}@127.0.0.1:5432/postgres"
    fi
    echo "✔  PostgreSQL password updated."
}
