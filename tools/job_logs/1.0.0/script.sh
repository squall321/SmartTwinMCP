#!/usr/bin/env bash
# job_logs — tail Slurm stdout/stderr for a registered job
set -euo pipefail

export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import json, os, sys

sys.path.insert(0, os.environ["SHARED_DIR"])
import audit
from job_helpers import resolve_job, fail


def tail_file(path: str, n: int) -> tuple[bool, str]:
    """Return (exists, tail_text). Reads file as text (errors=replace), keeps last n lines."""
    if not os.path.exists(path):
        return False, ""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            # Files can be large; read all then slice. For 5000-line cap this is fine
            # for typical Slurm logs. If logs grow huge we can switch to a seek-from-end
            # implementation later.
            lines = f.readlines()
    except OSError as e:
        return True, f"<read error: {type(e).__name__}: {e}>"
    return True, "".join(lines[-n:])


def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])
    job = resolve_job(args)
    if not job:
        fail("job not found in registry", lookup=args)

    work_dir = job.get("work_dir") or ""
    if not work_dir:
        fail("registry row has no work_dir", registry_id=job.get("id"))

    n = int(args.get("lines", 50))

    stdout_path = os.path.join(work_dir, "lsdyna.slurm.out")
    stderr_path = os.path.join(work_dir, "lsdyna.slurm.err")

    out_exists, out_tail = tail_file(stdout_path, n)
    err_exists, err_tail = tail_file(stderr_path, n)

    # §25.3.3 inspection audit with 5-min session_seen dedup guard.
    caller = os.environ.get("USER") or os.environ.get("LOGNAME") or "unknown"
    tool_qn = "job_logs@1.0.0"
    target_id = str(job["id"])
    if not audit.session_seen(caller, tool_qn, target_id, within_sec=300):
        audit.record_event(
            actor=caller,
            tool=tool_qn,
            action="inspect",
            summary=f"tailed logs for job {target_id} ({n} lines)",
            target_kind="job",
            target_id=target_id,
            detail={
                "lines": n,
                "stdout_exists": out_exists,
                "stderr_exists": err_exists,
            },
        )

    print(json.dumps({
        "ok": True,
        "tool": "job_logs",
        "registry_id": job["id"],
        "work_dir": work_dir,
        "stdout_path": stdout_path,
        "stderr_path": stderr_path,
        "stdout_exists": out_exists,
        "stderr_exists": err_exists,
        "stdout_tail": out_tail,
        "stderr_tail": err_tail,
        "lines": n,
    }, ensure_ascii=False))


try:
    main()
except SystemExit:
    raise
except Exception as e:
    fail(f"unhandled exception: {type(e).__name__}: {e}")
PY
