import os
from pathlib import Path
from config import BASE_DIR

def find_script_for_function(function_name: str) -> str:
    """Scan scripts/ directory to find which script contains the function definition."""
    scripts_dir = BASE_DIR / "scripts"
    if scripts_dir.exists():
        for file in os.listdir(scripts_dir):
            if file.endswith(".sh"):
                file_path = scripts_dir / file
                try:
                    with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
                        content = f.read()
                    # Match function definition: function_name() or function function_name
                    if f"{function_name}()" in content or f"function {function_name}" in content:
                        # Auto-normalize line endings to LF on the fly to prevent CRLF bash parsing errors
                        with open(file_path, "rb") as bf:
                            raw_bytes = bf.read()
                        if b"\r\n" in raw_bytes:
                            with open(file_path, "wb") as bf:
                                bf.write(raw_bytes.replace(b"\r\n", b"\n"))
                        return str(file_path)
                except Exception:
                    pass
    
    # Fallback to system.sh if not found
    fallback = BASE_DIR / "scripts" / "system.sh"
    if fallback.exists():
        # Auto-normalize fallback file as well
        try:
            with open(fallback, "rb") as bf:
                raw_bytes = bf.read()
            if b"\r\n" in raw_bytes:
                with open(fallback, "wb") as bf:
                    bf.write(raw_bytes.replace(b"\r\n", b"\n"))
        except Exception:
            pass
        return str(fallback)
    return ""


def build_cmd(function: str, *args: str) -> list[str]:
    script_path = find_script_for_function(function)
    if not script_path:
        raise ValueError(f"Could not locate a script defining function: {function}")
        
    # Use standard shell positional parameter expansion for safe execution:
    # $1 is the script path to source, $2 is the function name, and $@ starting from $3 are args.
    #
    # Shared helpers (_ufw_allow_port in firewall.sh, _register_panel_service in
    # service.sh) are defined in their own scripts but called from many install
    # scripts. Source those libraries first — from the same directory as the
    # target — so those calls resolve. Re-sourcing the target when it *is* one of
    # the libraries is harmless (function definitions are simply re-evaluated).
    snippet = (
        '_libdir="$(dirname "$1")"; '
        'for _lib in firewall.sh service.sh; do '
        'if [ -f "$_libdir/$_lib" ]; then source "$_libdir/$_lib"; fi; '
        'done; '
        'source "$1" && "$2" "${@:3}"'
    )
    return [
        "bash",
        "-c",
        snippet,
        "--",
        script_path,
        function,
        *[str(a) for a in args]
    ]

