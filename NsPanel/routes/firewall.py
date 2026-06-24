"""Firewall API."""
import ipaddress
import re

from fastapi import APIRouter, Form, HTTPException

from core import audit, bash_invoker, runner
from features import system as system_feature

router = APIRouter(prefix="/api/v1/firewall")

# A port is a number, optionally suffixed with /tcp or /udp (e.g. 443 or 443/udp).
_PORT_RE = re.compile(r"^\d{1,5}(?:/(?:tcp|udp))?$", re.IGNORECASE)
_VALID_ACTIONS = {"allow", "deny", "reject", "limit"}


@router.get("")
def get_firewall():
    return {
        "status": "success",
        "ufw": system_feature.get_ufw_info()
    }


@router.post("/install")
async def install_ufw():
    cmd = bash_invoker.build_cmd("install_ufw")
    job_id = runner.create_job(cmd, "Install UFW Firewall")
    runner.start_job(job_id)
    audit.log("firewall.install_ufw", f"job={job_id}")
    return {
        "status": "success",
        "job_id": job_id,
        "title": "Installing UFW Firewall"
    }


@router.post("/add-port")
async def add_port(
    port: str = Form(...),
    action: str = Form("ALLOW"),
    source: str = Form("Anywhere"),
    comment: str = Form("")
):
    port = port.strip()
    action = action.strip()
    source = source.strip()
    comment = comment.strip()

    # Validate up front so bad input is rejected with a clear 400 rather than
    # being handed to ufw (mirrors the validation done in routes/system.py).
    if not _PORT_RE.match(port):
        raise HTTPException(
            status_code=400,
            detail=f"Invalid port: {port!r}. Use a number, optionally with protocol, e.g. 443 or 443/tcp.",
        )
    if not 1 <= int(port.split("/")[0]) <= 65535:
        raise HTTPException(status_code=400, detail=f"Port out of range (1–65535): {port}")
    if action.lower() not in _VALID_ACTIONS:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid action: {action!r}. Expected one of: {', '.join(sorted(_VALID_ACTIONS))}.",
        )
    # Source is either an IP/CIDR or the sentinel "Anywhere"/"any" (empty == any).
    if source.lower() not in ("anywhere", "any", ""):
        try:
            ipaddress.ip_network(source, strict=False)
        except ValueError:
            raise HTTPException(
                status_code=400,
                detail=f"Invalid source: {source!r}. Use an IP/CIDR (e.g. 10.0.0.0/8) or 'Anywhere'.",
            )

    cmd = bash_invoker.build_cmd("ufw_allow_port", port, action, source, comment)
    title = f"Adding rule: {action} {port} from {source}"
    job_id = runner.create_job(cmd, title)
    runner.start_job(job_id)
    audit.log("firewall.add_rule", f"port={port} action={action} source={source} job={job_id}")
    return {
        "status": "success",
        "job_id": job_id,
        "title": title
    }


@router.post("/delete-port")
async def delete_port(rule_num: int = Form(...)):
    cmd = bash_invoker.build_cmd("ufw_delete_port", str(rule_num))
    job_id = runner.create_job(cmd, f"Delete rule #{rule_num}")
    runner.start_job(job_id)
    audit.log("firewall.delete_rule", f"rule_num={rule_num} job={job_id}")
    return {
        "status": "success",
        "job_id": job_id,
        "title": f"Deleting firewall rule #{rule_num}"
    }
