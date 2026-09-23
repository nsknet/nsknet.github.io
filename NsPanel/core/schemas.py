"""Response and request contracts shared by every route.

Two shapes cover the whole API:

* :class:`JobResponse`  — an action was accepted and runs as a background job;
  the client opens ``/stream/{job_id}`` to watch it.
* :class:`DataResponse` — a read returned state, always under ``data``.

Keeping these in one place means the frontend has exactly two envelopes to
handle instead of the per-route dicts this module replaced.
"""
from typing import Any

from pydantic import BaseModel, Field


class JobResponse(BaseModel):
    """Accepted action running in the background."""

    status: str = "success"
    job_id: str
    title: str
    # Route-specific payload (e.g. the created tunnel's public info).
    extra: dict[str, Any] = Field(default_factory=dict)


class DataResponse[T](BaseModel):
    """A read: state under `data`, nothing else."""

    status: str = "success"
    data: T


class MessageResponse(BaseModel):
    """A synchronous action that finished without spawning a job."""

    status: str = "success"
    message: str


class ToolInfo(BaseModel):
    """Static metadata a tool module declares."""

    name: str
    display_name: str
    description: str
    logo: str | None = None
    requires_password: bool = False
    firewall_ports: list[int] = Field(default_factory=list)
    install_params: list[dict[str, Any]] = Field(default_factory=list)
    can_uninstall: bool = False
    can_change_password: bool = False


class ToolStatus(BaseModel):
    """Live status probed in Python — never from bash."""

    installed: bool
    version: str | None = None
    service_state: str = "n/a"
    ports: list[int] = Field(default_factory=list)
    extra: dict[str, Any] = Field(default_factory=dict)


class Tool(BaseModel):
    module: ToolInfo
    status: ToolStatus
