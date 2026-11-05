"""HTTP Basic Auth, plus the CSRF guard that Basic Auth needs.

Password is taken from the PANEL_PASSWORD env var (set by run.sh) or, if
unset (e.g. uvicorn started directly), generated here. Either way it is
printed once at startup by app.py's lifespan handler.

Browsers re-send cached Basic credentials on *any* request to the panel's
origin, including a form another website auto-submits. So every state-changing
request must also carry the `X-NsPanel: 1` header: a custom header cannot be
set by a plain cross-site form, and from cross-site script it forces a CORS
preflight the panel never approves.
"""
import os
import secrets

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPBasic, HTTPBasicCredentials

from config import USERNAME
from core import audit

_security = HTTPBasic()
CSRF_HEADER = "X-NsPanel"
_SAFE_METHODS = {"GET", "HEAD", "OPTIONS"}
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


def require_csrf_header(request: Request) -> None:
    """Reject state-changing requests that a foreign page could have forged."""
    if request.method in _SAFE_METHODS:
        return
    if request.headers.get("sec-fetch-site") == "cross-site":
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Cross-site request refused")
    if request.headers.get(CSRF_HEADER) != "1":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail=f"Missing {CSRF_HEADER} header"
        )
