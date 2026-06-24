"""Audit log REST API."""
from fastapi import APIRouter

from core import audit

router = APIRouter(prefix="/api/v1")


@router.get("/logs")
def get_logs():
    return audit.tail()
