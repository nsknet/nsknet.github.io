#!/usr/bin/env bash
# disks.sh — Block device operations: mount, unmount, format.

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
set -eo pipefail


# ── Mount a partition ──────────────────────────────────────────────────────────
# Usage: mount_disk <device> <mountpoint> [persist]
#
# Mounts <device> at <mountpoint> (created if missing). When persist == "1" a
# matching entry is added to /etc/fstab (keyed by UUID, deduplicated) so the
# mount survives reboots.
mount_disk() {
    local device="$1"
    local mountpoint="$2"
    local persist="${3:-0}"

    echo "════════════════════════════════════════════════════════════"
    echo "  Mount ${device} → ${mountpoint}"
    echo "════════════════════════════════════════════════════════════"

    if [ -z "$device" ] || [ -z "$mountpoint" ]; then
        echo "❌  Error: device and mountpoint are required."
        return 1
    fi
    if [ ! -b "$device" ]; then
        echo "❌  Error: '${device}' is not a block device."
        return 1
    fi

    # Detect the filesystem so we can report it and write a correct fstab entry.
    local fstype
    fstype="$(blkid -o value -s TYPE "$device" 2>/dev/null || true)"
    if [ -z "$fstype" ]; then
        echo "❌  Error: '${device}' has no detectable filesystem. Format it first."
        return 1
    fi
    echo "▶  Detected filesystem: ${fstype}"

    if ! mountpoint -q "$mountpoint" 2>/dev/null; then
        echo "▶  Creating mount point ${mountpoint}..."
        mkdir -p "$mountpoint"
        echo "▶  Mounting..."
        # FUSE-based mount helpers (ntfs-3g, exfat-fuse) fork a background daemon
        # that inherits this job's std streams. If it inherits the panel runner's
        # stdout pipe it keeps it open forever, so the runner never sees EOF and
        # the job appears to hang even though the mount already succeeded. Detach
        # the mount helper's fds (stdin/stdout → /dev/null, stderr → temp file) so
        # the daemon can't hold the pipe; we surface any error ourselves.
        local mnt_err
        mnt_err="$(mktemp)"
        if ! mount "$device" "$mountpoint" </dev/null >/dev/null 2>"$mnt_err"; then
            sed 's/^/    /' "$mnt_err"
            rm -f "$mnt_err"
            echo "❌  Error: failed to mount ${device} at ${mountpoint}."
            return 1
        fi
        rm -f "$mnt_err"
    else
        echo "▶  ${mountpoint} is already a mount point — skipping mount."
    fi

    if [ "$persist" = "1" ]; then
        local uuid
        uuid="$(blkid -o value -s UUID "$device" 2>/dev/null || true)"
        if [ -n "$uuid" ]; then
            echo "▶  Persisting to /etc/fstab (UUID=${uuid})..."
            # Drop any prior entry for this UUID or mount point, then append fresh.
            sed -i "\#UUID=${uuid}[[:space:]]#d" /etc/fstab 2>/dev/null || true
            sed -i "\# ${mountpoint}[[:space:]]#d" /etc/fstab 2>/dev/null || true
            echo "UUID=${uuid} ${mountpoint} ${fstype} defaults,nofail 0 2" >> /etc/fstab
            echo "   → Entry persisted."
        else
            echo "⚠  Could not read UUID — skipping fstab persistence."
        fi
    fi

    echo ""
    echo "▶  Current mount:"
    findmnt "$mountpoint" || df -h "$mountpoint"
    echo ""
    echo "✔  ${device} mounted at ${mountpoint}."
    echo "════════════════════════════════════════════════════════════"
}

