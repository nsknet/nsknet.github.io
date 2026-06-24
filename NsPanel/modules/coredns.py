from features import services
from modules.base import Module


class CoreDNSModule(Module):
    name = "coredns"
    display_name = "CoreDNS"
    description = "Lightweight DNS server. Map domains to IPs and forward the rest upstream."
    bash_function = "install_coredns"
    uninstall_function = "uninstall_coredns"
    requires_password = False
    firewall_ports = [53]          # opens the subnet dialog; UDP+TCP handled in the script
    logo = "coredns.png"

    def is_installed(self) -> bool:
        return services.which("coredns") is not None

    def get_status(self) -> dict:
        status = services.tool_status(
            binary="coredns",
            service="coredns",
            version_cmd=["coredns", "-version"],
            ports=[53],
        )
        if status["installed"]:
            status["extra"]["config"] = "/etc/coredns/Corefile"
            status["extra"]["records"] = "/etc/coredns/hosts"
        return status
