"""System API."""
import ipaddress
import re

from fastapi import APIRouter, Form, HTTPException

from core import audit, bash_invoker, runner
from features import disks as disks_feature
from features import system as system_feature

router = APIRouter(prefix="/api/v1/system")

# Linux interface names: letters, digits, and a few separators (e.g. eth0, ens3, enp0s3, wlan0).
_IFACE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.@:-]{0,15}$")

# Block-device paths: /dev/sda1, /dev/vdb, /dev/nvme0n1p2, /dev/mapper/vg-lv, …
_DEVICE_RE = re.compile(r"^/dev/[A-Za-z0-9][A-Za-z0-9/_.-]{0,63}$")
# Mount points must be absolute paths without traversal or shell-hostile chars.
_MOUNT_RE = re.compile(r"^/[A-Za-z0-9][A-Za-z0-9/_.-]{0,127}$")
# Filesystems the panel can create — must stay in sync with format_disk in disks.sh.
_VALID_FSTYPES = {"ext4", "ext3", "ext2", "xfs", "btrfs", "vfat", "ntfs"}


@router.get("")
def get_system():
    return {
        "status": "success",
        "info": system_feature.get_full_info()
    }


@router.post("/common-config")
async def run_common_config():
    cmd = bash_invoker.build_cmd("common_configs")
    job_id = runner.create_job(cmd, "Common Config Setup")
    runner.start_job(job_id)
    audit.log("system.common_configs", f"job={job_id}")
    return {
        "status": "success",
        "job_id": job_id,
        "title": "Common Config Setup"
    }


@router.post("/set-timezone")
async def set_timezone(tz: str = Form(...)):
    allowed = {"Asia/Ho_Chi_Minh", "America/New_York"}
    if tz not in allowed:
        tz = "Asia/Ho_Chi_Minh"
    cmd = bash_invoker.build_cmd("set_timezone", tz)
    job_id = runner.create_job(cmd, f"Set Timezone → {tz}")
    runner.start_job(job_id)
    audit.log("system.set_timezone", f"tz={tz} job={job_id}")
    return {
        "status": "success",
        "job_id": job_id,
        "title": f"Setting Timezone → {tz}"
    }


@router.post("/install-utils")
async def install_utils():
    cmd = bash_invoker.build_cmd("install_common_utils")
    job_id = runner.create_job(cmd, "Install Common Utilities")
    runner.start_job(job_id)
    audit.log("system.install_utils", f"job={job_id}")
    return {
        "status": "success",
        "job_id": job_id,
        "title": "Installing Common Utilities"
    }


@router.post("/set-network")
async def set_network(
    iface: str = Form(...),
    method: str = Form(...),
    address: str = Form(""),
    gateway: str = Form(""),
    dns: str = Form(""),
):
    """Configure an interface for DHCP or a static IPv4 address via netplan."""
    iface = iface.strip()
    method = method.strip().lower()

    if not _IFACE_RE.match(iface):
        raise HTTPException(status_code=400, detail=f"Invalid interface name: {iface}")
    if method not in ("dhcp", "manual"):
        raise HTTPException(status_code=400, detail="method must be 'dhcp' or 'manual'")

    addr_cidr = ""
    gw = ""
    dns_list = ""
    if method == "manual":
        # Address must be CIDR notation (e.g. 192.168.1.50/24).
        try:
            iface_addr = ipaddress.ip_interface(address.strip())
            if iface_addr.version != 4:
                raise ValueError("only IPv4 is supported")
        except ValueError:
            raise HTTPException(
                status_code=400,
                detail="Address must be IPv4 in CIDR notation, e.g. 192.168.1.50/24",
            )
        addr_cidr = str(iface_addr)

        gateway = gateway.strip()
        if gateway:
            try:
                if ipaddress.ip_address(gateway).version != 4:
                    raise ValueError("only IPv4 is supported")
            except ValueError:
                raise HTTPException(status_code=400, detail=f"Invalid gateway: {gateway}")
            gw = gateway

        servers = [s.strip() for s in re.split(r"[,\s]+", dns) if s.strip()]
        for s in servers:
            try:
                ipaddress.ip_address(s)
            except ValueError:
                raise HTTPException(status_code=400, detail=f"Invalid DNS server: {s}")
        dns_list = ",".join(servers)

    cmd = bash_invoker.build_cmd("set_network_ip", iface, method, addr_cidr, gw, dns_list)
    title = (
        f"Set {iface} → DHCP"
        if method == "dhcp"
        else f"Set {iface} → {addr_cidr}"
    )
    job_id = runner.create_job(cmd, title)
    runner.start_job(job_id)
    audit.log(
        "system.set_network",
        f"iface={iface} method={method} address={addr_cidr} gateway={gw} job={job_id}",
    )
    return {
        "status": "success",
        "job_id": job_id,
        "title": title,
    }


