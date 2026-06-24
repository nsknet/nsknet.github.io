from features import services
from modules.base import Module


class MariaDBModule(Module):
    name = "mariadb"
    display_name = "MariaDB"
    description = "MariaDB server via APT. Auto-generates root credentials saved to /etc/mysql/credentials.yml."
    bash_function = "install_mariadb"
    uninstall_function = "uninstall_mariadb"
    change_password_function = "set_mariadb_password"
    requires_password = True
    firewall_ports = [3306]
    logo = "mariadb.png"

    def is_installed(self) -> bool:
        return services.which("mariadb") is not None or services.dpkg_installed("mariadb-server")

    def get_status(self) -> dict:
        status = services.tool_status(
            binary="mariadb",
            pkg="mariadb-server",
            service="mariadb",
            version_cmd=["mariadb", "--version"],
            ports=[3306],
        )
        if status["installed"]:
            status["extra"]["credentials"] = "/etc/mysql/credentials.yml"
        return status
