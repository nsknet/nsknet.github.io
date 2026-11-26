#!/usr/bin/env bash
# nginx.sh — NGINX installation and site management (Ubuntu 22.04 / 24.04)

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail

# First line of the nginx.conf written below. When it is present the file is
# already panel-managed, so a re-install leaves it (and any hand tuning) alone.
NGINX_CONF_MARKER="# Managed by NsPanel (nginx.sh). Remove this line to let a re-install rewrite the file."

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

    _write_nginx_main_conf

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

    # Site trees belong to www-data (apps write there); per-site permissions are
    # applied by _setup_site_permissions whenever a site is added. The config and
    # log directories stay root-owned: nginx's master process (root) reads
    # conf.d and opens the log files, so a www-data-writable copy would let a
    # compromised web app inject server config or plant a symlink that root then
    # writes through.
    chown root:root /var/www/nginx
    chown -R root:root /var/www/nginx/conf.d
    chown root:adm /var/www/nginx/log
    chown www-data:www-data /var/www/nginx/sites
    chmod 755 /var/www/nginx /var/www/nginx/log /var/www/nginx/conf.d /var/www/nginx/sites

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  NGINX installed."
    echo "   Configs : /var/www/nginx/conf.d/"
    echo "   Logs    : /var/www/nginx/log/"
    echo "════════════════════════════════════════════════════════════"
}

