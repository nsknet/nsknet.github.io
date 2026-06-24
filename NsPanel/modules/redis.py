from features import services
from modules.base import Module


class RedisModule(Module):
    name = "redis"
    display_name = "Redis"
    description = (
        "Redis in-memory store — cache, session, output cache and SignalR "
        "backplane for .NET. Port 6379, password-protected (requirepass)."
    )
    bash_function = "install_redis"
    uninstall_function = "uninstall_redis"
    change_password_function = "set_redis_password"
    logo = "redis.png"
    requires_password = True
    firewall_ports = [6379]

    def is_installed(self) -> bool:
        return services.dpkg_installed("redis-server")

    def get_status(self) -> dict:
        status = services.tool_status(
            pkg="redis-server",
            service="redis-server",
            ports=[6379],
        )
        if status["installed"]:
            _, out = services.run(["redis-server", "--version"])
            if out:
                status["version"] = services.first_line(out)
            status["extra"]["credentials"] = "/etc/redis/credentials.yml"
        return status
