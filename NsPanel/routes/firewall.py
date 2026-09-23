"""Firewall API: UFW rules."""
import ipaddress
from typing import Annotated, Any

from fastapi import APIRouter, Form
from pydantic import BaseModel, field_validator

from core import jobs
from core.schemas import DataResponse, JobResponse
from core.validators import UFW_ACTIONS, UFW_PORT
from features import system as system_feature

router = APIRouter(prefix="/api/v1/firewall")

_FIREWALL_SCRIPT = "firewall.sh"


class PortRule(BaseModel):
    port: str
    action: str = "allow"
    source: str = "Anywhere"
    comment: str = ""

    @field_validator("port")
    @classmethod
    def _port(cls, v: str) -> str:
        v = v.strip()
        if not UFW_PORT.match(v):
            raise ValueError("use a number, optionally with protocol, e.g. 443 or 443/tcp")
        if not 1 <= int(v.split("/")[0]) <= 65535:
            raise ValueError("port out of range (1–65535)")
        return v

    @field_validator("action")
    @classmethod
    def _action(cls, v: str) -> str:
        v = v.strip()
        if v.lower() not in UFW_ACTIONS:
            raise ValueError(f"expected one of: {', '.join(sorted(UFW_ACTIONS))}")
        return v

    @field_validator("source")
    @classmethod
    def _source(cls, v: str) -> str:
        v = v.strip()
        # Either an IP/CIDR or the sentinel "Anywhere"/"any" (empty == any).
        if v.lower() in ("anywhere", "any", ""):
            return v
        try:
            ipaddress.ip_network(v, strict=False)
        except ValueError as exc:
            raise ValueError("use an IP/CIDR (e.g. 10.0.0.0/8) or 'Anywhere'") from exc
        return v


@router.get("")
def get_firewall() -> DataResponse[dict[str, Any]]:
    return DataResponse(data=system_feature.get_ufw_info())


@router.post("/install")
def install_ufw() -> JobResponse:
    return jobs.launch_bash(
        "install_ufw",
        script=_FIREWALL_SCRIPT,
        label="Install UFW Firewall",
        title="Installing UFW Firewall",
        audit_action="firewall.install_ufw",
    )


@router.post("/add-port")
def add_port(rule: Annotated[PortRule, Form()]) -> JobResponse:
    title = f"Adding rule: {rule.action} {rule.port} from {rule.source}"
    return jobs.launch_bash(
        "ufw_allow_port",
        rule.port,
        rule.action,
        rule.source,
        rule.comment.strip(),
        script=_FIREWALL_SCRIPT,
        label=title,
        title=title,
        audit_action="firewall.add_rule",
        audit_detail=f"port={rule.port} action={rule.action} source={rule.source}",
    )


@router.post("/delete-port")
def delete_port(rule_num: Annotated[int, Form()]) -> JobResponse:
    return jobs.launch_bash(
        "ufw_delete_port",
        str(rule_num),
        script=_FIREWALL_SCRIPT,
        label=f"Delete rule #{rule_num}",
        title=f"Deleting firewall rule #{rule_num}",
        audit_action="firewall.delete_rule",
        audit_detail=f"rule_num={rule_num}",
    )
