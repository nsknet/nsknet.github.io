"""Services management: REST API for custom systemd services."""
import re

from fastapi import APIRouter, Form, HTTPException

from config import SERVICES_DIR
from core import audit, runner
from features import cloudflare_tunnel as cft
from features import panel_services as psvc
from features import services as fsvc

router = APIRouter(prefix="/api/v1/services")

_NAME_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]*$")


@router.get("")
def get_services():
    return psvc.list_services()


@router.get("/{name}")
def get_service_detail(name: str):
    svc = psvc.get_service(name)
    if svc is None:
        raise HTTPException(status_code=404, detail=f"Service '{name}' not found.")
    return svc


@router.post("/create")
async def services_create(
    name: str = Form(...),
    description: str = Form(""),
    working_dir: str = Form(...),
    command: str = Form(...),
    user: str = Form("root"),
    env_vars: str = Form(""),
):
    name = name.strip()
    description = description.strip()
    working_dir = working_dir.strip()
    command = command.strip()
    user = user.strip() or "root"
    env_raw = env_vars.strip()

    if not _NAME_RE.match(name):
        raise HTTPException(status_code=400, detail="Invalid name (letters, digits, . _ - only, no spaces).")
    if not working_dir:
        raise HTTPException(status_code=400, detail="Working directory is required.")
    if not command:
        raise HTTPException(status_code=400, detail="Command (ExecStart) is required.")
    if psvc.service_exists(name):
        raise HTTPException(status_code=400, detail=f"A service named '{name}' already exists.")

    env_list = [ln.strip() for ln in env_raw.splitlines() if ln.strip()]
    svc_file = psvc.write_service(name, description, working_dir, command, user, env_list)

    cmd = [
        "bash", "-c",
        f"systemctl daemon-reload && "
        f"systemctl enable {svc_file} && "
        f"systemctl start {name} && "
        f"echo 'Service {name} enabled and started successfully.'",
    ]
    job_id = runner.create_job(cmd, label=f"Register & start {name}")
    runner.start_job(job_id)
    audit.log("service.create", f"name={name} user={user} dir={working_dir} cmd={command} job={job_id}")

    return {
        "status": "success",
        "job_id": job_id,
        "title": f"Starting service '{name}'"
    }


# Sync `def` on purpose: the Cloudflare SDK is blocking (several HTTP calls),
# so FastAPI runs this in its threadpool instead of stalling the event loop.
@router.post("/tunnels/create")
def tunnels_create(
    api_token: str = Form(...),
    hostname: str = Form(...),
    url: str = Form(...),
):
    cloudflared_bin = fsvc.which("cloudflared")
    if not cloudflared_bin:
        raise HTTPException(
            status_code=400,
            detail="cloudflared is not installed. Install it from the Tools screen first.",
        )

    try:
        hostname = cft.normalize_hostname(hostname)
        service_url = cft.normalize_service_url(url)
    except cft.TunnelError as exc:
        raise HTTPException(status_code=400, detail=str(exc))

    name = cft.tunnel_service_name(hostname)
    if not _NAME_RE.match(name):
        raise HTTPException(status_code=400, detail=f"Derived service name '{name}' is invalid.")
    if psvc.service_exists(name):
        raise HTTPException(
            status_code=400,
            detail=f"A tunnel service for '{hostname}' already exists ({name}). Delete it first to recreate.",
        )

    try:
        result = cft.setup_cloudflare_tunnel(api_token, hostname, service_url)
    except cft.TunnelError as exc:
        raise HTTPException(status_code=400, detail=str(exc))

    unit_extra = [
        "After=network-online.target",
        "Wants=network-online.target",
        *psvc.tunnel_unit_lines(
            result.hostname, result.service_url, result.tunnel_id, result.tunnel_name, result.zone_name
        ),
    ]
    svc_file = psvc.write_service(
        name,
        f"Cloudflare Tunnel {result.hostname} -> {result.service_url}",
        str(SERVICES_DIR),
        f"{cloudflared_bin} tunnel --no-autoupdate run --token {result.token}",
        "root",
        [],
        unit_extra=unit_extra,
    )

    cmd = [
        "bash", "-c",
        f"systemctl daemon-reload && "
        f"systemctl enable {svc_file} && "
        f"systemctl start {name} && "
        f"echo 'Tunnel {name} enabled and started: https://{result.hostname} -> {result.service_url}'",
    ]
    job_id = runner.create_job(cmd, label=f"Register & start {name}")
    runner.start_job(job_id)
    # Never log the API token or the tunnel token.
    audit.log(
        "tunnel.create",
        f"name={name} hostname={result.hostname} url={result.service_url} "
        f"tunnel_id={result.tunnel_id} zone={result.zone_name} job={job_id}",
    )

    return {
        "status": "success",
        "job_id": job_id,
        "title": f"Starting tunnel '{name}'",
        "service_name": name,
        "tunnel": result.public_info(),
    }


