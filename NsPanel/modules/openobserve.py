from pathlib import Path

from features import services
from modules.base import Module

_BINARY = "/opt/openobserve/openobserve"
_CRED_FILE = "/opt/openobserve/credentials.yml"


class OpenObserveModule(Module):
    name = "openobserve"
    display_name = "OpenObserve"
    description = "OpenObserve — logs, metrics, traces and dashboards. UI on port 5080 (localhost)."
    bash_function = "install_openobserve"
    uninstall_function = "uninstall_openobserve"
    logo = "openobserve.png"
    requires_password = True
    firewall_ports = [5080]

    def is_installed(self) -> bool:
        return Path(_BINARY).exists()

    def get_status(self) -> dict:
        installed = self.is_installed()

        state = "not installed"
        if installed:
            state = services.service_state("openobserve")

        version = None
        if installed:
            _, out = services.run([_BINARY, "--version"])
            if out:
                version = services.first_line(out)

        extra: dict = {}
        if installed:
            extra["credentials"] = _CRED_FILE

        return {
            "installed": installed,
            "version": version,
            "service_state": state,
            "ports": [5080],
            "extra": extra,
        }
