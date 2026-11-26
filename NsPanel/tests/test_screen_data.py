"""Read endpoints the redesigned screens depend on."""

from features import alerts
from features import disks as disks_feature
from features import system as system_feature


def test_timezones_are_listed(client):
    zones = client.get("/api/v1/system/timezones").json()["data"]
    assert "Europe/Berlin" in zones
    assert zones == sorted(zones)


def test_firewall_reports_what_must_stay_reachable(client, monkeypatch):
    ufw = {"installed": True, "enabled": True, "rules": []}
    monkeypatch.setattr(system_feature, "get_ufw_info", lambda: ufw)
    monkeypatch.setattr(system_feature, "ufw_defaults", lambda: {"incoming": "deny", "outgoing": "allow"})
    monkeypatch.setattr(system_feature, "ssh_ports", lambda: [2222])
    data = client.get("/api/v1/firewall").json()["data"]
    assert data["ssh_ports"] == [2222]
    assert data["panel_port"]
    assert data["client_ip"]
    assert data["defaults"]["incoming"] == "deny"


def test_firewall_disable_is_a_job(client, fake_runner, audit_log):
    assert client.post("/api/v1/firewall/disable").status_code == 200
    assert fake_runner.last_cmd == ["ufw", "--force", "disable"]


def test_firewall_install_allows_the_panel_port(client, fake_runner, audit_log):
    client.post("/api/v1/firewall/install")
    assert fake_runner.last["env"]["NSPANEL_PORT"]


def test_disks_are_annotated_with_why_they_are_in_use():
    tree = {
        "path": "/dev/sda",
        "type": "disk",
        "fstype": "",
        "mountpoint": "",
        "children": [
            {"path": "/dev/sda1", "type": "part", "fstype": "ext4", "mountpoint": "/", "children": []},
            {"path": "/dev/sda2", "type": "part", "fstype": "", "mountpoint": "", "children": []},
        ],
    }
    disk = disks_feature._annotate_in_use(tree)
    assert disk["in_use"] == "/dev/sda1 mounted on /"
    assert disk["system"] is True
    assert disk["children"][1]["in_use"] == ""
    blank = disks_feature._annotate_in_use(
        {"path": "/dev/sdb", "type": "disk", "fstype": "", "mountpoint": "", "children": []}
    )
    assert (blank["in_use"], blank["system"]) == ("", False)


def test_dashboard_carries_alerts(client, monkeypatch):
    alert = {"level": "warn", "title": "x", "detail": "", "link": ""}
    monkeypatch.setattr(alerts, "collect", lambda: [alert])
    monkeypatch.setattr(system_feature, "get_stats", lambda: {})
    from features import sites
    from modules import registry

    monkeypatch.setattr(sites, "list_sites_with_status", lambda: [])
    monkeypatch.setattr(registry, "serialize_all", lambda: [])
    assert client.get("/api/v1/dashboard").json()["data"]["alerts"][0]["title"] == "x"


def test_alert_probes_never_raise(monkeypatch):
    def boom():
        raise RuntimeError("probe failed")

    monkeypatch.setattr(alerts, "_disk_alerts", boom)
    assert isinstance(alerts.collect(), list)


def test_processes_flag_protected_ones(client):
    import os

    rows = client.get("/api/v1/processes", params={"q": str(os.getpid())}).json()["data"]
    mine = [r for r in rows if r["pid"] == os.getpid()]
    assert mine and mine[0]["protected"] is True


def test_dashboard_live_is_stats_and_alerts_only(client, monkeypatch):
    monkeypatch.setattr(alerts, "collect", lambda: [])
    monkeypatch.setattr(system_feature, "get_stats", lambda: {"cpu_percent": 1})
    data = client.get("/api/v1/dashboard/live").json()["data"]
    assert data == {"stats": {"cpu_percent": 1}, "alerts": []}
