"""Firewall screen: listing, adding rules and the lockout context."""

import pytest

import config
from features import system as system_feature


@pytest.fixture(autouse=True)
def ufw(monkeypatch):
    monkeypatch.setattr(
        system_feature, "get_ufw_info", lambda: {"installed": True, "enabled": True, "rules": []}
    )
    monkeypatch.setattr(system_feature, "ufw_defaults", lambda: {"incoming": "deny", "outgoing": "allow"})
    monkeypatch.setattr(system_feature, "ssh_ports", lambda: [2222])


def test_listing_carries_what_the_lockout_guard_needs(client):
    data = client.get("/api/v1/firewall").json()["data"]
    assert data["ssh_ports"] == [2222]
    assert data["panel_port"] == config.PORT
    assert data["client_ip"] == "testclient"
    assert data["defaults"]["incoming"] == "deny"


def test_add_port_passes_the_rule_as_positional_args(client, fake_runner):
    response = client.post(
        "/api/v1/firewall/add-port",
        data={"port": "8443/tcp", "action": "limit", "source": "10.0.0.0/8", "comment": " web "},
    )
    assert response.status_code == 200, response.text
    cmd = fake_runner.last_cmd
    assert cmd[-5:] == ["ufw_allow_port", "8443/tcp", "limit", "10.0.0.0/8", "web"]


@pytest.mark.parametrize(
    "form",
    [
        {"port": "0"},
        {"port": "70000"},
        {"port": "80; rm -rf /"},
        {"port": "80", "action": "nuke"},
        {"port": "80", "source": "not-an-ip"},
    ],
)
def test_add_port_rejects_bad_rules(client, fake_runner, form):
    response = client.post("/api/v1/firewall/add-port", data=form)
    assert response.status_code == 422
    assert response.json()["status"] == "error"
    assert not fake_runner.jobs


def test_install_tells_the_script_which_port_the_panel_uses(client, fake_runner):
    client.post("/api/v1/firewall/install")
    assert fake_runner.last["env"]["NSPANEL_PORT"] == str(config.PORT)
