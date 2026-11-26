#!/usr/bin/env bash
# lib/common.sh — helpers every install script may call.
#
# core/bash_invoker.py sources everything in scripts/lib/ before the target
# script, so these functions are always defined. Do not put tool-specific logic
# here; that belongs in the tool's own script.

# ── Console output ────────────────────────────────────────────────────────────

# A boxed section title. Use once at the top of an install/uninstall function.
log_header() {
    echo "════════════════════════════════════════════════════════════"
    echo "  $*"
    echo "════════════════════════════════════════════════════════════"
}

# One step within a function.
log_step() {
    echo "▶  $*"
}

log_done() {
    echo ""
    echo "✓  $*"
}

log_warn() {
    echo "⚠  $*" >&2
}


# ── APT ───────────────────────────────────────────────────────────────────────
# Every script calls apt-get directly; this wrapper makes each call wait for the
# dpkg lock (held by unattended-upgrades for minutes on a fresh VPS) instead of
# failing on the spot, and never lets apt stop to ask a question — including the
# "config file was modified" prompt a later upgrade hits on files our scripts
# rewrote (keep ours: confold; take the default when there is no choice: confdef).
apt-get() {
    DEBIAN_FRONTEND=noninteractive command apt-get -o DPkg::Lock::Timeout=300 \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# Wait (up to 5 min) until no apt/dpkg process holds the dpkg locks. For tools
# that do not honour DPkg::Lock::Timeout: dpkg -i, add-apt-repository.
_wait_dpkg_lock() {
    local i
    command -v fuser >/dev/null 2>&1 || return 0
    for ((i = 0; i < 300; i++)); do
        if ! fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; then
            return 0
        fi
        [ "$i" -eq 0 ] && echo "▶  Waiting for another package manager to finish..."
        sleep 1
    done
    log_warn "The dpkg lock is still held after 5 minutes."
    return 1
}

add-apt-repository() {
    _wait_dpkg_lock || return 1
    DEBIAN_FRONTEND=noninteractive command add-apt-repository "$@"
}

# Only installs/removals need the lock; queries (dpkg -l, -s) run as usual.
dpkg() {
    case "${1:-}" in
        -i | --install | -r | --remove | -P | --purge | --configure)
            _wait_dpkg_lock || return 1
            DEBIAN_FRONTEND=noninteractive command dpkg --force-confdef --force-confold "$@"
            ;;
        *) command dpkg "$@" ;;
    esac
}


# ── Platform ──────────────────────────────────────────────────────────────────

_os_id() { . /etc/os-release 2>/dev/null && echo "${ID:-unknown}"; }
_os_version() { . /etc/os-release 2>/dev/null && echo "${VERSION_ID:-unknown}"; }
_os_codename() { . /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-unknown}}"; }
_os_arch() { command dpkg --print-architecture 2>/dev/null || uname -m; }

# Fail fast, with a clear message, on an OS release or CPU the tool's vendor
# repository does not serve — instead of an apt error halfway through.
# Usage: _require_platform "<tool>" "<ubuntu versions>" "<architectures>"
#   e.g. _require_platform "SQL Server" "22.04 24.04" "amd64"
_require_platform() {
    local tool="$1" versions="$2" arches="$3" id version arch
    id="$(_os_id)"
    version="$(_os_version)"
    arch="$(_os_arch)"
    if [ "$id" != "ubuntu" ]; then
        echo "❌  ${tool} is only supported on Ubuntu here (this host: ${id} ${version})."
        return 1
    fi
    if [[ " ${versions} " != *" ${version} "* ]]; then
        echo "❌  ${tool}: Ubuntu ${version} is not supported by its repository (supported: ${versions})."
        return 1
    fi
    if [[ " ${arches} " != *" ${arch} "* ]]; then
        echo "❌  ${tool}: ${arch} is not supported (supported: ${arches})."
        return 1
    fi
}

# Verify a download against its published SHA-256.
# Usage: _verify_sha256 <file> <expected-hex>
_verify_sha256() {
    local file="$1" expected="$2" actual
    actual="$(sha256sum "$file" | cut -d' ' -f1)"
    if [ "${actual,,}" != "${expected,,}" ]; then
        echo "❌  Checksum mismatch for $(basename "$file")"
        echo "    expected ${expected}"
        echo "    got      ${actual}"
        return 1
    fi
    echo "▶  Checksum OK ($(basename "$file"))."
}

