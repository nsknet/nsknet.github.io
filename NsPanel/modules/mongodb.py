from features import systemctl
from modules.base import Module


class MongoDBModule(Module):
    name = "mongodb"
    display_name = "MongoDB"
    description = "MongoDB 9.x community edition document database."
    bash_function = "install_mongodb"
    uninstall_function = "uninstall_mongodb"
    logo = "mongodb.png"
    firewall_ports = [27017]

    def is_installed(self) -> bool:
        return systemctl.which("mongod") is not None or systemctl.dpkg_installed("mongodb-org")

    def get_status(self) -> dict:
        return systemctl.tool_status(
            binary="mongod",
            pkg="mongodb-org",
            service="mongod",
            version_cmd=["mongod", "--version"],
            ports=[27017],
        )
