#!/usr/bin/env bash
# elasticsearch.sh — Elasticsearch 8.x and Kibana (Ubuntu 22.04 / 24.04, amd64 / arm64)
# Reference: https://www.elastic.co/guide/en/elasticsearch/reference/current/deb.html
#
# Security: authentication is ON (built-in `elastic` superuser, password from
# DB_PASSWORD, saved 0600 in ES_CRED_FILE). TLS is OFF on both HTTP and the
# transport layer: this is a single node (no transport peers) meant for a LAN
# behind UFW. Put a TLS-terminating proxy in front, or enable
# xpack.security.http.ssl, before exposing it beyond a trusted network —
# without TLS the password crosses the network in clear text.

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail

ES_PORT=9200
KIBANA_PORT=5601
# Elastic APT major version; override with ELASTIC_MAJOR (e.g. 9).
ELASTIC_MAJOR="${ELASTIC_MAJOR:-8}"
ES_HOME="/usr/share/elasticsearch"
ES_CONF_DIR="/etc/elasticsearch"
ES_CRED_FILE="${ES_CONF_DIR}/credentials.yml"
ES_URL="http://127.0.0.1:${ES_PORT}"

# ── Shared: add Elastic APT repository ────────────────────────────────────────
_elastic_add_repo() {
    local list="/etc/apt/sources.list.d/elastic-${ELASTIC_MAJOR}.x.list"
    local keyring="/usr/share/keyrings/elasticsearch-keyring.gpg"
    if [ -f "$list" ] && [ -s "$keyring" ]; then
        return 0  # already added
    fi

    echo "▶  Adding Elastic ${ELASTIC_MAJOR}.x APT repository..."
    apt-get update -q
    apt-get install -y gnupg curl apt-transport-https

    # Import the Elasticsearch PGP signing key.
    curl -fsSL --max-time 60 --retry 3 https://artifacts.elastic.co/GPG-KEY-elasticsearch \
        | gpg --batch --yes --dearmor -o "$keyring"

    echo "deb [signed-by=${keyring}] \
https://artifacts.elastic.co/packages/${ELASTIC_MAJOR}.x/apt stable main" > "$list"

    apt-get update -q
}

# Elastic publishes the same repository for every Ubuntu release; these are the
# LTS releases and CPUs it supports.
_elastic_require_platform() {
    if [[ ! "$ELASTIC_MAJOR" =~ ^[0-9]+$ ]]; then
        echo "❌  ELASTIC_MAJOR must be a major version such as 8 (got '${ELASTIC_MAJOR}')."
        return 1
    fi
    _require_platform "$1" "22.04 24.04" "amd64 arm64"
}

# Passwords are placed inside a curl config file and a JSON string; the panel's
# validators already forbid these characters — refuse rather than escape.
_es_check_password() {
    case "$1" in
        *'"'* | *\\* | *$'\n'*)
            echo "❌  The password may not contain double quotes, backslashes or newlines."
            return 1
            ;;
    esac
}

# curl against the local node as `elastic`. The credentials go in a 0600 config
# file (curl -K) inside a 0700 temp dir, never on the command line.
# Usage: _es_curl <elastic-password> <curl args...>
_es_curl() {
    local pw="$1" dir rc=0
    shift
    dir="$(mktemp -d)"
    install -m 600 /dev/null "${dir}/curl.conf"
    printf 'user = "elastic:%s"\n' "$pw" > "${dir}/curl.conf"
    curl -K "${dir}/curl.conf" "$@" || rc=$?
    rm -rf "$dir"
    return "$rc"
}

# True when <password> authenticates as elastic.
_es_auth_ok() {
    local code
    code="$(_es_curl "$1" -s -o /dev/null -w '%{http_code}' --max-time 10 \
        "${ES_URL}/_security/_authenticate" || true)"
    [ "$code" = "200" ]
}

# The elastic password saved by a previous install ("" if none).
_es_saved_password() {
    if [ -f "$ES_CRED_FILE" ]; then
        sed -n 's/^admin_password: "\(.*\)"$/\1/p' "$ES_CRED_FILE"
    fi
}

