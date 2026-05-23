#!/usr/bin/env bash
# get_job_details — single job + disk state
set -euo pipefail

export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import json, os, sys, datetime, glob

sys.path.insert(0, os.environ["SHARED_DIR"])
import registry


def fail(reason):
    print(json.dumps({"ok": False, "reason": reason}))
    sys.exit(1)


def disk_state(job: dict) -> dict:
    """Check what's actually on disk for this job."""
    wd = job.get("work_dir")
    od = job.get("output_dir")
    rc = job.get("runner_config_path")
    state = {
        "work_dir_exists": bool(wd) and os.path.isdir(wd),
        "output_dir_exists": bool(od) and os.path.isdir(od),
        "scenario_json_exists": bool(wd) and os.path.exists(os.path.join(wd, "scenario.json")),
        "runner_config_exists": bool(rc) and os.path.exists(rc),
    }
    if state["output_dir_exists"]:
        run_dirs = glob.glob(os.path.join(od, "Run_*"))
        state["num_run_dirs"] = len(run_dirs)
        state["sphere_report_html_exists"] = os.path.exists(os.path.join(od, "sphere_report.html"))
        state["sphere_report_json_exists"] = os.path.exists(os.path.join(od, "sphere_report.json"))
        # count d3plot files (1 per finished sim, roughly)
        d3plots = glob.glob(os.path.join(od, "Run_*", "Output", "d3plot"))
        state["num_finished_d3plot"] = len(d3plots)
        report_dirs = glob.glob(os.path.join(od, "Run_*", "Output", "report"))
        state["num_deep_reports"] = len(report_dirs)
    return state


def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])

    job = None
    if "registry_id" in args:
        job = registry.get_by_id(int(args["registry_id"]))
    elif "work_dir" in args:
        rows = registry.list_recent(limit=1)  # we'll filter manually
        wd = args["work_dir"].rstrip("/")
        rows = [r for r in registry.list_recent(limit=500) if r.get("work_dir", "").rstrip("/") == wd]
        if rows:
            job = rows[0]

    if not job:
        fail("Job not found in registry. Try list_recent_jobs to see what's available.")

    ts = job.get("submitted_at")
    if ts:
        job["submitted_at_human"] = datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")

    job["disk_state"] = disk_state(job)

    print(json.dumps({"ok": True, "job": job}, ensure_ascii=False, default=str))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        fail(f"{type(e).__name__}: {e}")
PY
