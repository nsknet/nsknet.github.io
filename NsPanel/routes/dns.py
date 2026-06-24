"""DNS API: list and manage CoreDNS host records (domain → IPv4)."""
from fastapi import APIRouter, Form, HTTPException

from core import audit
from features import dns as dns_feature

router = APIRouter(prefix="/api/v1/dns")


@router.get("")
def get_dns():
    st = dns_feature.status()
    return {
        "status": "success",
        "installed": st["installed"],
        "running": st["running"],
        "version": st["version"],
        "hosts_file": str(dns_feature.HOSTS_FILE),
        "records": dns_feature.read_records() if st["installed"] else [],
    }


def _require_installed():
    if not dns_feature.is_installed():
        raise HTTPException(status_code=400, detail="CoreDNS is not installed.")


@router.post("/records")
def set_record(ip: str = Form(...), domain: str = Form(...)):
    _require_installed()
    ip = ip.strip()
    domain = domain.strip().rstrip(".").lower()

    if not dns_feature.valid_ipv4(ip):
        raise HTTPException(status_code=400, detail="Invalid IPv4 address.")
    if not dns_feature.valid_domain(domain):
        raise HTTPException(status_code=400, detail="Invalid domain name.")

    dns_feature.upsert_record(ip, domain)
    audit.log("dns.record_set", f"domain={domain} ip={ip}")
    return {"status": "success", "message": f"Mapped {domain} → {ip}"}


@router.post("/records/delete")
def delete_record(domain: str = Form(...)):
    _require_installed()
    domain = domain.strip().rstrip(".").lower()

    if not dns_feature.delete_record(domain):
        raise HTTPException(status_code=404, detail=f"No record for '{domain}'.")
    audit.log("dns.record_delete", f"domain={domain}")
    return {"status": "success", "message": f"Removed {domain}"}
