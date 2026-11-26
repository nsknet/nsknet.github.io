#!/usr/bin/env bash
# cloudflared.sh — Cloudflare Tunnel client installation
# Installs from Cloudflare's official apt repository (pkg.cloudflare.com), so
# apt verifies every package against Cloudflare's signing key and updates come
# with the normal `apt upgrade`. The repo serves amd64, arm64 and armhf.
# Docs: https://pkg.cloudflare.com/index.html

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


CLOUDFLARED_KEY_URL="https://pkg.cloudflare.com/cloudflare-main.gpg"
CLOUDFLARED_KEYRING="/usr/share/keyrings/cloudflare-main.gpg"
CLOUDFLARED_LIST="/etc/apt/sources.list.d/cloudflared.list"
# Fingerprint of "CloudFlare Software Packaging 2025", the key that signs the
# repository. A download that does not carry it is refused. If Cloudflare
# rotates its key, update this value from pkg.cloudflare.com.
CLOUDFLARED_KEY_FPR="CC94B39C77AE7342A68B89628A682D308D4E5E73"

_cloudflared_install_key() {
    local tmp fpr gnupg_home
    command -v gpg >/dev/null 2>&1 || apt-get install -y gnupg
    tmp="$(mktemp)"
    if ! curl -fsSL --max-time 60 --retry 3 -o "$tmp" "$CLOUDFLARED_KEY_URL"; then
        rm -f "$tmp"
        echo "✗  Could not download ${CLOUDFLARED_KEY_URL}" >&2
        return 1
    fi
    # Throwaway gpg home: inspecting the key must not touch root's keyring.
    gnupg_home="$(mktemp -d)"
    # The published file is a binary keyring; dearmor it if it ever comes armored.
    if grep -q -- "-----BEGIN PGP PUBLIC KEY BLOCK-----" "$tmp"; then
        GNUPGHOME="$gnupg_home" gpg --batch --yes --dearmor -o "${tmp}.gpg" "$tmp"
        mv -f "${tmp}.gpg" "$tmp"
    fi
    fpr="$(GNUPGHOME="$gnupg_home" gpg --batch --show-keys --with-colons "$tmp" 2>/dev/null \
        | awk -F: '$1 == "fpr" && !seen { print $10; seen = 1 }')" || true
    rm -rf "$gnupg_home"
    if [[ "${fpr^^}" != "$CLOUDFLARED_KEY_FPR" ]]; then
        rm -f "$tmp"
        echo "✗  Cloudflare's signing key has an unexpected fingerprint (${fpr:-none}); expected ${CLOUDFLARED_KEY_FPR}." >&2
        echo "   Refusing to trust it. Check https://pkg.cloudflare.com/ and update CLOUDFLARED_KEY_FPR." >&2
        return 1
    fi
    install -m 0644 "$tmp" "$CLOUDFLARED_KEYRING"
    rm -f "$tmp"
    echo "▶  Signing key installed (${CLOUDFLARED_KEY_FPR})."
}

install_cloudflared() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing cloudflared"
    echo "════════════════════════════════════════════════════════════"

    _require_platform "cloudflared" "22.04 24.04 26.04" "amd64 arm64"

    apt-get update -q
    apt-get install -y ca-certificates curl

    echo "▶  Adding Cloudflare's apt repository..."
    install -d -m 0755 /usr/share/keyrings
    _cloudflared_install_key
    echo "deb [signed-by=${CLOUDFLARED_KEYRING}] https://pkg.cloudflare.com/cloudflared any main" \
        > "$CLOUDFLARED_LIST"

    apt-get update -q
    apt-get install -y cloudflared

    cloudflared --version
    echo "✔  cloudflared installed (updates arrive through apt)."
}

uninstall_cloudflared() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Removing cloudflared"
    echo "════════════════════════════════════════════════════════════"
    apt-get purge -y cloudflared 2>/dev/null || dpkg -r cloudflared 2>/dev/null || true
    apt-get autoremove -y || true
    rm -f "$CLOUDFLARED_LIST" "$CLOUDFLARED_KEYRING"
    echo "✔  cloudflared removed."
}
