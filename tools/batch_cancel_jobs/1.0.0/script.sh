#!/usr/bin/env bash
# batch_cancel_jobs — cancel many jobs by filter (mode: own, dry_run default true)
set -euo pipefail
export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import json, os, sys, subprocess

sys.path.insert(0, os.environ["SHARED_DIR"])
import registry
import job_helpers

MAX_BATCH = 100

def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])

    caller = os.environ.get("USER") or os.environ.get("LOGNAME")
    if not caller:
        job_helpers.fail("cannot determine caller identity (USER/LOGNAME unset)")

    dry_run = bool(args.get("dry_run", True))

    # --- collect candidate jobs, ALWAYS filtered by user = caller first ---
    if "registry_ids" in args:
        # explicit-id path. Look each up; skip rows owned by other users (don't fail —
        # the user may have passed a mixed list and only own a subset).
        candidates = []
        skipped_not_owner = 0
        missing = []
        for rid in args["registry_ids"]:
            row = registry.get_by_id(int(rid))
            if row is None:
                missing.append(rid)
                continue
            if row.get("user") != caller:
                skipped_not_owner += 1
                continue
            candidates.append(row)
    else:
        # filter path. Use SQL filters from registry.list_recent where possible.
        skipped_not_owner = 0  # SQL filter already excludes other users
        missing = []
        submitted_before = args.get("submitted_before")
        # If submitted_before is set, we post-filter — fetch a wider pool so we
        # can still detect "> MAX_BATCH" matches accurately.
        fetch_limit = (MAX_BATCH * 5 + 1) if submitted_before is not None else (MAX_BATCH + 1)
        candidates = registry.list_recent(
            limit=fetch_limit,
            user=caller,
            status=args.get("status"),
            tool=args.get("tool_name"),
            project_like=args.get("project_like"),
        )
        if submitted_before is not None:
            candidates = [c for c in candidates if (c.get("submitted_at") or 0) < int(submitted_before)]

    # --- enforce hard batch cap on the FINAL matched count ---
    if len(candidates) > MAX_BATCH:
        job_helpers.fail(
            f"batch too large: {len(candidates)} matches > MAX_BATCH={MAX_BATCH}. "
            f"Narrow your filter (e.g. submitted_before, project_like) or chunk the request.",
            matched=len(candidates),
            max_batch=MAX_BATCH,
        )

    def summarize(row):
        return {
            "registry_id": row["id"],
            "tool_name": row.get("tool_name"),
            "project_name": row.get("project_name"),
            "work_dir": row.get("work_dir"),
            "slurm_job_ids": row.get("slurm_job_ids") or [],
            "status": row.get("status"),
            "user": row.get("user"),
        }

    out = {
        "ok": True,
        "tool": "batch_cancel_jobs",
        "dry_run": dry_run,
        "would_cancel": [],
        "cancelled": [],
        "failures": [],
    }

    if dry_run:
        out["would_cancel"] = [summarize(r) for r in candidates]
    else:
        for row in candidates:
            slurm_ids = row.get("slurm_job_ids") or []
            entry = summarize(row)
            if not slurm_ids:
                # No Slurm IDs recorded → mark cancelled in registry only.
                registry.update_status(row["id"], "cancelled",
                                       notes="cancelled via batch_cancel_jobs (no slurm ids)")
                out["cancelled"].append(entry)
                continue
            try:
                r = subprocess.run(
                    ["scancel"] + [str(s) for s in slurm_ids],
                    capture_output=True, text=True, timeout=30,
                )
            except FileNotFoundError:
                entry["reason"] = "scancel not found on PATH"
                out["failures"].append(entry)
                continue
            except subprocess.TimeoutExpired:
                entry["reason"] = "scancel timed out after 30s"
                out["failures"].append(entry)
                continue
            if r.returncode == 0:
                registry.update_status(row["id"], "cancelled",
                                       notes="cancelled via batch_cancel_jobs")
                entry["scancel_stderr"] = (r.stderr or "")[-200:]
                out["cancelled"].append(entry)
            else:
                entry["reason"] = f"scancel rc={r.returncode}"
                entry["scancel_stderr"] = (r.stderr or "")[-500:]
                out["failures"].append(entry)

    out["summary"] = {
        "matched": len(candidates),
        "cancelled": len(out["cancelled"]),
        "failed": len(out["failures"]),
        "skipped_not_owner": skipped_not_owner,
    }
    if missing:
        out["summary"]["missing_registry_ids"] = missing

    print(json.dumps(out, ensure_ascii=False, default=str))

try:
    main()
except SystemExit:
    raise
except Exception as e:
    job_helpers.fail(f"{type(e).__name__}: {e}")
PY
