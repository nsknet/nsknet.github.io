from features import services
from modules.base import Module


class MssqlModule(Module):
    name = "mssql"
    display_name = "SQL Server 2025"
    description = "Microsoft SQL Server 2025 via APT. SA credentials saved to /var/opt/mssql/credentials.yml."
    bash_function = "install_mssql"
    uninstall_function = "uninstall_mssql"
    change_password_function = "set_mssql_password"
    requires_password = True          # SA password (auto-generated; meets MSSQL complexity)
    firewall_ports = [1433]
    logo = "mssql.png"

    install_params = [
        {
            "name": "edition",
            "env": "MSSQL_PID",
            "type": "select",
            "label": "Edition",
            "default": "developer",
            "help": "Developer & Express are free. Standard/Enterprise require a license.",
            "options": [
                {"value": "developer", "label": "Developer — free, non-production"},
                {"value": "express", "label": "Express — free, limited (10GB/db)"},
                {"value": "standard", "label": "Standard — licensed"},
                {"value": "enterprise", "label": "Enterprise — licensed"},
                {"value": "evaluation", "label": "Evaluation — 180 days"},
            ],
        },
    ]

    def is_installed(self) -> bool:
        return services.dpkg_installed("mssql-server")

    def get_status(self) -> dict:
        status = services.tool_status(
            pkg="mssql-server",
            service="mssql-server",
            ports=[1433],
        )
        if status["installed"]:
            _, out = services.run(["dpkg-query", "-W", "-f=${Version}", "mssql-server"])
            if out and "not found" not in out:
                status["version"] = f"mssql {out.strip()}"
            status["extra"]["credentials"] = "/var/opt/mssql/credentials.yml"
        return status
