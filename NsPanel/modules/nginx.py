from features import services
from modules.base import Module


class NginxModule(Module):
    name = "nginx"
    display_name = "NGINX Web Server"
    description = "Reverse proxy and static web server. Required for hosting sites."
    bash_function = "install_nginx"
    uninstall_function = "uninstall_nginx"
    logo = "nginx.png"

    def is_installed(self) -> bool:
        return services.which("nginx") is not None

    def get_status(self) -> dict:
        return services.tool_status(
            binary="nginx",
            service="nginx",
            version_cmd=["nginx", "-v"],
            ports=[80],
        )
