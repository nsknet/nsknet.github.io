"""Auto-discovers tool modules in this package.

Every .py file in modules/ (except base/registry/__init__) is imported and
scanned for Module subclasses. Adding a tool requires no edits here — see
docs/ADDING_A_TOOL.md.
"""
import importlib
import pkgutil
from pathlib import Path

from core.schemas import Tool, ToolInfo, ToolStatus
from modules.base import Module

_SKIP = {"base", "registry", "__init__"}
_cache: list[Module] | None = None


def _discover() -> list[Module]:
    instances: list[Module] = []
    for info in pkgutil.iter_modules([str(Path(__file__).parent)]):
        if info.name in _SKIP:
            continue
        mod = importlib.import_module(f"modules.{info.name}")
        for obj in vars(mod).values():
            if isinstance(obj, type) and issubclass(obj, Module) and obj is not Module:
                instances.append(obj())
    instances.sort(key=lambda m: m.display_name.lower())
    return instances


def get_modules() -> list[Module]:
    global _cache
    if _cache is None:
        _cache = _discover()
    return _cache


def get_module(name: str) -> Module | None:
    for module in get_modules():
        if module.name == name:
            return module
    return None


def describe(module: Module) -> ToolInfo:
    """The module's static metadata, as the API exposes it."""
    return ToolInfo(
        name=module.name,
        display_name=module.display_name,
        description=module.description,
        logo=module.logo,
        requires_password=module.requires_password,
        firewall_ports=list(module.firewall_ports or []),
        install_params=list(module.install_params or []),
        can_uninstall=bool(module.uninstall_function),
        can_change_password=bool(module.change_password_function),
    )


def serialize(module: Module) -> Tool:
    """Metadata + a live status probe. Used by both /tools and /dashboard."""
    return Tool(module=describe(module), status=ToolStatus(**module.get_status()))


def serialize_all() -> list[Tool]:
    return [serialize(m) for m in get_modules()]
