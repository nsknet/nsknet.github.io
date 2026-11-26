"""Pure helpers in features/ that the routes rely on."""

import pytest

from features import cloudflare_tunnel as cf
from features import system as system_feature
from features import units


def test_unit_file_parsing_reads_fields_and_tunnel_metadata():
    content = "\n".join(
        [
            "[Unit]",
            "Description=My app",
            "[Service]",
            "WorkingDirectory=/var/www/app",
            "ExecStart=/usr/bin/dotnet App.dll",
            "User=www-data",
            "Restart=always",
            "RestartSec=5",
            "SyslogIdentifier=app",
            "Environment=ASPNETCORE_URLS=http://127.0.0.1:5000",
            "Environment=DOTNET_ENVIRONMENT=Production",
            *units.tunnel_unit_lines(
                "app.example.com", "http://localhost:5000", "abc", "app-tunnel", "example.com"
            ),
        ]
    )
    fields = units._parse_service_file(content)
    assert fields["description"] == "My app"
    assert fields["working_dir"] == "/var/www/app"
    assert fields["user"] == "www-data"
    assert fields["restart_sec"] == "5"
    assert fields["env_vars"] == ["ASPNETCORE_URLS=http://127.0.0.1:5000", "DOTNET_ENVIRONMENT=Production"]
    assert fields["tunnel"] == {
        "hostname": "app.example.com",
        "service_url": "http://localhost:5000",
        "tunnel_id": "abc",
        "tunnel_name": "app-tunnel",
        "zone": "example.com",
        "public_url": "https://app.example.com",
    }


def test_unit_without_tunnel_id_has_no_tunnel():
    fields = units._parse_service_file("X-NsPanel-Tunnel-Hostname=app.example.com\n")
    assert fields["tunnel"] is None


def test_inline_tunnel_tokens_are_redacted():
    text = "ExecStart=/usr/bin/cloudflared tunnel run --token eyJhIjoiYiJ9\n"
    assert "eyJ" not in units.redact(text)
    assert units.REDACTED in units.redact(text)


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("HTTPS://Dev.Example.com/", "dev.example.com"),
        ("app.example.com.", "app.example.com"),
    ],
)
def test_hostname_normalisation(raw, expected):
    assert cf.normalize_hostname(raw) == expected


@pytest.mark.parametrize("raw", ["", "localhost", "not a host"])
def test_bad_hostnames_are_refused(raw):
    with pytest.raises(cf.TunnelError):
        cf.normalize_hostname(raw)


@pytest.mark.parametrize(
    ("url", "port", "expected"),
    [
        ("5016", None, "http://localhost:5016"),
        ("localhost:5016/", None, "http://localhost:5016"),
        ("http://127.0.0.1", 5016, "http://127.0.0.1:5016"),
        ("https://10.0.0.5:8443/api/", None, "https://10.0.0.5:8443/api"),
    ],
)
def test_service_url_normalisation(url, port, expected):
    assert cf.normalize_service_url(url, port) == expected


@pytest.mark.parametrize(("url", "port"), [("", None), ("ftp://host", None), ("localhost", 70000)])
def test_bad_service_urls_are_refused(url, port):
    with pytest.raises(cf.TunnelError):
        cf.normalize_service_url(url, port)


def test_tunnel_names():
    assert cf.tunnel_service_name("app.example.com") == "cloudflared.app.example.com"
    assert cf.default_tunnel_name("app.example.com") == "app-example-com-tunnel"


def test_ufw_status_parsing(monkeypatch):
    output = (
        "Status: active\n\n"
        "     To                         Action      From\n"
        "     --                         ------      ----\n"
        "[ 1] 22/tcp                     ALLOW IN    Anywhere\n"
        "[ 2] 8080/tcp                   LIMIT IN    10.0.0.0/8                 # admin\n"
        "[ 3] 22/tcp (v6)                ALLOW IN    Anywhere (v6)\n"
    )

    class Result:
        stdout = output

    monkeypatch.setattr(system_feature.shutil, "which", lambda name: "/usr/sbin/ufw")
    monkeypatch.setattr(system_feature.subprocess, "run", lambda *a, **k: Result())
    info = system_feature.get_ufw_info()
    assert info["enabled"] is True
    first, second, third = info["rules"]
    assert first == {
        "num": 1,
        "to": "22/tcp",
        "action": "ALLOW",
        "direction": "IN",
        "from_": "Anywhere",
        "is_v6": False,
        "label": "SSH",
    }
    assert second["action"] == "LIMIT" and second["from_"] == "10.0.0.0/8" and second["label"] == "admin"
    assert third["is_v6"] is True


def test_ufw_defaults_parsing(monkeypatch):
    class Result:
        stdout = "Status: active\nDefault: deny (incoming), allow (outgoing), disabled (routed)\n"

    monkeypatch.setattr(system_feature.shutil, "which", lambda name: "/usr/sbin/ufw")
    monkeypatch.setattr(system_feature.subprocess, "run", lambda *a, **k: Result())
    assert system_feature.ufw_defaults() == {"incoming": "deny", "outgoing": "allow", "routed": "disabled"}
