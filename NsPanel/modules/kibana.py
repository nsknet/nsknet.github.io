from features import services
from modules.base import Module


class KibanaModule(Module):
    name = "kibana"
    display_name = "Kibana"
    description = "Kibana dashboard UI for Elasticsearch. Listens on port 5601 (localhost only)."
    bash_function = "install_kibana"
    uninstall_function = "uninstall_kibana"
    logo = "kibana.png"
    firewall_ports = [5601]

    def is_installed(self) -> bool:
        return services.dpkg_installed("kibana")

    def get_status(self) -> dict:
        status = services.tool_status(
            pkg="kibana",
            service="kibana",
            ports=[5601],
        )
        if status["installed"]:
            _, out = services.run(
                ["dpkg-query", "-W", "-f=${Version}", "kibana"]
            )
            if out and "not found" not in out:
                status["version"] = f"kibana {out.strip()}"
        return status
