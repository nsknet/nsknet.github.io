"""Background jobs held in memory: GET /api/v1/jobs.

Lets the UI find a job again after a reload or after its output dialog was
closed; the output itself is replayed by GET /stream/{job_id}.
"""
from fastapi import APIRouter

from core import runner
from core.schemas import DataResponse, JobSummary

router = APIRouter(prefix="/api/v1")


@router.get("/jobs")
def list_jobs() -> DataResponse[list[JobSummary]]:
    return DataResponse(data=[JobSummary(**job) for job in runner.list_jobs()])
