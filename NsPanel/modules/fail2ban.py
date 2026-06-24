from features import services
from modules.base import Module


class Fail2banModule(Module):
    name = "fail2ban"
    display_name = "Fail2ban"
    description = "SSH brute-force protection: bans IPs after repeated auth failures."
    bash_function = "install_fail2ban"
    uninstall_function = "uninstall_fail2ban"
    logo = "fail2ban.png"

    def is_installed(self) -> bool:
        return services.which("fail2ban-client") is not None or services.dpkg_installed("fail2ban")

    def get_status(self) -> dict:
        return services.tool_status(
            binary="fail2ban-client",
            pkg="fail2ban",
            service="fail2ban",
            version_cmd=["fail2ban-client", "--version"],
            ports=[],
        )