@router.post("/{name}/tunnel-delete")
def service_tunnel_delete(name: str, api_token: str = Form(...)):
    """Delete the service AND clean up on Cloudflare (CNAME, ingress rule, tunnel if unused)."""
    if not psvc.service_exists(name):
        raise HTTPException(status_code=404, detail=f"Service '{name}' not found.")
    svc = psvc.get_service(name)
    tunnel = (svc or {}).get("tunnel")
    if not tunnel:
        raise HTTPException(
            status_code=400,
            detail=f"Service '{name}' is not a panel-managed Cloudflare tunnel (no tunnel metadata in its unit file).",
        )

    # Disconnect the connector before removing the tunnel on Cloudflare's side.
    fsvc.run(["systemctl", "stop", name], timeout=20)

    try:
        cleanup = cft.delete_cloudflare_tunnel(api_token, tunnel["hostname"], tunnel["tunnel_id"])
    except cft.TunnelError as exc:
        raise HTTPException(
            status_code=400,
            detail=f"{exc} — the service was stopped but not deleted; fix the token and retry, "
                   f"or use 'Delete Service' to remove only the local unit.",
        )

    p = psvc.svc_path(name)
    summary = (
        f"Cloudflare cleanup: DNS records removed={cleanup['dns_deleted']}, "
        f"tunnel deleted={cleanup['tunnel_deleted']}, ingress updated={cleanup['ingress_updated']}"
    )
    cmd = [
        "bash", "-c",
        f"echo '{summary}' ; "
        f"systemctl stop {name} ; systemctl disable {name} ; "
        f"rm -f {p} && systemctl daemon-reload && echo 'Service {name} deleted.'",
    ]
    job_id = runner.create_job(cmd, label=f"Delete tunnel {name}")
    runner.start_job(job_id)
    audit.log(
        "tunnel.delete",
        f"name={name} hostname={tunnel['hostname']} tunnel_id={tunnel['tunnel_id']} "
        f"dns_deleted={cleanup['dns_deleted']} tunnel_deleted={cleanup['tunnel_deleted']} job={job_id}",
    )
    return {
        "status": "success",
        "job_id": job_id,
        "title": f"Deleting tunnel '{name}'"
    }


@router.post("/{name}/start")
async def service_start(name: str):
    if not psvc.service_exists(name):
        raise HTTPException(status_code=404, detail=f"Service '{name}' not found.")
    job_id = runner.create_job(["systemctl", "start", name], label=f"Start {name}")
    runner.start_job(job_id)
    audit.log("service.start", f"name={name} job={job_id}")
    return {
        "status": "success",
        "job_id": job_id,
        "title": f"Starting '{name}'"
    }


