"""Background jobs: list them and cancel one.

Lets the UI find a job again after a reload or after its output dialog was
closed; the output itself is replayed by GET /stream/{job_id}.
"""
from fastapi import APIRouter, HTTPException, status

from core import audit, runner
from core.schemas import DataResponse, JobSummary, MessageResponse

router = APIRouter(prefix="/api/v1")


@router.get("/jobs")
def list_jobs() -> DataResponse[list[JobSummary]]:
    return DataResponse(data=[JobSummary(**job) for job in runner.list_jobs()])


@router.post("/jobs/{job_id}/cancel")
def cancel_job(job_id: str) -> MessageResponse:
    job = runner.get_job(job_id)
    if job is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No such job.")
    if not runner.cancel(job_id):
        raise HTTPException(status.HTTP_409_CONFLICT, "The job has already finished.")
    audit.log("job.cancel", f"job={job_id} label={job['label']!r}")
    return MessageResponse(message="Stopping the job…")
