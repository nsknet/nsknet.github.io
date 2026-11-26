"""Append-only audit log, one JSON object per line.

    {"ts": "2026-11-25T10:11:12Z", "action": "service.start", "detail": "name=demo",
     "user": "admin", "ip": "10.0.0.5"}

`user`/`ip` come from the request that caused the entry (set by
core.auth.require_session through a context variable). The file is created
0600 and rotated by size. Lines in the older `ts | action | detail` format are
still read back.
"""

import contextvars
import datetime
import json
import os
import threading
from pathlib import Path

import config

_actor: contextvars.ContextVar[tuple[str, str]] = contextvars.ContextVar("audit_actor", default=("", ""))
_lock = threading.Lock()
_path: Path | None = None


def log_path() -> Path:
    global _path
    if _path is None:
        _path = config.audit_log_path()
    return _path


def set_path(path: Path | None) -> None:
    """Point the log somewhere else (tests); None goes back to the configured path."""
    global _path
    _path = path


def set_actor(user: str, ip: str) -> None:
    _actor.set((user, ip))


def _now() -> str:
    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(action: str, detail: str = "", *, user: str | None = None, ip: str | None = None) -> None:
    actor_user, actor_ip = _actor.get()
    entry = {
        "ts": _now(),
        "action": action,
        "detail": detail,
        "user": user if user is not None else actor_user,
        "ip": ip if ip is not None else actor_ip,
    }
    # json.dumps escapes newlines, so a value cannot forge a second entry.
    line = json.dumps(entry, ensure_ascii=False) + "\n"
    path = log_path()
    with _lock:
        path.parent.mkdir(parents=True, exist_ok=True)
        _rotate_if_needed(path)
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        with os.fdopen(fd, "a", encoding="utf-8") as fh:
            fh.write(line)


def _rotate_if_needed(path: Path) -> None:
    try:
        if path.stat().st_size < config.AUDIT_MAX_BYTES:
            return
    except OSError:
        return
    for index in range(config.AUDIT_BACKUPS - 1, 0, -1):
        older = path.with_name(f"{path.name}.{index}")
        if older.exists():
            os.replace(older, path.with_name(f"{path.name}.{index + 1}"))
    os.replace(path, path.with_name(f"{path.name}.1"))


def _parse(line: str) -> dict | None:
    line = line.strip()
    if not line:
        return None
    if line.startswith("{"):
        try:
            entry = json.loads(line)
        except ValueError:
            return None
        return {
            "ts": str(entry.get("ts", "")),
            "action": str(entry.get("action", "")),
            "detail": str(entry.get("detail", "")),
            "user": str(entry.get("user", "")),
            "ip": str(entry.get("ip", "")),
        }
    # Legacy: `ts | action | detail`
    ts, _, rest = line.partition(" | ")
    action, _, detail = rest.partition(" | ")
    return {"ts": ts, "action": action, "detail": detail, "user": "", "ip": ""}


def _read_tail_lines(path: Path, n: int) -> list[str]:
    """The last `n` lines, reading backwards from the end in blocks."""
    with open(path, "rb") as fh:
        fh.seek(0, os.SEEK_END)
        end = fh.tell()
        block = 64 * 1024
        data = b""
        pos = end
        while pos > 0 and data.count(b"\n") <= n:
            step = min(block, pos)
            pos -= step
            fh.seek(pos)
            data = fh.read(step) + data
    return data.decode("utf-8", "replace").splitlines()[-n:]


def entries(limit: int = config.AUDIT_TAIL_LINES, offset: int = 0, q: str = "") -> list[dict]:
    """Newest first. `q` filters on action/detail/user/ip (case-insensitive)."""
    path = log_path()
    if not path.exists():
        return []
    wanted = offset + limit
    # Filtering needs more lines than it returns; read generously but bounded.
    scan = wanted if not q else max(wanted * 20, 5000)
    parsed = [e for e in (_parse(line) for line in reversed(_read_tail_lines(path, scan))) if e]
    if q:
        needle = q.lower()
        parsed = [e for e in parsed if needle in " ".join(e.values()).lower()]
    return parsed[offset:wanted]


def tail(n: int = config.AUDIT_TAIL_LINES) -> list[str]:
    """Last n raw lines, newest first (kept for callers that only need text)."""
    path = log_path()
    if not path.exists():
        return []
    return _read_tail_lines(path, n)[::-1]
