"""Login, logout, session info and password change.

`login` is the only API route reachable without a session. It is rate limited
per client IP, always costs one scrypt check, and audits every attempt.
"""

import time
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Form, HTTPException, Request, Response, status

import config
from core import audit, passwords, session, version
from core.auth import client_ip, require_csrf_header, require_session
from core.schemas import DataResponse, MessageResponse

router = APIRouter(prefix="/api/v1/auth", dependencies=[Depends(require_csrf_header)])

# A small fixed delay on every failure slows scripted guessing further and keeps
# a wrong-username reply indistinguishable in timing from a wrong password.
_FAILURE_DELAY = 0.5


def _set_cookie(response: Response, request: Request, token: str) -> None:
    response.set_cookie(
        config.SESSION_COOKIE,
        token,
        max_age=config.SESSION_MAX_SECONDS,
        httponly=True,
        samesite="strict",
        secure=request.url.scheme == "https",
        path="/",
    )


def _me(username: str) -> dict[str, Any]:
    return {"username": username, "version": version.info(), "bundle_stale": version.bundle_stale()}


@router.post("/login")
def login(
    request: Request,
    response: Response,
    username: Annotated[str, Form(max_length=64)],
    password: Annotated[str, Form(max_length=256)],
) -> DataResponse[dict[str, Any]]:
    ip = client_ip(request)
    wait = session.lockout_remaining(ip)
    if wait:
        audit.log("auth.login_blocked", f"username={username!r}", user="", ip=ip)
        raise HTTPException(
            status.HTTP_429_TOO_MANY_REQUESTS,
            f"Too many failed attempts. Try again in {max(1, wait // 60)} minute(s).",
            headers={"Retry-After": str(wait)},
        )
    if not passwords.check(username, password):
        locked = session.record_failure(ip)
        audit.log("auth.login_failed", f"username={username!r} locked={bool(locked)}", user="", ip=ip)
        time.sleep(_FAILURE_DELAY)
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Wrong username or password.")

    session.record_success(ip)
    # A fresh token on every login: a token planted before login is never promoted.
    session.destroy(request.cookies.get(config.SESSION_COOKIE))
    token = session.create(username, ip)
    _set_cookie(response, request, token)
    audit.log("auth.login", f"username={username!r}", user=username, ip=ip)
    return DataResponse(data=_me(username))


@router.post("/logout")
def logout(request: Request, response: Response) -> MessageResponse:
    current = session.get(request.cookies.get(config.SESSION_COOKIE))
    session.destroy(request.cookies.get(config.SESSION_COOKIE))
    response.delete_cookie(config.SESSION_COOKIE, path="/")
    if current:
        audit.log("auth.logout", "", user=current.username, ip=client_ip(request))
    return MessageResponse(message="Signed out.")


@router.get("/me")
def me(username: Annotated[str, Depends(require_session)]) -> DataResponse[dict[str, Any]]:
    return DataResponse(data=_me(username))


@router.post("/password")
def change_password(
    request: Request,
    response: Response,
    username: Annotated[str, Depends(require_session)],
    current_password: Annotated[str, Form(max_length=256)],
    new_password: Annotated[str, Form(max_length=256)],
) -> MessageResponse:
    if not passwords.check(username, current_password):
        audit.log("auth.password_change_failed", "wrong current password")
        time.sleep(_FAILURE_DELAY)
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "The current password is wrong.")
    problem = passwords.validate_new(new_password)
    if problem:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, problem)
    passwords.save(new_password, username)
    # Sign out every other browser; keep this one signed in on a fresh token.
    session.destroy_all()
    _set_cookie(response, request, session.create(username, client_ip(request)))
    audit.log("auth.password_changed", "")
    return MessageResponse(message="Password changed. Other sessions were signed out.")
