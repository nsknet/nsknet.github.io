from features import services
from modules.base import Module


def _fpm_service() -> str | None:
    """Resolve the versioned php-fpm service name (e.g. php8.3-fpm) from the
    installed CLI's major.minor, or None when PHP isn't installed."""
    code, out = services.run(["php", "-r", "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;"])
    out = out.strip()
    if code == 0 and out:
        return f"php{out}-fpm"
    return None


class PhpModule(Module):
    name = "php"
    display_name = "PHP-FPM"
    description = "PHP-FPM via the ondrej/php PPA, configured to run as www-data for nginx."
    bash_function = "install_php"
    uninstall_function = "uninstall_php"
    logo = "php.png"

    def is_installed(self) -> bool:
        return services.which("php") is not None

    def get_status(self) -> dict:
        return services.tool_status(
            binary="php",
            service=_fpm_service(),
            version_cmd=["php", "-v"],
        )
