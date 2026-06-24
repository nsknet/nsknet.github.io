from features import services
from modules.base import Module


class RabbitMQModule(Module):
    name = "rabbitmq"
    display_name = "RabbitMQ"
    description = "RabbitMQ 4.x message broker with management UI. AMQP on 5672, management on 15672."
    bash_function = "install_rabbitmq"
    uninstall_function = "uninstall_rabbitmq"
    change_password_function = "set_rabbitmq_password"
    logo = "rabbitmq.png"
    requires_password = True
    firewall_ports = [5672, 15672]

    def is_installed(self) -> bool:
        return services.dpkg_installed("rabbitmq-server")

    def get_status(self) -> dict:
        status = services.tool_status(
            pkg="rabbitmq-server",
            service="rabbitmq-server",
            ports=[5672, 15672],
        )
        if status["installed"]:
            _, out = services.run(["rabbitmqctl", "version"])
            if out:
                status["version"] = services.first_line(out)
            cred_file = "/etc/rabbitmq/credentials.yml"
            status["extra"]["credentials"] = cred_file
        return status
