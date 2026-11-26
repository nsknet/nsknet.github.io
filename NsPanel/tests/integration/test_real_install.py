"""Real installs on a throwaway Ubuntu machine (the GitHub runner in CI).

These run the exact command the panel would run (core.bash_invoker.build_cmd)
as root, then check the result from the outside. They change the machine, so
they only run when NSPANEL_INTEGRATION=1 on Linux as root:

    sudo -E env "PATH=$PATH" NSPANEL_INTEGRATION=1 python -m pytest tests/integration -v
"""

import os
import shutil
import subprocess
import sys

import pytest

from core import bash_invoker

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        os.environ.get("NSPANEL_INTEGRATION") != "1"
        or not sys.platform.startswith("linux")
        or not hasattr(os, "geteuid")
        or os.geteuid() != 0,
        reason="needs NSPANEL_INTEGRATION=1, Linux and root",
    ),
]

PANEL_PORT = "7777"


def run_action(function: str, *args: str, script: str, env: dict[str, str] | None = None) -> str:
    """Run one bash action the way the job runner does; fail with its output."""
    cmd = bash_invoker.build_cmd(function, *args, script=script)
    result = subprocess.run(
        cmd,
        env={**os.environ, "DEBIAN_FRONTEND": "noninteractive", **(env or {})},
        capture_output=True,
        text=True,
        timeout=1200,
    )
    output = result.stdout + result.stderr
    assert result.returncode == 0, f"{function} exited {result.returncode}\n{output[-6000:]}"
    return output


def sh(*cmd: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=60)


def test_nginx_installs_and_serves():
    run_action("install_nginx", script="nginx.sh")
    assert sh("systemctl", "is-active", "nginx").stdout.strip() == "active"
    assert sh("nginx", "-t").returncode == 0
    assert os.path.isdir("/var/www/nginx/sites")


def test_redis_installs_with_a_password_and_uninstalls():
    password = "ci-only-Redis-pass-1"
    run_action(
        "install_redis",
        script="redis.sh",
        env={"DB_PASSWORD": password, "ALLOWED_SUBNETS": "10.0.0.0/8"},
    )
    assert sh("systemctl", "is-active", "redis-server").stdout.strip() == "active"

    anonymous = sh("redis-cli", "ping")
    assert "PONG" not in anonymous.stdout, "Redis answered without a password"
    authed = subprocess.run(
        ["redis-cli", "ping"],
        env={**os.environ, "REDISCLI_AUTH": password},
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert authed.stdout.strip() == "PONG"
    assert oct(os.stat("/etc/redis/credentials.yml").st_mode & 0o777) == "0o600"

    run_action("uninstall_redis", script="redis.sh")
    assert sh("systemctl", "is-active", "redis-server").stdout.strip() != "active"


@pytest.mark.skipif(shutil.which("sshd") is None, reason="no OpenSSH server on this machine")
def test_enabling_ufw_keeps_ssh_and_the_panel_reachable():
    ssh_ports = {
        line.split()[1] for line in sh("sshd", "-T").stdout.splitlines() if line.startswith("port ")
    } or {"22"}

    run_action("install_ufw", script="firewall.sh", env={"NSPANEL_PORT": PANEL_PORT})
    status = sh("ufw", "status").stdout
    assert "Status: active" in status
    rules = [line.split()[0] for line in status.splitlines() if "ALLOW" in line]
    for port in ssh_ports:
        assert any(rule.split("/")[0] == port or rule == "OpenSSH" for rule in rules), status
    assert any(rule.split("/")[0] == PANEL_PORT for rule in rules), status
