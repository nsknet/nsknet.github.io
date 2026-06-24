"""Append-only audit log: `ISO8601 | action | detail` per line."""
import datetime

from config import AUDIT_LOG, AUDIT_TAIL_LINES


def _now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(action: str, detail: str = "") -> None:
    line = f"{_now()} | {action} | {detail}\n"
    with open(AUDIT_LOG, "a", encoding="utf-8") as f:
        f.write(line)


def tail(n: int = AUDIT_TAIL_LINES) -> list[str]:
    """Last n lines, newest first."""
    if not AUDIT_LOG.exists():
        return []
    lines = AUDIT_LOG.read_text(encoding="utf-8").splitlines()
    return lines[-n:][::-1]
