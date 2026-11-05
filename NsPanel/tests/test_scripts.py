"""Static checks on scripts/*.sh that run on any OS (no bash needed).

The panel runs a function by sourcing scripts/lib/*.sh plus ONE script (see
core/bash_invoker.build_cmd). A function that calls something defined only in
another, unsourced script fails at runtime with "command not found" — that is
how `common_configs` broke. This test models the same sourcing rule.
"""
import re
from pathlib import Path

import pytest

from config import SCRIPTS_DIR, SCRIPTS_LIB_DIR
from core import bash_invoker

_DEF = re.compile(r"^[ \t]*(?:function[ \t]+)?([A-Za-z_][\w-]*)[ \t]*\(\)", re.MULTILINE)
_SOURCE = re.compile(r'^[ \t]*(?:source|\.)[ \t]+"\$\{_\w+\}/([\w.-]+\.sh)"', re.MULTILINE)
_WORD = re.compile(r"[A-Za-z_][\w-]*")

SCRIPTS = sorted(SCRIPTS_DIR.glob("*.sh"))
LIBS = sorted(SCRIPTS_LIB_DIR.glob("*.sh"))


def _text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _defined(path: Path) -> set[str]:
    return set(_DEF.findall(_text(path)))


def _code_words(path: Path) -> set[str]:
    """Words outside comments — a superset of the commands a script runs."""
    words: set[str] = set()
    for line in _text(path).splitlines():
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        words.update(_WORD.findall(line))
    return words


ALL_DEFINED = {name: path for path in SCRIPTS + LIBS for name in _defined(path)}


@pytest.mark.parametrize("script", SCRIPTS, ids=[p.name for p in SCRIPTS])
def test_every_cross_script_call_is_sourced(script):
    sourced = [*LIBS, script, *(SCRIPTS_DIR / name for name in _SOURCE.findall(_text(script)))]
    available = set().union(*(_defined(path) for path in sourced))
    missing = {
        word: ALL_DEFINED[word].name
        for word in _code_words(script)
        if word in ALL_DEFINED and word not in available
    }
    assert not missing, f"{script.name} calls functions it does not source: {missing}"


@pytest.mark.parametrize("script", SCRIPTS + LIBS, ids=[p.name for p in SCRIPTS + LIBS])
def test_scripts_use_lf_line_endings(script):
    assert b"\r\n" not in script.read_bytes(), f"{script.name} has CRLF line endings"


@pytest.mark.parametrize("script", SCRIPTS, ids=[p.name for p in SCRIPTS])
def test_no_interactive_prompts(script):
    """Jobs run with stdin closed: a `read -p` prompt can only fail."""
    assert not re.search(r"\bread\s+-r?p\b", _text(script)), f"{script.name} prompts on stdin"


def test_defines_ignores_names_embedded_in_longer_ones():
    common = SCRIPTS_LIB_DIR / "common.sh"
    assert not bash_invoker._defines(common, "ufw_allow_port")
    assert bash_invoker._defines(common, "_ufw_allow_port")
    assert bash_invoker.resolve_script("ufw_allow_port").endswith("firewall.sh")
