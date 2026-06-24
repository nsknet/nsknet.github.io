"""Auth-related routes. Basic Auth itself lives in core/auth.py.

Only /logout here: returns 401 so the browser drops its cached credentials.
Mounted WITHOUT the global auth dependency (it must work while logged in).
"""
import secrets
from fastapi import APIRouter, Response, Request, Depends
from fastapi.responses import RedirectResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from core.auth import get_password
from config import USERNAME

router = APIRouter()
security = HTTPBasic(auto_error=False)


@router.get("/logout")
def logout(
    request: Request,
    response: Response,
    credentials: HTTPBasicCredentials = Depends(security)
):
    # Check if correct credentials were provided
    credentials_are_correct = False
    if credentials:
        user_ok = secrets.compare_digest(credentials.username, USERNAME)
        pass_ok = secrets.compare_digest(credentials.password, get_password())
        if user_ok and pass_ok:
            credentials_are_correct = True

    just_logged_out = request.cookies.get("just_logged_out")

    if credentials_are_correct and just_logged_out:
        # User entered correct credentials AFTER we marked them as logged out.
        # Redirect to root and clear the cookie.
        res = RedirectResponse(url="/", status_code=302)
        res.delete_cookie("just_logged_out")
        return res

    # Otherwise, return 401 to clear credentials and prompt again
    res = Response(
        content="Logged out. Close this tab, or reload to sign in again.",
        status_code=401,
        headers={"WWW-Authenticate": "Basic"},
    )
    res.set_cookie("just_logged_out", "1", max_age=3600, httponly=True)
    return res