# Wait until the HTTP port answers (401 = up, security on).
_es_wait_ready() {
    local i code
    for ((i = 0; i < 90; i++)); do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${ES_URL}/" || true)"
        case "$code" in
            200 | 401) return 0 ;;
        esac
        sleep 2
    done
    echo "❌  Elasticsearch did not answer on ${ES_URL} within 180 s. Recent log:"
    journalctl -u elasticsearch --no-pager -n 40 || true
    return 1
}

# Make <new password> the elastic password on a running node:
#   1. it already works (fresh node: bootstrap.password; or a re-install with the
#      same password) → nothing to do;
#   2. the saved password works → change it through the security API;
#   3. neither (password lost) → elasticsearch-reset-password, which logs in
#      through a temporary file-realm user, reading the new password on stdin.
_es_set_elastic_password() {
    local new_pw="$1" old_pw i
    old_pw="$(_es_saved_password)"
    _es_check_password "$new_pw"

    # The security index may need a few seconds after the port opens.
    for ((i = 0; i < 15; i++)); do
        if _es_auth_ok "$new_pw"; then
            echo "▶  The elastic password is in place."
            return 0
        fi
        if [ -n "$old_pw" ] && [ "$old_pw" != "$new_pw" ] && _es_auth_ok "$old_pw"; then
            echo "▶  Changing the elastic password..."
            printf '{"password":"%s"}' "$new_pw" \
                | _es_curl "$old_pw" -fsS --max-time 30 -o /dev/null -X POST \
                    -H 'Content-Type: application/json' --data-binary @- \
                    "${ES_URL}/_security/user/elastic/_password"
            return 0
        fi
        sleep 4
    done

    echo "▶  Neither the new nor the saved password works — resetting it with elasticsearch-reset-password..."
    printf '%s\n%s\n' "$new_pw" "$new_pw" \
        | "${ES_HOME}/bin/elasticsearch-reset-password" -u elastic -i -b -s --url "$ES_URL" >/dev/null
    if ! _es_auth_ok "$new_pw"; then
        echo "❌  Could not set the elastic password."
        return 1
    fi
}

# Keystore edits run as root; give the file back the package's ownership/mode.
_es_keystore() {
    "${ES_HOME}/bin/elasticsearch-keystore" "$@"
    chown root:elasticsearch "${ES_CONF_DIR}/elasticsearch.keystore"
    chmod 660 "${ES_CONF_DIR}/elasticsearch.keystore"
}

_es_keystore_has() {
    "${ES_HOME}/bin/elasticsearch-keystore" list 2>/dev/null | grep -Fx -- "$1" >/dev/null
}

# ── Elasticsearch ──────────────────────────────────────────────────────────────
install_elasticsearch() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing Elasticsearch ${ELASTIC_MAJOR}.x"
    echo "════════════════════════════════════════════════════════════"

    _elastic_require_platform "Elasticsearch"

    local es_password
    es_password="${DB_PASSWORD:-$(gen_password)}"
    _es_check_password "$es_password"

    _elastic_add_repo
    # On a first install the package auto-configures security and prints a
    # generated elastic password; that password is discarded below (its hash is
    # removed from the keystore before the first start).
    apt-get install -y elasticsearch curl

    echo "▶  Writing ${ES_CONF_DIR}/elasticsearch.yml..."
    cat > "${ES_CONF_DIR}/elasticsearch.yml" <<ESCONF
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch

cluster.name: elasticsearch-local
node.name: node-1

# Listen on all interfaces; UFW restricts access to the chosen subnets.
network.host: 0.0.0.0
http.port: ${ES_PORT}
discovery.type: single-node

indices.query.bool.max_clause_count: 32768

