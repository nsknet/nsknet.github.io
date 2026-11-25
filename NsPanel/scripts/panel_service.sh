#!/usr/bin/env bash
# panel_service.sh — run NsPanel itself as a systemd service.
#
# Called by routes/panel.py, which passes everything through the environment:
#   SVC_NAME, SVC_REPO_URL, SVC_BRANCH, SVC_REPO_DIR, SVC_CONF_DIR,
#   SVC_UPDATE_PATHS, SVC_SELF ("1" when the job runs inside the service itself),
#   and for install: SVC_PASSWORD (optional), SVC_PORT, SVC_TLS, ALLOWED_SUBNETS.
#
# Layout — every version runs from its own, already-verified directory, and the
# switch between them is one atomic symlink swap:
#   $SVC_REPO_DIR                       blobless clone, the source of every release
#   $SVC_REPO_DIR/releases/<sha>        git worktree of one commit (sparse: NsPanel/)
#   $SVC_REPO_DIR/releases/<sha>/NsPanel/.venv   that release's own virtualenv
#   $SVC_REPO_DIR/current  ->  releases/<sha>/NsPanel   what the unit runs
#   $SVC_CONF_DIR/nspanel.env           0600, bind address, port, TLS paths (no secrets)
#   $SVC_CONF_DIR/auth.json             0600, admin password hash (shared with run.sh)
#   $SVC_CONF_DIR/tls/                  self-signed certificate when HTTPS is on
#   $SVC_CONF_DIR/state.json            current/previous release, times, last check
#   /etc/systemd/system/$SVC_NAME.service
#
# After a restart onto a new release the service must answer /healthz within a
# minute; otherwise `current` is pointed back at the previous release and the
# service restarted again.

SVC_NAME="${SVC_NAME:-nspanel}"
SVC_REPO_URL="${SVC_REPO_URL:-https://github.com/nsknet/nsknet.github.io.git}"
SVC_BRANCH="${SVC_BRANCH:-main}"
SVC_REPO_DIR="${SVC_REPO_DIR:-/opt/nspanel}"
SVC_CONF_DIR="${SVC_CONF_DIR:-/etc/nspanel}"
SVC_UPDATE_PATHS="${SVC_UPDATE_PATHS:-NsPanel nspanel.sh}"
SVC_UFW_COMMENT="NsPanel service"
# Release directories kept on disk (current and previous are never removed).
SVC_KEEP_RELEASES=3
# Seconds a restarted service gets to answer /healthz before it is rolled back.
SVC_HEALTH_TIMEOUT=60

_svc_releases_dir() { echo "${SVC_REPO_DIR}/releases"; }
_svc_current_link() { echo "${SVC_REPO_DIR}/current"; }
_svc_unit_file() { echo "/etc/systemd/system/${SVC_NAME}.service"; }
_svc_env_file() { echo "${SVC_CONF_DIR}/nspanel.env"; }
_svc_state_file() { echo "${SVC_CONF_DIR}/state.json"; }
_svc_tls_dir() { echo "${SVC_CONF_DIR}/tls"; }
_svc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# The panel directory the service runs: the release `current` points at, or the
# clone's own NsPanel/ for installs made before releases existed.
_svc_panel_dir() {
    local link
    link="$(_svc_current_link)"
    if [ -L "$link" ]; then
        readlink -f "$link"
    else
        echo "${SVC_REPO_DIR}/NsPanel"
    fi
}

# Merge string keys into state.json (0600), keeping the keys the panel wrote
# (the last update check). Usage: _svc_state_set key value [key value ...]
_svc_state_set() {
    mkdir -p "$SVC_CONF_DIR"
    python3 - "$(_svc_state_file)" "$@" <<'PY'
import fcntl, json, os, sys
path, *pairs = sys.argv[1:]
with open(path + ".lock", "w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        data = {}
    for key, value in zip(pairs[::2], pairs[1::2]):
        data[key] = value
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
    os.replace(tmp, path)
PY
}

_svc_state_get() {
    python3 - "$(_svc_state_file)" "$1" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        print(json.load(fh).get(sys.argv[2], ""))
except (OSError, ValueError):
    pass
PY
}

_svc_state_has() {
    grep -q "\"$1\"" "$(_svc_state_file)" 2>/dev/null
}

# One install/update/rollback at a time. The lock is held until the job exits.
_svc_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    exec 9>/run/nspanel-service.lock
    if ! flock -n 9; then
        log_warn "Another install, update or rollback of the panel service is running."
        return 1
    fi
}

