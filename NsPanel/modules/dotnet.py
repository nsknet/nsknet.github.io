from features import services
from modules.base import Module


class DotnetModule(Module):
    name = "dotnet"
    display_name = ".NET SDK"
    description = "Installs the .NET SDK 6/7/8/9/10 — needed for .NET Core sites."
    bash_function = "install_netcore"
    uninstall_function = "uninstall_netcore"
    logo = "net.png"

    def is_installed(self) -> bool:
        return services.which("dotnet") is not None

    def get_status(self) -> dict:
        # SDK only — no long-running service of its own.
        return services.tool_status(
            binary="dotnet",
            service=None,
            version_cmd=["dotnet", "--version"],
            ports=[],
        )
