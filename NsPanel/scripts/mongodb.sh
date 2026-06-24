#!/usr/bin/env bash
# mongodb.sh — MongoDB 8.3 Community Edition (Ubuntu 24.04 / 22.04, Linux Mint 21+/22+)
# Reference: https://www.mongodb.com/docs/manual/administration/install-community/
#
# Notes:
#   - MongoDB 8.3 is a minor release in the 8.0 cycle. It still uses the 8.0
#     release signing key (server-8.0.asc) but its repo path is `8.3`.
#   - Currently only noble (24.04) and jammy (22.04) have 8.3 packages.
#     focal (20.04) gets no 8.3 — fall back to 8.0 there.

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


MONGO_PORT=27017
MONGO_VERSION="8.3"   # repo branch; auto-falls back to 8.0 on focal

# ── Detect the underlying Ubuntu LTS codename ─────────────────────────────────
# Linux Mint reports its own codename (wilma/virginia/xia/etc.) from
# `lsb_release -cs`, but /etc/os-release exposes UBUNTU_CODENAME — which is
# what MongoDB's APT repo expects (noble/jammy/focal).
_detect_ubuntu_codename() {
    local codename=""

    # 1) Prefer UBUNTU_CODENAME from /etc/os-release (set on Mint + Ubuntu derivatives).
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-}")"
    fi

    # 2) Fall back to lsb_release -cs (plain Ubuntu).
    if [ -z "$codename" ] && command -v lsb_release >/dev/null 2>&1; then
        codename="$(lsb_release -cs)"
    fi

    # 3) Map Linux Mint codenames → Ubuntu base codename (in case UBUNTU_CODENAME
    #    is missing for some reason).
    case "$codename" in
        # Mint 22.x → Ubuntu 24.04 Noble
        wilma|virginia|xia|zara) codename="noble" ;;
        # Mint 21.x → Ubuntu 22.04 Jammy
        vanessa|vera|victoria) codename="jammy" ;;
        # Mint 20.x → Ubuntu 20.04 Focal
        ulyana|ulyssa|uma|una) codename="focal" ;;
    esac

    echo "$codename"
}

# ── MongoDB ───────────────────────────────────────────────────────────────────
install_mongodb() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing MongoDB ${MONGO_VERSION} Community Edition"
    echo "════════════════════════════════════════════════════════════"

    # Prerequisites
    apt-get install -y gnupg curl lsb-release

    # Detect base Ubuntu LTS codename (works for Ubuntu and Linux Mint).
    local UBUNTU_CODENAME
    UBUNTU_CODENAME="$(_detect_ubuntu_codename)"
    echo "▶  Detected Ubuntu base codename: ${UBUNTU_CODENAME:-<unknown>}"

    # Pick the right MongoDB branch for this Ubuntu release.
    # 8.3 is only published for noble + jammy; focal still needs 8.0.
    local branch="${MONGO_VERSION}"
    case "$UBUNTU_CODENAME" in
        noble|jammy) ;;  # 8.3 supported
        focal)
            echo "⚠  MongoDB ${MONGO_VERSION} is not published for focal (20.04). Falling back to 8.0."
            branch="8.0"
            ;;
        *)
            echo "⚠  Unsupported / unrecognized codename '${UBUNTU_CODENAME}'."
            echo "   MongoDB ${MONGO_VERSION} officially supports only noble/jammy."
            echo "   Falling back to 'noble'. If this fails, set UBUNTU_CODENAME manually."
            UBUNTU_CODENAME="noble"
            ;;
    esac

    # Import the MongoDB GPG signing key. MongoDB 8.x (including 8.3) uses the
    # 8.0 release signing key, so the keyring file is named server-8.0.gpg
    # regardless of the branch we install.
    echo "▶  Importing MongoDB 8.x GPG key..."
    rm -f /usr/share/keyrings/mongodb-server-8.0.gpg
    curl -fsSL https://pgp.mongodb.com/server-8.0.asc \
        | gpg --batch --yes --dearmor -o /usr/share/keyrings/mongodb-server-8.0.gpg

    # Detect arch for the deb line (MongoDB ships amd64 + arm64).
    local ARCH
    case "$(dpkg --print-architecture)" in
        amd64) ARCH="amd64" ;;
        arm64) ARCH="arm64" ;;
        *)     ARCH="amd64,arm64" ;;  # let apt pick
    esac

    # Remove any stale MongoDB list files from previous branches so apt doesn't
    # see duplicate sources (e.g. 8.0 → 8.3 upgrade).
    rm -f /etc/apt/sources.list.d/mongodb-org-*.list

    echo "▶  Adding MongoDB ${branch} APT repository for ${UBUNTU_CODENAME} (${ARCH})..."
    echo "deb [ arch=${ARCH} signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] \
https://repo.mongodb.org/apt/ubuntu ${UBUNTU_CODENAME}/mongodb-org/${branch} multiverse" \
        | tee "/etc/apt/sources.list.d/mongodb-org-${branch}.list" > /dev/null

    apt-get update -q
    apt-get install -y mongodb-org

    # ── Bind to all interfaces so the LAN subnets allowed by UFW can connect.
    # MongoDB defaults to bindIp: 127.0.0.1, which would make the firewall
    # rules pointless. We rewrite it to 0.0.0.0 and let UFW restrict who
    # actually reaches the port.
    echo "▶  Configuring /etc/mongod.conf (bindIp → 0.0.0.0, port ${MONGO_PORT})..."
    if [ -f /etc/mongod.conf ]; then
        sed -i -E 's|^([[:space:]]*)bindIp:[[:space:]].*|\1bindIp: 0.0.0.0|' /etc/mongod.conf
        sed -i -E "s|^([[:space:]]*)port:[[:space:]].*|\1port: ${MONGO_PORT}|" /etc/mongod.conf
    fi

    # Firewall: allow only private subnets, deny everything else.
    _ufw_allow_port "${MONGO_PORT}" "MongoDB"

    # ── Service registration (same pattern as elasticsearch.sh) ───────────────
    # Use /bin/systemctl explicitly for daemon-reload in case PATH is stripped.
    /bin/systemctl daemon-reload
    systemctl enable mongod.service
    systemctl restart mongod.service
    _register_panel_service mongod
    systemctl status mongod --no-pager

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  MongoDB ${branch} installed."
    echo "   Port  : ${MONGO_PORT}  (bound to 0.0.0.0)"
    echo "   Data  : /var/lib/mongodb"
    echo "   Logs  : /var/log/mongodb/mongod.log"
    echo "   Conf  : /etc/mongod.conf"
    echo "   Allow : ${ALLOWED_SUBNETS[*]}"
    echo ""
    echo "   Test  : mongosh"
    echo "   ⚠  Auth is OFF. Enable authorization before exposing beyond LAN."
    echo "      https://www.mongodb.com/docs/manual/administration/security-checklist/"
    echo "════════════════════════════════════════════════════════════"
}

uninstall_mongodb() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Removing MongoDB"
    echo "════════════════════════════════════════════════════════════"
    systemctl disable --now mongod 2>/dev/null || true
    apt-get purge -y mongodb-org "mongodb-org-*" 2>/dev/null || true
    apt-get autoremove -y || true
    rm -rf /var/lib/mongodb /var/log/mongodb
    rm -f /etc/apt/sources.list.d/mongodb-org-*.list
    rm -f /usr/share/keyrings/mongodb-server-8.0.gpg
    _unregister_panel_service mongod
    echo "✔  MongoDB removed (data in /var/lib/mongodb deleted)."
}