# ── Code ──────────────────────────────────────────────────────────────────────

_svc_require_tools() {
    local missing=()
    command -v git >/dev/null 2>&1 || missing+=(git)
    command -v python3 >/dev/null 2>&1 || missing+=(python3)
    command -v openssl >/dev/null 2>&1 || missing+=(openssl)
    if [ ${#missing[@]} -gt 0 ]; then
        log_step "Installing ${missing[*]}..."
        apt-get update -q && apt-get install -y "${missing[@]}" || return 1
    fi
}

# Clone (first install) or fetch the branch. The clone's own working tree is
# never moved: releases are separate worktrees.
_svc_fetch() {
    if [ -d "${SVC_REPO_DIR}/.git" ]; then
        log_step "Fetching ${SVC_BRANCH} from ${SVC_REPO_URL}..."
        git -C "$SVC_REPO_DIR" fetch --quiet origin "$SVC_BRANCH" || return 1
    else
        log_step "Cloning ${SVC_REPO_URL} (${SVC_BRANCH}) into ${SVC_REPO_DIR}..."
        mkdir -p "$(dirname "$SVC_REPO_DIR")"
        # Blobless and without a checkout: history stays small (no old sample-site
        # tarballs) and only release worktrees fetch the files they need.
        git clone --quiet --filter=blob:none --no-checkout --branch "$SVC_BRANCH" \
            "$SVC_REPO_URL" "$SVC_REPO_DIR" || return 1
    fi
    # Release directories are not part of the repository.
    grep -qx '/releases/' "${SVC_REPO_DIR}/.git/info/exclude" 2>/dev/null \
        || printf '/releases/\n/current\n' >> "${SVC_REPO_DIR}/.git/info/exclude"
}

_svc_remote_head() {
    git -C "$SVC_REPO_DIR" rev-parse "origin/${SVC_BRANCH}"
}

# Venv + pinned dependencies for one panel directory.
_svc_setup_venv() {
    local panel="$1" venv
    venv="${panel}/.venv"
    if [ ! -x "${venv}/bin/pip" ]; then
        log_step "Creating virtualenv..."
        rm -rf "$venv"
        if ! python3 -m venv "$venv" 2>/dev/null; then
            apt-get update -q && apt-get install -y python3-venv python3-pip || return 1
            python3 -m venv "$venv" || return 1
        fi
    fi
    # Exact, hash-checked versions from the lock: each release gets the versions
    # it was tested with.
    log_step "Installing Python dependencies from requirements.lock..."
    "${venv}/bin/pip" install --quiet --require-hashes -r "${panel}/requirements.lock" || return 1
    "${venv}/bin/pip" install --quiet --no-deps -e "$panel" || return 1
}

# The code must import and carry a built frontend before we switch to it.
_svc_smoke_test() {
    local panel="$1"
    if [ ! -f "${panel}/static/dist/index.html" ]; then
        log_warn "static/dist/index.html is missing — the frontend is not built on this commit."
        return 1
    fi
    log_step "Checking that the new code imports..."
    (cd "$panel" && NSPANEL_AUDIT_LOG=/dev/null NSPANEL_STATE_DIR=/tmp .venv/bin/python -c "import app") || return 1
}

# Build (or reuse) the release directory for <sha>; prints its panel dir.
# Nothing the service runs is touched: a failure leaves no trace but a log line.
_svc_build_release() {
    local sha="$1" dir panel
    dir="$(_svc_releases_dir)/${sha}"
    panel="${dir}/NsPanel"
    if [ -f "${panel}/.release-ok" ]; then
        log_step "Release ${sha:0:7} is already built." >&2
        echo "$panel"
        return 0
    fi
    if ! _svc_build_release_steps "$sha" "$dir" "$panel" >&2; then
        log_warn "Release ${sha:0:7} failed its checks; it was not activated."
        git -C "$SVC_REPO_DIR" worktree remove --force "$dir" >/dev/null 2>&1 || rm -rf "$dir"
        git -C "$SVC_REPO_DIR" worktree prune 2>/dev/null || true
        return 1
    fi
    echo "$panel"
}

_svc_build_release_steps() {
    local sha="$1" dir="$2" panel="$3"
    rm -rf "$dir"
    git -C "$SVC_REPO_DIR" worktree prune
    mkdir -p "$(_svc_releases_dir)"
    log_step "Checking out ${sha:0:7} into ${dir}..."
    git -C "$SVC_REPO_DIR" worktree add --quiet --detach --no-checkout "$dir" "$sha" || return 1
    # Only NsPanel/ (best effort: an old git falls back to a full checkout).
    git -C "$dir" sparse-checkout set NsPanel >/dev/null 2>&1 || true
    git -C "$dir" reset --hard --quiet "$sha" || return 1
    _svc_setup_venv "$panel" || return 1
    _svc_smoke_test "$panel" || return 1
    touch "${panel}/.release-ok"
}

# Point `current` at a panel directory, atomically (rename over the old link).
_svc_point_current() {
    local target="$1" link tmp
    link="$(_svc_current_link)"
    tmp="${link}.new"
    ln -sfn "$target" "$tmp" && mv -Tf "$tmp" "$link"
}

_svc_commit_of() {
    [ -n "$1" ] && [ -d "$1" ] && git -C "$1" rev-parse HEAD 2>/dev/null
}

# Remove old releases, never the current or previous one.
_svc_prune_releases() {
    local keep_a keep_b dir count=0
    keep_a="$(readlink -f "$(_svc_current_link)" 2>/dev/null)"
    keep_b="$(_svc_state_get previous_release)"
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        count=$((count + 1))
        if [ "${dir}/NsPanel" = "$keep_a" ] || [ "${dir}/NsPanel" = "$keep_b" ]; then
            continue
        fi
        if [ "$count" -gt "$SVC_KEEP_RELEASES" ]; then
            git -C "$SVC_REPO_DIR" worktree remove --force "$dir" >/dev/null 2>&1 || rm -rf "$dir"
            echo "   removed old release $(basename "$dir" | cut -c1-7)"
        fi
    done < <(ls -1dt "$(_svc_releases_dir)"/*/ 2>/dev/null | sed 's:/$::')
    git -C "$SVC_REPO_DIR" worktree prune 2>/dev/null || true
}

# Store the admin password as a scrypt hash in ${SVC_CONF_DIR}/auth.json. The
# plaintext travels only through this process's environment.
_svc_set_password() {
    local panel="$1" password="$2"
    (cd "$panel" && NSPANEL_NEW_PASSWORD="$password" NSPANEL_AUTH_FILE="${SVC_CONF_DIR}/auth.json" \
        .venv/bin/python -m core.passwords set)
}

# Older installs kept PANEL_PASSWORD in the env file. Hash it (unless a hash
# already exists) and drop the plaintext line.
_svc_migrate_password() {
    local panel="$1" env_file old
    env_file="$(_svc_env_file)"
    [ -f "$env_file" ] && grep -q '^PANEL_PASSWORD=' "$env_file" || return 0
    if [ ! -s "${SVC_CONF_DIR}/auth.json" ]; then
        old="$(sed -n 's/^PANEL_PASSWORD="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$env_file")"
        (cd "$panel" && PANEL_PASSWORD="$old" NSPANEL_AUTH_FILE="${SVC_CONF_DIR}/auth.json" \
            .venv/bin/python -m core.passwords ensure >/dev/null) || return 1
    fi
    sed -i '/^PANEL_PASSWORD=/d' "$env_file"
    log_step "Moved the service password out of ${env_file} (now stored as a hash)."
}

# ── TLS ───────────────────────────────────────────────────────────────────────

_svc_tls_enabled() {
    grep -q '^NSPANEL_TLS_CERT=' "$(_svc_env_file)" 2>/dev/null
}

_svc_scheme() {
    if _svc_tls_enabled; then echo https; else echo http; fi
}

# A self-signed certificate for this host's name and IPv4 addresses, valid two
# years. Kept across reinstalls; replace the two files to use your own.
_svc_ensure_cert() {
    local dir cert key san ip
    dir="$(_svc_tls_dir)"
    cert="${dir}/cert.pem"
    key="${dir}/key.pem"
    if [ -s "$cert" ] && [ -s "$key" ]; then
        log_step "Using the existing certificate in ${dir}."
        return 0
    fi
    log_step "Creating a self-signed certificate in ${dir}..."
    mkdir -p "$dir"
    chmod 700 "$dir"
    san="DNS:$(hostname),DNS:localhost,IP:127.0.0.1"
    for ip in $(hostname -I 2>/dev/null); do
        [[ "$ip" == *:* ]] || san+=",IP:${ip}"
    done
    (
        umask 077
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
            -days 730 -subj "/CN=$(hostname)" -addext "subjectAltName=${san}" \
            -keyout "$key" -out "$cert" >/dev/null 2>&1
    ) || { log_warn "openssl could not create the certificate."; return 1; }
    echo "   SHA-256 fingerprint: $(openssl x509 -in "$cert" -noout -fingerprint -sha256 | cut -d= -f2)"
}

# ── systemd ───────────────────────────────────────────────────────────────────

_svc_write_unit() {
    local current tls_args=""
    current="$(_svc_current_link)"
    if _svc_tls_enabled; then
        tls_args=' --ssl-certfile ${NSPANEL_TLS_CERT} --ssl-keyfile ${NSPANEL_TLS_KEY}'
    fi
    cat > "$(_svc_unit_file)" <<EOF
[Unit]
Description=NsPanel server admin panel
Documentation=${SVC_REPO_URL%.git}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
WorkingDirectory=${current}
EnvironmentFile=$(_svc_env_file)
ExecStart=${current}/.venv/bin/uvicorn app:app --host \${NSPANEL_HOST} --port \${NSPANEL_PORT} --timeout-graceful-shutdown 15${tls_args}
Restart=on-failure
RestartSec=3
SyslogIdentifier=${SVC_NAME}

[Install]
WantedBy=multi-user.target
EOF
}

# 0 once the service answers /healthz, 1 after <timeout> seconds.
_svc_wait_healthy() {
    local port="$1" timeout="${2:-$SVC_HEALTH_TIMEOUT}" scheme i code
    scheme="$(_svc_scheme)"
    for ((i = 1; i <= timeout; i++)); do
        if systemctl is-active --quiet "${SVC_NAME}.service"; then
            if ! command -v curl >/dev/null 2>&1; then
                echo "   ${SVC_NAME} is active (curl missing, /healthz not checked)."
                return 0
            fi
            # -k: the certificate may be self-signed.
            code="$(curl -ks -o /dev/null -w '%{http_code}' "${scheme}://127.0.0.1:${port}/healthz" 2>/dev/null || true)"
            if [ "$code" = "200" ]; then
                echo "   ${SVC_NAME} is up on ${scheme}://…:${port} (after ${i}s)."
                return 0
            fi
        fi
        sleep 1
    done
    return 1
}

# Restart onto `current`; if it does not become healthy, point `current` back at
# <fallback> (a panel dir) and restart again. Runs inline, or from a transient
# unit when the job lives inside the service it restarts.
panel_service_watchdog() {
    local port="$1" fallback="${2:-}" failed
    systemctl reset-failed "${SVC_NAME}.service" 2>/dev/null || true
    systemctl restart "${SVC_NAME}.service" || true
    if _svc_wait_healthy "$port"; then
        return 0
    fi
    log_warn "${SVC_NAME} did not answer /healthz within ${SVC_HEALTH_TIMEOUT}s. Last log lines:"
    journalctl -u "${SVC_NAME}" -n 30 --no-pager 2>&1 || true
    if [ -z "$fallback" ] || [ ! -d "$fallback" ]; then
        log_warn "No previous release to roll back to."
        return 1
    fi
    failed="$(_svc_panel_dir)"
    log_warn "Rolling back to $(basename "$(dirname "$fallback")" | cut -c1-7)..."
    _svc_point_current "$fallback"
    _svc_state_set current_release "$fallback" previous_release "$failed" \
        current_commit "$(_svc_commit_of "$fallback")" previous_commit "$(_svc_commit_of "$failed")" \
        last_rollback_at "$(_svc_now)" last_rollback_from "$(_svc_commit_of "$failed")" \
        last_rollback_reason "no answer on /healthz within ${SVC_HEALTH_TIMEOUT}s"
    systemctl reset-failed "${SVC_NAME}.service" 2>/dev/null || true
    systemctl restart "${SVC_NAME}.service" || true
    _svc_wait_healthy "$port" || log_warn "The previous release did not come up either."
    return 1
}

# Restart with health check and automatic rollback to <fallback>.
_svc_restart() {
    local port="$1" fallback="${2:-}" scripts_dir
    if [ "${SVC_SELF:-0}" != "1" ]; then
        panel_service_watchdog "$port" "$fallback"
        return
    fi
    # Inside the service: a plain restart would kill this job's own cgroup before
    # its exit status reached the browser. Hand the restart (and the health check
    # and rollback) to a transient unit that runs outside it.
    if ! command -v systemd-run >/dev/null 2>&1; then
        systemctl restart --no-block "${SVC_NAME}.service" || return 1
        return 0
    fi
    scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    systemd-run --quiet --on-active=3 --unit="${SVC_NAME}-restart-$(date +%s)" \
        --setenv=SVC_NAME="$SVC_NAME" --setenv=SVC_REPO_DIR="$SVC_REPO_DIR" \
        --setenv=SVC_CONF_DIR="$SVC_CONF_DIR" \
        /bin/bash -c 'for l in "$1"/lib/*.sh; do source "$l"; done; source "$1/panel_service.sh"; panel_service_watchdog "$2" "$3"' \
        -- "$scripts_dir" "$port" "$fallback" || return 1
    echo "   ${SVC_NAME} restarts in a few seconds; if it does not answer within ${SVC_HEALTH_TIMEOUT}s it is rolled back."
}

_svc_port() {
    local port
    port="$(sed -n 's/^NSPANEL_PORT=//p' "$(_svc_env_file)" 2>/dev/null)"
    echo "${port:-7778}"
}

# ── UFW ───────────────────────────────────────────────────────────────────────
# Unlike _ufw_allow_port, never enables UFW: switching a firewall on from here
# would also cut off every other service (sites, databases) that has no rule.

_svc_ufw_clear() {
    command -v ufw >/dev/null 2>&1 || return 0
    local nums n
    # Delete from the highest number down so the remaining numbers stay valid.
    mapfile -t nums < <(ufw status numbered | grep -F "# ${SVC_UFW_COMMENT}" \
        | sed -nE 's/^\[ *([0-9]+)\].*/\1/p' | sort -rn)
    for n in "${nums[@]}"; do
        ufw --force delete "$n" >/dev/null
    done
    [ ${#nums[@]} -gt 0 ] && echo "   removed ${#nums[@]} old firewall rule(s)."
    return 0
}

_svc_ufw_allow() {
    local port="$1" cidr subnets
    if ! command -v ufw >/dev/null 2>&1; then
        log_warn "UFW is not installed — port ${port} is reachable from any network."
        return 0
    fi
    _svc_ufw_clear
    read -r -a subnets <<< "${ALLOWED_SUBNETS:-10.0.0.0/8 172.16.0.0/12 192.168.0.0/16}"
    for cidr in "${subnets[@]}"; do
        if [ "$cidr" = "0.0.0.0/0" ]; then
            echo "   UFW: allow any → tcp/${port}"
            ufw allow "${port}/tcp" comment "$SVC_UFW_COMMENT" >/dev/null
        else
            echo "   UFW: allow ${cidr} → tcp/${port}"
            ufw allow from "$cidr" to any port "$port" proto tcp comment "$SVC_UFW_COMMENT" >/dev/null
        fi
    done
    if ufw status | grep -q "inactive"; then
        log_warn "UFW is inactive: the rules are saved but not enforced. Enable it from the Firewall page."
    else
        ufw reload >/dev/null
    fi
}

# ── Actions ───────────────────────────────────────────────────────────────────

panel_service_install() {
    local port="${SVC_PORT:-7778}"
    local password="${SVC_PASSWORD:-}"
    local tls="${SVC_TLS:-1}"
    local env_file sha panel previous scheme
    env_file="$(_svc_env_file)"

    log_header "NsPanel service — port ${port}"
    _svc_lock || return 1
    if [ -z "$password" ] && [ ! -s "${SVC_CONF_DIR}/auth.json" ]; then
        log_warn "No password given, and no admin password is set yet."
        return 1
    fi

    # Refuse a port another program already listens on (our own service is fine).
    if ss -ltnH "sport = :${port}" 2>/dev/null | grep -q . \
        && ! { systemctl is-active --quiet "${SVC_NAME}.service" && [ "$(_svc_port)" = "$port" ]; }; then
        log_warn "Port ${port} is already in use:"
        ss -ltnpH "sport = :${port}" 2>/dev/null || true
        return 1
    fi

    _svc_require_tools || return 1
    _svc_fetch || { log_warn "Could not get the code."; return 1; }
    sha="$(_svc_remote_head)" || return 1
    panel="$(_svc_build_release "$sha")" || return 1
    previous=""
    [ -e "$(_svc_current_link)" ] || [ -d "${SVC_REPO_DIR}/NsPanel" ] && previous="$(_svc_panel_dir)"
    [ "$previous" = "$panel" ] && previous="$(_svc_state_get previous_release)"

    mkdir -p "$SVC_CONF_DIR"
    chmod 700 "$SVC_CONF_DIR"
    if [ -n "$password" ]; then
        log_step "Setting the admin password (stored as a hash in ${SVC_CONF_DIR}/auth.json)..."
        _svc_set_password "$panel" "$password" || { log_warn "Could not store the password."; return 1; }
    fi
    _svc_migrate_password "$panel" || true

    if [ "$tls" = "1" ]; then
        _svc_ensure_cert || return 1
    fi
    log_step "Writing ${env_file} and the systemd unit..."
    (
        umask 077
        {
            echo "PANEL_USERNAME=admin"
            echo "NSPANEL_AUTH_FILE=${SVC_CONF_DIR}/auth.json"
            echo "NSPANEL_HOST=0.0.0.0"
            echo "NSPANEL_PORT=${port}"
            echo "NSPANEL_SERVICE=1"
            if [ "$tls" = "1" ]; then
                echo "NSPANEL_TLS_CERT=$(_svc_tls_dir)/cert.pem"
                echo "NSPANEL_TLS_KEY=$(_svc_tls_dir)/key.pem"
            fi
        } > "$env_file"
    )
    _svc_point_current "$panel"
    _svc_write_unit
    systemctl daemon-reload
    systemctl enable --quiet "${SVC_NAME}.service"

    log_step "Opening port ${port} to: ${ALLOWED_SUBNETS:-private subnets}"
    _svc_ufw_allow "$port"

    _svc_state_has installed_at || _svc_state_set installed_at "$(_svc_now)"
    _svc_state_set updated_at "$(_svc_now)" port "$port" branch "$SVC_BRANCH" \
        subnets "${ALLOWED_SUBNETS:-}" tls "$tls" \
        current_release "$panel" current_commit "$sha" \
        previous_release "$previous" previous_commit "$(_svc_commit_of "$previous")"

    log_step "Starting ${SVC_NAME}..."
    _svc_restart "$port" "$previous" || return 1
    _svc_prune_releases

    scheme="$(_svc_scheme)"
    log_done "NsPanel service installed. Sign in as admin at:"
    local ip
    for ip in $(hostname -I 2>/dev/null); do
        [[ "$ip" == *:* ]] || echo "   ${scheme}://${ip}:${port}"
    done
    [ "$scheme" = "https" ] && echo "   The certificate is self-signed: the browser asks you to trust it once."
    return 0
}

panel_service_update() {
    log_header "Update NsPanel service"
    [ -d "${SVC_REPO_DIR}/.git" ] || { log_warn "${SVC_REPO_DIR} is not installed."; return 1; }
    _svc_lock || return 1

    local old_panel old new panel
    old_panel="$(_svc_panel_dir)"
    old="$(_svc_commit_of "$old_panel")"
    echo "   current ${old:0:7}"
    _svc_fetch || { log_warn "Could not fetch the update."; return 1; }
    new="$(_svc_remote_head)" || return 1
    # The panel passes the commit it checked (and whose CI it looked at); never
    # jump past it to something newer that nobody has looked at.
    if [ -n "${SVC_TARGET:-}" ]; then
        if ! git -C "$SVC_REPO_DIR" merge-base --is-ancestor "$SVC_TARGET" "$new" 2>/dev/null; then
            log_warn "${SVC_TARGET:0:7} is not on ${SVC_BRANCH}; refusing to update to it."
            return 1
        fi
        new="$(git -C "$SVC_REPO_DIR" rev-parse "${SVC_TARGET}^{commit}")" || return 1
    fi
    if [ "$old" = "$new" ]; then
        log_done "Already up to date."
        return 0
    fi

    echo "   changes in ${SVC_UPDATE_PATHS}:"
    # shellcheck disable=SC2086  # SVC_UPDATE_PATHS is a list of paths
    git -C "$SVC_REPO_DIR" log --format='     %h %cs %s' "${old}..${new}" -- $SVC_UPDATE_PATHS | head -20

    # Build and verify the new release beside the running one; the service keeps
    # running the old code until the switch.
    panel="$(_svc_build_release "$new")" || {
        log_warn "The service was not changed and keeps running ${old:0:7}."
        return 1
    }

    _svc_migrate_password "$panel" || log_warn "Could not migrate the stored password; it still works from ${SVC_CONF_DIR}/nspanel.env."
    _svc_point_current "$panel"
    # Pick up unit changes shipped with the new version.
    _svc_write_unit
    systemctl daemon-reload
    _svc_state_set updated_at "$(_svc_now)" branch "$SVC_BRANCH" \
        current_release "$panel" current_commit "$new" \
        previous_release "$old_panel" previous_commit "$old"

    log_step "Restarting ${SVC_NAME}..."
    _svc_restart "$(_svc_port)" "$old_panel" || return 1
    _svc_prune_releases
    log_done "Updated ${old:0:7} → ${new:0:7}."
}

panel_service_rollback() {
    log_header "Roll back NsPanel service"
    _svc_lock || return 1
    local current previous
    current="$(_svc_panel_dir)"
    previous="$(_svc_state_get previous_release)"
    if [ -z "$previous" ] || [ ! -f "${previous}/app.py" ]; then
        log_warn "There is no previous release on disk to roll back to."
        return 1
    fi
    echo "   $(_svc_commit_of "$current" | cut -c1-7) → $(_svc_commit_of "$previous" | cut -c1-7)"
    _svc_point_current "$previous"
    _svc_write_unit
    systemctl daemon-reload
    _svc_state_set updated_at "$(_svc_now)" \
        current_release "$previous" current_commit "$(_svc_commit_of "$previous")" \
        previous_release "$current" previous_commit "$(_svc_commit_of "$current")"
    log_step "Restarting ${SVC_NAME}..."
    _svc_restart "$(_svc_port)" "$current" || return 1
    log_done "Rolled back."
}

panel_service_restart() {
    log_header "Restart NsPanel service"
    _svc_restart "$(_svc_port)" ""
}

panel_service_uninstall() {
    log_header "Uninstall NsPanel service"
    if [ "${SVC_SELF:-0}" = "1" ]; then
        log_warn "Refusing to uninstall the service from inside itself."
        return 1
    fi
    _svc_lock || return 1

    log_step "Stopping and disabling ${SVC_NAME}..."
    systemctl disable --now --quiet "${SVC_NAME}.service" 2>/dev/null || true
    rm -f "$(_svc_unit_file)"
    systemctl daemon-reload

    log_step "Removing firewall rules..."
    _svc_ufw_clear

    # Only the service's own files: auth.json is the admin password of every
    # panel on this host, and tunnels/ holds Cloudflare tunnel tokens.
    log_step "Removing the service's files in ${SVC_CONF_DIR} and ${SVC_REPO_DIR}..."
    rm -f "$(_svc_env_file)" "$(_svc_state_file)" "$(_svc_state_file).lock"
    rm -rf "$(_svc_tls_dir)"
    case "$SVC_REPO_DIR" in /opt/?*) rm -rf "$SVC_REPO_DIR" ;; esac

    log_done "NsPanel service removed. The admin password is unchanged."
}
