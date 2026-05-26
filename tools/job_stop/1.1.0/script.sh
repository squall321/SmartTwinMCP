#!/usr/bin/env bash
set -euo pipefail
export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"
python3 - <<'PY'
import json, os, sys, subprocess
sys.path.insert(0, os.environ["SHARED_DIR"])
import registry
import audit
from job_helpers import resolve_job, run_koochainrun, fail

def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])
    job = resolve_job(args)
    if not job:
        fail("Job not found in registry.")

    out = {"ok": True, "job_id": job["id"], "tool": job["tool_name"], "work_dir": job["work_dir"]}

    # KooChainRun stop (for KooChainRun-based jobs)
    if job["tool_name"] in ("single_drop_simulation", "fullangle_drop_simulation"):
        rc, so, se = run_koochainrun("stop", job["work_dir"], timeout=60)
        out["koochainrun_stop"] = {"rc": rc, "stdout": so[-1000:], "stderr": se[-500:]}
    else:
        # raw lsdyna — scancel by slurm IDs
        slurm_ids = job.get("slurm_job_ids") or []
        if slurm_ids:
            r = subprocess.run(["scancel"] + slurm_ids, capture_output=True, text=True, timeout=30)
            out["scancel"] = {"rc": r.returncode, "stderr": r.stderr[-500:]}

    registry.update_status(job["id"], "cancelled", notes="stopped via job_stop tool")
    out["new_status"] = "cancelled"

    # §25.3.1 audit row (success path only; failures stay silent per §25.3).
    actor = os.environ.get("USER") or os.environ.get("LOGNAME") or "unknown"
    audit.record_event(
        actor=actor,
        tool="job_stop@1.1.0",
        action="cancel",
        summary=f"stopped job {job['id']} ({job['tool_name']}) at {job['work_dir']}",
        target_kind="job",
        target_id=str(job["id"]),
        detail={
            "tool_name": job["tool_name"],
            "work_dir": job["work_dir"],
            "slurm_job_ids": job.get("slurm_job_ids") or [],
            "previous_status": job.get("status"),
        },
    )

    print(json.dumps(out, ensure_ascii=False, default=str))

try: main()
except Exception as e: fail(f"{type(e).__name__}: {e}")
PY