# Install packages that are nice to have but not required: one at a time, so a
# package missing from this release (e.g. rar without multiverse) skips itself
# instead of failing the whole install.
_apt_install_optional() {
    local pkg
    for pkg in "$@"; do
        apt-get install -y -q "$pkg" >/dev/null 2>&1 || log_warn "Optional package '${pkg}' is not available here — skipped."
    done
}

# ── /etc/fstab ────────────────────────────────────────────────────────────────
# A broken fstab can stop the next boot, so every edit is: back up, change,
# verify with findmnt, and restore the backup if the change added errors.

# Copy /etc/fstab to /var/backups/nspanel/; prints the backup's path.
_fstab_backup() {
    local backup
    mkdir -p /var/backups/nspanel
    backup="/var/backups/nspanel/fstab.$(date +%Y%m%d-%H%M%S)"
    cp -a /etc/fstab "$backup"
    echo "$backup"
}

# Number of errors `findmnt --verify` reports for /etc/fstab.
_fstab_error_count() {
    local count
    count="$(findmnt --verify --tab-file /etc/fstab 2>&1 | grep -c '\[E\]' || true)"
    echo "${count:-0}"
}

# Restore <backup> when the edit added errors (pre-existing ones are not ours).
# Usage: _fstab_verify_or_restore <backup> <errors-before>
_fstab_verify_or_restore() {
    local backup="$1" before="${2:-0}" after
    after="$(_fstab_error_count)"
    if [ "$after" -le "$before" ]; then
        return 0
    fi
    findmnt --verify --tab-file /etc/fstab 2>&1 | sed 's/^/    /' || true
    cp -a "$backup" /etc/fstab
    log_warn "/etc/fstab failed verification after the change and was restored from ${backup}."
    return 1
}

# Drop entries whose mount point (field 2) or source (field 1) equals the value
# exactly — no regex, so dots or slashes in paths cannot match other lines.
# Usage: _fstab_remove_field <1|2> <value>
_fstab_remove_field() {
    local field="$1" value="$2" tmp
    tmp="$(mktemp /etc/fstab.XXXXXX)"
    awk -v f="$field" -v v="$value" '/^[[:space:]]*#/ || NF < 2 || $f != v' /etc/fstab > "$tmp"
    chmod --reference=/etc/fstab "$tmp"
    mv -f "$tmp" /etc/fstab
}

# Refuse 0.0.0.0/0 in ALLOWED_SUBNETS for a service that has no authentication
# of its own: on the open internet anyone could read or change its data.
# Usage: _forbid_public_access "<tool>"
_forbid_public_access() {
    if [[ " ${ALLOWED_SUBNETS:-} " == *" 0.0.0.0/0 "* ]]; then
        echo "❌  ${1} has no login of its own: refusing to open it to every IP (0.0.0.0/0)."
        echo "    Pick private subnets, or put it behind something that authenticates."
        return 1
    fi
}


# ── Secrets ───────────────────────────────────────────────────────────────────

# Random 28-character [0-9a-f] password. Safe under `set -o pipefail`, unlike
# `tr … </dev/urandom | head`, which dies with SIGPIPE (exit 141).
gen_password() {
    openssl rand -hex 14
}

# Set `key: "value"` in a YAML-ish credentials file, keeping the other lines.
# Usage: cred_set <file> <key> <value>
# The value is handed to awk through the environment, so characters that are
# special to sed (`&`, `|`, `\`) are written verbatim. No-op if the file is missing.
cred_set() {
    local file="$1" key="$2" value="$3" tmp
    [ -f "$file" ] || return 0
    tmp="$(mktemp "${file}.XXXXXX")"   # mktemp creates it 0600
    CRED_KEY="$key" CRED_VALUE="$value" awk '
        index($0, ENVIRON["CRED_KEY"] ":") == 1 {
            print ENVIRON["CRED_KEY"] ": \"" ENVIRON["CRED_VALUE"] "\""
            next
        }
        { print }
    ' "$file" > "$tmp"
    mv -f "$tmp" "$file"
}


