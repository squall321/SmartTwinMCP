#!/usr/bin/env bash
set -euo pipefail
export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"
python3 - <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["SHARED_DIR"])
from job_helpers import resolve_job, run_koochainrun, fail

def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])
    job = resolve_job(args)
    if not job:
        fail("Job not found in registry.")
    if job["tool_name"] not in ("single_drop_simulation", "fullangle_drop_simulation"):
        fail(f"job_collect only supports KooChainRun-based jobs. Got: {job['tool_name']}")
    rc_path = job.get("runner_config_path")
    if not rc_path or not os.path.exists(rc_path):
        fail(f"runner_config.json missing: {rc_path}")

    rc, so, se = run_koochainrun("collect", rc_path, timeout=300)
    print(json.dumps({
        "ok": rc == 0, "job_id": job["id"], "work_dir": job["work_dir"],
        "output_dir": job["output_dir"],
        "koochainrun_collect": {"rc": rc, "stdout": so[-3000:], "stderr": se[-500:]},
    }, ensure_ascii=False, default=str))

try: main()
except Exception as e: fail(f"{type(e).__name__}: {e}")
PY
