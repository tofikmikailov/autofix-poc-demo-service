"""
Section 8/9/10: minimal HTTP front door for the AutoFix agent container.

Exposes:
  POST /api/jobs         - accept a new job, dispatch it (async) to
                            execute-job.sh, enforce MAX_CONCURRENT_JOBS=1
  GET  /api/jobs/{jobId} - poll job status/result
  GET  /health           - liveness + busy/currentJobId, for Docker
                            Compose healthcheck and n8n's own busy-check

Design notes (Section 9):
  - A single process-wide lock enforces one job at a time. The lock is
    also mirrored to a workspace lock file (/workspace/agent.lock) so a
    container restart mid-job can detect and clear a stale lock (the
    owning process is gone once the container restarts, since jobs never
    survive a restart -- see Section 10).
  - Bearer auth (AUTOFIX_AGENT_API_TOKEN) guards /api/jobs; there are no
    Jira/Postgres/Elasticsearch credentials anywhere in this container
    (Section 6), so this token is the only thing standing between the
    network and arbitrary job dispatch.
  - Job state is kept both in-memory and persisted to
    /workspace/state/<jobId>.json so GET /api/jobs/{jobId} survives a
    server.py restart as long as the workspace volume does.
"""

import json
import os
import subprocess
import threading
import time
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, ValidationError, field_validator

APP_ROOT = Path(__file__).resolve().parent
WORKSPACE_ROOT = Path(os.environ.get("AUTOFIX_WORKSPACE_ROOT", "/workspace"))
STATE_DIR = WORKSPACE_ROOT / "state"
LOCK_FILE = WORKSPACE_ROOT / "agent.lock"
EXECUTE_JOB = APP_ROOT / "execute-job.sh"

API_TOKEN = os.environ.get("AUTOFIX_AGENT_API_TOKEN")

app = FastAPI(title="autofix-agent", version="1.0")

_lock = threading.Lock()
_busy = False
_current_job_id: Optional[str] = None


class JobRequest(BaseModel):
    schemaVersion: int
    jobId: str
    incidentId: int
    jiraKey: str
    fingerprint: str
    branchName: str
    contextHash: str
    ticketContext: dict

    @field_validator("jobId")
    @classmethod
    def job_id_format(cls, v: str) -> str:
        import re
        if not re.match(r"^autofix-\d+-\d+$", v):
            raise ValueError("jobId must match autofix-<incidentId>-<attempt>")
        return v


def _require_auth(authorization: Optional[str]) -> None:
    if not API_TOKEN:
        # Misconfiguration: refuse to run wide open.
        raise HTTPException(status_code=503, detail="AUTOFIX_AGENT_API_TOKEN not configured")
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="INVALID_AGENT_TOKEN")
    token = authorization.removeprefix("Bearer ").strip()
    if token != API_TOKEN:
        raise HTTPException(status_code=401, detail="INVALID_AGENT_TOKEN")


def _state_path(job_id: str) -> Path:
    return STATE_DIR / f"{job_id}.json"


def _write_state(job_id: str, payload: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = _state_path(job_id).with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload))
    tmp.replace(_state_path(job_id))


def _read_state(job_id: str) -> Optional[dict]:
    path = _state_path(job_id)
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return None


def _run_job(job_id: str, job_file: Path, result_file: Path) -> None:
    global _busy, _current_job_id
    _write_state(job_id, {"jobId": job_id, "status": "RUNNING", "startedAt": time.time()})

    try:
        subprocess.run(
            ["bash", str(EXECUTE_JOB), str(job_file), str(result_file)],
            check=False,
        )
    finally:
        if result_file.exists():
            try:
                result = json.loads(result_file.read_text())
            except json.JSONDecodeError:
                result = {"jobId": job_id, "status": "AGENT_FAILED", "errorCode": "INVALID_AGENT_OUTPUT"}
        else:
            result = {"jobId": job_id, "status": "AGENT_FAILED", "errorCode": "NO_RESULT_FILE"}

        _write_state(job_id, result)

        with _lock:
            _busy = False
            _current_job_id = None
        LOCK_FILE.unlink(missing_ok=True)


@app.on_event("startup")
def _clear_stale_lock() -> None:
    # Section 10: jobs never survive a container restart, so any lock
    # file left over from before a restart is definitionally stale.
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOCK_FILE.unlink(missing_ok=True)


@app.get("/health")
def health():
    with _lock:
        return {"status": "ok", "busy": _busy, "currentJobId": _current_job_id}


@app.post("/api/jobs")
async def create_job(request: Request, authorization: Optional[str] = Header(default=None)):
    _require_auth(authorization)

    body = await request.json()
    try:
        job = JobRequest.model_validate(body)
    except ValidationError as exc:
        raise HTTPException(status_code=400, detail={"errorCode": "INVALID_JOB", "errors": exc.errors()})

    existing = _read_state(job.jobId)
    if existing is not None and existing.get("status") in {"RUNNING", "PR_READY", "HUMAN_REQUIRED", "AGENT_FAILED"}:
        return JSONResponse(status_code=200, content={"jobId": job.jobId, "status": existing["status"], "duplicate": True})

    with _lock:
        global _busy, _current_job_id
        if _busy:
            return JSONResponse(
                status_code=409,
                content={"errorCode": "AGENT_BUSY", "currentJobId": _current_job_id},
            )
        _busy = True
        _current_job_id = job.jobId

    WORKSPACE_ROOT.mkdir(parents=True, exist_ok=True)
    LOCK_FILE.write_text(job.jobId)

    job_file = STATE_DIR / f"{job.jobId}.request.json"
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    job_file.write_text(json.dumps(job.model_dump()))
    result_file = STATE_DIR / f"{job.jobId}.result.json"

    thread = threading.Thread(target=_run_job, args=(job.jobId, job_file, result_file), daemon=True)
    thread.start()

    return JSONResponse(status_code=202, content={"jobId": job.jobId, "status": "ACCEPTED"})


@app.get("/api/jobs/{job_id}")
def get_job(job_id: str, authorization: Optional[str] = Header(default=None)):
    _require_auth(authorization)
    state = _read_state(job_id)
    if state is None:
        raise HTTPException(status_code=404, detail={"errorCode": "JOB_NOT_FOUND"})
    return state
