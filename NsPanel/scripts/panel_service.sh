#!/usr/bin/env bash
# panel_service.sh — run NsPanel itself as a systemd service.
#
# Called by routes/panel.py, which passes everything through the environment:
#   SVC_NAME, SVC_REPO_URL, SVC_BRANCH, SVC_REPO_DIR, SVC_CONF_DIR,
#   SVC_UPDATE_PATHS, SVC_SELF ("1" when the job runs inside the service itself),
#   and for install: SVC_PASSWORD, SVC_PORT, ALLOWED_SUBNETS.
#
# Layout:
#   $SVC_REPO_DIR                  sparse, blobless clone (only NsPanel/ checked out)
#   $SVC_REPO_DIR/NsPanel/.venv    the service's own virtualenv
#   $SVC_CONF_DIR/nspanel.env      0600, PANEL_PASSWORD + bind address
#   $SVC_CONF_DIR/state.json       install/update times, port, subnets, last check
#   /etc/systemd/system/$SVC_NAME.service

SVC_NAME="${SVC_NAME:-nspanel}"
SVC_REPO_URL="${SVC_REPO_URL:-https://github.com/nsknet/nsknet.github.io.git}"
SVC_BRANCH="${SVC_BRANCH:-main}"
SVC_REPO_DIR="${SVC_REPO_DIR:-/opt/nspanel}"
SVC_CONF_DIR="${SVC_CONF_DIR:-/etc/nspanel}"
SVC_UPDATE_PATHS="${SVC_UPDATE_PATHS:-NsPanel nspanel.sh}"
SVC_UFW_COMMENT="NsPanel service"

_svc_panel_dir() { echo "${SVC_REPO_DIR}/NsPanel"; }
_svc_unit_file() { echo "/etc/systemd/system/${SVC_NAME}.service"; }
_svc_env_file() { echo "${SVC_CONF_DIR}/nspanel.env"; }
_svc_state_file() { echo "${SVC_CONF_DIR}/state.json"; }
_svc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Merge string keys into state.json, keeping the keys the panel wrote (the last
# update check). Usage: _svc_state_set key value [key value ...]
_svc_state_set() {
    python3 - "$(_svc_state_file)" "$@" <<'PY'
import json, os, sys
path, *pairs = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError):
    data = {}
for key, value in zip(pairs[::2], pairs[1::2]):
    data[key] = value
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
os.replace(tmp, path)
PY
}

_svc_state_has() {
    grep -q "\"$1\"" "$(_svc_state_file)" 2>/dev/null
}

# ── Code ──────────────────────────────────────────────────────────────────────

