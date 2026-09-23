"""System API: timezone, network and disk validation."""
import pytest

from features import disks as disks_feature
from features import system as system_feature


@pytest.fixture(autouse=True)
def stub_system(monkeypatch):
    monkeypatch.setattr(system_feature, "get_full_info", lambda: {"hostname": "vps"})
    monkeypatch.setattr(system_feature, "get_ufw_info", lambda: {"active": True, "rules": []})
    monkeypatch.setattr(disks_feature, "list_disks", lambda: [{"device": "/dev/sda"}])


def test_system_info_uses_the_data_envelope(client):
    assert client.get("/api/v1/system").json()["data"]["hostname"] == "vps"


def test_disks_use_the_data_envelope(client):
    assert client.get("/api/v1/system/disks").json()["data"][0]["device"] == "/dev/sda"


def test_timezone_accepts_any_real_zone(client, fake_runner, audit_log):
    body = client.post("/api/v1/system/set-timezone", data={"tz": "Europe/Berlin"}).json()
    assert body["title"] == "Setting Timezone → Europe/Berlin"
    assert fake_runner.last_cmd[-1] == "Europe/Berlin"


def test_timezone_rejects_unknown_zones(client, fake_runner):
    assert client.post("/api/v1/system/set-timezone", data={"tz": "Mars/Olympus"}).status_code == 400
    assert not fake_runner.jobs


def test_static_network_requires_cidr(client, fake_runner):
    response = client.post(
        "/api/v1/system/set-network",
        data={"iface": "eth0", "method": "manual", "address": "192.168.1.50"},
    )
    assert response.status_code == 400
    assert not fake_runner.jobs


def test_static_network_passes_normalized_values(client, fake_runner, audit_log):
    client.post(
        "/api/v1/system/set-network",
        data={
            "iface": "eth0",
            "method": "manual",
            "address": "192.168.1.50/24",
            "gateway": "192.168.1.1",
            "dns": "1.1.1.1, 8.8.8.8",
        },
    )
    args = fake_runner.last_cmd[6:]
    assert args == ["eth0", "manual", "192.168.1.50/24", "192.168.1.1", "1.1.1.1,8.8.8.8"]


def test_dhcp_clears_the_address_fields(client, fake_runner, audit_log):
    client.post("/api/v1/system/set-network", data={"iface": "eth0", "method": "dhcp"})
    assert fake_runner.last_cmd[6:] == ["eth0", "dhcp", "", "", ""]


@pytest.mark.parametrize(
    "payload",
    [
        {"iface": "bad iface", "method": "dhcp"},
        {"iface": "eth0", "method": "carrier-pigeon"},
        {"iface": "eth0", "method": "manual", "address": "10.0.0.5/24", "gateway": "not-an-ip"},
        {"iface": "eth0", "method": "manual", "address": "10.0.0.5/24", "dns": "1.1.1.1,nope"},
    ],
)
def test_network_rejects_bad_input(client, fake_runner, payload):
    assert client.post("/api/v1/system/set-network", data=payload).status_code in (400, 422)
    assert not fake_runner.jobs


def test_swap_size_is_clamped(client, fake_runner, audit_log):
    client.post("/api/v1/system/swap", data={"size_gb": "999"})
    assert fake_runner.last_cmd[-1] == "64"


@pytest.mark.parametrize(
    "payload",
    [
        {"device": "/etc/passwd", "mountpoint": "/mnt/data"},
        {"device": "/dev/sda1", "mountpoint": "relative/path"},
        {"device": "/dev/sda1; rm -rf /", "mountpoint": "/mnt/data"},
    ],
)
def test_mount_rejects_bad_paths(client, fake_runner, payload):
    assert client.post("/api/v1/system/disk/mount", data=payload).status_code == 400
    assert not fake_runner.jobs


def test_format_rejects_unknown_filesystems(client, fake_runner):
    response = client.post(
        "/api/v1/system/disk/format", data={"device": "/dev/sdb1", "fstype": "zfs"}
    )
    assert response.status_code == 400
    assert not fake_runner.jobs


def test_format_passes_device_fstype_and_label(client, fake_runner, audit_log):
    client.post(
        "/api/v1/system/disk/format",
        data={"device": "/dev/sdb1", "fstype": "EXT4", "label": "data-01"},
    )
    assert fake_runner.last_cmd[6:] == ["/dev/sdb1", "ext4", "data-01"]
