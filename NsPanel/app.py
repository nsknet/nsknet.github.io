"""FastAPI entry point for NsPanel.

Launch with run.sh (recommended), which creates the virtualenv, generates the
session password and binds per NSPANEL_HOST/NSPANEL_PORT. See docs/ARCHITECTURE.md.
"""
import asyncio
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles

from config import DIST_DIR, HOST, LOGO_DIR, PORT
from core import runner
from core.auth import get_password, require_auth
from routes import (
    auth,
    dashboard,
    dns,
    firewall,
    logs,
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
    # run.sh prints the full banner; this line covers the direct-uvicorn case.
    print("=" * 60)
    print(f"  NsPanel  ->  http://{HOST}:{PORT}")
    print(f"  user: admin   password: {get_password()}")
    print("=" * 60, flush=True)
    yield


app = FastAPI(title="NsPanel", lifespan=lifespan)

# Everything except /logout and static assets sits behind one Basic Auth dependency.
_auth = [Depends(require_auth)]

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
app.include_router(stream.router, dependencies=_auth)
app.include_router(auth.router)  # /logout — must work without auth

# Tool icons keep their own URL prefix so the built SPA can reference them
# independently of the bundle's hashed asset names.
app.mount("/logo", StaticFiles(directory=str(LOGO_DIR)), name="logo")


_MISSING_BUILD_HTML = (
    "<h1>NsPanel frontend is not built</h1>"
    "<p>Run <code>cd frontend &amp;&amp; npm ci &amp;&amp; npm run build</code>.</p>"
)


@app.get("/{full_path:path}", include_in_schema=False, dependencies=_auth)
def spa(full_path: str):
    """Serve the built Vue SPA, falling back to index.html for client routes."""
    root = DIST_DIR.resolve()
    candidate = (DIST_DIR / full_path).resolve()
    if full_path and candidate.is_file() and candidate.is_relative_to(root):
        return FileResponse(candidate)
    index = DIST_DIR / "index.html"
    if index.exists():
        return FileResponse(index)
    return HTMLResponse(_MISSING_BUILD_HTML, status_code=503)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=HOST, port=PORT)
