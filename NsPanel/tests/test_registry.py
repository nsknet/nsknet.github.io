"""Every tool module must be wired to a bash script that really defines its functions.

This is the test that catches the common mistake when adding a tool: declaring
`bash_function = "install_foo"` and forgetting to write `install_foo()`.
"""
import pytest

from core import bash_invoker
from modules import registry

MODULES = registry.get_modules()
MODULE_IDS = [m.name for m in MODULES]


def test_modules_are_discovered():
    assert MODULES, "no tool modules discovered"


@pytest.mark.parametrize("module", MODULES, ids=MODULE_IDS)
def test_module_declares_required_metadata(module):
    assert module.name and module.name.islower()
    assert module.display_name
    assert module.description


@pytest.mark.parametrize("module", MODULES, ids=MODULE_IDS)
def test_module_bash_functions_exist_in_scripts(module):
    for function in (
        module.bash_function,
        module.uninstall_function,
        module.change_password_function,
    ):
        if function:
            bash_invoker.resolve_script(function, module.script_name)


@pytest.mark.parametrize("module", MODULES, ids=MODULE_IDS)
def test_module_serializes(module):
    tool = registry.serialize(module)
    assert tool.module.name == module.name
    assert isinstance(tool.status.installed, bool)


def test_module_names_are_unique():
    names = [m.name for m in MODULES]
    assert len(names) == len(set(names))


def _functions_called_from_routes() -> set[str]:
    """Every bash function name the HTTP layer passes to the invoker."""
    import re
    from pathlib import Path

    names: set[str] = set()
    for path in (Path(__file__).resolve().parents[1] / "routes").glob("*.py"):
        source = path.read_text(encoding="utf-8")
        names |= set(re.findall(r'launch_bash\(\s*"([a-z_]+)"', source))
        names |= set(re.findall(r'build_cmd\(\s*"([a-z_]+)"', source))
    return names


def test_routes_only_call_bash_functions_that_exist():
    """Catches a route wired to a function nobody ever wrote."""
    called = _functions_called_from_routes()
    assert called, "no bash calls found in routes/ — the scan pattern is wrong"

    missing = []
    for function in sorted(called):
        try:
            bash_invoker.resolve_script(function)
        except bash_invoker.ScriptNotFound:
            missing.append(function)
    assert not missing, f"routes call bash functions no script defines: {missing}"
