"""Health and version: GET /healthz (no auth) and GET /api/v1/version.

/healthz is what systemd-side probes and the restart wait poll: it answers
without a session and reveals nothing beyond "up" and the running commit.
"""

from typing import Any

from fastapi import APIRouter, Depends

from core import version
from core.auth import require_session
from core.schemas import DataResponse

router = APIRouter()


@router.api_route("/healthz", methods=["GET", "HEAD"], include_in_schema=False)
def healthz() -> dict[str, Any]:
    info = version.info()
    return {"ok": True, "version": info["version"], "commit": info["commit"]}


@router.get("/api/v1/version", dependencies=[Depends(require_session)])
def get_version() -> DataResponse[dict[str, Any]]:
    return DataResponse(data={**version.info(), "bundle_stale": version.bundle_stale()})
