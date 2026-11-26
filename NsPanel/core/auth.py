"""Session auth for every route, plus the CSRF guard.

A login (routes/auth.py) sets an HttpOnly, SameSite=Strict session cookie;
`require_session` admits a request only with a live session. The cookie is
never readable by script and never sent on cross-site requests.

SameSite already stops a foreign page from riding the session, but the panel
keeps a second, independent guard on every state-changing request: it must
carry the `X-NsPanel: 1` header (a plain cross-site form cannot set it, and
cross-site script would need a CORS preflight the panel never approves), and
must not come from another origin.
"""

from urllib.parse import urlsplit

from fastapi import HTTPException, Request, status

import config
from core import audit, session

CSRF_HEADER = "X-NsPanel"
_SAFE_METHODS = {"GET", "HEAD", "OPTIONS"}


def client_ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"


async def require_session(request: Request) -> str:
    """Dependency: the logged-in username, or 401.

    Async on purpose: it runs in the request's own task, so the audit actor it
    sets is inherited by the (sync, threadpool) route handler that follows.
    """
    current = session.get(request.cookies.get(config.SESSION_COOKIE))
    if current is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Not signed in")
    audit.set_actor(current.username, client_ip(request))
    return current.username


def require_csrf_header(request: Request) -> None:
    """Reject state-changing requests that a foreign page could have forged."""
    if request.method in _SAFE_METHODS:
        return
    if request.headers.get("sec-fetch-site") == "cross-site":
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Cross-site request refused")
    origin = request.headers.get("origin")
    if origin and origin != "null":
        host = request.headers.get("host", "")
        if urlsplit(origin).netloc.lower() != host.lower():
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Cross-origin request refused")
    if request.headers.get(CSRF_HEADER) != "1":
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=f"Missing {CSRF_HEADER} header")