@router.post("/{name}/stop")
async def service_stop(name: str):
    if not psvc.service_exists(name):
        raise HTTPException(status_code=404, detail=f"Service '{name}' not found.")
    job_id = runner.create_job(["systemctl", "stop", name], label=f"Stop {name}")
    runner.start_job(job_id)
    audit.log("service.stop", f"name={name} job={job_id}")
    return {
        "status": "success",
        "job_id": job_id,
        "title": f"Stopping '{name}'"
    }


@router.post("/{name}/restart")
async def service_restart(name: str):
    if not psvc.service_exists(name):
        raise HTTPException(status_code=404, detail=f"Service '{name}' not found.")
    job_id = runner.create_job(["systemctl", "restart", name], label=f"Restart {name}")
    runner.start_job(job_id)
    audit.log("service.restart", f"name={name} job={job_id}")
    return {
        "status": "success",
        "job_id": job_id,
        "title": f"Restarting '{name}'"
    }


@router.post("/{name}/enable")
async def service_enable(name: str):
    if not psvc.service_exists(name):
        raise HTTPException(status_code=404, detail=f"Service '{name}' not found.")
    p = psvc.svc_path(name)
    cmd = ["bash", "-c", f"systemctl daemon-reload && systemctl enable {p}"]
    job_id = runner.create_job(cmd, label=f"Enable {name}")
    runner.start_job(job_id)
    audit.log("service.enable", f"name={name} job={job_id}")
    return {
        "status": "success",
        "job_id": job_id,
        "title": f"Enabling '{name}'"
    }


@router.post("/{name}/disable")
async def service_disable(name: str):
    if not psvc.service_exists(name):
        raise HTTPException(status_code=404, detail=f"Service '{name}' not found.")
    job_id = runner.create_job(["systemctl", "disable", name], label=f"Disable {name}")
    runner.start_job(job_id)
    audit.log("service.disable", f"name={name} job={job_id}")
    return {
        "status": "success",
        "job_id": job_id,
        "title": f"Disabling '{name}'"
    }


@router.post("/{name}/edit")
async def service_edit_save(name: str, content: str = Form(...)):
    if not psvc.service_exists(name):
        raise HTTPException(status_code=404, detail=f"Service '{name}' not found.")
    psvc.write_service_raw(name, content)
    cmd = [
        "bash", "-c",
        f"systemctl daemon-reload && systemctl restart {name} && echo 'Service {name} restarted.'",
    ]
    job_id = runner.create_job(cmd, label=f"Save & restart {name}")
    runner.start_job(job_id)
    audit.log("service.edit", f"name={name} bytes={len(content)} job={job_id}")
    return {
        "status": "success",
        "job_id": job_id,
        "title": f"Saving & restarting '{name}'"
    }


@router.get("/{name}/status")
def service_status_output(name: str):
    if not psvc.service_exists(name):
        raise HTTPException(status_code=404, detail=f"Service '{name}' not found.")
    output = psvc.get_status_output(name)
    audit.log("service.status", f"name={name}")
    return {
        "status": "success",
        "output": output
    }


@router.get("/{name}/logs")
def service_logs_output(name: str):
    if not psvc.service_exists(name):
        raise HTTPException(status_code=404, detail=f"Service '{name}' not found.")
    output = psvc.get_journal_logs(name)
    audit.log("service.logs", f"name={name}")
    return {
        "status": "success",
        "output": output
    }


@router.post("/{name}/delete")
async def service_delete(name: str):
    if not psvc.service_exists(name):
        raise HTTPException(status_code=404, detail=f"Service '{name}' not found.")
    p = psvc.svc_path(name)
    cmd = [
        "bash", "-c",
        f"systemctl stop {name} ; systemctl disable {name} ; "
        f"rm -f {p} && systemctl daemon-reload && echo 'Service {name} deleted.'",
    ]
    job_id = runner.create_job(cmd, label=f"Delete {name}")
    runner.start_job(job_id)
    audit.log("service.delete", f"name={name} path={p} job={job_id}")
    return {
        "status": "success",
        "job_id": job_id,
        "title": f"Deleting '{name}'"
    }
