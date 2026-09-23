"""DNS API: CoreDNS host records (domain → IPv4)."""
from typing import Annotated, Any

from fastapi import APIRouter, Form, HTTPException

from core import audit
from core.schemas import DataResponse, MessageResponse
from core.validators import bad_request
from features import dns as dns_feature

router = APIRouter(prefix="/api/v1/dns")


@router.get("")
def get_dns() -> DataResponse[dict[str, Any]]:
    st = dns_feature.status()
    return DataResponse(
        data={
            "installed": st["installed"],
            "running": st["running"],
            "version": st["version"],
            "hosts_file": str(dns_feature.HOSTS_FILE),
            "records": dns_feature.read_records() if st["installed"] else [],
        }
    )


def _require_installed() -> None:
    if not dns_feature.is_installed():
        raise bad_request("CoreDNS is not installed.")


@router.post("/records")
def set_record(ip: Annotated[str, Form()], domain: Annotated[str, Form()]) -> MessageResponse:
    _require_installed()
    ip = ip.strip()
    domain = domain.strip().rstrip(".").lower()

    if not dns_feature.valid_ipv4(ip):
        raise bad_request("Invalid IPv4 address.")
    if not dns_feature.valid_domain(domain):
        raise bad_request("Invalid domain name.")

    dns_feature.upsert_record(ip, domain)
    audit.log("dns.record_set", f"domain={domain} ip={ip}")
    return MessageResponse(message=f"Mapped {domain} → {ip}")


@router.post("/records/delete")
def delete_record(domain: Annotated[str, Form()]) -> MessageResponse:
    _require_installed()
    domain = domain.strip().rstrip(".").lower()

    if not dns_feature.delete_record(domain):
        raise HTTPException(status_code=404, detail=f"No record for '{domain}'.")
    audit.log("dns.record_delete", f"domain={domain}")
    return MessageResponse(message=f"Removed {domain}")
