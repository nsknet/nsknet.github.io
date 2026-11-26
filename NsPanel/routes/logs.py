"""Audit log API."""

from typing import Annotated

from fastapi import APIRouter, Query

from core import audit
from core.schemas import DataResponse

router = APIRouter(prefix="/api/v1")


@router.get("/logs")
def get_logs(
    limit: Annotated[int, Query(ge=1, le=2000)] = 500,
    offset: Annotated[int, Query(ge=0)] = 0,
    q: Annotated[str, Query(max_length=200)] = "",
) -> DataResponse[list[dict[str, str]]]:
    """Audit entries, newest first: `{ts, action, detail, user, ip}`."""
    return DataResponse(data=audit.entries(limit=limit, offset=offset, q=q.strip()))
