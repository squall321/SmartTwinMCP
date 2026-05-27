#!/usr/bin/env bash
set -euo pipefail
export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"
python3 - <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["SHARED_DIR"])
import audit
from job_helpers import resolve_job, run_koochainrun, fail

def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])
    job = resolve_job(args)
    if not job:
        fail("Job not found in registry.")
    if job["tool_name"] not in ("single_drop_simulation", "fullangle_drop_simulation"):
        fail(f"job_diagnose only supports KooChainRun-based jobs. Got: {job['tool_name']}")

    rc, so, se = run_koochainrun("diagnose", job["work_dir"], timeout=60)

    # §25.3.3 inspection audit with 5-min session_seen dedup guard.
    caller = os.environ.get("USER") or os.environ.get("LOGNAME") or "unknown"
    tool_qn = "job_diagnose@1.0.0"
    target_id = str(job["id"])
    if not audit.session_seen(caller, tool_qn, target_id, within_sec=300):
        audit.record_event(
            actor=caller,
            tool=tool_qn,
            action="inspect",
            summary=f"diagnosed job {target_id} ({job['tool_name']}, diagnose rc={rc})",
            target_kind="job",
            target_id=target_id,
            detail={
                "tool_inspected": job["tool_name"],
                "diagnose_rc": rc,
            },
        )

    print(json.dumps({
        "ok": rc == 0, "job_id": job["id"], "work_dir": job["work_dir"],
        "koochainrun_diagnose": {"rc": rc, "stdout": so[-5000:], "stderr": se[-500:]},
    }, ensure_ascii=False, default=str))

try: main()
except Exception as e: fail(f"{type(e).__name__}: {e}")
PY
