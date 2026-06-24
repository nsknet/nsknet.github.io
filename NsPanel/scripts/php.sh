#!/usr/bin/env bash
# php.sh — PHP-FPM (Ubuntu 22.04 / 24.04) via the ondrej/php PPA

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


# Version may be overridden by the panel via the PHP_VERSION env var (e.g. "8.2").
PHP_VERSION="${PHP_VERSION:-8.3}"

install_php() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing PHP-FPM ${PHP_VERSION}"
    echo "════════════════════════════════════════════════════════════"

    export DEBIAN_FRONTEND=noninteractive

    # ── ondrej/php PPA (provides current PHP on 22.04 and 24.04) ──────────────
    echo "▶  Adding ondrej/php PPA..."
    apt-get update -q
    apt-get install -y software-properties-common ca-certificates
    add-apt-repository -y ppa:ondrej/php
    apt-get update -q

    # ── PHP-FPM + the extensions a typical web app needs ─────────────────────
    echo "▶  Installing PHP ${PHP_VERSION} and common extensions..."
    apt-get install -y \
        "php${PHP_VERSION}-fpm" \
        "php${PHP_VERSION}-cli" \
        "php${PHP_VERSION}-common" \
        "php${PHP_VERSION}-opcache" \
        "php${PHP_VERSION}-mysql" \
        "php${PHP_VERSION}-pgsql" \
        "php${PHP_VERSION}-gd" \
        "php${PHP_VERSION}-curl" \
        "php${PHP_VERSION}-mbstring" \
        "php${PHP_VERSION}-xml" \
        "php${PHP_VERSION}-zip" \
        "php${PHP_VERSION}-bcmath" \
        "php${PHP_VERSION}-intl"

    local fpm_service="php${PHP_VERSION}-fpm"
    local pool_conf="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
    local sock="/run/php/php${PHP_VERSION}-fpm.sock"

    # Ubuntu's default pool already runs as www-data and listens on the unix
    # socket below; make the key bits explicit so nginx (also www-data) can talk
    # to it immediately.
    if [ -f "$pool_conf" ]; then
        echo "▶  Tuning pool (${pool_conf})..."
        sed -i \
            -e "s|^user = .*|user = www-data|" \
            -e "s|^group = .*|group = www-data|" \
            -e "s|^listen = .*|listen = ${sock}|" \
            -e "s|^;\?listen.owner = .*|listen.owner = www-data|" \
            -e "s|^;\?listen.group = .*|listen.group = www-data|" \
            -e "s|^;\?listen.mode = .*|listen.mode = 0660|" \
            "$pool_conf"
    fi

    systemctl enable "$fpm_service"
    systemctl restart "$fpm_service"
    systemctl status "$fpm_service" --no-pager || true
    _register_panel_service "$fpm_service"

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  PHP-FPM ${PHP_VERSION} installed."
    "php${PHP_VERSION}" -v | head -n1 || true
    echo "   FPM service : ${fpm_service}"
    echo "   FPM socket  : ${sock}"
    echo "   Pool user   : www-data"
    echo "   In nginx:   fastcgi_pass unix:${sock};"
    echo "════════════════════════════════════════════════════════════"
}

uninstall_php() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Removing PHP-FPM ${PHP_VERSION}"
    echo "════════════════════════════════════════════════════════════"
    systemctl disable --now "php${PHP_VERSION}-fpm" 2>/dev/null || true
    apt-get purge -y "php${PHP_VERSION}-*" 2>/dev/null || true
    apt-get autoremove -y || true
    _unregister_panel_service "php${PHP_VERSION}-fpm"
    echo "✔  PHP-FPM ${PHP_VERSION} removed."
}
