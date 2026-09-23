"""Input patterns shared by the routes.

Every value that reaches a bash script or a systemd unit passes through one of
these. Keeping the patterns in one module means a route cannot accidentally use
a laxer rule than its neighbour for the same kind of value.
"""
import re

from fastapi import HTTPException

# Unit / site names — also used as filenames under /var/www.
NAME = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]*$")
DOMAIN = re.compile(r"^[a-zA-Z0-9.-]+$")
DLL = re.compile(r"^[a-zA-Z0-9._-]+$")
PROXY_TARGET = re.compile(r"^https?://[a-zA-Z0-9.\-:/]+$")
# A UFW port spec: 443 or 443/udp.
UFW_PORT = re.compile(r"^\d{1,5}(?:/(?:tcp|udp))?$", re.IGNORECASE)
# Linux interface names: eth0, ens3, enp0s3, wlan0 …
IFACE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.@:-]{0,15}$")
# Block devices: /dev/sda1, /dev/nvme0n1p2, /dev/mapper/vg-lv …
DEVICE = re.compile(r"^/dev/[A-Za-z0-9][A-Za-z0-9/_.-]{0,63}$")
# Mount points: absolute, no traversal, no shell-hostile characters.
MOUNT = re.compile(r"^/[A-Za-z0-9][A-Za-z0-9/_.-]{0,127}$")
# Install scripts interpolate passwords into SQL strings and unit files, so
# exclude quotes, backslash, $, backtick and whitespace.
PASSWORD = re.compile(r"^[A-Za-z0-9!@#%^&*()\-_=+.:,?]+$")

PASSWORD_HELP = (
    "Password may only contain letters, digits, and these symbols: "
    "! @ # % ^ & * ( ) - _ = + . : , ?"
)

# Filesystems the panel can create — must stay in sync with format_disk in disks.sh.
VALID_FSTYPES = {"ext4", "ext3", "ext2", "xfs", "btrfs", "vfat", "ntfs"}
UFW_ACTIONS = {"allow", "deny", "reject", "limit"}


def bad_request(detail: str) -> HTTPException:
    return HTTPException(status_code=400, detail=detail)


def require_match(value: str, pattern: re.Pattern[str], detail: str) -> str:
    """Return the stripped value, or raise 400 with `detail`."""
    value = (value or "").strip()
    if not pattern.match(value):
        raise bad_request(detail)
    return value


def require_choice(value: str, allowed: set[str], detail: str) -> str:
    value = (value or "").strip()
    if value not in allowed:
        raise bad_request(detail)
    return value


def require_name(value: str, what: str = "name") -> str:
    value = require_match(value, NAME, f"Invalid {what} (letters, digits, . _ - only, no spaces).")
    if ".." in value:
        raise bad_request(f"Invalid {what}.")
    return value


def require_password(value: str | None) -> str:
    """Shared check for install-time and change-password flows."""
    pw = (value or "").strip()
    if not pw:
        raise bad_request("A password is required.")
    if len(pw) < 8:
        raise bad_request("Password must be at least 8 characters.")
    if not PASSWORD.match(pw):
        raise bad_request(PASSWORD_HELP)
    return pw