@router.post("/swap")
async def install_swap(size_gb: int = Form(...)):
    size_gb = max(1, min(size_gb, 64))
    cmd = bash_invoker.build_cmd("install_virtual_ram", str(size_gb))
    job_id = runner.create_job(cmd, f"Install {size_gb} GB Swap")
    runner.start_job(job_id)
    audit.log("system.install_swap", f"size_gb={size_gb} job={job_id}")
    return {
        "status": "success",
        "job_id": job_id,
        "title": f"Installing {size_gb} GB Virtual RAM"
    }


# ── Disks ───────────────────────────────────────────────────────────────────────

@router.get("/disks")
def get_disks():
    return {
        "status": "success",
        "disks": disks_feature.list_disks(),
    }


def _validate_device(device: str) -> str:
    device = device.strip()
    if not _DEVICE_RE.match(device):
        raise HTTPException(status_code=400, detail=f"Invalid device path: {device!r}")
    return device


def _validate_mountpoint(mountpoint: str) -> str:
    mountpoint = mountpoint.strip().rstrip("/") or "/"
    if not _MOUNT_RE.match(mountpoint):
        raise HTTPException(
            status_code=400,
            detail=f"Invalid mount point: {mountpoint!r}. Use an absolute path, e.g. /mnt/data.",
        )
    return mountpoint


@router.post("/disk/mount")
async def mount_disk(
    device: str = Form(...),
    mountpoint: str = Form(...),
    persist: bool = Form(False),
):
    device = _validate_device(device)
    mountpoint = _validate_mountpoint(mountpoint)
    cmd = bash_invoker.build_cmd("mount_disk", device, mountpoint, "1" if persist else "0")
    title = f"Mount {device} → {mountpoint}"
    job_id = runner.create_job(cmd, title)
    runner.start_job(job_id)
    audit.log("system.mount_disk", f"device={device} mountpoint={mountpoint} persist={persist} job={job_id}")
    return {"status": "success", "job_id": job_id, "title": title}


@router.post("/disk/unmount")
async def unmount_disk(
    target: str = Form(...),
    remove_fstab: bool = Form(False),
):
    target = target.strip()
    # target may be a device (/dev/...) or a mount point (/mnt/...).
    if not (_DEVICE_RE.match(target) or _MOUNT_RE.match(target)):
        raise HTTPException(status_code=400, detail=f"Invalid target: {target!r}")
    cmd = bash_invoker.build_cmd("unmount_disk", target, "1" if remove_fstab else "0")
    title = f"Unmount {target}"
    job_id = runner.create_job(cmd, title)
    runner.start_job(job_id)
    audit.log("system.unmount_disk", f"target={target} remove_fstab={remove_fstab} job={job_id}")
    return {"status": "success", "job_id": job_id, "title": title}


@router.post("/disk/format")
async def format_disk(
    device: str = Form(...),
    fstype: str = Form(...),
    label: str = Form(""),
):
    device = _validate_device(device)
    fstype = fstype.strip().lower()
    if fstype not in _VALID_FSTYPES:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid filesystem: {fstype!r}. Expected one of: {', '.join(sorted(_VALID_FSTYPES))}.",
        )
    label = label.strip()
    if label and not re.match(r"^[A-Za-z0-9._-]{1,32}$", label):
        raise HTTPException(status_code=400, detail="Label may only contain letters, digits, '.', '_' and '-' (max 32).")
    cmd = bash_invoker.build_cmd("format_disk", device, fstype, label)
    title = f"Format {device} as {fstype}"
    job_id = runner.create_job(cmd, title)
    runner.start_job(job_id)
    audit.log("system.format_disk", f"device={device} fstype={fstype} label={label} job={job_id}")
    return {"status": "success", "job_id": job_id, "title": title}