# ── Unmount a partition ────────────────────────────────────────────────────────
# Usage: unmount_disk <target> [remove_fstab]
#
# <target> may be either a device (/dev/sdb1) or a mount point (/mnt/data).
# When remove_fstab == "1" the matching /etc/fstab entry is also removed so the
# partition is not re-mounted on the next boot.
unmount_disk() {
    local target="$1"
    local remove_fstab="${2:-0}"

    echo "════════════════════════════════════════════════════════════"
    echo "  Unmount ${target}"
    echo "════════════════════════════════════════════════════════════"

    if [ -z "$target" ]; then
        echo "❌  Error: target is required."
        return 1
    fi

    # Resolve the mount point (works whether target is a device or a path).
    local mp uuid
    mp="$(findmnt -n -o TARGET "$target" 2>/dev/null | head -n1 || true)"
    uuid="$(blkid -o value -s UUID "$target" 2>/dev/null || true)"

    echo "▶  Unmounting ${target}..."
    if ! umount "$target"; then
        echo "❌  Error: failed to unmount. The device may be busy — close any open"
        echo "    files or processes using it (try: lsof ${mp:-$target}) and retry."
        return 1
    fi
    echo "   → Unmounted."

    if [ "$remove_fstab" = "1" ]; then
        echo "▶  Removing /etc/fstab entries..."
        [ -n "$uuid" ] && sed -i "\#UUID=${uuid}[[:space:]]#d" /etc/fstab 2>/dev/null || true
        [ -n "$mp" ] && sed -i "\# ${mp}[[:space:]]#d" /etc/fstab 2>/dev/null || true
        echo "   → fstab cleaned."
    fi

    echo ""
    echo "✔  ${target} unmounted."
    echo "════════════════════════════════════════════════════════════"
}

# ── Format a partition ─────────────────────────────────────────────────────────
# Usage: format_disk <device> <fstype> [label]
#
# Creates a fresh <fstype> filesystem on <device>. THIS DESTROYS ALL DATA on the
# device. The caller (web panel) gates this behind an explicit confirmation.
format_disk() {
    local device="$1"
    local fstype="$2"
    local label="${3:-}"

    echo "════════════════════════════════════════════════════════════"
    echo "  Format ${device} as ${fstype}"
    echo "════════════════════════════════════════════════════════════"
    echo "  ⚠  ALL DATA on ${device} will be permanently erased."
    echo ""

    if [ -z "$device" ] || [ -z "$fstype" ]; then
        echo "❌  Error: device and fstype are required."
        return 1
    fi
    if [ ! -b "$device" ]; then
        echo "❌  Error: '${device}' is not a block device."
        return 1
    fi

    # Refuse to format anything that is currently mounted — a strong safety net.
    if findmnt -n -S "$device" >/dev/null 2>&1; then
        echo "❌  Error: '${device}' is mounted. Unmount it before formatting."
        return 1
    fi

    local label_args=()
    case "$fstype" in
        ext2|ext3|ext4)
            command -v "mkfs.${fstype}" >/dev/null || { echo "▶  Installing e2fsprogs..."; apt-get install -y e2fsprogs; }
            [ -n "$label" ] && label_args=(-L "$label")
            echo "▶  Running mkfs.${fstype}..."
            "mkfs.${fstype}" -F "${label_args[@]}" "$device"
            ;;
        xfs)
            command -v mkfs.xfs >/dev/null || { echo "▶  Installing xfsprogs..."; apt-get install -y xfsprogs; }
            [ -n "$label" ] && label_args=(-L "$label")
            echo "▶  Running mkfs.xfs..."
            mkfs.xfs -f "${label_args[@]}" "$device"
            ;;
        btrfs)
            command -v mkfs.btrfs >/dev/null || { echo "▶  Installing btrfs-progs..."; apt-get install -y btrfs-progs; }
            [ -n "$label" ] && label_args=(-L "$label")
            echo "▶  Running mkfs.btrfs..."
            mkfs.btrfs -f "${label_args[@]}" "$device"
            ;;
        vfat|fat32)
            command -v mkfs.vfat >/dev/null || { echo "▶  Installing dosfstools..."; apt-get install -y dosfstools; }
            [ -n "$label" ] && label_args=(-n "$label")
            echo "▶  Running mkfs.vfat (FAT32)..."
            mkfs.vfat -F 32 "${label_args[@]}" "$device"
            ;;
        ntfs)
            command -v mkfs.ntfs >/dev/null || { echo "▶  Installing ntfs-3g..."; apt-get install -y ntfs-3g; }
            [ -n "$label" ] && label_args=(-L "$label")
            echo "▶  Running mkfs.ntfs (quick format)..."
            mkfs.ntfs -f "${label_args[@]}" "$device"
            ;;
        *)
            echo "❌  Error: unsupported filesystem '${fstype}'."
            echo "    Supported: ext4, ext3, ext2, xfs, btrfs, vfat, ntfs."
            return 1
            ;;
    esac

    echo ""
    echo "▶  New filesystem:"
    blkid "$device" || true
    echo ""
    echo "✔  ${device} formatted as ${fstype}."
    echo "════════════════════════════════════════════════════════════"
}
