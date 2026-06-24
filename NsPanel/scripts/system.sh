#!/usr/bin/env bash
# system.sh — Common VPS setup and swap management (Ubuntu 24.04+)

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


# ── Common configuration ───────────────────────────────────────────────────────
common_configs() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Common VPS Configuration"
    echo "════════════════════════════════════════════════════════════"

    echo ""
    echo "▶  Timezone → Asia/Ho_Chi_Minh (GMT+7)"
    ln -sf /usr/share/zoneinfo/Asia/Ho_Chi_Minh /etc/localtime
    timedatectl set-timezone Asia/Ho_Chi_Minh 2>/dev/null || true
    timedatectl status

    echo ""
    echo "▶  Updating package index..."
    apt-get update -q

    echo ""
    echo "▶  Installing common utilities..."
    apt-get install -y --no-install-recommends \
        wget curl axel rsync \
        htop bpytop ncdu iotop sysstat \
        tmux \
        rar unrar zip unzip p7zip-full \
        jq git bc tree pv \
        nano vim less \
        lsof psmisc \
        ca-certificates gnupg lsb-release software-properties-common apt-transport-https \
        net-tools dnsutils iproute2 iftop mtr-tiny traceroute

    echo ""
    echo "▶  Installing cloudflared..."
    install_cloudflared

    echo ""
    echo "▶  Configuring UFW firewall..."
    install_ufw

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  Common configuration complete."
    echo "════════════════════════════════════════════════════════════"
}

# ── Virtual RAM (swap) ─────────────────────────────────────────────────────────
install_virtual_ram() {
    local size_gb="${1:-4}"
    local swapfile="/swapfile"

    echo "════════════════════════════════════════════════════════════"
    echo "  Virtual RAM (swap) Configuration"
    echo "════════════════════════════════════════════════════════════"
    echo "  Target: ${size_gb} GB on ${swapfile}"
    echo ""

    # 1. Check if the swapfile is already active and matches the requested size
    local current_active=false
    local current_size_gb=0

    if swapon --show | grep -q "^${swapfile}"; then
        current_active=true
        # Calculate current size in GB from /proc/swaps
        local size_kb=$(awk -v sf="$swapfile" '$1 == sf {print $3}' /proc/swaps 2>/dev/null)
        if [ -n "$size_kb" ]; then
            current_size_gb=$(( (size_kb + 524288) / 1048576 ))
        fi
    fi

    if [ "$current_active" = true ] && [ "$current_size_gb" -eq "$size_gb" ]; then
        echo "✔  Swap file ${swapfile} is already active and configured with the requested size of ${size_gb} GB."
        echo "   Nothing to change."
        echo ""
        swapon --show
        echo ""
        free -h
        echo "════════════════════════════════════════════════════════════"
        return 0
    fi

    # 2. Deactivate active swap cleanly
    if [ "$current_active" = true ]; then
        echo "▶  Disabling existing active swap on ${swapfile} (${current_size_gb} GB)..."
        
        # Free up OS pagecaches, dentries, and inodes to release physical RAM
        echo "   → Syncing and dropping system memory caches..."
        sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        
        if ! swapoff "$swapfile"; then
            echo ""
            echo "❌  Error: Failed to deactivate existing swap."
            echo "    Your system RAM might be fully exhausted and unable to hold the active swap pages."
            echo "    Please close memory-heavy applications first, then try again."
            echo "════════════════════════════════════════════════════════════"
            return 1
        fi
        echo "   → Deactivation successful."
    fi

    # 3. Ensure disk cleanup (remove existing file to prevent size/allocation issues)
    if [ -f "$swapfile" ] || [ -L "$swapfile" ]; then
        echo "▶  Removing old swap file ${swapfile}..."
        rm -f "$swapfile"
    fi

    # 4. Allocate new swap file
    echo "▶  Allocating ${size_gb} GB for ${swapfile}..."
    # fallocate is instant; fall back to dd if the filesystem/OS doesn't support it
    if fallocate -l "${size_gb}G" "$swapfile" 2>/dev/null; then
        echo "   (used fallocate)"
    else
        echo "   (falling back to dd — this may take a moment)"
        if ! dd if=/dev/zero of="$swapfile" bs=1M count=$(( size_gb * 1024 )) status=progress; then
            echo "❌  Error: Failed to allocate file via dd. Check disk space."
            echo "════════════════════════════════════════════════════════════"
            return 1
        fi
    fi

    # 5. Set correct permissions
    chmod 600 "$swapfile"
    chown root:root "$swapfile"

    # 6. Format as swap space
    echo "▶  Formatting as swap..."
    if ! mkswap "$swapfile"; then
        echo "❌  Error: Failed to format ${swapfile} as swap."
        echo "════════════════════════════════════════════════════════════"
        return 1
    fi

    # 7. Activate swap
    echo "▶  Activating swap..."
    if ! swapon "$swapfile"; then
        echo "❌  Error: Failed to activate swap."
        echo "════════════════════════════════════════════════════════════"
        return 1
    fi

    # 8. Clean up and persist in /etc/fstab (deduplicate old entries)
    echo "▶  Updating /etc/fstab entry..."
    # Remove any existing lines starting with /swapfile followed by space/tab
    sed -i '/^\/swapfile[[:space:]]/d' /etc/fstab 2>/dev/null || true
    # Append fresh entry
    echo "${swapfile} none swap defaults 0 0" >> /etc/fstab
    echo "   → Entry successfully persisted."

    echo ""
    echo "▶  New swap status:"
    swapon --show
    echo ""
    free -h

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "✔  ${size_gb} GB virtual RAM configured successfully."
    echo "════════════════════════════════════════════════════════════"
}

