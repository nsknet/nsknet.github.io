"""DNS screen: CoreDNS host records stored in a hosts file."""

from pathlib import Path

import pytest

from features import dns as dns_feature


@pytest.fixture
def hosts(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """CoreDNS 'installed', with its hosts file under tmp_path."""
    coredns_dir = tmp_path / "coredns"
    monkeypatch.setattr(dns_feature, "COREDNS_DIR", coredns_dir)
    monkeypatch.setattr(dns_feature, "HOSTS_FILE", coredns_dir / "hosts")
    monkeypatch.setattr(dns_feature, "is_installed", lambda: True)
    monkeypatch.setattr(
        dns_feature, "status", lambda: {"installed": True, "running": True, "version": "1.11"}
    )
    return coredns_dir / "hosts"


def test_records_round_trip_through_the_hosts_file(client, hosts):
    ok = client.post("/api/v1/dns/records", data={"ip": "10.0.0.5", "domain": "App.Example.com."})
    assert ok.status_code == 200, ok.text
    client.post("/api/v1/dns/records", data={"ip": "10.0.0.6", "domain": "api.example.com"})

    body = client.get("/api/v1/dns").json()["data"]
    assert body["installed"] is True
    assert body["records"] == [
        {"ip": "10.0.0.6", "domain": "api.example.com"},
        {"ip": "10.0.0.5", "domain": "app.example.com"},
    ]
    assert hosts.read_text().startswith("# CoreDNS host records")


def test_upsert_replaces_the_ip_of_an_existing_domain(client, hosts):
    client.post("/api/v1/dns/records", data={"ip": "10.0.0.5", "domain": "app.example.com"})
    client.post("/api/v1/dns/records", data={"ip": "10.0.0.9", "domain": "app.example.com"})
    assert dns_feature.read_records() == [{"ip": "10.0.0.9", "domain": "app.example.com"}]


def test_one_line_can_map_several_domains(hosts):
    hosts.parent.mkdir(parents=True)
    hosts.write_text("# comment\n\n10.0.0.1 a.lan b.lan\nbroken-line\n")
    assert dns_feature.read_records() == [
        {"ip": "10.0.0.1", "domain": "a.lan"},
        {"ip": "10.0.0.1", "domain": "b.lan"},
    ]


@pytest.mark.parametrize(
    ("ip", "domain"),
    [("10.0.0.256", "app.example.com"), ("::1", "app.example.com"), ("10.0.0.5", "bad_domain!")],
)
def test_invalid_input_is_rejected(client, hosts, ip, domain):
    response = client.post("/api/v1/dns/records", data={"ip": ip, "domain": domain})
    assert response.status_code == 400
    assert response.json()["status"] == "error"
    assert not hosts.exists()


def test_delete_reports_missing_records(client, hosts):
    client.post("/api/v1/dns/records", data={"ip": "10.0.0.5", "domain": "app.example.com"})
    assert client.post("/api/v1/dns/records/delete", data={"domain": "app.example.com"}).status_code == 200
    assert dns_feature.read_records() == []
    missing = client.post("/api/v1/dns/records/delete", data={"domain": "app.example.com"})
    assert missing.status_code == 404


def test_writes_need_coredns(client, hosts, monkeypatch):
    monkeypatch.setattr(dns_feature, "is_installed", lambda: False)
    response = client.post("/api/v1/dns/records", data={"ip": "10.0.0.5", "domain": "a.example.com"})
    assert response.status_code == 400
    assert "not installed" in response.json()["message"]
