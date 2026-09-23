"""Tools API: install, re-install, uninstall and password changes for tool modules."""
from typing import Annotated

from fastapi import APIRouter, Form, HTTPException, Request

from core import audit, jobs
from core.schemas import DataResponse, JobResponse, Tool
from core.validators import bad_request, require_password
from modules import registry
from modules.base import Module

router = APIRouter(prefix="/api/v1/tools")

# Subnets the install dialog may request a port be opened to. Validated server-side
# so only these exact CIDRs reach the firewall script (no arbitrary values).
ALLOWED_SUBNET_CHOICES = {
    "10.0.0.0/8",  # class A private
    "172.16.0.0/12",  # class B private
    "192.168.0.0/16",  # class C private
    "127.0.0.0/8",  # loopback
    "0.0.0.0/0",  # everything (any IP)
}


def _module_or_404(name: str) -> Module:
    module = registry.get_module(name)
    if module is None:
        raise HTTPException(status_code=404, detail=f"Unknown tool: {name}")
    return module


def _collect_install_params(module: Module, form) -> dict[str, str]:
    """Read + validate a module's declared install_params from the posted form.

    Returns {env_var: value} to merge into the install job's environment. Values
    travel via env (never argv), so they are not echoed to the live log.
    """
    env: dict[str, str] = {}
    for spec in module.install_params or []:
        name = spec["name"]
        label = spec.get("label", name)
        env_key = spec.get("env", name)
        ptype = spec.get("type", "string")
        raw = form.get(name)
        value = (str(raw) if raw is not None else str(spec.get("default", ""))).strip()

        if ptype == "select":
            allowed = {str(o["value"]) for o in spec.get("options", [])}
            if value not in allowed:
                raise bad_request(f"Invalid value for {label}.")
        elif ptype == "number":
            try:
                num = float(value)
            except ValueError as exc:
                raise bad_request(f"{label} must be a number.") from exc
            if "min" in spec and num < spec["min"]:
                raise bad_request(f"{label} must be ≥ {spec['min']}.")
            if "max" in spec and num > spec["max"]:
                raise bad_request(f"{label} must be ≤ {spec['max']}.")
            # Preserve integers without a trailing .0
            value = str(int(num)) if num.is_integer() else str(num)
        elif ptype == "checkbox":
            value = "true" if value.lower() in ("1", "true", "yes", "on") else "false"
        else:  # string
            if any(ord(c) < 32 for c in value):
                raise bad_request(f"{label} contains invalid characters.")
            value = value[:256]

        env[env_key] = value
    return env


def _resolve_subnets(module: Module, allowed_subnets: str | None) -> str | None:
    if not module.firewall_ports or not allowed_subnets:
        return None
    requested = [s.strip() for s in allowed_subnets.split(",") if s.strip()]
    invalid = [s for s in requested if s not in ALLOWED_SUBNET_CHOICES]
    if invalid:
        raise bad_request(f"Invalid subnet(s): {', '.join(invalid)}")
    if not requested:
        return None
    # 0.0.0.0/0 (any) makes every other subnet redundant — collapse to it.
    if "0.0.0.0/0" in requested:
        return "0.0.0.0/0"
    return " ".join(requested)


@router.get("")
def get_tools() -> DataResponse[list[Tool]]:
    return DataResponse(data=registry.serialize_all())


@router.post("/{name}/install")
async def install_tool(
    request: Request,
    name: str,
    db_password: Annotated[str | None, Form()] = None,
    allowed_subnets: Annotated[str | None, Form()] = None,
    reinstall: Annotated[str | None, Form()] = None,
) -> JobResponse:
    module = _module_or_404(name)

    # Re-install re-runs the installer over an existing install, so it skips the
    # already-installed guard that a fresh install enforces.
    is_reinstall = str(reinstall).lower() in ("1", "true", "yes", "on")
    if module.is_installed() and not is_reinstall:
        audit.log("tool.install_refused", f"name={name} reason=already_installed")
        raise bad_request(f"{module.display_name} is already installed.")

    if not module.bash_function:
        raise bad_request(f"{module.display_name} has no install action.")

    # Secrets and firewall scope travel via env (not argv) so they never show up
    # in the command line echoed to the live log.
    env: dict[str, str] = {}
    if module.requires_password:
        env["DB_PASSWORD"] = require_password(db_password)
    if module.install_params:
        env.update(_collect_install_params(module, await request.form()))
    subnets = _resolve_subnets(module, allowed_subnets)
    if subnets:
        env["ALLOWED_SUBNETS"] = subnets

    verb = "Re-install" if is_reinstall else "Install"
    return jobs.launch_bash(
        module.bash_function,
        script=module.script_name,
        label=f"{verb} {module.display_name}",
        title=f"{verb}ing {module.display_name}",
        env=env,
        audit_action="tool.reinstall" if is_reinstall else "tool.install",
        audit_detail=(
            f"name={name} display={module.display_name} subnets={env.get('ALLOWED_SUBNETS', 'default')}"
        ),
    )


@router.post("/{name}/uninstall")
def uninstall_tool(name: str) -> JobResponse:
    module = _module_or_404(name)
    if not module.uninstall_function:
        raise bad_request(f"{module.display_name} cannot be uninstalled from the panel.")

    return jobs.launch_bash(
        module.uninstall_function,
        script=module.script_name,
        label=f"Uninstall {module.display_name}",
        title=f"Uninstalling {module.display_name}",
        audit_action="tool.uninstall",
        audit_detail=f"name={name} display={module.display_name}",
    )


@router.post("/{name}/change-password")
def change_password(name: str, db_password: Annotated[str | None, Form()] = None) -> JobResponse:
    module = _module_or_404(name)
    if not module.change_password_function:
        raise bad_request(f"{module.display_name} does not support changing its password.")

    return jobs.launch_bash(
        module.change_password_function,
        script=module.script_name,
        label=f"Change {module.display_name} password",
        title=f"Changing {module.display_name} password",
        env={"DB_PASSWORD": require_password(db_password)},
        audit_action="tool.change_password",
        audit_detail=f"name={name} display={module.display_name}",
    )
