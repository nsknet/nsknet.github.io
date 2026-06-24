#!/usr/bin/env bash
# elasticsearch.sh — Elasticsearch 8.x and Kibana (Ubuntu)
# Reference: https://tecadmin.net/how-to-setup-elasticsearch-on-ubuntu-22-04/

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


ES_PORT=9200
KIBANA_PORT=5601

# ── Shared: add Elastic APT repository ────────────────────────────────────────
_elastic_add_repo() {
    if [ -f /etc/apt/sources.list.d/elastic-8.x.list ]; then
        return 0  # already added
    fi

    echo "▶  Adding Elastic 8.x APT repository..."
    apt-get install -y gnupg wget apt-transport-https

    # Import the Elasticsearch PGP signing key.
    # Remove any stale keyring first so gpg --dearmor doesn't prompt to overwrite.
    rm -f /usr/share/keyrings/elasticsearch-keyring.gpg
    wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg

    # Add the 8.x APT repo
    echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] \
https://artifacts.elastic.co/packages/8.x/apt stable main" \
        | tee /etc/apt/sources.list.d/elastic-8.x.list > /dev/null

    apt-get update -q
}

# ── Elasticsearch ──────────────────────────────────────────────────────────────
install_elasticsearch() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing Elasticsearch 8.x"
    echo "════════════════════════════════════════════════════════════"

    _elastic_add_repo
    apt-get install -y elasticsearch

    echo "▶  Writing /etc/elasticsearch/elasticsearch.yml..."
    cat > /etc/elasticsearch/elasticsearch.yml <<ESCONF
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch

cluster.name: elasticsearch-local
node.name: node-1

# Listen on all interfaces; UFW restricts access to private subnets only.
network.host: 0.0.0.0
http.port: ${ES_PORT}
discovery.type: single-node

indices.query.bool.max_clause_count: 32768


# Disable TLS and auth for local/LAN dev use
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
xpack.security.transport.ssl.enabled: false
xpack.security.http.ssl.enabled: false
ESCONF

    echo "▶  Setting JVM heap to 8 GB..."
    mkdir -p /etc/elasticsearch/jvm.options.d
    cat > /etc/elasticsearch/jvm.options.d/heap.options <<'JVMCONF'
-Xms8g
-Xmx8g
JVMCONF

    # Firewall: allow only private subnets, deny everything else.
    _ufw_allow_port "${ES_PORT}" "Elasticsearch"

    # Reload systemd in case the unit was just installed, then enable & start.
    /bin/systemctl daemon-reload
    systemctl enable elasticsearch.service
    systemctl restart elasticsearch.service
    _register_panel_service elasticsearch
    systemctl status elasticsearch --no-pager

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  Elasticsearch 8.x installed."
    echo "   API  : http://<server-ip>:${ES_PORT}"
    echo "   Logs : /var/log/elasticsearch/"
    echo "   Allow: ${ALLOWED_SUBNETS[*]}"
    echo ""
    echo "   Test : curl http://127.0.0.1:${ES_PORT}"
    echo "   Tip  : Install Kibana separately for the UI dashboard."
    echo "   Note : If elastic cannot start, try to disable SELinux or use a stronger machine."
    echo "════════════════════════════════════════════════════════════"
}

# ── Kibana ─────────────────────────────────────────────────────────────────────
install_kibana() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing Kibana 8.x"
    echo "════════════════════════════════════════════════════════════"

    _elastic_add_repo
    apt-get install -y kibana

    echo "▶  Writing /etc/kibana/kibana.yml..."
    cat > /etc/kibana/kibana.yml <<KCONF
server.port: ${KIBANA_PORT}
# Listen on all interfaces; UFW restricts access to private subnets only.
server.host: "0.0.0.0"
elasticsearch.hosts: ["http://127.0.0.1:${ES_PORT}"]
KCONF

    # Firewall: allow only private subnets, deny everything else.
    _ufw_allow_port "${KIBANA_PORT}" "Kibana"

    /bin/systemctl daemon-reload
    systemctl enable kibana.service
    systemctl restart kibana.service
    _register_panel_service kibana
    systemctl status kibana --no-pager

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  Kibana 8.x installed."
    echo "   UI   : http://<server-ip>:${KIBANA_PORT}"
    echo "   Allow: ${ALLOWED_SUBNETS[*]}"
    echo ""
    echo "   Note : Elasticsearch must be running for Kibana to connect."
    echo "   Tip  : Check kibana version: /usr/share/kibana/bin/kibana -V"
    echo "════════════════════════════════════════════════════════════"
}

# Backwards-compatible alias (installs both)
install_elastic_kibana() {
    install_elasticsearch
    install_kibana
}

uninstall_elasticsearch() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Removing Elasticsearch"
    echo "════════════════════════════════════════════════════════════"
    systemctl disable --now elasticsearch 2>/dev/null || true
    apt-get purge -y elasticsearch 2>/dev/null || true
    apt-get autoremove -y || true
    rm -rf /var/lib/elasticsearch /var/log/elasticsearch /etc/elasticsearch
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
