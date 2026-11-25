"""FastAPI entry point for NsPanel.

Launch with run.sh (recommended), which creates the virtualenv, makes sure an
admin password exists and binds per NSPANEL_HOST/NSPANEL_PORT. See
docs/ARCHITECTURE.md.
"""
import asyncio
import logging
import os
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from starlette.exceptions import HTTPException as StarletteHTTPException

from config import DIST_DIR, HOST, LOGO_DIR, PORT
from core import passwords, runner, version
from core.auth import require_csrf_header, require_session
from routes import (
    auth,
    dashboard,
    dns,
    firewall,
    jobs,
    logs,
    meta,
    panel,
    processes,
    services,
    sites,
    stream,
    system,
    tools,
)

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
log = logging.getLogger("nspanel")


@asynccontextmanager
async def lifespan(app: FastAPI):
    runner.set_event_loop(asyncio.get_running_loop())
    runner.load_history()
    log.info("NsPanel %s -> http://%s:%s", version.label(), HOST, PORT)

    # PANEL_PASSWORD pins the password (re-hashed every start). Without it and
    # without a stored hash (plain `uvicorn app:app`), make one and print it once;
    # run.sh and the service installer always store a hash before starting.
    pinned = os.environ.get("PANEL_PASSWORD")
    if pinned:
        passwords.save(pinned)
    elif not passwords.is_set():
        generated = passwords.generate()
        passwords.save(generated)
        print(f"  No admin password was set. Generated one — user: admin   password: {generated}", flush=True)
    yield
    await runner.shutdown()


# No /docs, /redoc or /openapi.json: they would be served without auth.
app = FastAPI(title="NsPanel", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)


# ── Security headers ──────────────────────────────────────────────────────────
# The SPA loads only its own bundle; nothing may frame the panel (clickjacking
# would let a foreign page drive real clicks with the session).
_SECURITY_HEADERS = {
    "Content-Security-Policy": (
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
        "img-src 'self' data:; font-src 'self' data:; connect-src 'self'; "
        "object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
    ),
    "X-Frame-Options": "DENY",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Cross-Origin-Opener-Policy": "same-origin",
}


@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    for name, value in _SECURITY_HEADERS.items():
        response.headers.setdefault(name, value)
    return response


# ── One error envelope ────────────────────────────────────────────────────────
# Every failure is `{status: "error", message, code}`; `detail` is kept for
# clients written against FastAPI's default shape.


def _error(code: int, message: str, detail=None, headers=None) -> JSONResponse:
    body = {
        "status": "error",
        "code": code,
        "message": message,
        "detail": message if detail is None else detail,
    }
    return JSONResponse(body, status_code=code, headers=headers)


@app.exception_handler(StarletteHTTPException)
async def http_error(request: Request, exc: StarletteHTTPException) -> JSONResponse:
    message = exc.detail if isinstance(exc.detail, str) else "Request failed"
    return _error(exc.status_code, message, exc.detail, getattr(exc, "headers", None))


@app.exception_handler(RequestValidationError)
async def validation_error(request: Request, exc: RequestValidationError) -> JSONResponse:
    parts = []
    for err in exc.errors():
        field = str(err.get("loc", [""])[-1])
        parts.append(f"{field}: {err.get('msg', 'invalid')}" if field else str(err.get("msg")))
    return _error(422, "; ".join(parts) or "Invalid input", jsonable_errors(exc))


def jsonable_errors(exc: RequestValidationError) -> list[dict]:
    return [{"loc": list(e.get("loc", [])), "msg": str(e.get("msg", ""))} for e in exc.errors()]


@app.exception_handler(Exception)
async def unhandled_error(request: Request, exc: Exception) -> JSONResponse:
    log.exception("Unhandled error on %s %s", request.method, request.url.path)
    return _error(500, "Internal error — see the panel log (journalctl -u nspanel) for details.")


# ── Routes ────────────────────────────────────────────────────────────────────
# Everything under /api and /stream needs a session; POSTs also need the
# X-NsPanel header (CSRF guard, see core/auth.py). /api/v1/auth/login, /healthz,
# the SPA shell and static assets are public.
_auth = [Depends(require_session), Depends(require_csrf_header)]

app.include_router(meta.router)
app.include_router(auth.router)
app.include_router(dashboard.router, dependencies=_auth)
app.include_router(system.router, dependencies=_auth)
app.include_router(processes.router, dependencies=_auth)
app.include_router(firewall.router, dependencies=_auth)
app.include_router(tools.router, dependencies=_auth)
app.include_router(sites.router, dependencies=_auth)
app.include_router(dns.router, dependencies=_auth)
app.include_router(services.router, dependencies=_auth)
app.include_router(logs.router, dependencies=_auth)
app.include_router(jobs.router, dependencies=_auth)
app.include_router(panel.router, dependencies=_auth)
app.include_router(stream.router, dependencies=_auth)

# Tool icons keep their own URL prefix so the built SPA can reference them
# independently of the bundle's hashed asset names.
app.mount("/logo", StaticFiles(directory=str(LOGO_DIR)), name="logo")


_MISSING_BUILD_HTML = (
    "<h1>NsPanel frontend is not built</h1>"
    "<p>Run <code>cd frontend &amp;&amp; npm ci &amp;&amp; npm run build</code>.</p>"
)


# Paths that belong to the server, never to the client router: an unknown one is
# a real 404, not a reason to hand back index.html.
_SERVER_ROOTS = {"api", "stream", "logo", "assets", "healthz"}

# Hashed bundle files never change under the same name; index.html must always be
# revalidated, or a browser keeps pointing at a bundle a `git pull` deleted.
_IMMUTABLE = {"Cache-Control": "public, max-age=31536000, immutable"}
_NO_CACHE = {"Cache-Control": "no-cache"}


@app.get("/{full_path:path}", include_in_schema=False)
def spa(full_path: str):
    """Serve the built Vue SPA, falling back to index.html for client routes.

    Public: the shell holds no data. It asks /api/v1/auth/me and shows the
    login screen when there is no session.
    """
    root = DIST_DIR.resolve()
    candidate = (DIST_DIR / full_path).resolve()
    if full_path and candidate.is_file() and candidate.is_relative_to(root):
        headers = _IMMUTABLE if full_path.startswith("assets/") else _NO_CACHE
        return FileResponse(candidate, headers=headers)
    if full_path.split("/", 1)[0] in _SERVER_ROOTS:
        raise HTTPException(status_code=404, detail="Not found")
    index = DIST_DIR / "index.html"
    if index.exists():
        return FileResponse(index, headers=_NO_CACHE)
    return HTMLResponse(_MISSING_BUILD_HTML, status_code=503)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=HOST, port=PORT)
