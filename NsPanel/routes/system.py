"""System API: host info, timezone, network, swap and disks."""
import ipaddress
import re
from typing import Annotated, Any
from zoneinfo import available_timezones

from fastapi import APIRouter, Form
from pydantic import BaseModel, field_validator

from core import jobs
from core.schemas import DataResponse, JobResponse
from core.validators import DEVICE, IFACE, MOUNT, VALID_FSTYPES, bad_request, require_match
from features import disks as disks_feature
from features import system as system_feature

router = APIRouter(prefix="/api/v1/system")

_SYSTEM_SCRIPT = "system.sh"
_DISKS_SCRIPT = "disks.sh"
_LABEL_RE = re.compile(r"^[A-Za-z0-9._-]{1,32}$")


@router.get("")
def get_system() -> DataResponse[dict[str, Any]]:
    return DataResponse(data=system_feature.get_full_info())


@router.post("/common-config")
def run_common_config() -> JobResponse:
    return jobs.launch_bash(
        "common_configs",
        script=_SYSTEM_SCRIPT,
        label="Common Config Setup",
        audit_action="system.common_configs",
    )


@router.post("/install-utils")
def install_utils() -> JobResponse:
    return jobs.launch_bash(
        "install_common_utils",
        script=_SYSTEM_SCRIPT,
        label="Install Common Utilities",
        title="Installing Common Utilities",
        audit_action="system.install_utils",
    )


@router.post("/set-timezone")
def set_timezone(tz: Annotated[str, Form()]) -> JobResponse:
    tz = tz.strip()
    if tz not in available_timezones():
        raise bad_request(f"Unknown timezone: {tz!r}")
    return jobs.launch_bash(
        "set_timezone",
        tz,
        script=_SYSTEM_SCRIPT,
        label=f"Set Timezone → {tz}",
        title=f"Setting Timezone → {tz}",
        audit_action="system.set_timezone",
        audit_detail=f"tz={tz}",
    )


class NetworkConfig(BaseModel):
    """DHCP or a static IPv4 address for one interface, applied via netplan."""

    iface: str
    method: str
    address: str = ""
    gateway: str = ""
    dns: str = ""

    @field_validator("iface")
    @classmethod
    def _iface(cls, v: str) -> str:
        v = v.strip()
        if not IFACE.match(v):
            raise ValueError("invalid interface name")
        return v

    @field_validator("method")
    @classmethod
    def _method(cls, v: str) -> str:
        v = v.strip().lower()
        if v not in ("dhcp", "manual"):
            raise ValueError("method must be 'dhcp' or 'manual'")
        return v

    def resolved(self) -> tuple[str, str, str]:
        """(address/CIDR, gateway, comma-separated DNS) — empty strings for DHCP."""
        if self.method == "dhcp":
            return "", "", ""

        address = self.address.strip()
        try:
            # Require an explicit prefix: ip_interface() would silently read a
            # bare address as /32, which is never what a static config wants.
            if "/" not in address:
                raise ValueError
            iface_addr = ipaddress.ip_interface(address)
            if iface_addr.version != 4:
                raise ValueError
        except ValueError as exc:
            raise bad_request("Address must be IPv4 in CIDR notation, e.g. 192.168.1.50/24") from exc

        gateway = self.gateway.strip()
        if gateway:
            try:
                if ipaddress.ip_address(gateway).version != 4:
                    raise ValueError
            except ValueError as exc:
                raise bad_request(f"Invalid gateway: {gateway}") from exc

        servers = [s.strip() for s in re.split(r"[,\s]+", self.dns) if s.strip()]
        for server in servers:
            try:
                ipaddress.ip_address(server)
            except ValueError as exc:
                raise bad_request(f"Invalid DNS server: {server}") from exc

        return str(iface_addr), gateway, ",".join(servers)


