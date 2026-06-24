"""CoreDNS record management.

CoreDNS is configured (by scripts/coredns.sh) with the `hosts` plugin pointed at
an external file, /etc/coredns/hosts, in standard ``IP domain`` format. The hosts
plugin watches that file and auto-reloads it, so adding/removing a record is just
an atomic rewrite of this file — no service restart required.

Status checks stay in Python (per the architecture rules); the file is simple so
its reads/writes live here too rather than in a bash action.
"""
import ipaddress
import os
import re
import tempfile
from pathlib import Path

from features import services

COREDNS_DIR = Path("/etc/coredns")
HOSTS_FILE = COREDNS_DIR / "hosts"

_DOMAIN_RE = re.compile(r"^(?=.{1,253}$)[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$")

_HEADER = (
    "# CoreDNS host records — managed by NsPanel (DNS screen).\n"
    "# Format: <IPv4> <domain>   e.g.   192.168.1.10 example.com\n"
)


def is_installed() -> bool:
    return services.which("coredns") is not None


def valid_ipv4(value: str) -> bool:
    try:
        return isinstance(ipaddress.ip_address(value), ipaddress.IPv4Address)
    except ValueError:
        return False


def valid_domain(value: str) -> bool:
    return bool(_DOMAIN_RE.match(value))


def status() -> dict:
    """{installed, running, version} for the DNS screen header."""
    st = services.tool_status(
        binary="coredns",
        service="coredns",
        version_cmd=["coredns", "-version"],
    )
    return {
        "installed": st["installed"],
        "running": st["service_state"] == "active",
        "version": st["version"],
    }


def read_records() -> list[dict]:
    """Parse /etc/coredns/hosts → [{"ip": ..., "domain": ...}, ...].

    Lines may map one IP to several domains (``IP a.com b.com``); each domain
    becomes its own row. Comments/blank lines are skipped. Returns [] if the file
    is missing or unreadable.
    """
    if not HOSTS_FILE.exists():
        return []
    try:
        text = HOSTS_FILE.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []

    records: list[dict] = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        ip, domains = parts[0], parts[1:]
        for domain in domains:
            records.append({"ip": ip, "domain": domain})
    return records


def _write_records(records: list[dict]) -> None:
    """Atomically rewrite the hosts file from a list of {ip, domain} rows."""
    COREDNS_DIR.mkdir(parents=True, exist_ok=True)
    lines = [f"{r['ip']} {r['domain']}" for r in records]
    body = _HEADER + ("\n".join(lines) + "\n" if lines else "")

    fd, tmp = tempfile.mkstemp(dir=str(COREDNS_DIR), prefix=".hosts.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(body)
        os.chmod(tmp, 0o644)
        os.replace(tmp, HOSTS_FILE)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def upsert_record(ip: str, domain: str) -> None:
    """Add (or update the IP of) a record keyed by domain."""
    records = [r for r in read_records() if r["domain"] != domain]
    records.append({"ip": ip, "domain": domain})
    records.sort(key=lambda r: r["domain"])
    _write_records(records)


def delete_record(domain: str) -> bool:
    """Remove every record for `domain`. Returns True if anything was removed."""
    records = read_records()
    kept = [r for r in records if r["domain"] != domain]
    if len(kept) == len(records):
        return False
    _write_records(kept)
    return True