_svc_require_tools() {
    local missing=()
    command -v git >/dev/null 2>&1 || missing+=(git)
    command -v python3 >/dev/null 2>&1 || missing+=(python3)
    if [ ${#missing[@]} -gt 0 ]; then
        log_step "Installing ${missing[*]}..."
        apt-get update -q && apt-get install -y "${missing[@]}" || return 1
    fi
}

# Clone (first install) or move the clone to the remote branch tip.
_svc_sync_code() {
    if [ -d "${SVC_REPO_DIR}/.git" ]; then
        log_step "Fetching ${SVC_BRANCH} from ${SVC_REPO_URL}..."
        git -C "$SVC_REPO_DIR" fetch --quiet origin "$SVC_BRANCH" || return 1
        git -C "$SVC_REPO_DIR" reset --hard --quiet "origin/${SVC_BRANCH}" || return 1
    else
        log_step "Cloning ${SVC_REPO_URL} (${SVC_BRANCH}) into ${SVC_REPO_DIR}..."
        mkdir -p "$(dirname "$SVC_REPO_DIR")"
        # Blobless + sparse: history stays small (no old sample-site tarballs)
        # and only NsPanel/ (plus the repo's top-level files) is checked out.
        git clone --quiet --filter=blob:none --sparse --branch "$SVC_BRANCH" \
            "$SVC_REPO_URL" "$SVC_REPO_DIR" || return 1
        git -C "$SVC_REPO_DIR" sparse-checkout set NsPanel || return 1
    fi
    echo "   at $(git -C "$SVC_REPO_DIR" log -1 --format='%h %s (%cs)')"
}

_svc_setup_venv() {
    local panel venv
    panel="$(_svc_panel_dir)"
    venv="${panel}/.venv"
    if [ ! -x "${venv}/bin/pip" ]; then
        log_step "Creating virtualenv..."
        rm -rf "$venv"
        if ! python3 -m venv "$venv" 2>/dev/null; then
            apt-get update -q && apt-get install -y python3-venv python3-pip || return 1
            python3 -m venv "$venv" || return 1
        fi
    fi
    log_step "Installing Python dependencies..."
    "${venv}/bin/pip" install --quiet --upgrade pip || return 1
    "${venv}/bin/pip" install --quiet -e "$panel" || return 1
}

# The code on disk must import and carry a built frontend before we restart onto it.
_svc_smoke_test() {
    local panel
    panel="$(_svc_panel_dir)"
    if [ ! -f "${panel}/static/dist/index.html" ]; then
        log_warn "static/dist/index.html is missing — the frontend is not built on this commit."
        return 1
    fi
    log_step "Checking that the new code imports..."
    (cd "$panel" && NSPANEL_AUDIT_LOG=/dev/null .venv/bin/python -c "import app") || return 1
}

# ── systemd ───────────────────────────────────────────────────────────────────

_svc_write_unit() {
    local panel
    panel="$(_svc_panel_dir)"
    cat > "$(_svc_unit_file)" <<EOF
[Unit]
Description=NsPanel server admin panel
Documentation=${SVC_REPO_URL%.git}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${panel}
EnvironmentFile=$(_svc_env_file)
ExecStart=${panel}/.venv/bin/uvicorn app:app --host \${NSPANEL_HOST} --port \${NSPANEL_PORT}
Restart=on-failure
RestartSec=3
SyslogIdentifier=${SVC_NAME}

[Install]
WantedBy=multi-user.target
EOF
}

# Restart without killing ourselves mid-job: when this job runs inside the
# service, a plain `systemctl restart` would stop the job's own cgroup before
# its exit status reaches the browser. A transient timer runs outside it.
_svc_schedule_restart() {
    if command -v systemd-run >/dev/null 2>&1; then
        systemd-run --quiet --on-active=3 --unit="${SVC_NAME}-restart-$(date +%s)" \
            systemctl restart "${SVC_NAME}.service" || return 1
    else
        systemctl restart --no-block "${SVC_NAME}.service" || return 1
    fi
    echo "   ${SVC_NAME} restarts in a few seconds."
}

# Restart now and wait until it answers, or show why it did not.
_svc_restart_and_wait() {
    local port="$1" i code
    systemctl restart "${SVC_NAME}.service" || true
    for i in $(seq 1 20); do
        if systemctl is-active --quiet "${SVC_NAME}.service"; then
            # 401 = up and asking for the password.
            code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null || true)"
            if [ "$code" = "401" ] || ! command -v curl >/dev/null 2>&1; then
                echo "   ${SVC_NAME} is up on port ${port} (after ${i}s)."
                return 0
            fi
        fi
        sleep 1
    done
    log_warn "${SVC_NAME} did not come up. Last log lines:"
    journalctl -u "${SVC_NAME}" -n 30 --no-pager 2>&1 || true
    return 1
}

_svc_restart() {
    if [ "${SVC_SELF:-0}" = "1" ]; then
        _svc_schedule_restart
    else
        _svc_restart_and_wait "$1"
    fi
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
    local env_file
    env_file="$(_svc_env_file)"

    log_header "NsPanel service — port ${port}"
    if [ -z "$password" ]; then
        log_warn "No password given."
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
    _svc_sync_code || { log_warn "Could not get the code."; return 1; }
    _svc_setup_venv || { log_warn "Could not install the Python dependencies."; return 1; }
    _svc_smoke_test || return 1

    log_step "Writing ${env_file} and the systemd unit..."
    mkdir -p "$SVC_CONF_DIR"
    chmod 700 "$SVC_CONF_DIR"
    (
        umask 077
        # The password charset (core/validators.PASSWORD) has no quote, $, \ or
        # space, so a double-quoted value is read back verbatim by systemd.
        cat > "$env_file" <<EOF
PANEL_USERNAME=admin
PANEL_PASSWORD="${password}"
NSPANEL_HOST=0.0.0.0
NSPANEL_PORT=${port}
NSPANEL_SERVICE=1
EOF
    )
    _svc_write_unit
    systemctl daemon-reload
    systemctl enable --quiet "${SVC_NAME}.service"

    log_step "Opening port ${port} to: ${ALLOWED_SUBNETS:-private subnets}"
    _svc_ufw_allow "$port"

    _svc_state_has installed_at || _svc_state_set installed_at "$(_svc_now)"
    _svc_state_set updated_at "$(_svc_now)" port "$port" branch "$SVC_BRANCH" \
        subnets "${ALLOWED_SUBNETS:-}"

    log_step "Starting ${SVC_NAME}..."
    _svc_restart "$port" || return 1

    log_done "NsPanel service installed. Log in as admin with the password you set:"
    local ip
    for ip in $(hostname -I 2>/dev/null); do
        [[ "$ip" == *:* ]] || echo "   http://${ip}:${port}"
    done
}

panel_service_update() {
    log_header "Update NsPanel service"
    [ -d "${SVC_REPO_DIR}/.git" ] || { log_warn "${SVC_REPO_DIR} is not installed."; return 1; }

    local old new
    old="$(git -C "$SVC_REPO_DIR" rev-parse HEAD)"
    echo "   current ${old:0:7}"
    _svc_sync_code || { log_warn "Could not fetch the update."; return 1; }
    new="$(git -C "$SVC_REPO_DIR" rev-parse HEAD)"
    if [ "$old" = "$new" ]; then
        log_done "Already up to date."
        return 0
    fi

    echo "   changes in ${SVC_UPDATE_PATHS}:"
    # shellcheck disable=SC2086  # SVC_UPDATE_PATHS is a list of paths
    git -C "$SVC_REPO_DIR" log --format='     %h %cs %s' "${old}..${new}" -- $SVC_UPDATE_PATHS | head -20

    if ! _svc_setup_venv || ! _svc_smoke_test; then
        log_warn "The new version failed its checks — rolling back to ${old:0:7}. The service was not restarted."
        git -C "$SVC_REPO_DIR" reset --hard --quiet "$old"
        _svc_setup_venv >/dev/null 2>&1 || true
        return 1
    fi

    _svc_state_set updated_at "$(_svc_now)"
    log_step "Restarting ${SVC_NAME}..."
    _svc_restart "$(_svc_port)" || return 1
    log_done "Updated ${old:0:7} → ${new:0:7}."
}

panel_service_restart() {
    log_header "Restart NsPanel service"
    _svc_restart "$(_svc_port)"
}

panel_service_uninstall() {
    log_header "Uninstall NsPanel service"
    if [ "${SVC_SELF:-0}" = "1" ]; then
        log_warn "Refusing to uninstall the service from inside itself."
        return 1
    fi

    log_step "Stopping and disabling ${SVC_NAME}..."
    systemctl disable --now --quiet "${SVC_NAME}.service" 2>/dev/null || true
    rm -f "$(_svc_unit_file)"
    systemctl daemon-reload

    log_step "Removing firewall rules..."
    _svc_ufw_clear

    log_step "Removing ${SVC_CONF_DIR} and ${SVC_REPO_DIR}..."
    # Only ever the configured directories, never an empty or root path.
    case "$SVC_CONF_DIR" in /etc/?*) rm -rf "$SVC_CONF_DIR" ;; esac
    case "$SVC_REPO_DIR" in /opt/?*) rm -rf "$SVC_REPO_DIR" ;; esac

    log_done "NsPanel service removed."
}
