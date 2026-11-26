"""Guards that keep a click in the panel from taking the server down."""

import json
import os
import subprocess

import psutil
import pytest

from features import disks as disks_feature
from features import system as system_feature
from features import units
from routes import processes

# ── Process kill ──────────────────────────────────────────────────────────────


@pytest.mark.parametrize("pid", [-1, 0, 1])
def test_kill_refuses_special_pids(client, pid, monkeypatch):
    sent: list[int] = []
    monkeypatch.setattr(psutil.Process, "send_signal", lambda self, sig: sent.append(self.pid))
    response = client.post("/api/v1/processes/kill", data={"pid": pid})
    assert response.status_code == 403
    assert not sent


def test_kill_refuses_the_panel_itself(client):
    response = client.post("/api/v1/processes/kill", data={"pid": os.getpid()})
    assert response.status_code == 403


def test_kill_refuses_unknown_signals(client):
    response = client.post("/api/v1/processes/kill", data={"pid": 4242, "sig": "HUP"})
    assert response.status_code == 422


def test_kill_signals_through_psutil_only(client, audit_log, monkeypatch):
    sent: list[tuple[int, int]] = []

    class FakeProcess:
        def __init__(self, pid: int) -> None:
            self.pid = pid

        def send_signal(self, sig: int) -> None:
            sent.append((self.pid, sig))

    monkeypatch.setattr(processes.psutil, "Process", FakeProcess)
    monkeypatch.setattr(processes, "_protected_pids", lambda: {0, 1})
    response = client.post("/api/v1/processes/kill", data={"pid": 4242, "sig": "term"})
    assert response.status_code == 200
    assert sent == [(4242, processes._SIGNALS["TERM"])]
    assert audit_log == [("process.kill", "pid=4242 sig=TERM success=True")]


def test_kill_reports_a_missing_process(client, audit_log, monkeypatch):
    def gone(pid: int):
        raise psutil.NoSuchProcess(pid)

    monkeypatch.setattr(processes.psutil, "Process", gone)
    monkeypatch.setattr(processes, "_protected_pids", lambda: {0, 1})
    assert client.post("/api/v1/processes/kill", data={"pid": 4242}).status_code == 404


@pytest.mark.parametrize(
    ("argv", "shown"),
    [
        (["cloudflared", "tunnel", "run", "--token", "eyJsecret"], "cloudflared tunnel run --token ***"),
        (["sqlcmd", "-U", "SA", "-P", "hunter2"], "sqlcmd -U SA -P ***"),
        (["app", "--password=hunter2", "-p", "8080"], "app --password=*** -p 8080"),
    ],
)
def test_process_list_masks_credentials(argv, shown):
    assert processes._redact(argv) == shown


# ── Firewall delete ───────────────────────────────────────────────────────────

_RULES = {
    "installed": True,
    "enabled": True,
    "rules": [
        {"num": 1, "to": "22/tcp", "action": "ALLOW", "from_": "Anywhere", "is_v6": False, "label": "SSH"},
        {"num": 2, "to": "8080/tcp", "action": "ALLOW", "from_": "10.0.0.0/8", "is_v6": False, "label": "x"},
    ],
}


@pytest.fixture
def ufw_rules(monkeypatch):
    monkeypatch.setattr(system_feature, "get_ufw_info", lambda: _RULES)


def test_firewall_delete_runs_when_the_rule_still_matches(client, fake_runner, audit_log, ufw_rules):
    response = client.post(
        "/api/v1/firewall/delete-port",
        data={"rule_num": 2, "to": "8080/tcp", "action": "ALLOW", "from": "10.0.0.0/8"},
    )
    assert response.status_code == 200
    assert fake_runner.last_cmd[-3:] == ["ufw_delete_port", "2", "8080/tcp"]


