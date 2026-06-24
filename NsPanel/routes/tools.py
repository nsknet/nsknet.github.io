"""Tools API."""
import re

from fastapi import APIRouter, Form, HTTPException, Request

from core import audit, bash_invoker, runner
from modules import registry

router = APIRouter(prefix="/api/v1/tools")

# Subnets the install dialog may request a port be opened to. Validated server-side
# so only these exact CIDRs reach the firewall script (no arbitrary values).
ALLOWED_SUBNET_CHOICES = {
    "10.0.0.0/8",       # class A private
    "172.16.0.0/12",    # class B private
    "192.168.0.0/16",   # class C private
    "127.0.0.0/8",      # loopback
    "0.0.0.0/0",        # everything (any IP)
}

# Install scripts interpolate the password into SQL strings and systemd unit
# files, so restrict it to characters that are safe in those contexts —
# excluding quotes, backslash, $, backtick and whitespace, which could break
# the surrounding command. The UI auto-generates alphanumeric passwords; this
# guards hand-typed ones (the field is editable).
_PASSWORD_RE = re.compile(r"^[A-Za-z0-9!@#%^&*()\-_=+.:,?]+$")
_PASSWORD_HELP = (
    "Password may only contain letters, digits, and these symbols: "
    "! @ # % ^ & * ( ) - _ = + . : , ?"
)


def _collect_install_params(module, form) -> dict[str, str]:
    """Read + validate a module's declared install_params from the posted form.

    Returns {env_var: value} to merge into the install job's environment. Values
    travel via env (never argv), so they are not echoed to the live log.
    """
    env: dict[str, str] = {}
    for spec in getattr(module, "install_params", []) or []:
        name = spec["name"]
        env_key = spec.get("env", name)
        ptype = spec.get("type", "string")
        default = spec.get("default", "")
        raw = form.get(name)
        value = (str(raw) if raw is not None else str(default)).strip()

        if ptype == "select":
            allowed = {str(o["value"]) for o in spec.get("options", [])}
            if value not in allowed:
                raise HTTPException(status_code=400, detail=f"Invalid value for {spec.get('label', name)}.")
        elif ptype == "number":
            try:
                num = float(value)
            except ValueError:
                raise HTTPException(status_code=400, detail=f"{spec.get('label', name)} must be a number.")
            if "min" in spec and num < spec["min"]:
                raise HTTPException(status_code=400, detail=f"{spec.get('label', name)} must be ≥ {spec['min']}.")
            if "max" in spec and num > spec["max"]:
                raise HTTPException(status_code=400, detail=f"{spec.get('label', name)} must be ≤ {spec['max']}.")
            # Preserve integers without a trailing .0
            value = str(int(num)) if num.is_integer() else str(num)
        elif ptype == "checkbox":
            value = "true" if value.lower() in ("1", "true", "yes", "on") else "false"
        else:  # string
            if any(ord(c) < 32 for c in value):
                raise HTTPException(status_code=400, detail=f"{spec.get('label', name)} contains invalid characters.")
            value = value[:256]

        env[env_key] = value
    return env


def _validate_password(db_password: str | None) -> str:
    """Shared password check for install + change-password. Returns the cleaned
    password or raises HTTPException(400)."""
    pw = (db_password or "").strip()
    if not pw:
        raise HTTPException(status_code=400, detail="A password is required.")
    if len(pw) < 8:
        raise HTTPException(status_code=400, detail="Password must be at least 8 characters.")
    if not _PASSWORD_RE.match(pw):
        raise HTTPException(status_code=400, detail=_PASSWORD_HELP)
    return pw


def serialize_tool(m) -> dict:
    return {
        "module": {
            "name": m.name,
            "display_name": m.display_name,
            "description": m.description,
            "logo": getattr(m, "logo", m.name[:2].upper()),
            "requires_password": getattr(m, "requires_password", False),
            "firewall_ports": list(getattr(m, "firewall_ports", []) or []),
            "install_params": list(getattr(m, "install_params", []) or []),
            "can_uninstall": bool(getattr(m, "uninstall_function", None)),
            "can_change_password": bool(getattr(m, "change_password_function", None)),
        },
        "status": m.get_status()
    }


