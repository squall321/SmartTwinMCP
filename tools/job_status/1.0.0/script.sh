#!/usr/bin/env bash
set -euo pipefail
export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"
python3 - <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["SHARED_DIR"])
import registry
from job_helpers import resolve_job, run_koochainrun, slurm_queue_for, fail

def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])
    job = resolve_job(args)
    if not job:
        fail("Job not found in registry.")
    out = {"ok": True, "job_id": job["id"], "tool": job["tool_name"],
           "work_dir": job["work_dir"], "output_dir": job["output_dir"]}

    slurm_ids = job.get("slurm_job_ids") or []
    if job.get("sphere_job_id"):
        slurm_ids = list(slurm_ids) + [job["sphere_job_id"]]
    out["squeue"] = slurm_queue_for(slurm_ids) if slurm_ids else {}

    # KooChainRun status (only for tools that use KooChainRun)
    rc_path = job.get("runner_config_path")
    if rc_path and os.path.exists(rc_path):
        rc, so, se = run_koochainrun("status", rc_path, timeout=30)
        out["koochainrun_status"] = {"rc": rc, "stdout": so[-2000:], "stderr": se[-500:]}

    print(json.dumps(out, ensure_ascii=False, default=str))

try: main()
except Exception as e: fail(f"{type(e).__name__}: {e}")
PY
