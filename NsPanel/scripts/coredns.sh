#!/usr/bin/env bash
# coredns.sh — CoreDNS DNS server (Ubuntu 24.04+)
# Installs the CoreDNS binary, points the `hosts` plugin at a panel-managed
# record file (/etc/coredns/hosts, standard "IP domain" format), and forwards
# everything else upstream. DNS records (domain -> IPv4) are managed from the
# panel's DNS screen, which rewrites /etc/coredns/hosts; the hosts plugin
# auto-reloads it, so no restart is needed for record changes.

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


COREDNS_VERSION="1.14.4"
# SHA-256 of the v1.14.4 release tarballs (from the release's .sha256 files).
# Update together with COREDNS_VERSION.
COREDNS_SHA256_AMD64="5b0e6a6a8b97bdcaec65baa70e83ca88ce03ab852355c656e3f7953405cfe36e"
COREDNS_SHA256_ARM64="b3491ed0fbe530a549640a4073d90037ffafa483f007936e1943c1ae0def7325"
COREDNS_BIN="/usr/local/bin/coredns"
COREDNS_DIR="/etc/coredns"
COREDNS_CONF="${COREDNS_DIR}/Corefile"
COREDNS_HOSTS="${COREDNS_DIR}/hosts"
COREDNS_UNIT="/etc/systemd/system/coredns.service"
RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/coredns-no-stub.conf"

# Open UDP <port> to the chosen subnets. DNS is primarily UDP, and the shared
# _ufw_allow_port helper only handles TCP, so this mirrors its subnet logic for
# UDP. Uses the same ALLOWED_SUBNETS env var (set by the panel install dialog).
_coredns_ufw_allow_udp() {
    local port="$1"
    local comment="$2"

    command -v ufw >/dev/null 2>&1 || return 0
    # Like the TCP helper, store the rules even while UFW is inactive, so DNS
    # over UDP keeps working once the operator enables the firewall. ufw itself
    # skips a rule that already exists, so a re-install adds no duplicates.

    local subnets
    if [ -n "${ALLOWED_SUBNETS// /}" ]; then
        read -r -a subnets <<< "$ALLOWED_SUBNETS"
    else
        subnets=("127.0.0.0/8" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16")
    fi

    local cidr
    for cidr in "${subnets[@]}"; do
        if [ "$cidr" = "0.0.0.0/0" ]; then
            echo "▶  UFW: allow any → udp/${port} (${comment})"
            ufw allow "${port}/udp" comment "$comment" >/dev/null
        else
            echo "▶  UFW: allow ${cidr} → udp/${port} (${comment})"
            ufw allow from "$cidr" to any port "$port" proto udp comment "$comment" >/dev/null
        fi
    done
    ufw reload >/dev/null 2>&1 || true
}

# If systemd-resolved holds port 53 (its stub listener binds 127.0.0.53:53),
# disable only the stub listener so CoreDNS can bind :53 — without losing
# resolved itself as the system resolver. The modern, minimal fix.
_coredns_free_port53() {
    systemctl is-active --quiet systemd-resolved 2>/dev/null || return 0
    # Is something already listening on :53 (other than what we're about to run)?
    if ! ss -lunH 'sport = :53' 2>/dev/null | grep -q ':53'; then
        return 0
    fi
    echo "▶  systemd-resolved is using port 53 — disabling its stub listener..."
    mkdir -p "$(dirname "$RESOLVED_DROPIN")"
    cat > "$RESOLVED_DROPIN" <<'EOF'
# Added by NsPanel so CoreDNS can bind port 53.
[Resolve]
DNSStubListener=no
EOF
    systemctl restart systemd-resolved || true
    # Point /etc/resolv.conf at the real resolved managed file (stub-free).
    if [ -f /run/systemd/resolve/resolv.conf ]; then
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    fi
}

install_coredns() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing CoreDNS ${COREDNS_VERSION}"
    echo "  Records file: ${COREDNS_HOSTS}"
    echo "════════════════════════════════════════════════════════════"

    export DEBIAN_FRONTEND=noninteractive

    # A resolver open to the internet is a DNS amplification source, and
    # CoreDNS has no login of its own: never expose it to 0.0.0.0/0.
    _forbid_public_access "CoreDNS"

    # ── Dependencies (download + extract + port check) ────────────
    command -v wget   >/dev/null 2>&1 || apt-get install -y wget
    command -v tar    >/dev/null 2>&1 || apt-get install -y tar
    command -v ss     >/dev/null 2>&1 || apt-get install -y iproute2

    # ── Download, verify and install the CoreDNS binary ───────────
    local arch tgz url tmpdir published expected
    arch="$(_os_arch)"
    case "$arch" in
        amd64) expected="$COREDNS_SHA256_AMD64" ;;
        arm64) expected="$COREDNS_SHA256_ARM64" ;;
        *)
            echo "✗  CoreDNS: architecture ${arch} is not supported here (amd64, arm64)." >&2
            return 1
            ;;
    esac
    tgz="coredns_${COREDNS_VERSION}_linux_${arch}.tgz"
    url="https://github.com/coredns/coredns/releases/download/v${COREDNS_VERSION}/${tgz}"
    tmpdir="$(mktemp -d)"

    echo "▶  Downloading ${url}..."
    if ! wget -q --timeout=60 --tries=3 -O "${tmpdir}/${tgz}" "$url" \
        || ! wget -q --timeout=60 --tries=3 -O "${tmpdir}/${tgz}.sha256" "${url}.sha256"; then
        rm -rf "$tmpdir"
        echo "✗  Could not download CoreDNS ${COREDNS_VERSION} from GitHub." >&2
        return 1
    fi

    # The release's own .sha256 must agree with the hash pinned in this script
    # (so a tampered release is caught too), and the tarball must match it.
    published="$(awk 'NR == 1 { print $1 }' "${tmpdir}/${tgz}.sha256")"
    if [[ "${published,,}" != "${expected,,}" ]]; then
        rm -rf "$tmpdir"
        echo "✗  The published checksum of ${tgz} (${published:-none}) does not match the pinned one (${expected})." >&2
        return 1
    fi
    if ! _verify_sha256 "${tmpdir}/${tgz}" "$expected"; then
        rm -rf "$tmpdir"
        return 1
    fi

    echo "▶  Extracting binary to ${COREDNS_BIN}..."
    tar --no-same-owner -xzf "${tmpdir}/${tgz}" -C "$tmpdir" coredns
    install -m 0755 "${tmpdir}/coredns" "$COREDNS_BIN"
    rm -rf "$tmpdir"

    # ── Config dir + panel-managed record file ────────────────────
    mkdir -p "$COREDNS_DIR"
    if [ ! -f "$COREDNS_HOSTS" ]; then
        echo "▶  Creating empty record file ${COREDNS_HOSTS}..."
        cat > "$COREDNS_HOSTS" <<'EOF'
