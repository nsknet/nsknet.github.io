"""The admin password, stored only as a scrypt hash.

The hash lives in a root-only JSON file (config.auth_file_path(), by default
/etc/nspanel/auth.json) shared by every panel on the host — the run.sh checkout
and the systemd service — so there is one admin password per server.

Also a small CLI, used by run.sh and scripts/panel_service.sh::

    python -m core.passwords ensure   # create a password if none is set; print it once
    python -m core.passwords reset    # generate a new one and print it
    python -m core.passwords set      # read the new password from NSPANEL_NEW_PASSWORD or stdin

`PANEL_PASSWORD` in the environment pins the password: `ensure` re-hashes it
every launch, so the variable stays the source of truth while it is set.
"""
import base64
import hashlib
import hmac
import json
import os
import secrets
import sys
from pathlib import Path

import config

# scrypt cost: ~16 MiB and ~50 ms per check, enough to make offline guessing slow
# while a single login stays instant.
_N, _R, _P = 2**14, 8, 1
_DKLEN = 32


def _b64(data: bytes) -> str:
    return base64.b64encode(data).decode("ascii")


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.scrypt(password.encode(), salt=salt, n=_N, r=_R, p=_P, dklen=_DKLEN)
    return f"scrypt${_N}${_R}${_P}${_b64(salt)}${_b64(digest)}"


def verify_password(password: str, encoded: str) -> bool:
    try:
        scheme, n, r, p, salt, digest = encoded.split("$")
        if scheme != "scrypt":
            return False
        expected = base64.b64decode(digest)
        actual = hashlib.scrypt(
            password.encode(),
            salt=base64.b64decode(salt),
            n=int(n),
            r=int(r),
            p=int(p),
            dklen=len(expected),
            maxmem=64 * 1024 * 1024,
        )
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(actual, expected)


# A well-formed hash of a random password: checked against when no password is
# set, so a login attempt costs the same either way.
_DUMMY_HASH = hash_password(secrets.token_urlsafe(16))


def _path() -> Path:
    return config.auth_file_path()


def load() -> dict | None:
    """`{"username", "hash", "updated_at"}`, or None when no password is set."""
    try:
        data = json.loads(_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not data.get("hash"):
        return None
    return data


def is_set() -> bool:
    return load() is not None


def save(password: str, username: str | None = None) -> None:
    """Hash and store `password`, atomically, readable by root only."""
    import time

    path = _path()
    path.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "username": username or config.USERNAME,
        "hash": hash_password(password),
        "updated_at": int(time.time()),
    }
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(record, fh)
    os.replace(tmp, path)


def check(username: str, password: str) -> bool:
    """Constant-effort credential check: always runs one scrypt."""
    record = load()
    encoded = record["hash"] if record else _DUMMY_HASH
    expected_user = (record or {}).get("username", config.USERNAME)
    password_ok = verify_password(password, encoded)
    user_ok = hmac.compare_digest(username.encode(), str(expected_user).encode())
    return bool(record) and password_ok and user_ok


def generate() -> str:
    return secrets.token_urlsafe(18)


def validate_new(password: str) -> str | None:
    """Why `password` is not acceptable as the admin password, or None."""
    if len(password) < config.PASSWORD_MIN_LENGTH:
        return f"Use at least {config.PASSWORD_MIN_LENGTH} characters."
    if password.strip() != password:
        return "The password must not start or end with whitespace."
    return None


def _main(argv: list[str]) -> int:
    command = argv[0] if argv else ""
    if command == "ensure":
        pinned = os.environ.get("PANEL_PASSWORD")
        if pinned:
            save(pinned)
            return 0
        if is_set():
            return 0
        password = generate()
        save(password)
        print(password)
        return 0
    if command == "reset":
        password = generate()
        save(password)
        print(password)
        return 0
    if command == "set":
        password = os.environ.get("NSPANEL_NEW_PASSWORD") or sys.stdin.readline().rstrip("\n")
        problem = validate_new(password)
        if problem:
            print(problem, file=sys.stderr)
            return 1
        save(password)
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
