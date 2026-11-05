#!/usr/bin/env bash
# nginx.sh — NGINX installation and site management (Ubuntu 24.04+)

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail

# ── Install NGINX ──────────────────────────────────────────────────────────────
install_nginx() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing NGINX"
    echo "════════════════════════════════════════════════════════════"

    apt-get update -q
    apt-get install -y nginx acl

    systemctl enable nginx
    systemctl start nginx
    _register_panel_service nginx

    echo ""
    echo "▶  Creating directory structure..."
    mkdir -p /var/www/nginx/{log,conf.d,sites}

    echo "▶  Writing optimised nginx.conf..."
    cp -n /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak 2>/dev/null || true

    cat > /etc/nginx/nginx.conf <<'NGINX_CONF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;

include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    # --- Basics ---
    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    types_hash_max_size 2048;
    server_tokens       off;

    # --- Timeouts ---
    client_body_timeout   12;
    client_header_timeout 12;
    send_timeout          10;

    # --- Buffers ---
    client_body_buffer_size      16k;
    client_header_buffer_size    1k;
    client_max_body_size         64m;
    large_client_header_buffers  4 4k;

    # --- MIME ---
    include      /etc/nginx/mime.types;
    default_type application/octet-stream;

    # --- Logging ---
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" rt=$request_time '
                    'ua="$upstream_addr" us="$upstream_status" ut="$upstream_response_time"';

    access_log /var/www/nginx/log/global-access.log main;
    error_log  /var/www/nginx/log/global-error.log warn;

    # --- Gzip ---
    gzip              on;
    gzip_static       on;
    gzip_vary         on;
    gzip_proxied      any;
    gzip_comp_level   5;
    gzip_buffers      16 8k;
    gzip_http_version 1.1;
    gzip_min_length   256;
    gzip_types
        text/plain text/css text/xml text/javascript
        application/json application/javascript application/xml+rss
        application/vnd.ms-fontobject application/x-font-ttf
        font/opentype image/svg+xml;

    # --- Virtual hosts ---
    include /var/www/nginx/conf.d/*.conf;
    include /etc/nginx/conf.d/*.conf;

    # Default: reject unknown hosts
    server {
        listen 80 default_server;
        server_name _;
        return 444;
    }
}
NGINX_CONF

    echo "▶  Creating default error pages..."
    cat > /usr/share/nginx/html/404.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>404 — Not Found</title>
<style>body{font-family:system-ui,sans-serif;text-align:center;padding:4rem;background:#09090b;color:#a1a1aa}
h1{color:#f4f4f5;font-size:3rem;margin-bottom:.5rem}p{color:#71717a}</style></head>
<body><h1>404</h1><p>Page not found.</p></body></html>
HTML

    echo "▶  Testing configuration..."
    if nginx -t 2>&1; then
        systemctl reload nginx
        echo "▶  NGINX reloaded successfully."
    else
        echo "✗  Configuration test failed — check above output."
        return 1
    fi

    echo "▶  Configuring UFW firewall..."
    if command -v ufw &>/dev/null; then
        ufw allow 'Nginx HTTP'  comment 'NGINX HTTP'
        ufw allow 'Nginx HTTPS' comment 'NGINX HTTPS'
    fi

    # Base ownership for the whole tree; per-site permissions are applied by
    # _setup_site_permissions whenever a new site is added.
    chown -R www-data:www-data /var/www/nginx
    chmod 755 /var/www/nginx /var/www/nginx/log /var/www/nginx/conf.d /var/www/nginx/sites

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  NGINX installed."
    echo "   Configs : /var/www/nginx/conf.d/"
    echo "   Logs    : /var/www/nginx/log/"
    echo "════════════════════════════════════════════════════════════"
}

# ── Site permission helper ────────────────────────────────────────────────────
# Applies the recommended group-writable + setgid + Default ACL scheme to a
# site directory so:
#   • www-data (nginx, php-fpm, dotnet services) can read AND write.
#   • Any user in the www-data group (devs) can upload via SFTP/SCP.
#   • Files/dirs created *later* — by SFTP, by WordPress, by tar extraction,
#     by .NET writing logs — automatically inherit the correct group and
#     write permissions, so this never breaks over time.
#
# Idempotent: safe to call multiple times on the same directory.
_setup_site_permissions() {
    local site_dir="$1"
    [[ -d "$site_dir" ]] || { echo "  (skip permissions: $site_dir does not exist)"; return 0; }

    echo "▶  Applying site permissions to ${site_dir}..."

    # 1. Ownership: always www-data:www-data so the web stack works.
    chown -R www-data:www-data "$site_dir"

    # 2. setgid on dirs (2775) + group-writable files (664).
    #    setgid ensures new files/dirs inherit the www-data group.
    find "$site_dir" -type d -exec chmod 2775 {} \;
    find "$site_dir" -type f -exec chmod 664 {} \;

    # 3. ACLs — only if the `acl` tool is available (installed in install_nginx,
    #    but we don't want to hard-fail if a panel call hits this on an older
    #    box that hasn't been re-provisioned yet).
    if command -v setfacl &>/dev/null; then
        # Current ACL: www-data group gets rwx on everything that exists now.
        setfacl -R  -m u::rwx,g:www-data:rwx,o::rx "$site_dir"
        # Default ACL: everything created in the future inherits the same.
        # This is the bit that makes the setup survive umask quirks from
        # WinSCP, FileZilla, dotnet writing logs, WordPress uploads, etc.
        setfacl -R -d -m u::rwx,g:www-data:rwx,o::rx "$site_dir"
    else
        echo "  ⚠  setfacl not found — run install_nginx (or 'apt-get install acl') to enable Default ACL."
    fi
}

# register_site_ssl <name> <domain>
# Issues a Let's Encrypt certificate via the certbot nginx plugin (installing
# certbot on first use) and links the live cert into the site's ssl/ dir.
# Best-effort: callers guard the call with `|| echo` so a validation failure
# (bad DNS, port 80 unreachable) never rolls back an otherwise healthy site.
register_site_ssl() {
    local name="$1" domain="$2"
    local ssl_dir="/var/www/nginx/sites/${name}/ssl"

    echo "▶  Requesting Let's Encrypt certificate for ${domain}..."

    if ! command -v certbot &>/dev/null; then
        echo "▶  Installing certbot (first run)..."
        apt-get update -q
        apt-get install -y certbot python3-certbot-nginx
        # The apt package ships certbot.timer (twice-daily renew); no cron entry needed.
        systemctl enable --now certbot.timer 2>/dev/null || true
    elif ! certbot plugins --non-interactive 2>/dev/null | grep -q nginx; then
        # certbot exists (e.g. installed standalone earlier) but lacks the
        # nginx authenticator/installer plugin.
        echo "▶  certbot found but nginx plugin missing — installing python3-certbot-nginx..."
        apt-get install -y python3-certbot-nginx
        if ! certbot plugins --non-interactive 2>/dev/null | grep -q nginx; then
            echo "✗  nginx plugin still unavailable (certbot may be a snap build without it)." >&2
            echo "   Try: snap install certbot --classic  (or remove the old certbot and rerun)" >&2
            return 1
        fi
    fi

    # The nginx plugin finds the server block by server_name, validates over
    # HTTP-01, then rewrites the vhost for 443 + HTTP→HTTPS redirect.
    if ! certbot --nginx --non-interactive --agree-tos --register-unsafely-without-email \
        --redirect -d "$domain"; then
        echo "✗  certbot failed for ${domain} — check that DNS points to this server and port 80 is reachable." >&2
        return 1
    fi

    # www.<domain> is best-effort — only attempt it when the record actually
    # resolves, so a missing www record doesn't produce an alarming (but
    # harmless) certbot authentication failure in the logs.
    if getent hosts "www.${domain}" >/dev/null 2>&1; then
        certbot --nginx --non-interactive --agree-tos --register-unsafely-without-email \
            --expand -d "$domain" -d "www.${domain}" \
            || echo "  (www.${domain} skipped — validation failed)"
    else
        echo "  (www.${domain} skipped — no DNS record)"
    fi

    # Convenience symlinks: certbot renews in place under /etc/letsencrypt/live,
    # so these links always point at the current certificate.
    local live="/etc/letsencrypt/live/${domain}"
    if [[ -d "$live" ]]; then
        mkdir -p "$ssl_dir"
        ln -sfn "${live}/fullchain.pem" "${ssl_dir}/fullchain.pem"
        ln -sfn "${live}/privkey.pem"   "${ssl_dir}/privkey.pem"
        echo "▶  Certificate linked at ${ssl_dir}/"
    fi

    echo "✔  HTTPS enabled for ${domain}."
}

# --- Helper: static nginx block ---
_write_static_conf() {
    local conf="$1" name="$2" sname="$3" domain="$4" port="$5"
    local listen_line
    if [[ "$domain" == true ]]; then
        listen_line="listen 80; server_name ${sname};"
    else
        listen_line="listen ${port}; server_name _;"
    fi

    cat > "$conf" <<NGINX
server {
    client_max_body_size 200M;
    ${listen_line}
    root /var/www/nginx/sites/${name}/public;

    error_log  /var/www/nginx/log/${name}-error.log warn;
    access_log /var/www/nginx/log/${name}-access.log main;

    index index.html index.htm;

    location / {
        try_files \$uri \$uri.html \$uri/ \$uri/index.html =404;
    }

    location ~ /\. { deny all; }

    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
}
NGINX

    if [[ "$domain" == true ]]; then
        cat >> "$conf" <<NGINX

server {
    listen 80;
    server_name www.${sname};
    return 301 \$scheme://${sname}\$request_uri;
}
NGINX
    fi
}

# --- Helper: http-level map for WebSocket-aware Connection header ---
# Sends "Connection: upgrade" only when the client asked for an upgrade and
# "close" otherwise. Lives in conf.d (included inside http {}) so it also
# reaches servers whose nginx.conf predates this helper. Idempotent.
_ensure_connection_upgrade_map() {
    local map_conf="/var/www/nginx/conf.d/00-connection-upgrade.conf"
    [[ -f "$map_conf" ]] && return 0
    mkdir -p "$(dirname "$map_conf")"
    cat > "$map_conf" <<'NGINX'
# Managed by NsPanel (nginx.sh) — used by proxy sites as $connection_upgrade.
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
NGINX
}

# --- Helper: proxy nginx block ---
_write_proxy_conf() {
    local conf="$1" name="$2" sname="$3" target="$4" domain="$5" port="$6"
    local listen_line
    _ensure_connection_upgrade_map
    if [[ "$domain" == true ]]; then
        listen_line="listen 80; server_name ${sname};"
    else
        listen_line="listen ${port}; server_name _;"
    fi

    cat > "$conf" <<NGINX
server {
    client_max_body_size 200M;
    ${listen_line}

    error_log  /var/www/nginx/log/${name}-error.log warn;
    access_log /var/www/nginx/log/${name}-access.log main;

    location / {
        proxy_pass ${target};
        proxy_redirect          off;
        proxy_set_header Host              \$http_host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        # Stream responses straight through (SSE / token streaming, e.g. LLM
        # APIs); buffering would hold chunks back until the buffer fills.
        proxy_buffering off;
        proxy_cache     off;

        # Long-running requests (LLM generation, reports) must not hit a 504.
        proxy_connect_timeout 60s;
        proxy_read_timeout    900s;
        proxy_send_timeout    900s;
    }

    error_page 500 502 503 504 /50x.html;
}
NGINX

    if [[ "$domain" == true ]]; then
        cat >> "$conf" <<NGINX

server {
    listen 80;
    server_name www.${sname};
    return 301 \$scheme://${sname}\$request_uri;
}
NGINX
    fi
}

# --- Helper: write sample index.html ---
_write_sample_html() {
    local name="$1" sname="$2"
    cat > "/var/www/nginx/sites/${name}/public/index.html" <<HTML
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>${sname}</title>
<style>body{font-family:system-ui,sans-serif;max-width:650px;margin:4rem auto;padding:0 1rem;color:#374151}
h1{font-size:2rem;font-weight:700}</style></head>
<body><h1>${sname}</h1><p>Upload your files to <code>/var/www/nginx/sites/${name}/public/</code></p></body></html>
HTML
}

# --- Helper: deploy SampleBlankSite.tar and rename to the target dll name ---
SAMPLE_DOTNET_URL="https://nsknet.github.io/SampleBlankSite.tar"

_deploy_sample_dotnet() {
    local name="$1" dll="$2"
    local public_dir="/var/www/nginx/sites/${name}/public"
    # The panel runs from a clone of this repo, so the tarball is normally on disk
    # already (and matches the checked-out branch). Download only as a fallback.
    local local_tar
    local_tar="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/SampleBlankSite.tar"
    local tar_src="$local_tar" tmp_tar=""

    echo "▶  Deploying sample .NET site as '${dll}.dll'..."
    mkdir -p "$public_dir"

    if [[ ! -s "$local_tar" ]]; then
        tmp_tar="$(mktemp --suffix=.tar)"
        echo "   Downloading ${SAMPLE_DOTNET_URL}..."
        if ! wget -q "$SAMPLE_DOTNET_URL" -O "$tmp_tar" || [[ ! -s "$tmp_tar" ]]; then
            rm -f "$tmp_tar"
            echo "✗  Could not download the sample site from ${SAMPLE_DOTNET_URL}" >&2
            return 1
        fi
        tar_src="$tmp_tar"
    fi

    if ! tar --no-same-owner -xf "$tar_src" -C "$public_dir"; then
        [[ -n "$tmp_tar" ]] && rm -f "$tmp_tar"
        echo "✗  Could not extract ${tar_src} into ${public_dir}" >&2
        return 1
    fi
    [[ -n "$tmp_tar" ]] && rm -f "$tmp_tar"

    # Rename every SampleBlankSite.* → dll.* (.dll, .deps.json,
    # .runtimeconfig.json, .staticwebassets.endpoints.json, ...)
    local src
    for src in "${public_dir}/SampleBlankSite"*; do
        [[ -e "$src" ]] || continue
        local suffix="${src#${public_dir}/SampleBlankSite}"   # e.g. ".dll" or ""
        mv "$src" "${public_dir}/${dll}${suffix}"
    done

    # Update assembly name inside deps.json
    local deps="${public_dir}/${dll}.deps.json"
    [[ -f "$deps" ]] && sed -i "s/SampleBlankSite/${dll}/g" "$deps"

    # Note: ownership/ACLs are applied later by _setup_site_permissions, which
    # the caller (_create_dotnet_service / add_dotnet_site / add_nginx_site)
    # invokes after this returns. We intentionally don't chown here so the
    # ACL pass covers freshly-extracted tar contents in one place.
    echo "▶  Sample site deployed."
}

# --- Helper: create systemd unit for .NET ---
_create_dotnet_service() {
    local name="$1" dll="$2" port="$3" aspnetcore_env="${4:-Production}"

    # www-data's HOME is /var/www but that dir is root-owned by default.
    # .NET writes first-run sentinel files to $HOME/.dotnet — fix it once here
    # so all dotnet services on this machine share a single writable location.
    mkdir -p /var/www/.dotnet
    chown www-data:www-data /var/www/.dotnet

    # Deploy the placeholder app first so a failed download doesn't leave a
    # unit behind that crash-loops on a missing DLL.
    _deploy_sample_dotnet "$name" "$dll" || return 1

    mkdir -p /var/www/services
    cat > "/var/www/services/${name}.service" <<UNIT
[Unit]
Description=${name} .NET Core service
After=network.target

[Service]
WorkingDirectory=/var/www/nginx/sites/${name}/public
ExecStart=/usr/bin/dotnet /var/www/nginx/sites/${name}/public/${dll}.dll
Restart=always
RestartSec=10
KillSignal=SIGINT
SyslogIdentifier=${name}
User=www-data
Environment=ASPNETCORE_ENVIRONMENT=${aspnetcore_env}
Environment=DOTNET_PRINT_TELEMETRY_MESSAGE=false
Environment=ASPNETCORE_URLS=http://localhost:${port}

[Install]
WantedBy=multi-user.target
UNIT

    echo "▶  Enabling and starting ${name} service..."
    systemctl daemon-reload
    systemctl enable "/var/www/services/${name}.service"
    systemctl start "${name}" || echo "  (start failed — check logs, then restart)"
}

# ── Panel: non-interactive entry points ───────────────────────────────────────
# Called by the web panel (core/bash_invoker.py) as: source nginx.sh && <function> <args...>
# These functions are fully non-interactive and write an info.yml that the
# Python panel uses to discover and display the site.

# add_static_site <name> <kind:port|domain> <value> [ssl]
add_static_site() {
    local name="$1" kind="$2" value="$3" want_ssl="${4:-}"
    local site_dir="/var/www/nginx/sites/${name}"
    echo "▶  Creating static site '${name}' [${kind}:${value}]..."

    mkdir -p "${site_dir}"/{public,logs,data}

    local conf server_name
    if [[ "$kind" == "domain" ]]; then
        conf="/var/www/nginx/conf.d/${name}.conf"
        server_name="$value"
        _write_static_conf "$conf" "$name" "$server_name" true ""
    else
        conf="/var/www/nginx/conf.d/${name}-port.conf"
        server_name="_"
        _write_static_conf "$conf" "$name" "$server_name" false "$value"
        command -v ufw &>/dev/null && ufw allow "${value}/tcp" comment "${name}"
    fi

    _write_sample_html "$name" "${server_name}"

    cat > "${site_dir}/info.yml" <<YAML
name: ${name}
type: static
created_at: "$(date -u +'%Y-%m-%d %H:%M UTC')"
access:
  kind: ${kind}
  value: "${value}"
paths:
  public: ${site_dir}/public
  nginx_conf: ${conf}
  log_dir: /var/www/nginx/log
YAML

    _setup_site_permissions "${site_dir}"

    if nginx -t 2>&1; then
        systemctl reload nginx
    else
        mv -f "$conf" "${conf}.failed"
        echo "✗  nginx config test failed — vhost moved to ${conf}.failed, site not activated." >&2
        return 1
    fi

    if [[ "$kind" == "domain" && "$want_ssl" == "ssl" ]]; then
        register_site_ssl "$name" "$value" \
            || echo "⚠  SSL setup failed — site is live over HTTP; fix DNS and retry certbot later." >&2
    fi

    echo "✔  Static site '${name}' ready."
}

# add_proxy_site <name> <kind:port|domain> <value> <target> [ssl]
add_proxy_site() {
    local name="$1" kind="$2" value="$3" target="$4" want_ssl="${5:-}"
    local site_dir="/var/www/nginx/sites/${name}"
    echo "▶  Creating proxy site '${name}' → ${target} [${kind}:${value}]..."

    mkdir -p "${site_dir}"/{public,logs,data}

    local conf server_name
    if [[ "$kind" == "domain" ]]; then
        conf="/var/www/nginx/conf.d/${name}.conf"
        server_name="$value"
        _write_proxy_conf "$conf" "$name" "$server_name" "$target" true ""
    else
        conf="/var/www/nginx/conf.d/${name}-port.conf"
        server_name="_"
        _write_proxy_conf "$conf" "$name" "$server_name" "$target" false "$value"
        command -v ufw &>/dev/null && ufw allow "${value}/tcp" comment "${name}"
    fi

    cat > "${site_dir}/info.yml" <<YAML
name: ${name}
type: proxy
created_at: "$(date -u +'%Y-%m-%d %H:%M UTC')"
access:
  kind: ${kind}
  value: "${value}"
backend:
  proxy_target: "${target}"
paths:
  public: ${site_dir}/public
  nginx_conf: ${conf}
  log_dir: /var/www/nginx/log
YAML

    _setup_site_permissions "${site_dir}"

    if nginx -t 2>&1; then
        systemctl reload nginx
    else
        mv -f "$conf" "${conf}.failed"
        echo "✗  nginx config test failed — vhost moved to ${conf}.failed, site not activated." >&2
        return 1
    fi

    if [[ "$kind" == "domain" && "$want_ssl" == "ssl" ]]; then
        register_site_ssl "$name" "$value" \
            || echo "⚠  SSL setup failed — site is live over HTTP; fix DNS and retry certbot later." >&2
    fi

    echo "✔  Proxy site '${name}' ready."
}

# add_dotnet_site <name> <kind:port|domain> <value> <dll> <internal_port> [aspnetcore_env] [ssl]
add_dotnet_site() {
    local name="$1" kind="$2" value="$3" dll="${4%.dll}" internal_port="$5" aspnetcore_env="${6:-Production}" want_ssl="${7:-}"
    local site_dir="/var/www/nginx/sites/${name}"
    local internal_addr="http://127.0.0.1:${internal_port}"
    echo "▶  Creating .NET site '${name}' (${dll}.dll → :${internal_port}) [${kind}:${value}]..."

    mkdir -p "${site_dir}"/{public,logs,data}

    local conf server_name
    if [[ "$kind" == "domain" ]]; then
        conf="/var/www/nginx/conf.d/${name}.conf"
        server_name="$value"
        _write_proxy_conf "$conf" "$name" "$server_name" "$internal_addr" true ""
    else
        conf="/var/www/nginx/conf.d/${name}-port.conf"
        server_name="_"
        _write_proxy_conf "$conf" "$name" "$server_name" "$internal_addr" false "$value"
        command -v ufw &>/dev/null && ufw allow "${value}/tcp" comment "${name}"
    fi

    cat > "${site_dir}/info.yml" <<YAML
name: ${name}
type: dotnet
created_at: "$(date -u +'%Y-%m-%d %H:%M UTC')"
access:
  kind: ${kind}
  value: "${value}"
backend:
  dll: "${dll}"
  internal_port: ${internal_port}
  aspnetcore_env: "${aspnetcore_env}"
paths:
  public: ${site_dir}/public
  nginx_conf: ${conf}
  log_dir: /var/www/nginx/log
  systemd_unit: /var/www/services/${name}.service
YAML

    _create_dotnet_service "$name" "$dll" "$internal_port" "$aspnetcore_env"

    # Apply permissions AFTER tar extraction so ACLs cover all unpacked files,
    # then the systemd-started service (running as www-data) can write logs,
    # caches, and the .dotnet sentinel dir without further intervention.
    _setup_site_permissions "${site_dir}"

    if nginx -t 2>&1; then
        systemctl reload nginx
    else
        mv -f "$conf" "${conf}.failed"
        echo "✗  nginx config test failed — vhost moved to ${conf}.failed, site not activated." >&2
        return 1
    fi

    if [[ "$kind" == "domain" && "$want_ssl" == "ssl" ]]; then
        register_site_ssl "$name" "$value" \
            || echo "⚠  SSL setup failed — site is live over HTTP; fix DNS and retry certbot later." >&2
    fi

    echo "✔  .NET site '${name}' ready. Service registered in /var/www/services/."
}

uninstall_nginx() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Removing NGINX"
    echo "════════════════════════════════════════════════════════════"
    systemctl disable --now nginx 2>/dev/null || true
    apt-get purge -y nginx nginx-common nginx-core 2>/dev/null || true
    apt-get autoremove -y || true
    _unregister_panel_service nginx
    echo "✔  NGINX removed. Site files under /var/www/nginx were left in place."
}
