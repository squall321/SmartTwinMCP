#!/usr/bin/env bash
set -euo pipefail
export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"
python3 - <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["SHARED_DIR"])
import registry
import audit
from job_helpers import resolve_job, run_koochainrun, fail

def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])
    job = resolve_job(args)
    if not job:
        fail("Job not found in registry.")
    if job["tool_name"] not in ("single_drop_simulation", "fullangle_drop_simulation"):
        fail(f"job_rerun only supports KooChainRun-based jobs. Got: {job['tool_name']}")

    rc, so, se = run_koochainrun("rerun", job["work_dir"], timeout=120)
    out = {"ok": rc == 0, "job_id": job["id"], "work_dir": job["work_dir"],
           "koochainrun_rerun": {"rc": rc, "stdout": so[-2000:], "stderr": se[-500:]}}
    if rc == 0:
        registry.update_status(job["id"], "submitted", notes="rerun triggered")
        # §25.3.1 audit row (success path only; failures stay silent per §25.3).
        actor = os.environ.get("USER") or os.environ.get("LOGNAME") or "unknown"
        audit.record_event(
            actor=actor,
            tool="job_rerun@1.1.0",
            action="submit",
            summary=f"rerun triggered for job {job['id']} ({job['tool_name']}) at {job['work_dir']}",
            target_kind="job",
            target_id=str(job["id"]),
            detail={
                "tool_name": job["tool_name"],
                "work_dir": job["work_dir"],
                "project_name": job.get("project_name"),
                "rc": rc,
            },
        )
    print(json.dumps(out, ensure_ascii=False, default=str))

try: main()
except Exception as e: fail(f"{type(e).__name__}: {e}")
PY