# Write the panel's nginx.conf — once. A file that already carries
# NGINX_CONF_MARKER is left untouched, so re-running the install never clobbers
# later edits. The distribution's original is kept once, under a timestamped
# name (or the older nginx.conf.bak, if an earlier panel version made one).
# If the new file fails `nginx -t`, the previous one is put back.
_write_nginx_main_conf() {
    local conf="/etc/nginx/nginx.conf" backup prev

    if [[ -f "$conf" ]] && grep -qF "$NGINX_CONF_MARKER" "$conf"; then
        echo "▶  nginx.conf is already panel-managed — leaving it as is."
        return 0
    fi

    if [[ -f "$conf" && ! -e "${conf}.bak" ]] && ! compgen -G "${conf}.nspanel-orig-*" >/dev/null; then
        backup="${conf}.nspanel-orig-$(date -u +%Y%m%d-%H%M%S)"
        cp -p "$conf" "$backup"
        echo "▶  Original nginx.conf saved as ${backup}"
    fi

    prev="$(mktemp)"
    [[ -f "$conf" ]] && cp -p "$conf" "$prev"

    echo "▶  Writing optimised nginx.conf..."
    {
        printf '%s\n' "$NGINX_CONF_MARKER"
        cat <<'NGINX_CONF'
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
    } > "$conf"

    if ! nginx -t >/dev/null 2>&1; then
        nginx -t 2>&1 || true
        if [[ -s "$prev" ]]; then
            cp -p "$prev" "$conf"
            echo "✗  The new nginx.conf failed the config test — the previous file was restored." >&2
        else
            echo "✗  The new nginx.conf failed the config test." >&2
        fi
        rm -f "$prev"
        return 1
    fi
    rm -f "$prev"
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
    #    (chown -R does not follow symlinks, e.g. ssl/ → /etc/letsencrypt.)
    chown -R www-data:www-data "$site_dir"

    # 2. setgid on dirs (2775) + group-writable files (664).
    #    setgid ensures new files/dirs inherit the www-data group.
    find "$site_dir" -type d -exec chmod 2775 {} +
    find "$site_dir" -type f -exec chmod 664 {} +

    # 3. ACLs — only if the `acl` tool is available (installed in install_nginx,
    #    but we don't want to hard-fail if a panel call hits this on an older
    #    box that hasn't been re-provisioned yet).
    if command -v setfacl &>/dev/null; then
        # Current ACL: www-data group gets rw on everything that exists now.
        # Capital X: execute/search only on directories (and files that are
        # already executable), so site files do not all become executable.
        setfacl -R -m u::rwX,g:www-data:rwX,o::rX "$site_dir"
        # Default ACL (directories only): everything created in the future
        # inherits the same. The x here only reaches new directories — new
        # files are created without execute bits regardless.
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
#
# Optional env CERTBOT_EMAIL: the ACME account e-mail (expiry and security
# notices). Without it the account is registered without an e-mail. It only
# takes effect when certbot creates its account (first certificate on the host).
register_site_ssl() {
    local name="$1" domain="$2"
    local ssl_dir="/var/www/nginx/sites/${name}/ssl"
    local -a account=(--register-unsafely-without-email)

    if [[ -n "${CERTBOT_EMAIL:-}" ]]; then
        if [[ "$CERTBOT_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
            account=(--email "$CERTBOT_EMAIL" --no-eff-email)
        else
            log_warn "CERTBOT_EMAIL does not look like an e-mail address — registering without one."
        fi
    fi

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
    if ! certbot --nginx --non-interactive --agree-tos "${account[@]}" \
        --redirect -d "$domain"; then
        echo "✗  certbot failed for ${domain} — check that DNS points to this server and port 80 is reachable." >&2
        return 1
    fi

    # www.<domain> is best-effort — only attempt it when the record actually
    # resolves, so a missing www record doesn't produce an alarming (but
    # harmless) certbot authentication failure in the logs.
    if getent hosts "www.${domain}" >/dev/null 2>&1; then
        certbot --nginx --non-interactive --agree-tos "${account[@]}" \
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

# --- Helper: write sample index.html (never over an existing one) ---
_write_sample_html() {
    local name="$1" sname="$2"
    local index="/var/www/nginx/sites/${name}/public/index.html"
    [[ -e "$index" ]] && return 0
    cat > "$index" <<HTML
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

# The sample is a small archive of plain files. The download fallback cannot be
# checksummed (the tarball is rebuilt with every release of the sample), so
# refuse anything that is not a sane tar before a byte of it is extracted: a
# truncated or HTML error-page download, absolute or ../ paths, links, devices.
# GNU tar detects gzip/xz compression by itself, so both plain and compressed
# archives pass.
_sample_tar_is_safe() {
    local tar_file="$1" listing types
    if (( $(stat -c %s "$tar_file") > 100 * 1024 * 1024 )); then
        echo "✗  ${tar_file} is larger than 100 MB — not a sample site." >&2
        return 1
    fi
    if ! listing="$(tar -tf "$tar_file" 2>/dev/null)" || [[ -z "$listing" ]]; then
        echo "✗  ${tar_file} is not a valid tar archive." >&2
        return 1
    fi
    if grep -qvE '^[A-Za-z0-9._][A-Za-z0-9._/-]*$' <<<"$listing" \
        || grep -qE '(^|/)\.\.(/|$)' <<<"$listing"; then
        echo "✗  ${tar_file} contains unexpected paths — refusing to extract it." >&2
        return 1
    fi
    types="$(tar -tvf "$tar_file" | cut -c1 | sort -u)"
    if grep -qv '^[-d]$' <<<"$types"; then
        echo "✗  ${tar_file} contains links or special files — refusing to extract it." >&2
        return 1
    fi
}

_deploy_sample_dotnet() {
    local name="$1" dll="$2"
    local public_dir="/var/www/nginx/sites/${name}/public"
    # The panel runs from a clone of this repo, so the tarball is normally on disk
    # already (and matches the checked-out branch). Download only as a fallback.
    local local_tar
    local_tar="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/SampleBlankSite.tar"
    local tar_src="$local_tar" tmp_tar="" stage src base

    # Never overwrite an app that is already there (a retry, or files uploaded
    # before the site was registered).
    if [[ -e "${public_dir}/${dll}.dll" ]]; then
        echo "▶  ${dll}.dll already present in ${public_dir} — sample site not deployed."
        return 0
    fi

    echo "▶  Deploying sample .NET site as '${dll}.dll'..."
    mkdir -p "$public_dir"

    if [[ ! -s "$local_tar" ]]; then
        tmp_tar="$(mktemp --suffix=.tar)"
        echo "   Downloading ${SAMPLE_DOTNET_URL}..."
        if ! wget -q --timeout=60 --tries=3 -O "$tmp_tar" "$SAMPLE_DOTNET_URL" || [[ ! -s "$tmp_tar" ]]; then
            rm -f "$tmp_tar"
            echo "✗  Could not download the sample site from ${SAMPLE_DOTNET_URL}" >&2
            return 1
        fi
        tar_src="$tmp_tar"
    fi

    # Extract into a fresh private directory first, rename there, then move the
    # files into public/.
    stage="$(mktemp -d)"
    if ! _sample_tar_is_safe "$tar_src" \
        || ! tar --no-same-owner --no-same-permissions -xf "$tar_src" -C "$stage"; then
        rm -rf "$stage"
        [[ -n "$tmp_tar" ]] && rm -f "$tmp_tar"
        echo "✗  Could not extract ${tar_src}" >&2
        return 1
    fi
    [[ -n "$tmp_tar" ]] && rm -f "$tmp_tar"

    # Rename every SampleBlankSite.* → dll.* (.dll, .deps.json,
    # .runtimeconfig.json, .staticwebassets.endpoints.json, ...)
    for src in "${stage}/SampleBlankSite"*; do
        [[ -e "$src" ]] || continue
        mv "$src" "${stage}/${dll}${src#"${stage}"/SampleBlankSite}"
    done

    # Update assembly name inside deps.json
    local deps="${stage}/${dll}.deps.json"
    if [[ -f "$deps" ]]; then
        sed -i "s/SampleBlankSite/${dll}/g" "$deps"
    fi

    # Move into public/, keeping anything the user already put there.
    for src in "${stage}"/*; do
        [[ -e "$src" ]] || continue
        base="${src##*/}"
        if [[ -e "${public_dir}/${base}" ]]; then
            echo "   (kept existing ${base})"
        else
            mv "$src" "${public_dir}/"
        fi
    done
    rm -rf "$stage"

    # Note: ownership/ACLs are applied afterwards by _setup_site_permissions,
    # so the ACL pass covers the freshly-extracted files in one place.
    echo "▶  Sample site deployed."
}

# --- Helper: create, enable and start the systemd unit for a .NET site ---
_create_dotnet_service() {
    local name="$1" dll="$2" port="$3" aspnetcore_env="${4:-Production}"
    local unit="/var/www/services/${name}.service"

    # www-data's HOME is /var/www but that dir is root-owned by default.
    # .NET writes first-run sentinel files to $HOME/.dotnet — fix it once here
    # so all dotnet services on this machine share a single writable location.
    mkdir -p /var/www/.dotnet
    chown www-data:www-data /var/www/.dotnet

    mkdir -p /var/www/services
    cat > "$unit" <<UNIT
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

    if [[ ! -x /usr/bin/dotnet ]]; then
        log_warn "/usr/bin/dotnet not found — install the .NET SDK, then start ${name}."
    fi

    echo "▶  Enabling and starting ${name} service..."
    systemctl daemon-reload
    systemctl enable "$unit"
    systemctl start "${name}" || echo "  (start failed — check logs, then restart)"
}

# ── Site creation transaction ─────────────────────────────────────────────────
# Every add_*_site runs its steps through _site_create: the steps run in a
# subshell with errexit on, and if any of them fails (nginx -t, the sample
# download, UFW, systemd) everything the attempt created is removed again —
# vhost, site directory (only if this attempt created it), info.yml, log files,
# UFW rules and the systemd unit — so a retry starts clean. Pre-existing user
# content is never deleted.

# The vhost file of a site.
_site_conf_path() {
    local name="$1" kind="$2"
    if [[ "$kind" == "domain" ]]; then
        echo "/var/www/nginx/conf.d/${name}.conf"
    else
        echo "/var/www/nginx/conf.d/${name}-port.conf"
    fi
}

# The sources _ufw_allow_port opens a port to — same rule: ALLOWED_SUBNETS,
# else the private + loopback ranges. One per line.
_site_ufw_sources() {
    local -a subnets
    if [ -n "${ALLOWED_SUBNETS// /}" ]; then
        read -r -a subnets <<< "$ALLOWED_SUBNETS"
    else
        subnets=("127.0.0.0/8" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16")
    fi
    printf '%s\n' "${subnets[@]}"
}

# The sources that do NOT yet have an allow rule for <port>: the rules this
# attempt is about to add, and so the only ones a rollback may delete.
_site_new_ufw_sources() {
    local port="$1" src
    while read -r src; do
        [[ -n "$src" ]] || continue
        if ! command -v ufw >/dev/null 2>&1; then
            echo "$src"
        elif [[ "$src" == "0.0.0.0/0" ]]; then
            _ufw_has_rule "$port" "Anywhere" || echo "$src"
        else
            _ufw_has_rule "$port" "$src" || echo "$src"
        fi
    done < <(_site_ufw_sources)
}

# _site_ufw_revoke <port> <comment> <source>...
_site_ufw_revoke() {
    local port="$1" comment="$2" src label
    shift 2
    command -v ufw >/dev/null 2>&1 || return 0
    for src in "$@"; do
        label="$src"
        [[ "$src" == "0.0.0.0/0" ]] && label="Anywhere"
        _ufw_has_rule "$port" "$label" || continue
        echo "   UFW: removing ${src} → tcp/${port}"
        if [[ "$src" == "0.0.0.0/0" ]]; then
            ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
            # Older ufw only matches a rule when the comment is given too.
            _ufw_has_rule "$port" "$label" \
                && { ufw delete allow "${port}/tcp" comment "$comment" >/dev/null 2>&1 || true; }
        else
            ufw delete allow from "$src" to any port "$port" proto tcp >/dev/null 2>&1 || true
            _ufw_has_rule "$port" "$label" \
                && { ufw delete allow from "$src" to any port "$port" proto tcp comment "$comment" >/dev/null 2>&1 || true; }
        fi
    done
    return 0
}

# Open a port-mode site's port to the subnets chosen in ALLOWED_SUBNETS.
_site_open_port() {
    local name="$1" kind="$2" value="$3"
    [[ "$kind" == "port" ]] || return 0
    _ufw_allow_port "$value" "$name"
}

# Reload nginx. For a port-mode site also confirm nginx really listens on the
# port afterwards: `nginx -t` does not try to bind, and a reload whose new
# socket fails (port taken by another program) still exits 0, keeping the old
# config.
_site_reload_nginx() {
    local kind="$1" port="$2" i
    systemctl reload nginx
    [[ "$kind" == "port" ]] || return 0
    command -v ss >/dev/null 2>&1 || return 0
    for ((i = 0; i < 20; i++)); do
        if ss -ltnpH "sport = :${port}" 2>/dev/null | grep -q '"nginx"'; then
            return 0
        fi
        sleep 0.5
    done
    echo "✗  nginx is not listening on port ${port} after the reload — is the port used by another program?" >&2
    ss -ltnpH "sport = :${port}" 2>/dev/null || true
    return 1
}

# The vhost has just been written: test it before anything is started,
# enabled or opened.
_site_nginx_test() {
    local conf="$1"
    if ! nginx -t 2>&1; then
        echo "✗  nginx config test failed with ${conf} — the site was not created." >&2
        return 1
    fi
}

_site_body_static() {
    local name="$1" kind="$2" value="$3" conf="$4"
    local site_dir="/var/www/nginx/sites/${name}" server_name="_"

    mkdir -p "${site_dir}"/{public,logs,data}
    if [[ "$kind" == "domain" ]]; then
        server_name="$value"
        _write_static_conf "$conf" "$name" "$server_name" true ""
    else
        _write_static_conf "$conf" "$name" "$server_name" false "$value"
    fi
    _site_nginx_test "$conf"

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
    _site_open_port "$name" "$kind" "$value"
    _site_reload_nginx "$kind" "$value"
}

_site_body_proxy() {
    local name="$1" kind="$2" value="$3" conf="$4" target="$5"
    local site_dir="/var/www/nginx/sites/${name}"

    mkdir -p "${site_dir}"/{public,logs,data}
    if [[ "$kind" == "domain" ]]; then
        _write_proxy_conf "$conf" "$name" "$value" "$target" true ""
    else
        _write_proxy_conf "$conf" "$name" "_" "$target" false "$value"
    fi
    _site_nginx_test "$conf"

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
    _site_open_port "$name" "$kind" "$value"
    _site_reload_nginx "$kind" "$value"
}

_site_body_dotnet() {
    local name="$1" kind="$2" value="$3" conf="$4" dll="$5" internal_port="$6" aspnetcore_env="$7"
    local site_dir="/var/www/nginx/sites/${name}"
    local internal_addr="http://127.0.0.1:${internal_port}"

    mkdir -p "${site_dir}"/{public,logs,data}
    if [[ "$kind" == "domain" ]]; then
        _write_proxy_conf "$conf" "$name" "$value" "$internal_addr" true ""
    else
        _write_proxy_conf "$conf" "$name" "_" "$internal_addr" false "$value"
    fi
    _site_nginx_test "$conf"

    # Placeholder app before the unit, so a failed download never leaves a
    # unit behind that crash-loops on a missing DLL.
    _deploy_sample_dotnet "$name" "$dll"

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

    # Apply permissions AFTER tar extraction so ACLs cover all unpacked files,
    # then the systemd-started service (running as www-data) can write logs,
    # caches, and the .dotnet sentinel dir without further intervention.
    _setup_site_permissions "${site_dir}"
    _site_open_port "$name" "$kind" "$value"
    _create_dotnet_service "$name" "$dll" "$internal_port" "$aspnetcore_env"
    _site_reload_nginx "$kind" "$value"
}

# _site_create <type> <name> <kind> <value> <want_ssl> <body-args...>
_site_create() {
    local type="$1" name="$2" kind="$3" value="$4" want_ssl="$5"
    shift 5
    local site_dir="/var/www/nginx/sites/${name}"
    local unit="/var/www/services/${name}.service"
    local log_dir="/var/www/nginx/log"
    local conf had_dir=0 had_err_log=0 had_acc_log=0 rc=0
    local -a new_sources=()

    # Defence in depth (the route validates too): the name becomes a path.
    if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || "$name" == *..* ]]; then
        echo "✗  Invalid site name '${name}'." >&2
        return 1
    fi
    if [[ "$kind" != "domain" && "$kind" != "port" ]]; then
        echo "✗  Access kind must be 'domain' or 'port'." >&2
        return 1
    fi
    conf="$(_site_conf_path "$name" "$kind")"

    # Refuse to touch anything that is already there, so the rollback below
    # can never remove something this attempt did not create.
    if [[ -e "${site_dir}/info.yml" ]]; then
        echo "✗  A site named '${name}' already exists (${site_dir}/info.yml)." >&2
        return 1
    fi
    if [[ -e "$conf" || -L "$conf" ]]; then
        echo "✗  ${conf} already exists — remove it (or pick another name) and retry." >&2
        return 1
    fi
    if [[ "$type" == "dotnet" ]] \
        && { [[ -e "$unit" || -L "$unit" ]] || systemctl cat "${name}.service" >/dev/null 2>&1; }; then
        echo "✗  A systemd unit named '${name}.service' already exists — pick another site name." >&2
        return 1
    fi

    [[ -d "$site_dir" ]] && had_dir=1
    [[ -e "${log_dir}/${name}-error.log" ]] && had_err_log=1
    [[ -e "${log_dir}/${name}-access.log" ]] && had_acc_log=1
    if [[ "$kind" == "port" ]]; then
        mapfile -t new_sources < <(_site_new_ufw_sources "$value")
    fi

    set +e
    ( set -e; "_site_body_${type}" "$name" "$kind" "$value" "$conf" "$@" )
    rc=$?
    set -e

    if (( rc != 0 )); then
        echo "▶  Rolling back site '${name}'..." >&2
        if [[ "$type" == "dotnet" && ( -e "$unit" || -L "$unit" ) ]]; then
            systemctl disable --now "${name}.service" >/dev/null 2>&1 || true
            rm -f "$unit"
            systemctl daemon-reload || true
        fi
        if (( ${#new_sources[@]} )); then
            _site_ufw_revoke "$value" "$name" "${new_sources[@]}"
        fi
        rm -f "$conf"
        (( had_err_log )) || rm -f "${log_dir}/${name}-error.log"
        (( had_acc_log )) || rm -f "${log_dir}/${name}-access.log"
        if (( had_dir )); then
            rm -f "${site_dir}/info.yml"
        else
            rm -rf "${site_dir:?}"
        fi
        # nginx is only reloaded as the last step, but make sure the running
        # config does not still reference the removed vhost.
        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx >/dev/null 2>&1 || true
        fi
        echo "✗  Site '${name}' was not created; nothing was left behind." >&2
        return "$rc"
    fi

    if [[ "$kind" == "domain" && "$want_ssl" == "ssl" ]]; then
        register_site_ssl "$name" "$value" \
            || echo "⚠  SSL setup failed — site is live over HTTP; fix DNS and retry certbot later." >&2
    fi
}

# ── Panel: non-interactive entry points ───────────────────────────────────────
# Called by the web panel (core/bash_invoker.py) as: source nginx.sh && <function> <args...>
# These functions are fully non-interactive and write an info.yml that the
# Python panel uses to discover and display the site.
# A port-mode site's port is opened only to ALLOWED_SUBNETS (default: private
# ranges); see _ufw_allow_port in lib/common.sh.

# add_static_site <name> <kind:port|domain> <value> [ssl]
add_static_site() {
    local name="$1" kind="$2" value="$3" want_ssl="${4:-}"
    echo "▶  Creating static site '${name}' [${kind}:${value}]..."
    _site_create static "$name" "$kind" "$value" "$want_ssl"
    echo "✔  Static site '${name}' ready."
}

# add_proxy_site <name> <kind:port|domain> <value> <target> [ssl]
add_proxy_site() {
    local name="$1" kind="$2" value="$3" target="$4" want_ssl="${5:-}"
    echo "▶  Creating proxy site '${name}' → ${target} [${kind}:${value}]..."
    _site_create proxy "$name" "$kind" "$value" "$want_ssl" "$target"
    echo "✔  Proxy site '${name}' ready."
}

# add_dotnet_site <name> <kind:port|domain> <value> <dll> <internal_port> [aspnetcore_env] [ssl]
add_dotnet_site() {
    local name="$1" kind="$2" value="$3" dll="${4%.dll}" internal_port="$5" aspnetcore_env="${6:-Production}" want_ssl="${7:-}"
    echo "▶  Creating .NET site '${name}' (${dll}.dll → :${internal_port}) [${kind}:${value}]..."
    _site_create dotnet "$name" "$kind" "$value" "$want_ssl" "$dll" "$internal_port" "$aspnetcore_env"
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
