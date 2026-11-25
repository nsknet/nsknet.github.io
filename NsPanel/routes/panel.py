"""Panel service API: run NsPanel itself as a systemd service, and keep it updated.

Reads come from :mod:`features.panel_service`; every change is a bash job in
scripts/panel_service.sh. The password travels via the job's environment, never
argv, so it does not show up in the command echoed to the live log.
"""
from typing import Annotated, Any

from fastapi import APIRouter, Form, HTTPException, status
from fastapi.concurrency import run_in_threadpool

import config
from core import jobs, passwords, runner
from core.schemas import DataResponse, JobResponse
from core.validators import bad_request, require_port
from features import panel_service

router = APIRouter(prefix="/api/v1/panel")

_SCRIPT = "panel_service.sh"


def _job_env() -> dict[str, str]:
    """Paths and repo the script works with — config.py stays the one source."""
    return {
        "SVC_NAME": config.SERVICE_NAME,
        "SVC_REPO_URL": config.REPO_URL,
        "SVC_BRANCH": panel_service.branch(),
        "SVC_REPO_DIR": config.SERVICE_REPO_DIR.as_posix(),
        "SVC_CONF_DIR": config.SERVICE_CONF_DIR.as_posix(),
        "SVC_UPDATE_PATHS": " ".join(config.SERVICE_UPDATE_PATHS),
        # The service restarting itself must hand the restart to systemd.
        "SVC_SELF": "1" if panel_service.is_self() else "0",
    }


def _require_installed() -> None:
    if not panel_service.is_installed():
        raise bad_request("The panel service is not installed.")


def _require_idle() -> None:
    """A restart stops every job running inside the panel; refuse while any runs."""
    busy = runner.running_count()
    if busy:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"{busy} job(s) are still running. Wait for them to finish (or cancel them) first.",
        )


def _resolve_subnets(raw: str | None) -> str:
    requested = [s.strip() for s in (raw or "").split(",") if s.strip()]
    if not requested:
        raise bad_request("Select at least one subnet to open the port to.")
    allowed = {choice["cidr"] for choice in panel_service.lan_subnet_choices()}
    invalid = [s for s in requested if s not in allowed]
    if invalid:
        raise bad_request(f"Invalid subnet(s): {', '.join(invalid)}")
    if "0.0.0.0/0" in requested:
        return "0.0.0.0/0"
    return " ".join(dict.fromkeys(requested))


@router.get("")
def get_panel_service() -> DataResponse[dict[str, Any]]:
    return DataResponse(data=panel_service.get_status())


@router.post("/install")
def install_panel_service(
    password: Annotated[str | None, Form()] = None,
    port: Annotated[str | None, Form()] = None,
    allowed_subnets: Annotated[str | None, Form()] = None,
    tls: Annotated[bool, Form()] = True,
) -> JobResponse:
    # The service shares the host's admin password (core/passwords.py). Giving a
    # new one here replaces it for every panel on the host; leaving it empty
    # keeps the current one.
    secret = (password or "").strip()
    if secret:
        problem = passwords.validate_new(secret)
        if problem:
            raise bad_request(problem)
    elif not passwords.is_set():
        raise bad_request("Set an admin password for the service.")
    svc_port = require_port(port or config.SERVICE_PORT_DEFAULT)
    # The panel serving this request already holds its port — unless it is the
    # service itself being reconfigured on the same port.
    if svc_port == config.PORT and not panel_service.is_self():
        raise bad_request(f"Port {svc_port} is used by the panel you are on. Pick another one.")
    subnets = _resolve_subnets(allowed_subnets)

    reconfigure = panel_service.is_installed()
    if reconfigure:
        _require_idle()
    verb = "Reconfigure" if reconfigure else "Install"
    return jobs.launch_bash(
        "panel_service_install",
        script=_SCRIPT,
        label=f"{verb} NsPanel service",
        title=f"{verb} NsPanel service on port {svc_port}",
        env={
            **_job_env(),
            **({"SVC_PASSWORD": secret} if secret else {}),
            "SVC_PORT": str(svc_port),
            "SVC_TLS": "1" if tls else "0",
            "ALLOWED_SUBNETS": subnets,
        },
        audit_action="panel.reconfigure" if reconfigure else "panel.install",
        audit_detail=f"port={svc_port} subnets={subnets} tls={tls}",
    )


@router.post("/check")
async def check_panel_updates() -> DataResponse[dict[str, Any]]:
    _require_installed()
    await run_in_threadpool(panel_service.check_updates)
    return DataResponse(data=await run_in_threadpool(panel_service.get_status))


@router.post("/update")
def update_panel_service(force: Annotated[bool, Form()] = False) -> JobResponse:
    """Update to the branch tip — the exact commit checked here, not a newer one.

    Refused while CI is red or still running on that commit, unless `force`.
    """
    _require_installed()
    _require_idle()
    check = panel_service.check_updates()
    if check["error"]:
        raise bad_request(f"Could not check for updates: {check['error']}")
    target = (check.get("remote_commit") or {}).get("hash")
    if not target or target == check.get("base"):
        raise bad_request("Already up to date.")
    ci = (check.get("ci") or {}).get("state")
    if ci in ("failure", "pending") and not force:
        what = "failed" if ci == "failure" else "has not finished"
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"CI {what} on {target[:7]}. Wait for it, or update anyway.",
        )
    return jobs.launch_bash(
        "panel_service_update",
        script=_SCRIPT,
        label="Update NsPanel service",
        title=f"Updating NsPanel service to {target[:7]}",
        env={**_job_env(), "SVC_TARGET": target},
        audit_action="panel.update",
        audit_detail=f"target={target[:12]} ci={ci} force={force}",
    )


@router.post("/rollback")
def rollback_panel_service() -> JobResponse:
    _require_installed()
    _require_idle()
    if not panel_service.get_status()["can_rollback"]:
        raise bad_request("There is no previous release on disk to roll back to.")
    return jobs.launch_bash(
        "panel_service_rollback",
        script=_SCRIPT,
        label="Roll back NsPanel service",
        env=_job_env(),
        audit_action="panel.rollback",
    )


@router.post("/restart")
def restart_panel_service() -> JobResponse:
    _require_installed()
    _require_idle()
    return jobs.launch_bash(
        "panel_service_restart",
        script=_SCRIPT,
        label="Restart NsPanel service",
        env=_job_env(),
        audit_action="panel.restart",
    )


@router.post("/uninstall")
def uninstall_panel_service() -> JobResponse:
    _require_installed()
    if panel_service.is_self():
        raise bad_request(
            "This page is served by the service itself. Uninstall it from a panel started with run.sh."
        )
    return jobs.launch_bash(
        "panel_service_uninstall",
        script=_SCRIPT,
        label="Uninstall NsPanel service",
        env=_job_env(),
        audit_action="panel.uninstall",
    )
