from abc import ABC, abstractmethod
from typing import Optional


class Module(ABC):
    """One installable tool. Adding a tool = adding one file in modules/.

    Concrete subclasses may declare extra attributes (e.g. `requires_password`
    on PostgresModule); the registry only needs them to subclass Module.
    """

    name: str                     # "nginx"
    display_name: str             # "NGINX Web Server"
    description: str
    bash_function: Optional[str]  # "install_nginx", or None
    logo: Optional[str] = None    # "nginx.png" — filename inside /static/logo/

    # Optional lifecycle actions, each a bash function name (or None when the
    # tool doesn't support it). Re-install simply re-runs bash_function.
    uninstall_function: Optional[str] = None         # "uninstall_nginx"
    change_password_function: Optional[str] = None   # "set_postgres_password"

    # Install-time prompts shown by the UI before launching the install job.
    # When True, the install dialog asks for an admin/DB password (auto-generated,
    # regeneratable) and passes it to the script via the DB_PASSWORD env var.
    requires_password: bool = False
    # TCP ports the install script opens in UFW via _ufw_allow_port. When non-empty
    # the install dialog lets the user choose which subnets to expose them to
    # (class A/B/C private + loopback, or 0.0.0.0/0). Empty = no firewall prompt.
    firewall_ports: list[int] = []

    # Extra install-time inputs the dialog renders dynamically. Each spec is a
    # dict: {name, env, type, label, default, options?, help?, min?, max?} where
    # type ∈ {string, number, checkbox, select}. `env` is the env var the value
    # is passed to the install script under (same safe channel as DB_PASSWORD).
    # For `select`, `options` is [{value, label}] and the first is the default.
    install_params: list[dict] = []

    @abstractmethod
    def is_installed(self) -> bool: ...

    @abstractmethod
    def get_status(self) -> dict:
        """Returns: {installed, version, service_state, ports, extra}"""
        ...
