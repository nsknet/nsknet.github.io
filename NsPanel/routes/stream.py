"""SSE endpoint for live command output: GET /stream/{job_id}."""
from fastapi import APIRouter
from fastapi.responses import StreamingResponse

from core import runner

router = APIRouter()


@router.get("/stream/{job_id}")
def stream(job_id: str):
    return StreamingResponse(
        runner.stream_job(job_id),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            # Disable proxy buffering so events arrive line-by-line.
            "X-Accel-Buffering": "no",
        },
    )