# Authentication on (user elastic, see ${ES_CRED_FILE}).
# TLS off: single node, LAN only. Enable xpack.security.http.ssl (or use a TLS
# proxy) before exposing the API beyond a trusted network.
xpack.security.enabled: true
xpack.security.enrollment.enabled: false
xpack.security.transport.ssl.enabled: false
xpack.security.http.ssl.enabled: false
ESCONF

    # ── JVM heap: let Elasticsearch size it (50% of RAM, capped below 32 GB).
    # ES_HEAP (e.g. 4g or 2048m) pins it instead.
    local heap_file="${ES_CONF_DIR}/jvm.options.d/heap.options"
    mkdir -p "${ES_CONF_DIR}/jvm.options.d"
    if [ -n "${ES_HEAP:-}" ]; then
        if [[ ! "$ES_HEAP" =~ ^[0-9]+[mMgG]$ ]]; then
            echo "❌  ES_HEAP must look like 4g or 2048m (got '${ES_HEAP}')."
            return 1
        fi
        echo "▶  Setting JVM heap to ${ES_HEAP}..."
        printf -- '-Xms%s\n-Xmx%s\n' "$ES_HEAP" "$ES_HEAP" > "$heap_file"
    else
        echo "▶  JVM heap: automatic (50% of RAM, max 31 GB)."
        rm -f "$heap_file"
    fi

    # ── elastic password, before the first start ──────────────────────────────
    # bootstrap.password sets it when the security index has none yet (fresh
    # install, or a node an older panel ran with security off). The package's
    # auto-generated hash would take precedence, so drop it.
    # The auto-configured TLS keystore passwords go too: elasticsearch.yml above
    # no longer points at those certificates.
    echo "▶  Preparing the elastic password in the keystore..."
    local entry
    for entry in autoconfiguration.password_hash \
        xpack.security.http.ssl.keystore.secure_password \
        xpack.security.transport.ssl.keystore.secure_password \
        xpack.security.transport.ssl.truststore.secure_password; do
        if _es_keystore_has "$entry"; then
            _es_keystore remove "$entry"
        fi
    done
    printf '%s' "$es_password" | _es_keystore add -x -f bootstrap.password

    # Firewall: allow only the chosen subnets.
    _ufw_allow_port "${ES_PORT}" "Elasticsearch"

    # Reload systemd in case the unit was just installed, then enable & start.
    /bin/systemctl daemon-reload
    systemctl enable elasticsearch.service
    echo "▶  Starting Elasticsearch (may take a minute)..."
    systemctl restart elasticsearch.service
    _register_panel_service elasticsearch
    _es_wait_ready

    # Re-install with existing data keeps the stored password: change it.
    _es_set_elastic_password "$es_password"

    # The password now lives in the security index; keep no copy in the keystore.
    _es_keystore remove bootstrap.password || true

    # ── Save credentials ──────────────────────────────────────────────────────
    echo "▶  Saving credentials to ${ES_CRED_FILE}..."
    # Create it 0600 first: a later chmod leaves a window where the file is world-readable.
    install -m 600 /dev/null "$ES_CRED_FILE"
    cat > "$ES_CRED_FILE" <<CRED
# Elasticsearch credentials
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
service: elasticsearch

admin_user: "elastic"
admin_password: "${es_password}"

url: "http://<server-ip>:${ES_PORT}"
notes: "Basic auth over plain HTTP (no TLS); UFW restricts access to the chosen subnets."
CRED
    chmod 600 "$ES_CRED_FILE"

    systemctl status elasticsearch --no-pager || true

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  Elasticsearch ${ELASTIC_MAJOR}.x installed."
    echo "   API      : http://<server-ip>:${ES_PORT}  (HTTP, no TLS)"
    echo "   User     : elastic"
    echo "   Password : saved in ${ES_CRED_FILE} (mode 600)"
    echo "   Logs     : /var/log/elasticsearch/"
    echo "   Allow    : ${ALLOWED_SUBNETS[*]}"
    echo ""
    echo "   Test     : curl -u elastic ${ES_URL}   (prompts for the password)"
    echo "   Tip      : Install Kibana separately for the UI dashboard."
    echo "════════════════════════════════════════════════════════════"
}

# Change the elastic password. New password comes from DB_PASSWORD.
set_elasticsearch_password() {
    local es_password="${DB_PASSWORD:?DB_PASSWORD env var required}"
    echo "▶  Updating the elastic password..."
    _es_wait_ready
    _es_set_elastic_password "$es_password"

    if [ -f "$ES_CRED_FILE" ]; then
        echo "▶  Updating ${ES_CRED_FILE}..."
        cred_set "$ES_CRED_FILE" admin_password "${es_password}"
    fi
    echo "✔  Elasticsearch password updated (Kibana uses kibana_system and is unaffected)."
}

