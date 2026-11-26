import glob
import os

from features import systemctl
from modules.base import Module

# The major version scripts/postgres.sh installs (POSTGRES_VERSION overrides it).
DEFAULT_VERSION = "16"


def _installed_majors() -> list[str]:
    """Majors with a PGDG/Ubuntu server package on disk (/usr/lib/postgresql/<N>)."""
    return sorted(
        (os.path.basename(path) for path in glob.glob("/usr/lib/postgresql/*") if os.path.isdir(path)),
        key=lambda v: int(v) if v.isdigit() else 0,
    )


class PostgresModule(Module):
    name = "postgres"
    display_name = "PostgreSQL"
    description = (
        f"PostgreSQL {DEFAULT_VERSION} via PGDG (POSTGRES_VERSION overrides). "
        "Auto-generates credentials saved to /etc/postgresql/credentials.yml."
    )
    bash_function = "install_postgres"
    uninstall_function = "uninstall_postgres"
    change_password_function = "set_postgres_password"
    logo = "postgresql.png"
    requires_password = True
    firewall_ports = [5432]

    def is_installed(self) -> bool:
        # Any major: an install made with POSTGRES_VERSION=17 is still "installed".
        return bool(_installed_majors()) or systemctl.which("psql") is not None

    def get_status(self) -> dict:
        majors = _installed_majors()
        status = systemctl.tool_status(
            binary="psql",
            pkg=f"postgresql-{majors[-1]}" if majors else f"postgresql-{DEFAULT_VERSION}",
            service="postgresql",
            version_cmd=["psql", "--version"],
            ports=[5432],
        )
        if status["installed"]:
            status["extra"]["credentials"] = "/etc/postgresql/credentials.yml"
        return status
