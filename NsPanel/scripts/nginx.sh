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

include /usr/share/nginx/modules/*.conf;

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

# ── Certbot (Let's Encrypt) ───────────────────────────────────────────────────
install_certbot() {
    echo "▶  Installing certbot..."
    apt-get install -y certbot python3-certbot-nginx

    # Auto-renew twice daily (standard recommendation)
    systemctl enable --now snap.certbot.renew.timer 2>/dev/null || \
        (crontab -l 2>/dev/null; echo "0 0,12 * * * certbot renew --quiet") | crontab -

    echo "✔  Certbot installed. Run: certbot --nginx -d your-domain.com"
}

install_ssl_domain() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Setup HTTPS with Let's Encrypt"
    echo "════════════════════════════════════════════════════════════"
    read -rp "  Domain name (e.g. example.com): " domain

    # Accept bare domain and add www
    domain="${domain#www.}"
    certbot --nginx --non-interactive --agree-tos --register-unsafely-without-email \
        -d "$domain" -d "www.$domain"

    echo ""
    echo "✔  SSL certificate issued for ${domain}."
}

# ── Add Nginx site ─────────────────────────────────────────────────────────────
add_nginx_site() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Add New Nginx Site"
    echo "════════════════════════════════════════════════════════════"

    # --- Step 1: access method ---
    echo ""
    echo "  How is this site accessed?"
    echo "   1) Port  (random port, no domain)"
    echo "   2) Domain"
    read -rp "  Choice [1/2]: " access_choice

    local service_name server_name external_port use_domain=false

    if [[ "$access_choice" == "2" ]]; then
        use_domain=true
        read -rp "  Domain (e.g. example.com): " server_name
        service_name="$server_name"
    else
        read -rp "  Service name (no spaces): " service_name
        server_name="_"
        external_port=$(( RANDOM % 45000 + 5000 ))
        echo "  Assigned port: ${external_port}"
    fi

    # --- Step 2: backend type ---
    echo ""
    echo "  Backend type:"
    echo "   1) Proxy to existing local port"
    echo "   2) Static HTML files"
    echo "   3) New .NET Core service"
    read -rp "  Choice [1/2/3]: " backend_choice

    local internal_port internal_address dll_name is_static=false is_dotnet=false

    case "$backend_choice" in
        1)
            read -rp "  Local port or address (e.g. 5555 or http://127.0.0.1:5555): " raw
            if [[ "$raw" =~ ^[0-9]+$ ]]; then
                internal_port="$raw"
                internal_address="http://127.0.0.1:${raw}"
            else
                internal_address="$raw"
            fi
            ;;
        2)
            is_static=true
            ;;
        3)
            is_dotnet=true
            read -rp "  DLL name (without .dll): " dll_name
            dll_name="${dll_name%.dll}"

            if [[ "$use_domain" == false ]]; then
                internal_port=$(( external_port - 1 ))
            else
                internal_port=$(( RANDOM % 45000 + 5000 ))
            fi
            echo "  Internal .NET port: ${internal_port}"
            internal_address="http://127.0.0.1:${internal_port}"
            ;;
    esac

    # --- Create directories ---
    mkdir -p /var/www/nginx/sites/"$service_name"/{public,logs,data}

    # --- Write nginx config ---
    local conf_path
    if [[ "$use_domain" == true ]]; then
        conf_path="/var/www/nginx/conf.d/${service_name}.conf"
    else
        conf_path="/var/www/nginx/conf.d/${service_name}-port.conf"
    fi

    echo "▶  Writing ${conf_path}..."

    if [[ "$is_static" == true ]]; then
        _write_static_conf "$conf_path" "$service_name" "$server_name" \
            "$use_domain" "${external_port:-}"
        _write_sample_html "$service_name" "$server_name"
    else
        _write_proxy_conf "$conf_path" "$service_name" "$server_name" \
            "$internal_address" "$use_domain" "${external_port:-}"
    fi

    # --- .NET service ---
    if [[ "$is_dotnet" == true ]]; then
        _create_dotnet_service "$service_name" "$dll_name" "$internal_port"
    fi

    # --- Permissions: apply AFTER files are in place so ACLs cover everything.
    _setup_site_permissions "/var/www/nginx/sites/${service_name}"

    # --- Open port in firewall ---
    if [[ "$use_domain" == false ]] && command -v ufw &>/dev/null; then
        ufw allow "${external_port}/tcp" comment "${service_name}"
    fi

    # --- Reload nginx ---
    if nginx -t 2>&1; then
        systemctl reload nginx
    else
        echo "✗  nginx config test failed — site NOT activated."
        return 1
    fi

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  Site '${service_name}' created."
    if [[ "$use_domain" == true ]]; then
        echo "   URL    : http://${server_name}"
    else
        echo "   URL    : http://YOUR_IP:${external_port}"
    fi
    echo "   Files  : /var/www/nginx/sites/${service_name}/public/"
    echo "   Config : ${conf_path}"
    echo ""
    echo "   ℹ  To let a dev upload via SFTP/WinSCP, add them to the www-data group:"
    echo "        sudo usermod -aG www-data <username>"
    echo "      Then have them log out and back in."
    echo "════════════════════════════════════════════════════════════"
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

# --- Helper: proxy nginx block ---
_write_proxy_conf() {
    local conf="$1" name="$2" sname="$3" target="$4" domain="$5" port="$6"
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

    error_log  /var/www/nginx/log/${name}-error.log warn;
    access_log /var/www/nginx/log/${name}-access.log main;

    location / {
        proxy_pass ${target};
        proxy_redirect          off;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
        proxy_connect_timeout 60s;
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
_deploy_sample_dotnet() {
    local name="$1" dll="$2"
    local public_dir="/var/www/nginx/sites/${name}/public"
    local tar_local="${SCRIPT_DIR:-}/samples_scripts/SampleBlankSite.tar"
    local tar_dest="${public_dir}/SampleBlankSite.tar"

    echo "▶  Deploying sample .NET site as '${dll}.dll'..."

    if [[ -n "${SCRIPT_DIR:-}" && -f "$tar_local" ]]; then
        echo "   Using local SampleBlankSite.tar..."
        cp "$tar_local" "$tar_dest"
    else
        echo "   Downloading SampleBlankSite.tar..."
        wget -q "nsknet.github.io/SampleBlankSite.tar" -O "$tar_dest"
    fi

    tar -xf "$tar_dest" -C "$public_dir"
    rm -f "$tar_dest"

    # Rename every SampleBlankSite.* → dll.* (handles .dll, .pdb, .deps.json,
    # .runtimeconfig.json, and the native ELF binary with no extension)
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

    _deploy_sample_dotnet "$name" "$dll"

    echo "▶  Enabling and starting ${name} service..."
    systemctl daemon-reload
    systemctl enable "/var/www/services/${name}.service"
    systemctl start "${name}" || echo "  (start failed — check logs, then restart)"
}

# ── Panel: non-interactive entry points ───────────────────────────────────────
# Called by the web panel as: bash ubuntu.sh <function> <args...>
# These functions are fully non-interactive and write an info.yml that the
# Python panel uses to discover and display the site.

# add_static_site <name> <kind:port|domain> <value>
add_static_site() {
    local name="$1" kind="$2" value="$3"
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
        echo "✗  nginx config test failed — site not activated." >&2
        return 1
    fi
    echo "✔  Static site '${name}' ready."
}

# add_proxy_site <name> <kind:port|domain> <value> <target>
add_proxy_site() {
    local name="$1" kind="$2" value="$3" target="$4"
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
        echo "✗  nginx config test failed — site not activated." >&2
        return 1
    fi
    echo "✔  Proxy site '${name}' ready."
}

# add_dotnet_site <name> <kind:port|domain> <value> <dll> <internal_port> [aspnetcore_env]
add_dotnet_site() {
    local name="$1" kind="$2" value="$3" dll="${4%.dll}" internal_port="$5" aspnetcore_env="${6:-Production}"
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
        echo "✗  nginx config test failed — check above." >&2
        return 1
    fi
    echo "✔  .NET site '${name}' ready. Service registered in /var/www/services/."
}

# ── WordPress + phpMyAdmin ─────────────────────────────────────────────────────
install_wordpress_phpmyadmin() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Install WordPress & phpMyAdmin"
    echo "════════════════════════════════════════════════════════════"
    read -rp "  Domain name: " domain

    local site_dir="/var/www/nginx/sites/${domain}/public"
    mkdir -p "$site_dir"

    echo "▶  Downloading WordPress..."
    wget -q https://wordpress.org/latest.tar.gz -O /tmp/wp.tar.gz
    tar -xzf /tmp/wp.tar.gz -C /tmp
    cp -r /tmp/wordpress/. "$site_dir/"
    rm -rf /tmp/wordpress /tmp/wp.tar.gz

    echo "▶  Downloading phpMyAdmin..."
    local pma_ver="5.2.1"
    wget -q "https://files.phpmyadmin.net/phpMyAdmin/${pma_ver}/phpMyAdmin-${pma_ver}-english.tar.gz" -O /tmp/pma.tar.gz
    mkdir -p "$site_dir/phpMyAdmin"
    tar -xzf /tmp/pma.tar.gz -C /tmp
    cp -r "/tmp/phpMyAdmin-${pma_ver}-english/." "$site_dir/phpMyAdmin/"
    mkdir -p "$site_dir/phpMyAdmin/tmp"
    rm -rf "/tmp/phpMyAdmin-${pma_ver}-english" /tmp/pma.tar.gz

    # phpMyAdmin/tmp needs to be writable by php-fpm (www-data) — ACLs already
    # handle this since the parent site_dir is set up below, but make it
    # explicit so php-fpm can write session/cache files immediately.
    _setup_site_permissions "/var/www/nginx/sites/${domain}"

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  WordPress & phpMyAdmin installed."
    echo "   WordPress : http://${domain}"
    echo "   phpMyAdmin: http://${domain}/phpMyAdmin"
    echo "   Files     : ${site_dir}"
    echo "════════════════════════════════════════════════════════════"
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
