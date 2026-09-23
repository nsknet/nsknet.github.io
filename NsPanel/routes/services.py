"""Services API: panel-managed systemd units, including Cloudflare tunnels."""
from typing import Annotated, Any

from fastapi import APIRouter, Form, HTTPException
from pydantic import BaseModel, field_validator

from config import SERVICES_DIR
from core import jobs
from core.schemas import DataResponse, JobResponse
from core.validators import bad_request, require_name
from features import cloudflare_tunnel as cft
from features import systemctl, units

router = APIRouter(prefix="/api/v1/services")


class ServiceCreate(BaseModel):
    name: str
    description: str = ""
    working_dir: str
    command: str
    user: str = "root"
    env_vars: str = ""

    @field_validator("name")
    @classmethod
    def _valid_name(cls, v: str) -> str:
        return require_name(v, "service name")

    @field_validator("working_dir", "command")
    @classmethod
    def _required(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("this field is required")
        return v

    @property
    def env_list(self) -> list[str]:
        return [line.strip() for line in self.env_vars.splitlines() if line.strip()]


def _require_exists(name: str) -> str:
    if not units.service_exists(name):
        raise HTTPException(status_code=404, detail=f"Service '{name}' not found.")
    return name


def _register_and_start(name: str, unit_file: object, message: str) -> list[str]:
    return jobs.systemctl_chain(
        ["systemctl", "daemon-reload"],
        ["systemctl", "enable", str(unit_file)],
        ["systemctl", "start", name],
        echo=message,
    )


@router.get("")
def get_services() -> DataResponse[list[dict[str, Any]]]:
    return DataResponse(data=units.list_services())


@router.get("/{name}")
def get_service_detail(name: str) -> DataResponse[dict[str, Any]]:
    svc = units.get_service(name)
    if svc is None:
        raise HTTPException(status_code=404, detail=f"Service '{name}' not found.")
    return DataResponse(data=svc)


@router.post("/create")
def services_create(payload: Annotated[ServiceCreate, Form()]) -> JobResponse:
    if units.service_exists(payload.name):
        raise bad_request(f"A service named '{payload.name}' already exists.")

    user = payload.user.strip() or "root"
    unit_file = units.write_service(
        payload.name,
        payload.description.strip(),
        payload.working_dir,
        payload.command,
        user,
        payload.env_list,
    )
    cmd = _register_and_start(
        payload.name, unit_file, f"Service {payload.name} enabled and started successfully."
    )
    return jobs.launch(
        cmd,
        label=f"Register & start {payload.name}",
        title=f"Starting service '{payload.name}'",
        audit_action="service.create",
        audit_detail=f"name={payload.name} user={user} dir={payload.working_dir} cmd={payload.command}",
    )


# Sync `def` on purpose: the Cloudflare SDK is blocking (several HTTP calls),
# so FastAPI runs this in its threadpool instead of stalling the event loop.
@router.post("/tunnels/create")
def tunnels_create(
    api_token: Annotated[str, Form()],
    hostname: Annotated[str, Form()],
    url: Annotated[str, Form()],
) -> JobResponse:
    cloudflared_bin = systemctl.which("cloudflared")
    if not cloudflared_bin:
        raise bad_request("cloudflared is not installed. Install it from the Tools screen first.")

    try:
        hostname = cft.normalize_hostname(hostname)
        service_url = cft.normalize_service_url(url)
    except cft.TunnelError as exc:
        raise bad_request(str(exc)) from exc

    name = require_name(cft.tunnel_service_name(hostname), "derived service name")
    if units.service_exists(name):
        raise bad_request(
            f"A tunnel service for '{hostname}' already exists ({name}). Delete it first to recreate."
        )

    try:
        result = cft.setup_cloudflare_tunnel(api_token, hostname, service_url)
    except cft.TunnelError as exc:
        raise bad_request(str(exc)) from exc

    unit_extra = [
        "After=network-online.target",
        "Wants=network-online.target",
        *units.tunnel_unit_lines(
            result.hostname, result.service_url, result.tunnel_id, result.tunnel_name, result.zone_name
        ),
    ]
    unit_file = units.write_service(
        name,
        f"Cloudflare Tunnel {result.hostname} -> {result.service_url}",
        str(SERVICES_DIR),
        f"{cloudflared_bin} tunnel --no-autoupdate run --token {result.token}",
        "root",
        [],
        unit_extra=unit_extra,
    )
    cmd = _register_and_start(
        name,
        unit_file,
        f"Tunnel {name} enabled and started: https://{result.hostname} -> {result.service_url}",
    )
    # Never log the API token or the tunnel token.
    return jobs.launch(
        cmd,
        label=f"Register & start {name}",
        title=f"Starting tunnel '{name}'",
        audit_action="tunnel.create",
        audit_detail=(
            f"name={name} hostname={result.hostname} url={result.service_url} "
            f"tunnel_id={result.tunnel_id} zone={result.zone_name}"
        ),
        extra={"service_name": name, "tunnel": result.public_info()},
    )


@router.post("/{name}/tunnel-delete")
def service_tunnel_delete(name: str, api_token: Annotated[str, Form()]) -> JobResponse:
    _require_exists(name)
    svc = units.get_service(name)
    tunnel = (svc or {}).get("tunnel")
    if not tunnel:
        raise bad_request(
            f"Service '{name}' is not a panel-managed Cloudflare tunnel "
            f"(no tunnel metadata in its unit file)."
        )

    # Disconnect the connector before removing the tunnel on Cloudflare's side.
    systemctl.run(["systemctl", "stop", name], timeout=20)

    try:
        cleanup = cft.delete_cloudflare_tunnel(api_token, tunnel["hostname"], tunnel["tunnel_id"])
    except cft.TunnelError as exc:
        raise bad_request(
            f"{exc} — the service was stopped but not deleted; fix the token and retry, "
            f"or use 'Delete Service' to remove only the local unit."
        ) from exc

    summary = (
        f"Cloudflare cleanup: DNS records removed={cleanup['dns_deleted']}, "
        f"tunnel deleted={cleanup['tunnel_deleted']}, ingress updated={cleanup['ingress_updated']}"
    )
    cmd = jobs.systemctl_chain(
        ["echo", summary],
        ["systemctl", "stop", name],
        ["systemctl", "disable", name],
        ["rm", "-f", str(units.svc_path(name))],
        ["systemctl", "daemon-reload"],
        echo=f"Service {name} deleted.",
        ignore_failures=True,
    )
    return jobs.launch(
        cmd,
        label=f"Delete tunnel {name}",
        title=f"Deleting tunnel '{name}'",
        audit_action="tunnel.delete",
        audit_detail=(
            f"name={name} hostname={tunnel['hostname']} tunnel_id={tunnel['tunnel_id']} "
            f"dns_deleted={cleanup['dns_deleted']} tunnel_deleted={cleanup['tunnel_deleted']}"
        ),
    )


# --- Lifecycle: one systemctl verb each ---------------------------------------

_SIMPLE_ACTIONS = {
    "start": ("Start", "Starting"),
    "stop": ("Stop", "Stopping"),
    "restart": ("Restart", "Restarting"),
    "disable": ("Disable", "Disabling"),
}


def _simple_action(name: str, verb: str) -> JobResponse:
    _require_exists(name)
    label_verb, title_verb = _SIMPLE_ACTIONS[verb]
    return jobs.launch(
        ["systemctl", verb, name],
        label=f"{label_verb} {name}",
        title=f"{title_verb} '{name}'",
        audit_action=f"service.{verb}",
        audit_detail=f"name={name}",
    )


@router.post("/{name}/start")
def service_start(name: str) -> JobResponse:
    return _simple_action(name, "start")


@router.post("/{name}/stop")
def service_stop(name: str) -> JobResponse:
    return _simple_action(name, "stop")


@router.post("/{name}/restart")
def service_restart(name: str) -> JobResponse:
    return _simple_action(name, "restart")


@router.post("/{name}/disable")
def service_disable(name: str) -> JobResponse:
    return _simple_action(name, "disable")


@router.post("/{name}/enable")
def service_enable(name: str) -> JobResponse:
    _require_exists(name)
    cmd = jobs.systemctl_chain(
        ["systemctl", "daemon-reload"],
        ["systemctl", "enable", str(units.svc_path(name))],
    )
    return jobs.launch(
        cmd,
        label=f"Enable {name}",
        title=f"Enabling '{name}'",
        audit_action="service.enable",
        audit_detail=f"name={name}",
    )


@router.post("/{name}/edit")
def service_edit_save(name: str, content: Annotated[str, Form()]) -> JobResponse:
    _require_exists(name)
    units.write_service_raw(name, content)
    cmd = jobs.systemctl_chain(
        ["systemctl", "daemon-reload"],
        ["systemctl", "restart", name],
        echo=f"Service {name} restarted.",
    )
    return jobs.launch(
        cmd,
        label=f"Save & restart {name}",
        title=f"Saving & restarting '{name}'",
        audit_action="service.edit",
        audit_detail=f"name={name} bytes={len(content)}",
    )


@router.post("/{name}/delete")
def service_delete(name: str) -> JobResponse:
    _require_exists(name)
    cmd = jobs.systemctl_chain(
        ["systemctl", "stop", name],
        ["systemctl", "disable", name],
        ["rm", "-f", str(units.svc_path(name))],
        ["systemctl", "daemon-reload"],
        echo=f"Service {name} deleted.",
        ignore_failures=True,
    )
    return jobs.launch(
        cmd,
        label=f"Delete {name}",
        title=f"Deleting '{name}'",
        audit_action="service.delete",
        audit_detail=f"name={name} path={units.svc_path(name)}",
    )


# --- Read-only inspection -----------------------------------------------------


@router.get("/{name}/status")
def service_status_output(name: str) -> DataResponse[str]:
    _require_exists(name)
    return DataResponse(data=units.get_status_output(name))


@router.get("/{name}/logs")
def service_logs_output(name: str) -> DataResponse[str]:
    _require_exists(name)
    return DataResponse(data=units.get_journal_logs(name))
