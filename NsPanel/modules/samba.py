from features import services
from modules.base import Module


class SambaModule(Module):
    name = "samba"
    display_name = "Samba"
    description = "SMB/CIFS file sharing with password auth. One share, one login user (works on modern Windows)."
    bash_function = "install_samba"
    uninstall_function = "uninstall_samba"
    change_password_function = "set_samba_password"
    requires_password = True           # the Samba user's password (auto-generated; editable)
    firewall_ports = [445, 139]
    logo = "samba.png"

    # Share name + login username (the password comes from the requires_password
    # field, passed via DB_PASSWORD). Both are sanitized in the install script.
    install_params = [
        {
            "name": "share_name",
            "env": "SAMBA_SHARE",
            "type": "string",
            "label": "Share name",
            "default": "public",
            "help": "Folder is created at /srv/<share>. Access via \\\\<ip>\\<share>. Allowed: letters, digits, - and _.",
        },
        {
            "name": "username",
            "env": "SAMBA_USER",
            "type": "string",
            "label": "Login username",
            "default": "smbuser",
            "help": "The user you type on Windows when connecting. Lowercase letters, digits, - and _.",
        },
    ]

    def is_installed(self) -> bool:
        return services.which("smbd") is not None or services.dpkg_installed("samba")

    def get_status(self) -> dict:
        status = services.tool_status(
            binary="smbd",
            pkg="samba",
            service="smbd",
            version_cmd=["smbd", "--version"],
            ports=[445, 139],
        )
        if status["installed"]:
            status["extra"]["credentials"] = "/var/opt/samba/credentials.yml"
        return status
