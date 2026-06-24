"""Sites API: list, create, and per-site actions."""
import re

from fastapi import APIRouter, Form, HTTPException

from core import audit, bash_invoker, runner
from features import sites as sites_feature

router = APIRouter(prefix="/api/v1/sites")

_NAME_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]*$")
_DOMAIN_RE = re.compile(r"^[a-zA-Z0-9.-]+$")
_DLL_RE = re.compile(r"^[a-zA-Z0-9._-]+$")
_PROXY_RE = re.compile(r"^https?://[a-zA-Z0-9.\-:/]+$")
_ASPENV_ALLOWED = {"Production", "Development", "Test", "Demo", "Staging"}


@router.get("")
def get_sites():
    return {
        "status": "success",
        "sites": sites_feature.list_sites_with_status()
    }


@router.post("/create")
async def sites_create(
    access_kind: str = Form(...),
    access_value: str = Form(...),
    backend_type: str = Form(...),
    name: str = Form(""),
    proxy_target: str = Form(""),
    dll_name: str = Form(""),
    internal_port: str = Form(""),
    aspnetcore_env: str = Form("Production"),
):
    access_kind = access_kind.strip()
    access_value = access_value.strip()
    backend = backend_type.strip()

    if access_kind == "domain":
        name = access_value
    else:
        name = name.strip()

    if not _NAME_RE.match(name) or ".." in name:
        raise HTTPException(status_code=400, detail="Invalid site name (use letters, digits, . _ -).")
    if access_kind not in ("domain", "port"):
        raise HTTPException(status_code=400, detail="Choose an access kind (domain or port).")
    if access_kind == "domain" and not _DOMAIN_RE.match(access_value):
        raise HTTPException(status_code=400, detail="Invalid domain name.")
    if access_kind == "port" and not access_value.isdigit():
        raise HTTPException(status_code=400, detail="Port must be a number.")
    if backend not in ("static", "proxy", "dotnet"):
        raise HTTPException(status_code=400, detail="Choose a backend type.")

    if sites_feature.read_info(name) is not None:
        raise HTTPException(status_code=400, detail=f"A site named '{name}' already exists.")

    if backend == "static":
        cmd = bash_invoker.build_cmd("add_static_site", name, access_kind, access_value)
    elif backend == "proxy":
        target = proxy_target.strip()
        if not _PROXY_RE.match(target):
            raise HTTPException(status_code=400, detail="Proxy target must be http(s)://host:port.")
        cmd = bash_invoker.build_cmd("add_proxy_site", name, access_kind, access_value, target)
    else:  # dotnet
        dll = dll_name.strip()
        if dll.lower().endswith(".dll"):
            dll = dll[:-4]
        internal = internal_port.strip()
        aspenv = aspnetcore_env.strip()
        if not dll or not _DLL_RE.match(dll):
            raise HTTPException(status_code=400, detail="Invalid .dll name.")
        if not internal.isdigit():
            raise HTTPException(status_code=400, detail="Internal port must be a number.")
        if aspenv not in _ASPENV_ALLOWED:
            raise HTTPException(status_code=400, detail="Invalid ASP.NET Core environment.")
        cmd = bash_invoker.build_cmd(
            "add_dotnet_site", name, access_kind, access_value, dll, internal, aspenv
        )

    job_id = runner.create_job(cmd, label=f"Create site {name}")
    runner.start_job(job_id)
    audit.log("site.create", f"name={name} backend={backend} access={access_kind}:{access_value} job={job_id}")

    return {
        "status": "success",
        "job_id": job_id,
        "title": f"Creating site '{name}'"
    }


@router.get("/{name}")
def get_site(name: str):
    info = sites_feature.get_site(name)
    if info is None:
        raise HTTPException(status_code=404, detail=f"Site '{name}' not found.")
    return info


@router.post("/{name}/restart")
def site_restart(name: str):
    info = sites_feature.read_info(name)
    if info is None:
        raise HTTPException(status_code=404, detail=f"Site '{name}' not found.")
    if info.get("type") != "dotnet":
        raise HTTPException(status_code=400, detail="Only .NET sites have a service to restart.")
    job_id = runner.create_job(["systemctl", "restart", name], label=f"Restart {name}")
    runner.start_job(job_id)
    audit.log("site.restart", f"name={name} job={job_id}")
    return {
        "status": "success",
        "job_id": job_id,
        "title": f"Restarting '{name}'"
    }


@router.post("/{name}/reload-nginx")
def site_reload_nginx(name: str):
    job_id = runner.create_job(
        ["bash", "-c", "nginx -t && systemctl reload nginx"],
        label="Reload nginx"
    )
    runner.start_job(job_id)
    audit.log("nginx.reload", f"triggered_by=site:{name} job={job_id}")
    return {
        "status": "success",
        "job_id": job_id,
        "title": "Reloading nginx"
    }


@router.get("/{name}/config")
def site_config(name: str):
    info = sites_feature.read_info(name)
    if info is None:
        raise HTTPException(status_code=404, detail=f"Site '{name}' not found.")
    audit.log("site.config_view", f"name={name}")
    return {
        "status": "success",
        "config": sites_feature.read_config(info)
    }


@router.get("/{name}/logs")
def site_logs(name: str):
    info = sites_feature.read_info(name)
    if info is None:
        raise HTTPException(status_code=404, detail=f"Site '{name}' not found.")
    sections = sites_feature.tail_logs(info)
    audit.log("site.logs_view", f"name={name} sections={list(sections.keys())}")
    body = "\n\n".join(f"===== {label} =====\n{text}" for label, text in sections.items())
    return {
        "status": "success",
        "logs": body
    }