# CoreDNS host records — managed by NsPanel (DNS screen).
# Format: <IPv4> <domain>   e.g.   192.168.1.10 example.com
EOF
        chmod 644 "$COREDNS_HOSTS"
    fi

    # ── Corefile: hosts plugin (external file) + upstream forward ──
    echo "▶  Writing ${COREDNS_CONF}..."
    cat > "$COREDNS_CONF" <<EOF
.:53 {
    errors
    log
    hosts ${COREDNS_HOSTS} {
        fallthrough
    }
    forward . 8.8.8.8 8.8.4.4
    cache 30
}
EOF

    # ── Free port 53 if systemd-resolved's stub is on it ──────────
    _coredns_free_port53

    # ── systemd unit (run as root, matches the known-working setup) ─
    echo "▶  Writing ${COREDNS_UNIT}..."
    cat > "$COREDNS_UNIT" <<EOF
[Unit]
Description=CoreDNS DNS server
Documentation=https://coredns.io
After=network.target

[Service]
User=root
ExecStart=${COREDNS_BIN} -conf ${COREDNS_CONF}
ExecReload=/bin/kill -SIGUSR1 \$MAINPID
Restart=on-failure
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable coredns >/dev/null 2>&1 || true
    systemctl restart coredns
    _register_panel_service coredns

    # ── Firewall: DNS on 53 (TCP via shared helper + UDP) ─────────
    _ufw_allow_port 53 "CoreDNS"
    _coredns_ufw_allow_udp 53 "CoreDNS"

    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    ip="${ip:-<server-ip>}"

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  CoreDNS installed and running on port 53."
    echo "   Binary  : ${COREDNS_BIN}"
    echo "   Config  : ${COREDNS_CONF}"
    echo "   Records : ${COREDNS_HOSTS}  (manage from the panel's DNS screen)"
    echo "   Server  : ${ip}"
    echo "   Allow   : ${ALLOWED_SUBNETS[*]}"
    echo ""
    echo "   Add a record in the DNS screen, then test:"
    echo "     dig @${ip} <domain>"
    echo "════════════════════════════════════════════════════════════"
}

uninstall_coredns() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Removing CoreDNS"
    echo "════════════════════════════════════════════════════════════"
    systemctl disable --now coredns 2>/dev/null || true
    rm -f "$COREDNS_UNIT"
    systemctl daemon-reload || true
    rm -f "$COREDNS_BIN"
    _unregister_panel_service coredns

    # Restore systemd-resolved's stub listener if we disabled it.
    if [ -f "$RESOLVED_DROPIN" ]; then
        echo "▶  Re-enabling systemd-resolved stub listener..."
        rm -f "$RESOLVED_DROPIN"
        systemctl restart systemd-resolved 2>/dev/null || true
    fi

    echo "✔  CoreDNS removed. Records file ${COREDNS_HOSTS} was left untouched."
}
