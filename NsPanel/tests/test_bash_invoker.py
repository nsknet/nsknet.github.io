"""Locating and building bash commands."""
import pytest

from core import bash_invoker


def test_explicit_script_is_preferred():
    path = bash_invoker.resolve_script("install_nginx", "nginx.sh")
    assert path.endswith("nginx.sh")


def test_wrong_script_falls_back_to_scanning():
    """A module naming the wrong file still works — the scan finds the function."""
    path = bash_invoker.resolve_script("install_nginx", "redis.sh")
    assert path.endswith("nginx.sh")


def test_library_functions_resolve_from_scripts_lib():
    path = bash_invoker.resolve_script("_register_panel_service")
    assert path.replace("\\", "/").endswith("scripts/lib/common.sh")


def test_unknown_function_raises():
    with pytest.raises(bash_invoker.ScriptNotFound):
        bash_invoker.resolve_script("definitely_not_a_function")


def test_build_cmd_passes_arguments_positionally():
    cmd = bash_invoker.build_cmd("set_timezone", "Asia/Ho_Chi_Minh; rm -rf /")
    assert cmd[0:2] == ["bash", "-c"]
    # The argument is after the `--` separator, not inside the script text.
    assert "Asia/Ho_Chi_Minh" not in cmd[2]
    assert cmd[-1] == "Asia/Ho_Chi_Minh; rm -rf /"


def test_build_cmd_sources_the_shared_library_directory():
    assert '_libdir="$(dirname "$1")/lib"' in bash_invoker.build_cmd("install_nginx", script="nginx.sh")[2]