# Backwards-compatible alias used by old menu entries
install_virtual_ram_4g() {
    install_virtual_ram 4
}

# ── Individual config functions ───────────────────────────────────────────────

set_timezone() {
    local tz="${1:-Asia/Ho_Chi_Minh}"
    echo "▶  Setting timezone to ${tz}..."
    ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime
    timedatectl set-timezone "$tz" 2>/dev/null || true
    timedatectl status
    echo "✔  Timezone set to ${tz}."
}

install_common_utils() {
    echo "════════════════════════════════════════════════════════════"
    echo "  Installing common utilities"
    echo "════════════════════════════════════════════════════════════"
    apt-get update -q
    apt-get install -y --no-install-recommends \
        wget curl axel rsync \
        htop bpytop ncdu iotop sysstat \
        tmux \
        rar unrar zip unzip p7zip-full \
        jq git bc tree pv \
        nano vim less \
        lsof psmisc \
        ca-certificates gnupg lsb-release software-properties-common apt-transport-https \
        net-tools dnsutils iproute2 iftop mtr-tiny traceroute
    echo ""
    echo "✔  Common utilities installed."
}

# ── Network interface IP configuration (netplan) ──────────────────────────────
# Usage: set_network_ip <iface> <dhcp|manual> [address/cidr] [gateway] [dns_csv]
#
# Writes a dedicated drop-in /etc/netplan/90-nspanel-<iface>.yaml so it does not
# clobber the distro's own netplan files, then applies it. A timestamped backup
# of the drop-in (if it already existed) is kept alongside it.
set_network_ip() {
    local iface="$1"
    local method="$2"
    local address="$3"
    local gateway="$4"
    local dns_csv="$5"

    echo "════════════════════════════════════════════════════════════"
    echo "  Network configuration — ${iface}"
    echo "════════════════════════════════════════════════════════════"

    if [ -z "$iface" ] || [ -z "$method" ]; then
        echo "❌  Error: interface and method are required."
        return 1
    fi

    if ! ip link show "$iface" >/dev/null 2>&1; then
        echo "❌  Error: interface '${iface}' does not exist."
        return 1
    fi

    if [ ! -d /etc/netplan ]; then
        echo "❌  Error: /etc/netplan not found — this host does not use netplan."
        return 1
    fi

    local target="/etc/netplan/90-nspanel-${iface}.yaml"

    # Back up an existing drop-in before overwriting.
    if [ -f "$target" ]; then
        local backup="${target}.$(date +%Y%m%d-%H%M%S).bak"
        cp -a "$target" "$backup"
        echo "▶  Backed up existing config → ${backup}"
    fi

    # Build the nameserver block (shared by both methods).
    local dns_block=""
    if [ -n "$dns_csv" ]; then
        local servers
        IFS=',' read -ra servers <<< "$dns_csv"
        dns_block=$'      nameservers:\n        addresses:'
        local s
        for s in "${servers[@]}"; do
            [ -n "$s" ] && dns_block+=$'\n          - '"$s"
        done
    fi

    if [ "$method" = "dhcp" ]; then
        echo "▶  Configuring ${iface} for automatic (DHCP) addressing..."
        {
            echo "network:"
            echo "  version: 2"
            echo "  ethernets:"
            echo "    ${iface}:"
            echo "      dhcp4: true"
            [ -n "$dns_block" ] && printf '%s\n' "$dns_block"
        } > "$target"
    elif [ "$method" = "manual" ]; then
        if [ -z "$address" ]; then
            echo "❌  Error: manual method requires an address in CIDR notation."
            return 1
        fi
        echo "▶  Configuring ${iface} with static address ${address}..."
        [ -n "$gateway" ] && echo "   gateway: ${gateway}"
        {
            echo "network:"
            echo "  version: 2"
            echo "  ethernets:"
            echo "    ${iface}:"
            echo "      dhcp4: false"
            echo "      addresses:"
            echo "        - ${address}"
            if [ -n "$gateway" ]; then
                echo "      routes:"
                echo "        - to: default"
                echo "          via: ${gateway}"
            fi
            [ -n "$dns_block" ] && printf '%s\n' "$dns_block"
        } > "$target"
    else
        echo "❌  Error: unknown method '${method}' (expected dhcp or manual)."
        return 1
    fi

    chmod 600 "$target"

    echo ""
    echo "▶  Generated ${target}:"
    echo "────────────────────────────────────────────────────────────"
    cat "$target"
    echo "────────────────────────────────────────────────────────────"
    echo ""

    echo "▶  Validating configuration (netplan generate)..."
    if ! netplan generate; then
        echo "❌  Error: netplan validation failed. Reverting."
        rm -f "$target"
        return 1
    fi

    echo "▶  Applying configuration (netplan apply)..."
    echo "   ⚠  If you are connected over this interface, the session may briefly drop."
    if ! netplan apply; then
        echo "❌  Error: netplan apply failed."
        return 1
    fi

    # Give the interface a moment to settle, then report the result.
    sleep 2
    echo ""
    echo "▶  Current addresses on ${iface}:"
    ip -brief addr show "$iface" 2>/dev/null || ip addr show "$iface"
    echo ""
    echo "✔  Network configuration applied to ${iface}."
}

