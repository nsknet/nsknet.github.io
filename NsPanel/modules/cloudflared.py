from features import systemctl
from modules.base import Module


class CloudflaredModule(Module):
    name = "cloudflared"
    display_name = "Cloudflared"
    description = (
        "Cloudflare Tunnel client — expose local services through Cloudflare's network "
        "without opening firewall ports."
    )
    bash_function = "install_cloudflared"
    uninstall_function = "uninstall_cloudflared"
    logo = "cloudflare.png"

    def is_installed(self) -> bool:
        return systemctl.which("cloudflared") is not None

    def get_status(self) -> dict:
        return systemctl.tool_status(
            binary="cloudflared",
            pkg=None,
            service=None,
            version_cmd=["cloudflared", "--version"],
            ports=[],
        )
