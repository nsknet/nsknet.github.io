#!/usr/bin/env bash
# netcore.sh — .NET SDK installation (Ubuntu 22.04 / 24.04 / 26.04)
# Docs: https://learn.microsoft.com/dotnet/core/install/linux-ubuntu-install
#
# Installs from Ubuntu's own archive (built and security-patched by Canonical).
# The dotnet/backports PPA is added only when a requested version is not in the
# archive of this release (e.g. 10.0 on 22.04).
#
# Env:
#   DOTNET_VERSIONS  space-separated SDK versions to install (default "10.0"; .NET 8 left support in Nov 2026).
#                    A version that is unavailable is skipped with a warning.

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


DOTNET_DEFAULT_VERSIONS="10.0"
DOTNET_BACKPORTS_PPA="ppa:dotnet/backports"
# Pin that keeps dotnet packages from packages.microsoft.com: mixing Microsoft's
# and Ubuntu's builds of the same package breaks `dotnet` (see Microsoft's
# ".NET package mix ups on Linux"). Harmless when that repository is absent.
DOTNET_APT_PIN="/etc/apt/preferences.d/nspanel-dotnet"

# True when apt has an installable candidate for <package>.
_dotnet_pkg_available() {
    local candidate
    candidate="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ && !seen { print $2; seen = 1 }')"
    [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

_dotnet_backports_enabled() {
    grep -rqsE '^[^#]*ppa\.launchpadcontent\.net/dotnet/backports|^[^#]*ppa\.launchpad\.net/dotnet/backports' \
        /etc/apt/sources.list /etc/apt/sources.list.d/
}

install_netcore() {
    local -a requested=() missing=() installed=() failed=()
    local v
    read -r -a requested <<< "${DOTNET_VERSIONS:-$DOTNET_DEFAULT_VERSIONS}"
    if (( ${#requested[@]} == 0 )); then
        read -r -a requested <<< "$DOTNET_DEFAULT_VERSIONS"
    fi
    for v in "${requested[@]}"; do
        if [[ ! "$v" =~ ^[0-9]+\.[0-9]$ ]]; then
            echo "✗  Invalid .NET version '${v}' in DOTNET_VERSIONS (expected e.g. 8.0 or 10.0)." >&2
            return 1
        fi
    done

    echo "════════════════════════════════════════════════════════════"
    echo "  Installing .NET SDK (${requested[*]})"
    echo "════════════════════════════════════════════════════════════"

    _require_platform ".NET SDK" "22.04 24.04 26.04" "amd64 arm64"

    if [[ ! -f "$DOTNET_APT_PIN" ]]; then
        echo "▶  Pinning dotnet packages to the Ubuntu feeds (${DOTNET_APT_PIN})..."
        cat > "$DOTNET_APT_PIN" <<'PIN'
# Managed by NsPanel (netcore.sh): take .NET from Ubuntu's archive / the
# dotnet/backports PPA, never from packages.microsoft.com.
Package: dotnet* aspnet* netstandard*
Pin: origin "packages.microsoft.com"
Pin-Priority: -10
PIN
    fi

    apt-get update -q

    for v in "${requested[@]}"; do
        _dotnet_pkg_available "dotnet-sdk-${v}" || missing+=("$v")
    done

    if (( ${#missing[@]} )) && ! _dotnet_backports_enabled; then
        echo "▶  Not in Ubuntu's archive for this release: ${missing[*]} — adding ${DOTNET_BACKPORTS_PPA}..."
        apt-get install -y software-properties-common
        add-apt-repository -y "$DOTNET_BACKPORTS_PPA"
        apt-get update -q
    fi

    # One SDK at a time: a version this release does not offer is skipped
    # instead of aborting the others.
    for v in "${requested[@]}"; do
        if ! _dotnet_pkg_available "dotnet-sdk-${v}"; then
            log_warn ".NET SDK ${v} is not available for Ubuntu $(_os_version) ($(_os_arch)) — skipped."
            failed+=("$v")
            continue
        fi
        echo "▶  Installing dotnet-sdk-${v}..."
        if apt-get install -y "dotnet-sdk-${v}"; then
            installed+=("$v")
        else
            log_warn "dotnet-sdk-${v} failed to install — skipped."
            failed+=("$v")
        fi
    done

    if (( ${#installed[@]} == 0 )); then
        echo "✗  No .NET SDK could be installed (requested: ${requested[*]})." >&2
        return 1
    fi

    echo ""
    echo "▶  Installed versions:"
    dotnet --list-sdks

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  .NET SDK installation complete: ${installed[*]}"
    if (( ${#failed[@]} )); then
        echo "⚠  Skipped: ${failed[*]}"
    fi
    echo "════════════════════════════════════════════════════════════"
}

uninstall_netcore() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Removing .NET SDK"
    echo "════════════════════════════════════════════════════════════"
    apt-get purge -y "dotnet-sdk-*" "dotnet-runtime-*" "dotnet-host*" "aspnetcore-*" 2>/dev/null || true
    apt-get autoremove -y || true
    add-apt-repository -r "$DOTNET_BACKPORTS_PPA" -y 2>/dev/null || true
    rm -f "$DOTNET_APT_PIN"
    echo "✔  .NET SDK removed."
}
