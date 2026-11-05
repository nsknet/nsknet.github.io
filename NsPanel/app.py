"""FastAPI entry point for NsPanel.

Launch with run.sh (recommended), which creates the virtualenv, generates the
session password and binds per NSPANEL_HOST/NSPANEL_PORT. See docs/ARCHITECTURE.md.
"""
import asyncio
import os
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles

from config import DIST_DIR, HOST, LOGO_DIR, PORT
from core import runner
from core.auth import get_password, require_auth, require_csrf_header
from routes import (
    auth,
    dashboard,
    dns,
    firewall,
    jobs,
    logs,
    panel,
    processes,
    services,
    sites,
    stream,
    system,
    tools,
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    runner.set_event_loop(asyncio.get_running_loop())
    # run.sh prints the full banner. The password is printed only when it was
    # generated here (plain uvicorn): one passed in — by run.sh, or the systemd
    # service's EnvironmentFile — must not end up in the journal.
    print(f"NsPanel -> http://{HOST}:{PORT}", flush=True)
    if not os.environ.get("PANEL_PASSWORD"):
        print(f"  user: admin   password: {get_password()}", flush=True)
    yield


app = FastAPI(title="NsPanel", lifespan=lifespan)

# Everything except /logout and static assets sits behind Basic Auth; POSTs also
# need the X-NsPanel header (CSRF guard, see core/auth.py).
_auth = [Depends(require_auth), Depends(require_csrf_header)]

# JSON REST API
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
app.include_router(auth.router)  # /logout — must work without auth

# Tool icons keep their own URL prefix so the built SPA can reference them
# independently of the bundle's hashed asset names.
app.mount("/logo", StaticFiles(directory=str(LOGO_DIR)), name="logo")


_MISSING_BUILD_HTML = (
    "<h1>NsPanel frontend is not built</h1>"
    "<p>Run <code>cd frontend &amp;&amp; npm ci &amp;&amp; npm run build</code>.</p>"
)


# Paths that belong to the server, never to the client router: an unknown one is
# a real 404, not a reason to hand back index.html.
_SERVER_ROOTS = {"api", "stream", "logo", "assets"}

# Hashed bundle files never change under the same name; index.html must always be
# revalidated, or a browser keeps pointing at a bundle a `git pull` deleted.
_IMMUTABLE = {"Cache-Control": "public, max-age=31536000, immutable"}
_NO_CACHE = {"Cache-Control": "no-cache"}


@app.get("/{full_path:path}", include_in_schema=False, dependencies=_auth)
def spa(full_path: str):
    """Serve the built Vue SPA, falling back to index.html for client routes."""
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
