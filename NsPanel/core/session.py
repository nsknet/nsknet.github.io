"""Server-side login sessions and the login rate limiter.

Sessions live in memory: a restart signs everyone out, which is fine for a
single-admin panel and means there is no session store to protect on disk.
The browser only holds a random 32-byte token in an HttpOnly cookie.
"""
import secrets
import threading
import time
from collections import deque
from dataclasses import dataclass, field

import config


@dataclass
class Session:
    username: str
    ip: str
    created_at: float = field(default_factory=time.time)
    last_seen: float = field(default_factory=time.time)

    def expired(self, now: float) -> bool:
        return (
            now - self.last_seen > config.SESSION_IDLE_SECONDS
            or now - self.created_at > config.SESSION_MAX_SECONDS
        )


_sessions: dict[str, Session] = {}
_lock = threading.Lock()


def create(username: str, ip: str) -> str:
    token = secrets.token_urlsafe(32)
    with _lock:
        _purge(time.time())
        _sessions[token] = Session(username=username, ip=ip)
    return token


def get(token: str | None) -> Session | None:
    """The live session for `token`, touching its idle timer; None if absent or expired."""
    if not token:
        return None
    now = time.time()
    with _lock:
        session = _sessions.get(token)
        if session is None:
            return None
        if session.expired(now):
            del _sessions[token]
            return None
        session.last_seen = now
        return session


def destroy(token: str | None) -> None:
    if token:
        with _lock:
            _sessions.pop(token, None)


def destroy_all() -> None:
    """Sign every browser out — after a password change."""
    with _lock:
        _sessions.clear()


def _purge(now: float) -> None:
    for token in [t for t, s in _sessions.items() if s.expired(now)]:
        del _sessions[token]


# ── Login rate limiting ───────────────────────────────────────────────────────

_failures: dict[str, deque[float]] = {}
_locked_until: dict[str, float] = {}


def lockout_remaining(ip: str) -> int:
    """Seconds this IP must still wait before trying again (0 = may try)."""
    with _lock:
        until = _locked_until.get(ip, 0.0)
        remaining = until - time.time()
        if remaining <= 0:
            _locked_until.pop(ip, None)
            return 0
        return int(remaining) + 1


def record_failure(ip: str) -> int:
    """Count a failed login; returns the lockout in seconds it triggered (0 if none)."""
    now = time.time()
    with _lock:
        window = _failures.setdefault(ip, deque())
        window.append(now)
        while window and now - window[0] > config.LOGIN_WINDOW_SECONDS:
            window.popleft()
        if len(window) >= config.LOGIN_MAX_FAILURES:
            window.clear()
            _locked_until[ip] = now + config.LOGIN_LOCKOUT_SECONDS
            return config.LOGIN_LOCKOUT_SECONDS
        return 0


def record_success(ip: str) -> None:
    with _lock:
        _failures.pop(ip, None)
        _locked_until.pop(ip, None)


def reset() -> None:
    """Forget every session and failure (tests)."""
    with _lock:
        _sessions.clear()
        _failures.clear()
        _locked_until.clear()