# ── Kibana ─────────────────────────────────────────────────────────────────────
install_kibana() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing Kibana ${ELASTIC_MAJOR}.x"
    echo "════════════════════════════════════════════════════════════"

    _elastic_require_platform "Kibana"

    # Kibana talks to the local Elasticsearch as kibana_system; setting that
    # user's password needs the elastic login saved by install_elasticsearch.
    local elastic_pw
    elastic_pw="$(_es_saved_password)"
    if [ -z "$elastic_pw" ]; then
        echo "❌  ${ES_CRED_FILE} has no elastic password. Install (or re-install)"
        echo "    Elasticsearch from the panel first."
        return 1
    fi
    _es_check_password "$elastic_pw"
    if ! _es_auth_ok "$elastic_pw"; then
        echo "❌  Cannot log in to ${ES_URL} as elastic with the saved password."
        echo "    Make sure Elasticsearch is running (or re-install it to reset the password)."
        return 1
    fi

    _elastic_add_repo
    apt-get install -y kibana

    echo "▶  Setting the kibana_system password..."
    local kibana_pw
    kibana_pw="$(gen_password)"
    printf '{"password":"%s"}' "$kibana_pw" \
        | _es_curl "$elastic_pw" -fsS --max-time 30 -o /dev/null -X POST \
            -H 'Content-Type: application/json' --data-binary @- \
            "${ES_URL}/_security/user/kibana_system/_password"

    echo "▶  Writing /etc/kibana/kibana.yml..."
    # Holds the kibana_system password: readable by the kibana service only.
    install -m 640 -o root -g kibana /dev/null /etc/kibana/kibana.yml
    cat > /etc/kibana/kibana.yml <<KCONF
server.port: ${KIBANA_PORT}
# Listen on all interfaces; UFW restricts access to the chosen subnets.
server.host: "0.0.0.0"
elasticsearch.hosts: ["${ES_URL}"]
elasticsearch.username: "kibana_system"
elasticsearch.password: "${kibana_pw}"
KCONF

    # Firewall: allow only the chosen subnets.
    _ufw_allow_port "${KIBANA_PORT}" "Kibana"

    /bin/systemctl daemon-reload
    systemctl enable kibana.service
    systemctl restart kibana.service
    _register_panel_service kibana
    systemctl status kibana --no-pager || true

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  Kibana ${ELASTIC_MAJOR}.x installed."
    echo "   UI    : http://<server-ip>:${KIBANA_PORT}  (HTTP, no TLS)"
    echo "   Login : elastic — password in ${ES_CRED_FILE}"
    echo "   Allow : ${ALLOWED_SUBNETS[*]}"
    echo ""
    echo "   Note  : Kibana connects to Elasticsearch as kibana_system (password in /etc/kibana/kibana.yml)."
    echo "   Tip   : Check kibana version: /usr/share/kibana/bin/kibana -V"
    echo "════════════════════════════════════════════════════════════"
}

uninstall_elasticsearch() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Removing Elasticsearch"
    echo "════════════════════════════════════════════════════════════"
    systemctl disable --now elasticsearch 2>/dev/null || true
    apt-get purge -y elasticsearch 2>/dev/null || true
    apt-get autoremove -y || true
    rm -rf /var/lib/elasticsearch /var/log/elasticsearch "$ES_CONF_DIR"
    _unregister_panel_service elasticsearch
    echo "✔  Elasticsearch removed. (Elastic APT repo left in place for Kibana.)"
}

uninstall_kibana() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Removing Kibana"
    echo "════════════════════════════════════════════════════════════"
    systemctl disable --now kibana 2>/dev/null || true
    apt-get purge -y kibana 2>/dev/null || true
    apt-get autoremove -y || true
    rm -rf /var/lib/kibana /var/log/kibana /etc/kibana
    _unregister_panel_service kibana
    echo "✔  Kibana removed."
}
