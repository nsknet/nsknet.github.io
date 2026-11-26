"""Launching background jobs — the one place routes go to run something.

Every action route follows the same three steps: build a command, hand it to
:mod:`core.runner`, and record it in the audit log. `launch` and `launch_bash`
do all three and return the :class:`~core.schemas.JobResponse` the client needs
to open the SSE stream.

`systemctl_chain` builds multi-step systemd commands **without interpolating
names into a shell string** — the unit name travels as a positional argument,
so a name that slipped past validation still cannot break out of its slot.
"""

import re
from typing import Any

from core import audit, bash_invoker, runner
from core.schemas import JobResponse

# Bash functions that install or remove packages: they run one at a time
# (runner "exclusive" jobs) so two of them never fight over the dpkg lock.
_EXCLUSIVE = re.compile(r"^(install_|uninstall_|common_configs$|panel_service_(install|update)$)")


def launch(
    cmd: list[str],
    *,
    label: str,
    audit_action: str,
    audit_detail: str = "",
    env: dict[str, str] | None = None,
    title: str | None = None,
    extra: dict[str, Any] | None = None,
    exclusive: bool = False,
) -> JobResponse:
    """Create, start, and log one background job."""
    job_id = runner.create_job(cmd, label=label, env=env, exclusive=exclusive)
    runner.start_job(job_id)
    detail = f"{audit_detail} job={job_id}".strip()
    audit.log(audit_action, detail)
    return JobResponse(job_id=job_id, title=title or label, extra=extra or {})


def launch_bash(
    function: str,
    *args: str,
    label: str,
    audit_action: str,
    audit_detail: str = "",
    env: dict[str, str] | None = None,
    title: str | None = None,
    script: str | None = None,
    extra: dict[str, Any] | None = None,
) -> JobResponse:
    """Run a bash function from scripts/ as a background job."""
    cmd = bash_invoker.build_cmd(function, *args, script=script)
    return launch(
        cmd,
        label=label,
        audit_action=audit_action,
        audit_detail=audit_detail,
        env=env,
        title=title,
        extra=extra,
        exclusive=bool(_EXCLUSIVE.match(function)),
    )


# systemctl verbs a screen may run on one unit: (label verb, progress verb).
SYSTEMCTL_VERBS = {
    "start": ("Start", "Starting"),
    "stop": ("Stop", "Stopping"),
    "restart": ("Restart", "Restarting"),
    "disable": ("Disable", "Disabling"),
}


def launch_systemctl(verb: str, unit: str, *, audit_prefix: str) -> JobResponse:
    """`systemctl <verb> <unit>` as a job, audited as `<audit_prefix>.<verb>`."""
    label_verb, title_verb = SYSTEMCTL_VERBS[verb]
    return launch(
        ["systemctl", verb, unit],
        label=f"{label_verb} {unit}",
        title=f"{title_verb} '{unit}'",
        audit_action=f"{audit_prefix}.{verb}",
        audit_detail=f"name={unit}",
    )


def systemctl_chain(*steps: list[str], echo: str = "", ignore_failures: bool = False) -> list[str]:
    """Build one `bash -c` command running several argv-safe steps in order.

    Each step is a full argv list. Values are passed to the shell as positional
    parameters, never spliced into the script text::

        systemctl_chain(["systemctl", "restart", name], echo="Restarted.")

    `ignore_failures` joins the steps with `;` instead of `&&` (teardown paths
    where a stop/disable on an already-dead unit must not abort the rest).
    """
    argv: list[str] = []
    fragments: list[str] = []
    index = 1
    for step in steps:
        placeholders = " ".join(f'"${{{index + offset}}}"' for offset in range(len(step)))
        fragments.append(placeholders)
        argv.extend(str(part) for part in step)
        index += len(step)

    separator = " ; " if ignore_failures else " && "
    script = separator.join(fragments)
    if echo:
        argv.append(echo)
        script = f'{script}{separator}echo "${{{index}}}"'
    return ["bash", "-c", script, "--", *argv]
