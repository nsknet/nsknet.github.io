from features import systemctl
from modules.base import Module

_CRED_FILE = "/etc/mongodb/credentials.yml"


class MongoDBModule(Module):
    name = "mongodb"
    display_name = "MongoDB"
    description = (
        "MongoDB 8.x community edition document database. Authorization enabled; "
        f"admin credentials saved to {_CRED_FILE}."
    )
    bash_function = "install_mongodb"
    uninstall_function = "uninstall_mongodb"
    change_password_function = "set_mongodb_password"
    logo = "mongodb.png"
    requires_password = True
    firewall_ports = [27017]

    def is_installed(self) -> bool:
        return systemctl.which("mongod") is not None or systemctl.dpkg_installed("mongodb-org")

    def get_status(self) -> dict:
        status = systemctl.tool_status(
            binary="mongod",
            pkg="mongodb-org",
            service="mongod",
            version_cmd=["mongod", "--version"],
            ports=[27017],
        )
        if status["installed"]:
            status["extra"]["credentials"] = _CRED_FILE
        return status
