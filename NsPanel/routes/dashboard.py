"""Dashboard API."""
from fastapi import APIRouter

from features import sites, system
from modules import registry

router = APIRouter(prefix="/api/v1")


def tools_with_status() -> list[dict]:
    return [
        {
            "module": {
                "name": m.name,
                "display_name": m.display_name,
                "description": m.description,
                "logo": getattr(m, "logo", m.name[:2].upper()),
                "requires_password": getattr(m, "requires_password", False),
            },
            "status": m.get_status()
        }
        for m in registry.get_modules()
    ]


@router.get("/dashboard")
def get_dashboard():
    return {
        "status": "success",
        "stats": system.get_stats(),
        "sites": sites.list_sites_with_status(),
        "tools": tools_with_status(),
    }
