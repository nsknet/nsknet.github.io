#!/usr/bin/env bash
# netcore.sh — .NET SDK installation (Ubuntu 24.04+)
# Docs: https://learn.microsoft.com/dotnet/core/install/linux-ubuntu

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


install_netcore() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing .NET SDK (6, 7, 8, 9, 10)"
    echo "════════════════════════════════════════════════════════════"

    echo "▶  Adding dotnet/backports PPA..."
    add-apt-repository ppa:dotnet/backports -y

    apt-get update -q

    echo "▶  Installing SDK versions..."
    apt-get install -y \
        dotnet-sdk-6.0 \
        dotnet-sdk-7.0 \
        dotnet-sdk-8.0 \
        dotnet-sdk-9.0 \
        dotnet-sdk-10.0

    echo ""
    echo "▶  Installed versions:"
    dotnet --list-sdks

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  .NET SDK installation complete."
    echo "════════════════════════════════════════════════════════════"
}

uninstall_netcore() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Removing .NET SDK"
    echo "════════════════════════════════════════════════════════════"
    apt-get purge -y "dotnet-sdk-*" "dotnet-runtime-*" "dotnet-host*" "aspnetcore-*" 2>/dev/null || true
    apt-get autoremove -y || true
    add-apt-repository -r ppa:dotnet/backports -y 2>/dev/null || true
    echo "✔  .NET SDK removed."
}
