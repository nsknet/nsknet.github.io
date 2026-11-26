"""Firewall API: UFW rules."""

import ipaddress
from typing import Annotated, Any

from fastapi import APIRouter, Form, HTTPException, Request, status
from pydantic import BaseModel, field_validator

import config
from core import jobs
from core.auth import client_ip
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
def get_firewall(request: Request) -> DataResponse[dict[str, Any]]:
    """UFW rules plus what the screen needs to keep the operator from locking
    themselves out: the SSH and panel ports and the address they connect from."""
    info = system_feature.get_ufw_info()
    return DataResponse(
        data={
            **info,
            "defaults": system_feature.ufw_defaults(),
            "ssh_ports": system_feature.ssh_ports(),
            "panel_port": config.PORT,
            "client_ip": client_ip(request),
        }
    )


@router.post("/disable")
def disable_ufw() -> JobResponse:
    """Switch UFW off (rules are kept and come back on enable)."""
    return jobs.launch(
        ["ufw", "--force", "disable"],
        label="Disable UFW Firewall",
        title="Disabling UFW Firewall",
        audit_action="firewall.disable",
    )


@router.post("/install")
def install_ufw() -> JobResponse:
    return jobs.launch_bash(
        "install_ufw",
        script=_FIREWALL_SCRIPT,
        label="Install UFW Firewall",
        title="Installing UFW Firewall",
        audit_action="firewall.install_ufw",
        # install_ufw allows the panel's own port before enabling the firewall.
        env={"NSPANEL_PORT": str(config.PORT)},
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


def _norm(value: str) -> str:
    return " ".join(value.split()).lower()


@router.post("/delete-port")
def delete_port(
    rule_num: Annotated[int, Form()],
    to: Annotated[str, Form()],
    action: Annotated[str, Form()],
    from_: Annotated[str, Form(alias="from")],
) -> JobResponse:
    """Delete a numbered rule, but only if it is still the rule the operator saw.

    UFW renumbers rules after every delete, so a number alone can point at a
    different rule by the time the request arrives. The caller sends the rule's
    spec too; on mismatch nothing is deleted and the client is told to reload.
    """
    rules = system_feature.get_ufw_info().get("rules", [])
    current = next((r for r in rules if r["num"] == rule_num), None)
    expected = (_norm(to), _norm(action), _norm(from_))
    actual = current and (_norm(current["to"]), _norm(current["action"]), _norm(current["from_"]))
    if actual != expected:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            "The firewall rules changed since they were loaded. Reload and try again.",
        )
    spec = f"{to} {action} {from_}"
    return jobs.launch_bash(
        "ufw_delete_port",
        str(rule_num),
        to,
        script=_FIREWALL_SCRIPT,
        label=f"Delete rule #{rule_num}",
        title=f"Deleting firewall rule #{rule_num} ({spec})",
        audit_action="firewall.delete_rule",
        audit_detail=f"rule_num={rule_num} to={to!r} action={action} from={from_!r}",
    )
