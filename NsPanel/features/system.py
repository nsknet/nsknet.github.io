"""System metrics — used by the dashboard and the System page."""
import glob
import ipaddress
import platform
import re
import shutil
import socket
import subprocess
import time

import psutil

try:
    import yaml
except ImportError:  # pragma: no cover - yaml is a declared dependency
    yaml = None


def get_stats() -> dict:
    cpu = psutil.cpu_percent(interval=0.3)
    vm = psutil.virtual_memory()
    disk = psutil.disk_usage("/")
    uptime_s = int(time.time() - psutil.boot_time())
    return {
        "cpu_percent": round(cpu, 1),
        "ram_used_gb": round(vm.used / 1e9, 2),
        "ram_total_gb": round(vm.total / 1e9, 2),
        "ram_percent": vm.percent,
        "disk_used_gb": round(disk.used / 1e9, 1),
        "disk_total_gb": round(disk.total / 1e9, 1),
        "disk_percent": disk.percent,
        "uptime": human_uptime(uptime_s),
        "hostname": socket.gethostname(),
        "kernel": platform.release(),
    }


def get_full_info() -> dict:
    """Extended stats for the System page."""
    stats = get_stats()
    swap = psutil.swap_memory()
    try:
        load = psutil.getloadavg()
    except AttributeError:
        load = (0.0, 0.0, 0.0)
    cpu_logical = psutil.cpu_count(logical=True)
    cpu_physical = psutil.cpu_count(logical=False)

    netplan = _read_netplan_config()
    ips: list[dict] = []
    for iface, addrs in psutil.net_if_addrs().items():
        for addr in addrs:
            if addr.family == socket.AF_INET and not addr.address.startswith("127."):
                prefix = _netmask_to_prefix(addr.netmask)
                cfg = netplan.get(iface, {})
                ips.append({
                    "iface": iface,
                    "ip": addr.address,
                    "prefix": prefix,
                    "cidr": f"{addr.address}/{prefix}" if prefix is not None else addr.address,
                    "method": cfg.get("method", "unknown"),
                    "gateway": cfg.get("gateway", ""),
                    "dns": cfg.get("dns", []),
                })

    return {
        **stats,
        "swap_used_gb": round(swap.used / 1e9, 2),
        "swap_total_gb": round(swap.total / 1e9, 2),
        "swap_percent": round(swap.percent, 1),
        "swap_enabled": swap.total > 0,
        "load_1": round(load[0], 2),
        "load_5": round(load[1], 2),
        "load_15": round(load[2], 2),
        "cpu_count": cpu_logical,
        "cpu_count_physical": cpu_physical,
        "os_name": _read_os_name(),
        "architecture": platform.machine(),
        "ips": ips,
        "timezone": _read_timezone(),
    }


def _netmask_to_prefix(netmask: str | None) -> int | None:
    """Convert a dotted-quad netmask (e.g. 255.255.255.0) to a prefix length (24)."""
    if not netmask:
        return None
    try:
        return ipaddress.IPv4Network(f"0.0.0.0/{netmask}").prefixlen
    except (ValueError, ipaddress.AddressValueError, ipaddress.NetmaskValueError):
        return None


def _read_netplan_config() -> dict[str, dict]:
    """Parse /etc/netplan/*.yaml and return per-interface config.

    Returns a mapping of interface name → {method, gateway, dns}, where method
    is 'dhcp' or 'static'. Best-effort: returns {} if netplan/yaml is unavailable.
    """
    if yaml is None:
        return {}
    result: dict[str, dict] = {}
    for path in sorted(glob.glob("/etc/netplan/*.yaml")) + sorted(glob.glob("/etc/netplan/*.yml")):
        try:
            with open(path) as f:
                data = yaml.safe_load(f) or {}
        except (OSError, yaml.YAMLError):
            continue
        ethernets = ((data.get("network") or {}).get("ethernets") or {})
        for iface, conf in ethernets.items():
            if not isinstance(conf, dict):
                continue
            dhcp4 = conf.get("dhcp4")
            is_dhcp = dhcp4 is True or str(dhcp4).lower() in ("true", "yes")
            gateway = conf.get("gateway4", "")
            # Newer netplan uses routes: [{to: default, via: <gw>}]
            for route in (conf.get("routes") or []):
                if isinstance(route, dict) and route.get("to") in ("default", "0.0.0.0/0"):
                    gateway = route.get("via", gateway)
            dns = ((conf.get("nameservers") or {}).get("addresses") or [])
            result[iface] = {
                "method": "dhcp" if is_dhcp else "static",
                "gateway": gateway or "",
                "dns": list(dns),
            }
    return result


def _read_os_name() -> str:
    try:
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return platform.system()


def _read_timezone() -> str:
    try:
        result = subprocess.run(
            ["timedatectl", "show", "-p", "Timezone", "--value"],
            capture_output=True, text=True, timeout=3,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        pass
    return "unknown"


def get_ufw_info() -> dict:
    """Return UFW installation status, enabled state, and numbered rules."""
    if not shutil.which("ufw"):
        return {"installed": False, "enabled": False, "rules": []}
    try:
        result = subprocess.run(
            ["ufw", "status", "numbered"],
            capture_output=True, text=True, timeout=5,
        )
        output = result.stdout
        enabled = "Status: active" in output
        rules = []
        for line in output.splitlines():
            comment = ""
            if "#" in line:
                line, comment = line.split("#", 1)
                comment = comment.strip()
            m = re.match(
                r'^\[\s*(\d+)\]\s+(.+?)\s{2,}(ALLOW|DENY|REJECT|LIMIT)\s*(IN|OUT|FWD)?\s+(.*?)\s*$',
                line,
            )
            if m:
                to_port = m.group(2).strip()
                label = comment
                if not label:
                    port_clean = to_port.split("/")[0].strip()
                    if port_clean == "22":
                        label = "SSH"
                    elif port_clean == "80":
                        label = "HTTP"
                    elif port_clean == "443":
                        label = "HTTPS"
                    elif port_clean == "5432":
                        label = "PostgreSQL"
                    else:
                        label = f"Port {port_clean}"
                rules.append({
                    "num": int(m.group(1)),
                    "to": to_port,
                    "action": m.group(3).strip(),
                    "direction": (m.group(4) or "").strip(),
                    "from_": m.group(5).strip(),
                    "is_v6": "(v6)" in to_port,
                    "label": label,
                })
        return {"installed": True, "enabled": enabled, "rules": rules}
    except Exception:
        return {"installed": True, "enabled": False, "rules": []}


def human_uptime(seconds: int) -> str:
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes, _ = divmod(rem, 60)
    parts = []
    if days:
        parts.append(f"{days}d")
    if hours:
        parts.append(f"{hours}h")
    parts.append(f"{minutes}m")
    return " ".join(parts)
