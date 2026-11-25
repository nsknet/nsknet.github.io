from features import systemctl
from modules.base import Module


class DotnetModule(Module):
    name = "dotnet"
    display_name = ".NET SDK"
    description = "Installs the .NET SDK (10.0 by default; DOTNET_VERSIONS adds others) for .NET sites."
    script = "netcore.sh"
    bash_function = "install_netcore"
    uninstall_function = "uninstall_netcore"
    logo = "net.png"

    def is_installed(self) -> bool:
        return systemctl.which("dotnet") is not None

    def get_status(self) -> dict:
        # SDK only — no long-running service of its own.
        return systemctl.tool_status(
            binary="dotnet",
            service=None,
            version_cmd=["dotnet", "--version"],
            ports=[],
        )
