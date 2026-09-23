"""Dashboard API: one call for the overview screen."""
from typing import Any

from fastapi import APIRouter

from core.schemas import DataResponse
from features import sites, system
from modules import registry

router = APIRouter(prefix="/api/v1")


@router.get("/dashboard")
def get_dashboard() -> DataResponse[dict[str, Any]]:
    return DataResponse(
        data={
            "stats": system.get_stats(),
            "sites": sites.list_sites_with_status(),
            "tools": [t.model_dump() for t in registry.serialize_all()],
        }
    )
