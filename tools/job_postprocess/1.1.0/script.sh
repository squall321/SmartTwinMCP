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
    mode = args.get("mode", "all")
    job = resolve_job(args)
    if not job:
        fail("Job not found in registry.")
    if job["tool_name"] not in ("single_drop_simulation", "fullangle_drop_simulation"):
        fail(f"job_postprocess only supports KooChainRun-based jobs. Got: {job['tool_name']}")
    rc_path = job.get("runner_config_path")
    if not rc_path or not os.path.exists(rc_path):
        fail(f"runner_config.json missing: {rc_path}")

    flag = "--" + mode
    rc, so, se = run_koochainrun("postprocess", rc_path, flag, timeout=7200)
    out = {
        "ok": rc == 0, "job_id": job["id"], "work_dir": job["work_dir"],
        "output_dir": job["output_dir"], "mode": mode,
        "koochainrun_postprocess": {"rc": rc, "stdout": so[-3000:], "stderr": se[-500:]},
    }
    if mode in ("all", "sphere"):
        out["sphere_report_path"] = os.path.join(job["output_dir"], "sphere_report.html")
    if rc == 0:
        # §25.3.1 audit row (success path only; failures stay silent per §25.3).
        # action="pipeline_step" — §25.2 entry for running a downstream step
        # on an existing job (vs `submit` which is for brand-new jobs).
        actor = os.environ.get("USER") or os.environ.get("LOGNAME") or "unknown"
        audit.record_event(
            actor=actor,
            tool="job_postprocess@1.1.0",
            action="pipeline_step",
            summary=f"postprocess ({mode}) for job {job['id']} ({job['tool_name']}) at {job['work_dir']}",
            target_kind="job",
            target_id=str(job["id"]),
            detail={
                "tool_name": job["tool_name"],
                "mode": mode,
                "output_dir": job["output_dir"],
                "rc": rc,
            },
        )
    print(json.dumps(out, ensure_ascii=False, default=str))

try: main()
except Exception as e: fail(f"{type(e).__name__}: {e}")
PY
