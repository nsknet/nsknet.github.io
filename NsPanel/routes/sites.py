"""Sites API: list, create, and per-site actions (nginx vhosts)."""
from typing import Annotated, Any

from fastapi import APIRouter, Form, HTTPException
from pydantic import BaseModel, field_validator

from core import audit, bash_invoker, jobs
from core.schemas import DataResponse, JobResponse
from core.validators import DLL, DOMAIN, PROXY_TARGET, bad_request, require_name
from features import sites as sites_feature

router = APIRouter(prefix="/api/v1/sites")

_ASPENV_ALLOWED = {"Production", "Development", "Test", "Demo", "Staging"}
_BACKENDS = {"static", "proxy", "dotnet"}
_ACCESS_KINDS = {"domain", "port"}


class SiteCreate(BaseModel):
    access_kind: str
    access_value: str
    backend_type: str
    name: str = ""
    proxy_target: str = ""
    dll_name: str = ""
    internal_port: str = ""
    aspnetcore_env: str = "Production"
    auto_ssl: str = "false"

    @field_validator("access_kind")
    @classmethod
    def _kind(cls, v: str) -> str:
        v = v.strip()
        if v not in _ACCESS_KINDS:
            raise ValueError("choose an access kind (domain or port)")
        return v

    @field_validator("backend_type")
    @classmethod
    def _backend(cls, v: str) -> str:
        v = v.strip()
        if v not in _BACKENDS:
            raise ValueError("choose a backend type")
        return v

    @property
    def site_name(self) -> str:
        """Domain-bound sites are named after the domain; port sites carry their own name."""
        raw = self.access_value.strip() if self.access_kind == "domain" else self.name
        return require_name(raw, "site name")

    @property
    def wants_ssl(self) -> bool:
        # SSL registration only makes sense for domain-bound sites.
        return self.access_kind == "domain" and self.auto_ssl.strip().lower() in ("true", "1", "yes", "on")


def _build_site_command(payload: SiteCreate, name: str) -> list[str]:
    access_value = payload.access_value.strip()
    if payload.access_kind == "domain" and not DOMAIN.match(access_value):
        raise bad_request("Invalid domain name.")
    if payload.access_kind == "port" and not access_value.isdigit():
        raise bad_request("Port must be a number.")

    ssl_args = ["ssl"] if payload.wants_ssl else []

    if payload.backend_type == "static":
        return bash_invoker.build_cmd(
            "add_static_site", name, payload.access_kind, access_value, *ssl_args, script="nginx.sh"
        )

    if payload.backend_type == "proxy":
        target = payload.proxy_target.strip()
        if not PROXY_TARGET.match(target):
            raise bad_request("Proxy target must be http(s)://host:port.")
        return bash_invoker.build_cmd(
            "add_proxy_site",
            name,
            payload.access_kind,
            access_value,
            target,
            *ssl_args,
            script="nginx.sh",
        )

    dll = payload.dll_name.strip()
    if dll.lower().endswith(".dll"):
        dll = dll[:-4]
    if not dll or not DLL.match(dll):
        raise bad_request("Invalid .dll name.")
    internal = payload.internal_port.strip()
    if not internal.isdigit():
        raise bad_request("Internal port must be a number.")
    aspenv = payload.aspnetcore_env.strip()
    if aspenv not in _ASPENV_ALLOWED:
        raise bad_request("Invalid ASP.NET Core environment.")
    return bash_invoker.build_cmd(
        "add_dotnet_site",
        name,
        payload.access_kind,
        access_value,
        dll,
        internal,
        aspenv,
        *ssl_args,
        script="nginx.sh",
    )


@router.get("")
def get_sites() -> DataResponse[list[dict[str, Any]]]:
    return DataResponse(data=sites_feature.list_sites_with_status())