@router.post("/set-network")
def set_network(config: Annotated[NetworkConfig, Form()]) -> JobResponse:
    addr_cidr, gateway, dns_list = config.resolved()
    title = f"Set {config.iface} → DHCP" if config.method == "dhcp" else f"Set {config.iface} → {addr_cidr}"
    return jobs.launch_bash(
        "set_network_ip",
        config.iface,
        config.method,
        addr_cidr,
        gateway,
        dns_list,
        script=_SYSTEM_SCRIPT,
        label=title,
        title=title,
        audit_action="system.set_network",
        audit_detail=(
            f"iface={config.iface} method={config.method} address={addr_cidr} gateway={gateway}"
        ),
    )


@router.post("/swap")
def install_swap(size_gb: Annotated[int, Form()]) -> JobResponse:
    size_gb = max(1, min(size_gb, 64))
    return jobs.launch_bash(
        "install_virtual_ram",
        str(size_gb),
        script=_SYSTEM_SCRIPT,
        label=f"Install {size_gb} GB Swap",
        title=f"Installing {size_gb} GB Virtual RAM",
        audit_action="system.install_swap",
        audit_detail=f"size_gb={size_gb}",
    )


# ── Disks ─────────────────────────────────────────────────────────────────────


@router.get("/disks")
def get_disks() -> DataResponse[list[dict[str, Any]]]:
    return DataResponse(data=disks_feature.list_disks())


def _device(value: str) -> str:
    return require_match(value, DEVICE, f"Invalid device path: {value.strip()!r}")


def _mountpoint(value: str) -> str:
    value = value.strip().rstrip("/") or "/"
    if not MOUNT.match(value):
        raise bad_request(f"Invalid mount point: {value!r}. Use an absolute path, e.g. /mnt/data.")
    return value


@router.post("/disk/mount")
def mount_disk(
    device: Annotated[str, Form()],
    mountpoint: Annotated[str, Form()],
    persist: Annotated[bool, Form()] = False,
) -> JobResponse:
    device = _device(device)
    mountpoint = _mountpoint(mountpoint)
    title = f"Mount {device} → {mountpoint}"
    return jobs.launch_bash(
        "mount_disk",
        device,
        mountpoint,
        "1" if persist else "0",
        script=_DISKS_SCRIPT,
        label=title,
        title=title,
        audit_action="system.mount_disk",
        audit_detail=f"device={device} mountpoint={mountpoint} persist={persist}",
    )


@router.post("/disk/unmount")
def unmount_disk(
    target: Annotated[str, Form()],
    remove_fstab: Annotated[bool, Form()] = False,
) -> JobResponse:
    target = target.strip()
    # target may be a device (/dev/...) or a mount point (/mnt/...).
    if not (DEVICE.match(target) or MOUNT.match(target)):
        raise bad_request(f"Invalid target: {target!r}")
    title = f"Unmount {target}"
    return jobs.launch_bash(
        "unmount_disk",
        target,
        "1" if remove_fstab else "0",
        script=_DISKS_SCRIPT,
        label=title,
        title=title,
        audit_action="system.unmount_disk",
        audit_detail=f"target={target} remove_fstab={remove_fstab}",
    )


@router.post("/disk/format")
def format_disk(
    device: Annotated[str, Form()],
    fstype: Annotated[str, Form()],
    label: Annotated[str, Form()] = "",
) -> JobResponse:
    device = _device(device)
    fstype = fstype.strip().lower()
    if fstype not in VALID_FSTYPES:
        raise bad_request(
            f"Invalid filesystem: {fstype!r}. Expected one of: {', '.join(sorted(VALID_FSTYPES))}."
        )
    label = label.strip()
    if label and not _LABEL_RE.match(label):
        raise bad_request("Label may only contain letters, digits, '.', '_' and '-' (max 32).")
    title = f"Format {device} as {fstype}"
    return jobs.launch_bash(
        "format_disk",
        device,
        fstype,
        label,
        script=_DISKS_SCRIPT,
        label=title,
        title=title,
        audit_action="system.format_disk",
        audit_detail=f"device={device} fstype={fstype} label={label}",
    )
