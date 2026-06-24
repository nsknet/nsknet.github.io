"""Auto-discovers Module subclasses in this package.

Every .py file in modules/ (except base/registry/__init__) is imported and
scanned for Module subclasses. Adding a tool requires no edits here.
"""
import importlib
import pkgutil
from pathlib import Path

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
            if (
                isinstance(obj, type)
                and issubclass(obj, Module)
                and obj is not Module
            ):
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