@router.post("/create")
def sites_create(payload: Annotated[SiteCreate, Form()]) -> JobResponse:
    name = payload.site_name
    if sites_feature.read_info(name) is not None:
        raise bad_request(f"A site named '{name}' already exists.")

    cmd = _build_site_command(payload, name)
    return jobs.launch(
        cmd,
        label=f"Create site {name}",
        title=f"Creating site '{name}'",
        audit_action="site.create",
        audit_detail=(
            f"name={name} backend={payload.backend_type} "
            f"access={payload.access_kind}:{payload.access_value.strip()} ssl={payload.wants_ssl}"
        ),
    )


@router.get("/{name}")
def get_site(name: str) -> DataResponse[dict[str, Any]]:
    info = sites_feature.get_site(name)
    if info is None:
        raise HTTPException(status_code=404, detail=f"Site '{name}' not found.")
    return DataResponse(data=info)


def _dotnet_site_or_error(name: str) -> dict:
    """The site's info dict if it exists and is a .NET site, else raise."""
    info = sites_feature.read_info(name)
    if info is None:
        raise HTTPException(status_code=404, detail=f"Site '{name}' not found.")
    if info.get("type") != "dotnet":
        raise bad_request("Only .NET sites have a service to control.")
    return info


_SITE_ACTIONS = {
    "start": ("Start", "Starting"),
    "stop": ("Stop", "Stopping"),
    "restart": ("Restart", "Restarting"),
    "disable": ("Disable", "Disabling"),
}


def _site_service_action(name: str, verb: str) -> JobResponse:
    _dotnet_site_or_error(name)
    label_verb, title_verb = _SITE_ACTIONS[verb]
    return jobs.launch(
        ["systemctl", verb, name],
        label=f"{label_verb} {name}",
        title=f"{title_verb} '{name}'",
        audit_action=f"site.{verb}",
        audit_detail=f"name={name}",
    )


@router.post("/{name}/start")
def site_start(name: str) -> JobResponse:
    return _site_service_action(name, "start")


@router.post("/{name}/stop")
def site_stop(name: str) -> JobResponse:
    return _site_service_action(name, "stop")


@router.post("/{name}/restart")
def site_restart(name: str) -> JobResponse:
    return _site_service_action(name, "restart")


@router.post("/{name}/disable")
def site_disable(name: str) -> JobResponse:
    return _site_service_action(name, "disable")


@router.post("/{name}/enable")
def site_enable(name: str) -> JobResponse:
    info = _dotnet_site_or_error(name)
    unit = (info.get("paths") or {}).get("systemd_unit") or f"/var/www/services/{name}.service"
    cmd = jobs.systemctl_chain(["systemctl", "daemon-reload"], ["systemctl", "enable", unit])
    return jobs.launch(
        cmd,
        label=f"Enable {name}",
        title=f"Enabling '{name}'",
        audit_action="site.enable",
        audit_detail=f"name={name}",
    )


@router.post("/{name}/reload-nginx")
def site_reload_nginx(name: str) -> JobResponse:
    cmd = jobs.systemctl_chain(["nginx", "-t"], ["systemctl", "reload", "nginx"])
    return jobs.launch(
        cmd,
        label="Reload nginx",
        title="Reloading nginx",
        audit_action="nginx.reload",
        audit_detail=f"triggered_by=site:{name}",
    )


@router.get("/{name}/config")
def site_config(name: str) -> DataResponse[str]:
    info = sites_feature.read_info(name)
    if info is None:
        raise HTTPException(status_code=404, detail=f"Site '{name}' not found.")
    audit.log("site.config_view", f"name={name}")
    return DataResponse(data=sites_feature.read_config(info))


@router.get("/{name}/logs")
def site_logs(name: str) -> DataResponse[str]:
    info = sites_feature.read_info(name)
    if info is None:
        raise HTTPException(status_code=404, detail=f"Site '{name}' not found.")
    sections = sites_feature.tail_logs(info)
    audit.log("site.logs_view", f"name={name} sections={list(sections.keys())}")
    body = "\n\n".join(f"===== {label} =====\n{text}" for label, text in sections.items())
    return DataResponse(data=body)
