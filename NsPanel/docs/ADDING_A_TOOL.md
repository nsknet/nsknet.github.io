# Adding a tool

A tool is one Python file in `modules/` plus one bash script in `scripts/`.
Nothing else changes — the registry discovers the module, the Tools screen
renders it, and `tests/test_registry.py` checks the wiring.

## 1. The bash script — `scripts/mytool.sh`

```bash
#!/usr/bin/env bash
# mytool.sh — install and remove My Tool
set -eo pipefail

install_mytool() {
    log_header "Installing My Tool"

    apt-get update -q
    apt-get install -y mytool

    systemctl enable --now mytool
    _register_panel_service mytool      # makes it visible on the Services screen

    # Only when the tool listens on a port:
    _ufw_allow_port 1234 "My Tool"

    log_done "My Tool installed."
}

uninstall_mytool() {
    log_header "Removing My Tool"
    systemctl disable --now mytool || true
    apt-get purge -y mytool
    _unregister_panel_service mytool
    log_done "My Tool removed."
}
```

`log_header`, `log_step`, `log_done`, `log_warn`, `_ufw_allow_port`,
`_register_panel_service` and `_unregister_panel_service` come from
`scripts/lib/common.sh`, which is sourced automatically before your script.

Also from `common.sh`, and expected in a production-quality install:

| Helper | Use it to |
|---|---|
| `_require_platform "My Tool" "22.04 24.04" "amd64 arm64"` | fail fast on an Ubuntu release or CPU the vendor repo does not serve |
| `_os_codename`, `_os_version`, `_os_arch` | build repo lines and download names (never hard-code `noble` or `amd64`) |
| `_verify_sha256 <file> <hex>` | check every downloaded binary against the vendor's published checksum |
| `_apt_install_optional pkg…` | install nice-to-have packages without failing when one is missing |
| `_forbid_public_access "My Tool"` | refuse `0.0.0.0/0` for a service with no login of its own |
| `install -m 600 /dev/null "$FILE"` | create a credentials file before writing to it (never `chmod` afterwards) |

Secrets never go on a command line (it shows in `ps` and in the job log): pass
them on stdin, in an environment variable or in a 0600 file.

## 2. The module — `modules/mytool.py`

```python
from features import systemctl
from modules.base import Module


class MyToolModule(Module):
    name = "mytool"
    display_name = "My Tool"
    description = "Does something useful."
    logo = "mytool.png"  # file in static/logo/
    script = "mytool.sh"  # optional — defaults to "<name>.sh"
    bash_function = "install_mytool"
    uninstall_function = "uninstall_mytool"

    def is_installed(self) -> bool:
        return systemctl.which("mytool") is not None

    def get_status(self) -> dict:
        return systemctl.tool_status(
            binary="mytool",
            service="mytool",
            version_cmd=["mytool", "--version"],
            ports=[1234],
        )
```

`get_status()` must return the `ToolStatus` shape — `tool_status()` already
does. Add anything extra under `status["extra"]` (a credentials file path, a
dashboard URL); the Tools screen shows it as key/value rows.

## 3. Optional install-time inputs

| Attribute | Effect |
|---|---|
| `requires_password = True` | The install dialog asks for a password, passed as `DB_PASSWORD`. |
| `firewall_ports = [1234]` | The dialog lets the operator choose which subnets to expose; arrives as `ALLOWED_SUBNETS`. |
| `allow_public = False` | The tool has no login of its own: "Any IP" is not offered and `0.0.0.0/0` is refused. |
| `change_password_function` | Adds a "change password" action. |
| `install_params = [...]` | Extra form fields — see below. |

```python
install_params = [
    {
        "name": "edition",  # form field name
        "env": "MYTOOL_EDITION",  # env var the script reads
        "type": "select",  # string | number | checkbox | select
        "label": "Edition",
        "default": "free",
        "help": "Free is fine for most setups.",
        "options": [
            {"value": "free", "label": "Free"},
            {"value": "pro", "label": "Pro — licensed"},
        ],
    },
]
```

All of these reach the script as **environment variables**, never as arguments,
so they never appear in the live log. `number` accepts `min`/`max`.

## 4. Check it

```bash
pytest tests/test_registry.py   # every declared bash function must exist
bash -n scripts/mytool.sh
shellcheck -S warning scripts/mytool.sh
```

Then install it once from the Tools screen on a throwaway host and watch the live
output. If the install can run on a stock GitHub runner, add a case to
`tests/integration/test_real_install.py` (install, check from the outside,
uninstall) so CI keeps it working on every supported Ubuntu release.
