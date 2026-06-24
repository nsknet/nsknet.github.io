"""HTTP Basic Auth.

Password is taken from the PANEL_PASSWORD env var (set by run.sh) or, if
unset (e.g. uvicorn started directly), generated here. Either way it is
printed once at startup by app.py's lifespan handler.
"""
import os
import secrets

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBasic, HTTPBasicCredentials

from config import USERNAME
from core import audit

_security = HTTPBasic()
_PASSWORD = os.environ.get("PANEL_PASSWORD") or secrets.token_urlsafe(16)
_login_logged = False


def get_password() -> str:
    return _PASSWORD


def require_auth(credentials: HTTPBasicCredentials = Depends(_security)) -> str:
    user_ok = secrets.compare_digest(credentials.username, USERNAME)
    pass_ok = secrets.compare_digest(credentials.password, _PASSWORD)
    if not (user_ok and pass_ok):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid credentials",
            headers={"WWW-Authenticate": "Basic"},
        )
    # Single-user panel: log the login once per process.
    global _login_logged
    if not _login_logged:
        _login_logged = True
        audit.log("login", f"user '{USERNAME}' authenticated")
    return credentials.username
