"""Services management: REST API for custom systemd services."""
import re

from fastapi import APIRouter, Form, HTTPException

from core import audit, runner
from features import panel_services as psvc

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
