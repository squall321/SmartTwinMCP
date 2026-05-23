#!/usr/bin/env bash
# Placeholder: in production this calls `stcluster submit` (or sbatch).
# Reads args JSON from $STMC_ARGS_JSON, prints a JSON envelope on stdout.
set -euo pipefail

ARGS="${STMC_ARGS_JSON:-$(cat)}"

python3 - <<'PY'
import json, os, time, uuid

args = json.loads(os.environ["STMC_ARGS_JSON"])
job_id = f"stc-{uuid.uuid4().hex[:10]}"
print(json.dumps({
    "job_id": job_id,
    "case_dir": args["case_dir"],
    "solver": args["solver"],
    "partition": args.get("partition", "cpu"),
    "gpus": args.get("gpus", 0),
    "cpus": args.get("cpus", 8),
    "memory_gb": args.get("memory_gb", 32),
    "wall_time": args.get("wall_time"),
    "tags": args.get("tags", []),
    "submitted_at": int(time.time()),
    "_note": "placeholder script; replace with real cluster submit call.",
}, ensure_ascii=False))
PY
