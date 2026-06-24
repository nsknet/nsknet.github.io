"""FastAPI entry point for the VPS admin panel.

Run via run.sh (recommended) or directly:  uvicorn app:app --host 127.0.0.1 --port 7777
Binds to localhost only — reach it through an SSH tunnel.
"""
import asyncio
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI
from fastapi.staticfiles import StaticFiles

from config import HOST, PORT, STATIC_DIR
from core import runner
from core.auth import get_password, require_auth
from routes import auth, dashboard, dns, firewall, logs, processes, services, sites, stream, system, tools


def ensure_lf_line_endings():
    """Recursively convert CRLF line endings to LF for all .sh files in the workspace."""
    import os
    import logging
    from config import BASE_DIR

    logger = logging.getLogger("uvicorn.error")
    converted_count = 0

    for root, _, files in os.walk(BASE_DIR):
        for file in files:
            if file.endswith(".sh"):
                file_path = os.path.join(root, file)
                try:
                    with open(file_path, "rb") as f:
                        content = f.read()
                    
                    if b"\r\n" in content:
                        normalized = content.replace(b"\r\n", b"\n")
                        with open(file_path, "wb") as f:
                            f.write(normalized)
                        converted_count += 1
                        logger.info(f"Normalized line endings to LF: {file_path}")
                except Exception as e:
                    logger.error(f"Failed to normalize line endings for {file_path}: {e}")

    if converted_count > 0:
        logger.info(f"Successfully normalized line endings to LF for {converted_count} shell script(s).")


@asynccontextmanager
async def lifespan(app: FastAPI):
    runner.set_event_loop(asyncio.get_running_loop())
    # Automatically normalize all shell script line endings to prevent CRLF bash errors on Linux.
    ensure_lf_line_endings()
    # run.sh prints the full banner; this line covers the direct-uvicorn case.
    print("=" * 60)
    print(f"  VPS Admin Panel  ->  http://{HOST}:{PORT}")
    print(f"  user: admin   password: {get_password()}")
    print("=" * 60, flush=True)
    yield



app = FastAPI(title="VPS Admin Panel", lifespan=lifespan)

# Everything except /logout and static files sits behind a single Basic Auth dependency.
_auth = [Depends(require_auth)]

# Include the JSON REST routers
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

# Mount the static files directory at the root (/) to serve the Vue SPA.
# This must be mounted AFTER the API routers so it acts as a fallback for static pages.
app.mount("/", StaticFiles(directory=str(STATIC_DIR), html=True), name="static")

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=HOST, port=PORT)
