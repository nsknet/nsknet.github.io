"""Input that must never reach a path join, a unit file or systemctl argv."""
from pathlib import Path

import pytest

from features import sites as sites_feature
from features import units


@pytest.mark.parametrize("name", ["-rf", ".hidden", "a b", "x%2F..%2Fetc"])
@pytest.mark.parametrize("prefix", ["/api/v1/services", "/api/v1/sites"])
def test_bad_names_in_the_url_are_rejected_before_the_handler(client, fake_runner, prefix, name):
    response = client.post(f"{prefix}/{name}/restart")
    assert response.status_code in (404, 405, 422)
    assert not fake_runner.jobs


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("description", "demo\nExecStartPre=/bin/sh -c 'id'"),
        ("command", "/usr/bin/app\r\nUser=root"),
        ("working_dir", "/srv/app\nUser=root"),
        ("user", "root\nGroup=root"),
        ("env_vars", "GOOD=1\nnot an assignment"),
    ],
)
def test_service_create_rejects_unit_injection(client, fake_runner, field, value):
    payload = {"name": "demo", "working_dir": "/srv/app", "command": "/usr/bin/app", field: value}
    response = client.post("/api/v1/services/create", data=payload)
    assert response.status_code == 422
    assert not fake_runner.jobs


def test_unit_edit_is_verified_backed_up_and_swapped(tmp_path, monkeypatch):
    monkeypatch.setattr(units, "SERVICES_DIR", tmp_path)
    (tmp_path / "demo.service").write_text("[Service]\nExecStart=/bin/true\n")

    monkeypatch.setattr(units, "_verify_unit", lambda name, content: "Unknown key name 'Bogus'")
    with pytest.raises(units.UnitInvalid):
        units.write_service_raw("demo", "[Service]\nBogus=1\n")
    assert (tmp_path / "demo.service").read_text() == "[Service]\nExecStart=/bin/true\n"

    monkeypatch.setattr(units, "_verify_unit", lambda name, content: None)
    units.write_service_raw("demo", "[Service]\nExecStart=/bin/false")
    assert (tmp_path / "demo.service").read_text() == "[Service]\nExecStart=/bin/false\n"
    assert (tmp_path / "demo.service.bak").read_text() == "[Service]\nExecStart=/bin/true\n"


def test_unit_edit_route_reports_verify_errors(client, fake_runner, monkeypatch):
    monkeypatch.setattr(units, "service_exists", lambda name: True)

    def reject(name, content, verify=True):
        if verify:
            raise units.UnitInvalid("bad unit")

    monkeypatch.setattr(units, "write_service_raw", reject)
    response = client.post("/api/v1/services/demo/edit", data={"content": "x"})
    assert response.status_code == 400
    assert "bad unit" in response.json()["message"]
    assert not fake_runner.jobs
    # `force` saves anyway.
    forced = client.post("/api/v1/services/demo/edit", data={"content": "x", "force": "true"})
    assert forced.status_code == 200


def test_site_files_outside_the_panel_dirs_are_not_read(tmp_path, monkeypatch):
    secret = tmp_path / "shadow"
    secret.write_text("root:hash")
    monkeypatch.setattr(sites_feature, "NGINX_CONF_DIR", tmp_path / "conf.d")
    text = sites_feature.read_config({"paths": {"nginx_conf": str(secret)}})
    assert "root:hash" not in text
    assert "refusing" in text


def test_site_config_inside_the_conf_dir_is_read(tmp_path, monkeypatch):
    conf_dir = tmp_path / "conf.d"
    conf_dir.mkdir()
    (conf_dir / "demo.conf").write_text("server {}")
    monkeypatch.setattr(sites_feature, "NGINX_CONF_DIR", conf_dir)
    info = {"paths": {"nginx_conf": str(Path(conf_dir) / "demo.conf")}}
    assert sites_feature.read_config(info) == "server {}"
