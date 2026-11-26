"""Disk inventory — block devices, partitions, mount points and usage.

Backs the Disks section of the System page. Read-only: enumeration is done with
`lsblk` (JSON output) enriched with live usage figures from psutil. Mutating
operations (mount / unmount / format) run as streamed jobs via scripts/disks.sh.
"""

import json
import shutil
import subprocess

import psutil

# Filesystems we treat as "real" data partitions worth showing usage for. Pseudo
# and snap/loop filesystems are still listed but never get usage probed.
_PSEUDO_FSTYPES = {"squashfs"}


def list_disks() -> list[dict]:
    """Return the block-device tree: physical disks, each with its partitions.

    Each node carries name, device path, size, type, filesystem, mount point and
    a handful of descriptive fields. Mounted nodes additionally get used/avail/
    percent pulled from the live statvfs via psutil. Best-effort: returns [] when
    lsblk is unavailable (e.g. running the panel off-Linux during development).
    """
    if not shutil.which("lsblk"):
        return []

    cols = "NAME,KNAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL,MODEL,VENDOR,SERIAL,RM,RO,UUID"
    try:
        result = subprocess.run(
            ["lsblk", "-J", "-b", "-o", cols],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            return []
        data = json.loads(result.stdout or "{}")
    except (OSError, ValueError, subprocess.SubprocessError):
        return []

    # Map mountpoint → usage so we only call statvfs once per mounted filesystem.
    usage_by_mount = _usage_by_mountpoint()

    def transform(node: dict) -> dict:
        name = node.get("name") or ""
        mountpoint = node.get("mountpoint") or ""
        size_bytes = _to_int(node.get("size"))
        out = {
            "name": name,
            "path": f"/dev/{name}" if name and not name.startswith("/dev/") else name,
            "kname": node.get("kname") or name,
            "type": node.get("type") or "",
            "size_gb": round(size_bytes / 1e9, 2) if size_bytes else 0.0,
            "fstype": node.get("fstype") or "",
            "mountpoint": mountpoint,
            "label": node.get("label") or "",
            "model": (node.get("model") or "").strip(),
            "vendor": (node.get("vendor") or "").strip(),
            "serial": node.get("serial") or "",
            "uuid": node.get("uuid") or "",
            "removable": str(node.get("rm")).lower() in ("1", "true"),
            "readonly": str(node.get("ro")).lower() in ("1", "true"),
            "used_gb": None,
            "avail_gb": None,
            "use_percent": None,
        }
        if mountpoint and node.get("fstype") not in _PSEUDO_FSTYPES:
            u = usage_by_mount.get(mountpoint)
            if u:
                out["used_gb"] = u["used_gb"]
                out["avail_gb"] = u["avail_gb"]
                out["use_percent"] = u["percent"]
        children = node.get("children") or []
        out["children"] = [transform(c) for c in children]
        return out

    return [_annotate_in_use(transform(dev)) for dev in data.get("blockdevices", [])]


def _annotate_in_use(node: dict) -> dict:
    """Set `in_use` (a reason, or "") on every node: a disk is in use when it or
    any partition under it is mounted, swap, or an LVM/RAID/LUKS member. The
    Storage screen locks Format on those; the backend checks again anyway."""
    children = [_annotate_in_use(child) for child in node.get("children", [])]
    node["children"] = children
    reason = ""
    if node.get("mountpoint"):
        reason = f"mounted on {node['mountpoint']}"
    elif node.get("fstype") in _MEMBER_FSTYPES:
        reason = f"in use as {node['fstype']}"
    elif node.get("type") in ("lvm", "crypt") or str(node.get("type", "")).startswith("raid"):
        reason = f"holds a {node['type']} volume"
    else:
        reason = next((f"{c['path']} {c['in_use']}" for c in children if c.get("in_use")), "")
    node["in_use"] = reason
    node["system"] = node.get("mountpoint") in ("/", "/boot", "/boot/efi", "[SWAP]") or any(
        c.get("system") for c in children
    )
    return node


def _usage_by_mountpoint() -> dict[str, dict]:
    usage: dict[str, dict] = {}
    for part in psutil.disk_partitions(all=False):
        try:
            du = psutil.disk_usage(part.mountpoint)
        except (PermissionError, OSError):
            continue
        usage[part.mountpoint] = {
            "used_gb": round(du.used / 1e9, 2),
            "avail_gb": round(du.free / 1e9, 2),
            "percent": round(du.percent, 1),
        }
    return usage


def _to_int(value) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


# Filesystem signatures that mean "this device belongs to something else".
_MEMBER_FSTYPES = {"swap", "LVM2_member", "linux_raid_member", "crypto_LUKS", "zfs_member"}


def device_in_use(device: str) -> str | None:
    """Why <device> must not be formatted, or None when it looks free.

    Walks the device and every descendant in `lsblk` (a whole disk is "in use"
    when any of its partitions is mounted, is swap, or is an LVM/RAID member).
    Returns None off-Linux, where lsblk is missing; the bash side checks again.
    """
    if not shutil.which("lsblk"):
        return None
    try:
        result = subprocess.run(
            ["lsblk", "-J", "-o", "PATH,TYPE,FSTYPE,MOUNTPOINT", device],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            return f"{device} was not found"
        nodes = json.loads(result.stdout or "{}").get("blockdevices", [])
    except (OSError, ValueError, subprocess.SubprocessError):
        return "could not inspect the device"

    def walk(node: dict) -> str | None:
        path = node.get("path") or device
        if node.get("mountpoint"):
            return f"{path} is mounted on {node['mountpoint']}"
        if node.get("fstype") in _MEMBER_FSTYPES:
            return f"{path} is in use as {node['fstype']}"
        if node.get("type") in ("lvm", "raid0", "raid1", "raid5", "raid6", "raid10", "crypt"):
            return f"{path} holds a {node['type']} volume"
        for child in node.get("children") or []:
            reason = walk(child)
            if reason:
                return reason
        return None

    for node in nodes:
        reason = walk(node)
        if reason:
            return reason
    return None