# ── UFW ───────────────────────────────────────────────────────────────────────
# Usage: _ufw_allow_port <port> <comment>
#
# The caller (the web panel) selects which subnets to expose the port to via the
# ALLOWED_SUBNETS environment variable — a space-separated list of CIDRs, e.g.
#   ALLOWED_SUBNETS="10.0.0.0/8 192.168.0.0/16"
# Special value "0.0.0.0/0" opens the port to every IP (no source restriction).
# When ALLOWED_SUBNETS is unset/empty we fall back to the standard private +
# loopback subnets, matching the previous default.
_ufw_allow_port() {
    local port="$1"
    local comment="$2"

    # Resolve the effective subnet list (env override → default private subnets).
    local subnets
    if [ -n "${ALLOWED_SUBNETS// /}" ]; then
        read -r -a subnets <<< "$ALLOWED_SUBNETS"
    else
        subnets=("127.0.0.0/8" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16")
    fi
    # Export the effective list so install scripts' "Allow:" summary lines reflect
    # what was actually applied.
    ALLOWED_SUBNETS="${subnets[*]}"

    command -v ufw >/dev/null 2>&1 || {
        echo "▶  Installing UFW..."
        apt-get install -y ufw
    }

    # Never switch UFW on from here: enabling it with only some ports allowed
    # cuts off SSH on a custom port and every other listener. Rules added while
    # UFW is inactive are stored and take effect once the operator enables it
    # from the Firewall screen (install_ufw), which allows SSH and the panel first.
    if ufw status | grep -q "inactive"; then
        log_warn "UFW is inactive: tcp/${port} rules are saved but not enforced until it is enabled."
    fi

    # 0.0.0.0/0 means "any source" — express it as a plain port rule rather than
    # a from-rule so it reads as an unrestricted allow.
    local cidr
    for cidr in "${subnets[@]}"; do
        if [ "$cidr" = "0.0.0.0/0" ]; then
            if _ufw_has_rule "$port" "Anywhere"; then
                echo "▶  UFW: any → tcp/${port} already allowed, skipping."
            else
                echo "▶  UFW: allow any → tcp/${port} (${comment})"
                ufw allow "${port}/tcp" comment "$comment" >/dev/null
            fi
            continue
        fi

        if _ufw_has_rule "$port" "$cidr"; then
            echo "▶  UFW: ${cidr} → tcp/${port} already allowed, skipping."
        else
            echo "▶  UFW: allow ${cidr} → tcp/${port} (${comment})"
            ufw allow from "$cidr" to any port "$port" proto tcp comment "$comment" >/dev/null
        fi
    done

    ufw reload >/dev/null 2>&1 || true
}

# True when `ufw status` already has an ALLOW rule for exactly <port>/tcp from
# <source>. Matches whole columns, so port 80 never matches 8080/tcp.
# Usage: _ufw_has_rule <port> <source-cidr|Anywhere>
_ufw_has_rule() {
    local port="$1" source="$2"
    ufw status | awk -v to="${port}/tcp" -v src="$source" '
        $1 == to && toupper($2) == "ALLOW" && $3 == src { found = 1 }
        END { exit !found }
    '
}

# The TCP port(s) sshd listens on, one per line (defaults to 22).
# Tried in order: the effective sshd config (sshd -T needs /run/sshd, which is
# missing on 24.04 while ssh.socket has not started sshd yet), the ports a
# running sshd or ssh.socket listens on, then the Port lines of the config files.
_ssh_ports() {
    local ports=""
    if command -v sshd >/dev/null 2>&1; then
        mkdir -p /run/sshd 2>/dev/null || true
        ports="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -un)"
    fi
    if [ -z "$ports" ] && command -v ss >/dev/null 2>&1; then
        ports="$(ss -ltnpH 2>/dev/null | awk '/"sshd"|"systemd".*ssh/ { n = split($4, a, ":"); print a[n] }' | sort -un)"
    fi
    if [ -z "$ports" ]; then
        ports="$(cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null \
            | awk 'tolower($1) == "port" && $2 ~ /^[0-9]+$/ { print $2 }' | sort -un)"
    fi
    echo "${ports:-22}"
}

# ── Panel service registry ────────────────────────────────────────────────────
# Creates a symlink in /var/www/services/ pointing to the real systemd unit file.
# Called after installing APT-based services so the panel can see and manage them.
_register_panel_service() {
    local name="$1"
    local unit_path
    mkdir -p /var/www/services
    unit_path=$(systemctl show -p FragmentPath --value "$name" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$unit_path" && -f "$unit_path" ]]; then
        ln -sf "$unit_path" "/var/www/services/${name}.service"
        echo "▶  Panel: registered ${name} → /var/www/services/${name}.service"
    else
        echo "▶  Panel: could not find unit file for ${name}, skipping registration."
    fi
}

# Removes the panel's symlink for a service. Called from uninstall functions.
_unregister_panel_service() {
    local name="$1"
    if [ -L "/var/www/services/${name}.service" ] || [ -f "/var/www/services/${name}.service" ]; then
        rm -f "/var/www/services/${name}.service"
        echo "▶  Panel: unregistered ${name}"
    fi
}