@router.get("")
def get_tools():
    return {
        "status": "success",
        "tools": [serialize_tool(m) for m in registry.get_modules()]
    }


@router.post("/{name}/install")
async def install_tool(
    request: Request,
    name: str,
    db_password: str = Form(None),
    allowed_subnets: str = Form(None),
    reinstall: str = Form(None),
):
    module = registry.get_module(name)
    if module is None:
        raise HTTPException(status_code=404, detail=f"Unknown tool: {name}")

    # Re-install re-runs the installer over an existing install, so it skips the
    # already-installed guard that a fresh install enforces.
    is_reinstall = str(reinstall).lower() in ("1", "true", "yes", "on")
    if module.is_installed() and not is_reinstall:
        audit.log("tool.install_refused", f"name={name} reason=already_installed")
        raise HTTPException(status_code=400, detail=f"{module.display_name} is already installed.")

    if not module.bash_function:
        raise HTTPException(status_code=400, detail=f"{module.display_name} has no install action.")

    # Secrets and firewall scope are passed via env (not argv) so they never show
    # up in the command line echoed to the live log.
    env: dict[str, str] = {}

    if getattr(module, "requires_password", False):
        env["DB_PASSWORD"] = _validate_password(db_password)

    # Module-declared custom params (edition dropdown, etc.) → env.
    if getattr(module, "install_params", None):
        env.update(_collect_install_params(module, await request.form()))

    firewall_ports = list(getattr(module, "firewall_ports", []) or [])
    if firewall_ports and allowed_subnets:
        requested = [s.strip() for s in allowed_subnets.split(",") if s.strip()]
        invalid = [s for s in requested if s not in ALLOWED_SUBNET_CHOICES]
        if invalid:
            raise HTTPException(status_code=400, detail=f"Invalid subnet(s): {', '.join(invalid)}")
        if requested:
            # 0.0.0.0/0 (any) makes every other subnet redundant — collapse to it.
            if "0.0.0.0/0" in requested:
                requested = ["0.0.0.0/0"]
            env["ALLOWED_SUBNETS"] = " ".join(requested)

    verb = "Re-install" if is_reinstall else "Install"
    cmd = bash_invoker.build_cmd(module.bash_function)
    job_id = runner.create_job(cmd, label=f"{verb} {module.display_name}", env=env)
    runner.start_job(job_id)
    audit.log(
        "tool.reinstall" if is_reinstall else "tool.install",
        f"name={name} display={module.display_name} job={job_id} "
        f"subnets={env.get('ALLOWED_SUBNETS', 'default')}",
    )

    return {
        "status": "success",
        "job_id": job_id,
        "title": f"{verb}ing {module.display_name}",
    }


@router.post("/{name}/uninstall")
async def uninstall_tool(name: str):
    module = registry.get_module(name)
    if module is None:
        raise HTTPException(status_code=404, detail=f"Unknown tool: {name}")

    fn = getattr(module, "uninstall_function", None)
    if not fn:
        raise HTTPException(status_code=400, detail=f"{module.display_name} cannot be uninstalled from the panel.")

    cmd = bash_invoker.build_cmd(fn)
    job_id = runner.create_job(cmd, label=f"Uninstall {module.display_name}")
    runner.start_job(job_id)
    audit.log("tool.uninstall", f"name={name} display={module.display_name} job={job_id}")

    return {
        "status": "success",
        "job_id": job_id,
        "title": f"Uninstalling {module.display_name}",
    }


@router.post("/{name}/change-password")
async def change_password(name: str, db_password: str = Form(None)):
    module = registry.get_module(name)
    if module is None:
        raise HTTPException(status_code=404, detail=f"Unknown tool: {name}")

    fn = getattr(module, "change_password_function", None)
    if not fn:
        raise HTTPException(status_code=400, detail=f"{module.display_name} does not support changing its password.")

    env = {"DB_PASSWORD": _validate_password(db_password)}
    cmd = bash_invoker.build_cmd(fn)
    job_id = runner.create_job(cmd, label=f"Change {module.display_name} password", env=env)
    runner.start_job(job_id)
    audit.log("tool.change_password", f"name={name} display={module.display_name} job={job_id}")

    return {
        "status": "success",
        "job_id": job_id,
        "title": f"Changing {module.display_name} password",
    }
