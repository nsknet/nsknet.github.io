from features import services
from modules.base import Module


class PostgresModule(Module):
    name = "postgres"
    display_name = "PostgreSQL 16"
    description = "PostgreSQL 16 via PGDG. Auto-generates credentials saved to /etc/postgresql/credentials.yml."
    bash_function = "install_postgres"
    uninstall_function = "uninstall_postgres"
    change_password_function = "set_postgres_password"
    logo = "postgresql.png"
    requires_password = True
    firewall_ports = [5432]

    def is_installed(self) -> bool:
        return services.which("psql") is not None or services.dpkg_installed("postgresql-16")

    def get_status(self) -> dict:
        status = services.tool_status(
            binary="psql",
            pkg="postgresql-16",
            service="postgresql",
            version_cmd=["psql", "--version"],
            ports=[5432],
        )
        if status["installed"]:
            status["extra"]["credentials"] = "/etc/postgresql/credentials.yml"
        return status