@pytest.mark.parametrize(
    "payload",
    [
        # UFW renumbered: #1 is now a different rule than the operator saw.
        {"rule_num": 1, "to": "8080/tcp", "action": "ALLOW", "from": "10.0.0.0/8"},
        # The rule is gone entirely.
        {"rule_num": 3, "to": "8080/tcp", "action": "ALLOW", "from": "10.0.0.0/8"},
    ],
)
def test_firewall_delete_refuses_a_stale_rule_number(client, fake_runner, ufw_rules, payload):
    assert client.post("/api/v1/firewall/delete-port", data=payload).status_code == 409
    assert not fake_runner.jobs


# ── Disks ─────────────────────────────────────────────────────────────────────


def _fake_lsblk(monkeypatch, tree: dict) -> None:
    monkeypatch.setattr(disks_feature.shutil, "which", lambda name: "/usr/bin/lsblk")
    monkeypatch.setattr(
        disks_feature.subprocess,
        "run",
        lambda *a, **k: subprocess.CompletedProcess(a, 0, stdout=json.dumps(tree), stderr=""),
    )


def test_device_in_use_walks_partitions(monkeypatch):
    _fake_lsblk(
        monkeypatch,
        {
            "blockdevices": [
                {
                    "path": "/dev/sda",
                    "type": "disk",
                    "fstype": None,
                    "mountpoint": None,
                    "children": [{"path": "/dev/sda1", "type": "part", "fstype": "ext4", "mountpoint": "/"}],
                }
            ]
        },
    )
    assert disks_feature.device_in_use("/dev/sda") == "/dev/sda1 is mounted on /"


def test_device_in_use_flags_lvm_members(monkeypatch):
    _fake_lsblk(
        monkeypatch,
        {"blockdevices": [{"path": "/dev/sdb", "type": "disk", "fstype": "LVM2_member", "mountpoint": None}]},
    )
    assert "LVM2_member" in disks_feature.device_in_use("/dev/sdb")


def test_device_in_use_allows_a_blank_disk(monkeypatch):
    _fake_lsblk(
        monkeypatch,
        {"blockdevices": [{"path": "/dev/sdc", "type": "disk", "fstype": None, "mountpoint": None}]},
    )
    assert disks_feature.device_in_use("/dev/sdc") is None


# ── Tunnel tokens ─────────────────────────────────────────────────────────────


def test_unit_content_hides_inline_tunnel_tokens():
    unit = "ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate run --token eyJabc.def\n"
    assert "eyJabc" not in units.redact(unit)
    assert "--token ***" in units.redact(unit)


def test_saving_a_redacted_unit_keeps_the_real_token(tmp_path, monkeypatch):
    monkeypatch.setattr(units, "SERVICES_DIR", tmp_path)
    original = "[Service]\nExecStart=/usr/bin/cloudflared tunnel run --token eyJreal\n"
    (tmp_path / "cf-demo.service").write_text(original)
    edited = units.redact(original).replace("[Service]", "[Service]\nNice=5")
    units.write_service_raw("cf-demo", edited)
    saved = (tmp_path / "cf-demo.service").read_text()
    assert "--token eyJreal" in saved
    assert "Nice=5" in saved


def test_tunnel_tokens_go_to_a_private_env_file(tmp_path, monkeypatch):
    monkeypatch.setattr(units, "TUNNEL_ENV_DIR", tmp_path / "tunnels")
    path = units.write_tunnel_env("cf-demo", "eyJsecret")
    assert path.read_text() == "TUNNEL_TOKEN=eyJsecret\n"
    if os.name == "posix":
        assert path.stat().st_mode & 0o777 == 0o600


# ── Misc ──────────────────────────────────────────────────────────────────────


@pytest.mark.parametrize("path", ["/docs", "/redoc", "/openapi.json"])
def test_api_docs_are_not_served(client, path):
    response = client.get(path)
    assert "swagger" not in response.text.lower()
    assert '"openapi"' not in response.text


def test_jobs_do_not_inherit_the_panel_password():
    from core import runner

    assert "PANEL_PASSWORD" in runner._PRIVATE_ENV
