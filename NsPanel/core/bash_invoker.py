"""Builds the command that runs one bash function from scripts/.

Bash is the engine: install and configuration logic lives in scripts/, and the
panel only calls into it. A module names its script explicitly (`Module.script`),
so the common path is a direct lookup; the scan below is the fallback for
functions that are not owned by a tool module (system, firewall, disks, …) and
its result is cached for the process lifetime.
"""

import functools
import re

from config import SCRIPTS_DIR, SCRIPTS_LIB_DIR


class ScriptNotFound(ValueError):
    """No script in scripts/ defines the requested function."""


def _defines(path, function: str) -> bool:
    """True if `path` defines `function` — as a definition at line start, so
    `ufw_allow_port` does not match inside `_ufw_allow_port() {` or a call site."""
    try:
        content = path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return False
    name = re.escape(function)
    pattern = rf"^[ \t]*(?:function[ \t]+{name}\b|{name}[ \t]*\(\))"
    return re.search(pattern, content, re.MULTILINE) is not None


@functools.lru_cache(maxsize=256)
def find_script_for_function(function: str) -> str:
    """Path of the script defining `function`. Cached — scripts/ is static at runtime."""
    for path in sorted(SCRIPTS_DIR.glob("*.sh")):
        if _defines(path, function):
            return str(path)
    for path in sorted(SCRIPTS_LIB_DIR.glob("*.sh")):
        if _defines(path, function):
            return str(path)
    raise ScriptNotFound(f"No script in scripts/ defines the function '{function}'.")


def resolve_script(function: str, script: str | None = None) -> str:
    """Prefer the script a module declared; fall back to scanning for the function."""
    if script:
        candidate = SCRIPTS_DIR / script
        if candidate.is_file() and _defines(candidate, function):
            return str(candidate)
    return find_script_for_function(function)


def build_cmd(function: str, *args: str, script: str | None = None) -> list[str]:
    """`bash -c` command that sources the shared libs, then the target script,
    then calls `function` with `args`.

    Arguments travel as positional parameters ($3 onwards), never spliced into
    the script text, so a value containing shell metacharacters stays one word.
    """
    script_path = resolve_script(function, script)

    # scripts/lib/*.sh holds helpers install scripts call by name
    # (_ufw_allow_port, _register_panel_service, log_header, …). Source them
    # first so those calls resolve regardless of which script is the target.
    # The ERR trap (inherited by functions via `set -E`) names the file, line and
    # command that stopped a `set -e` script, instead of a bare "exit 1". It stays
    # quiet in scripts without errexit, where a failing command is not fatal.
    # BASH_COMMAND is the unexpanded source text, so no secret values are printed.
    snippet = (
        "set -E; "
        "trap '_rc=$?; [[ $- == *e* ]] && "
        'echo "✗ ${BASH_SOURCE[0]##*/}:${LINENO}: ${BASH_COMMAND} (exit $_rc)" >&2\' ERR; '
        '_libdir="$(dirname "$1")/lib"; '
        'if [ -d "$_libdir" ]; then '
        'for _lib in "$_libdir"/*.sh; do [ -f "$_lib" ] && source "$_lib"; done; '
        "fi; "
        'source "$1" && "$2" "${@:3}"'
    )
    return ["bash", "-c", snippet, "--", script_path, function, *[str(a) for a in args]]
