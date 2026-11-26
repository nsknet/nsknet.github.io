from features import systemctl
from modules.base import Module

_CRED_FILE = "/etc/elasticsearch/credentials.yml"


class ElasticsearchModule(Module):
    name = "elasticsearch"
    display_name = "Elasticsearch"
    description = (
        "Elasticsearch 8.x distributed search and analytics engine. Listens on port 9200; "
        f"login 'elastic', password saved to {_CRED_FILE}."
    )
    bash_function = "install_elasticsearch"
    uninstall_function = "uninstall_elasticsearch"
    change_password_function = "set_elasticsearch_password"
    logo = "elasticsearch.png"
    requires_password = True
    firewall_ports = [9200]

    def is_installed(self) -> bool:
        return systemctl.dpkg_installed("elasticsearch")

    def get_status(self) -> dict:
        status = systemctl.tool_status(
            pkg="elasticsearch",
            service="elasticsearch",
            ports=[9200],
        )
        if status["installed"]:
            _, out = systemctl.run(["dpkg-query", "-W", "-f=${Version}", "elasticsearch"])
            if out and "not found" not in out:
                status["version"] = f"elasticsearch {out.strip()}"
            status["extra"]["credentials"] = _CRED_FILE
        return status
