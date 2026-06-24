import os
import subprocess
import sys

from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich import box
from rich.text import Text

console = Console()


def _get_password() -> str:
    return os.environ.get("PANEL_PASSWORD", "<not set — launch via run.sh>")


def _print_banner() -> None:
    password = _get_password()
    pw_display = Text(password, style="bold yellow")

    info = Table.grid(padding=(0, 2))
    info.add_column(style="dim")
    info.add_column()
    info.add_row("URL", Text("http://127.0.0.1:7777", style="bold green"))
    info.add_row("Username", Text("admin", style="bold cyan"))
    info.add_row("Password", pw_display)
    info.add_row("", "")
    info.add_row(
        "Tunnel",
        Text("ssh -L 7777:localhost:7777 user@server", style="dim"),
    )

    console.print(
        Panel(info, title="[bold]VPS Admin Panel[/bold]", box=box.DOUBLE_EDGE, expand=False)
    )


def main() -> None:
    _print_banner()

    try:
        import uvicorn
        uvicorn.run("app:app", host="127.0.0.1", port=7777)
    except ImportError:
        console.print(
            "[red]uvicorn not found.[/red] Run via [bold]./run.sh[/bold] or activate your virtual environment."
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
