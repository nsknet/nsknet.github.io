from features import services
from modules.base import Module


class ElasticsearchModule(Module):
    name = "elasticsearch"
    display_name = "Elasticsearch"
    description = "Elasticsearch 8.x distributed search and analytics engine. Listens on port 9200."
    bash_function = "install_elasticsearch"
    uninstall_function = "uninstall_elasticsearch"
    logo = "elasticsearch.png"
    firewall_ports = [9200]

    def is_installed(self) -> bool:
        return services.dpkg_installed("elasticsearch")

    def get_status(self) -> dict:
        status = services.tool_status(
            pkg="elasticsearch",
            service="elasticsearch",
            ports=[9200],
        )
        if status["installed"]:
            _, out = services.run(
                ["dpkg-query", "-W", "-f=${Version}", "elasticsearch"]
            )
            if out and "not found" not in out:
                status["version"] = f"elasticsearch {out.strip()}"
        return status
