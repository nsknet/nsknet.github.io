"""Audit log API."""
from fastapi import APIRouter

from core import audit
from core.schemas import DataResponse

router = APIRouter(prefix="/api/v1")


@router.get("/logs")
def get_logs() -> DataResponse[list[str]]:
    return DataResponse(data=audit.tail())
