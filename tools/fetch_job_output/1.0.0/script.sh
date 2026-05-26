#!/usr/bin/env bash
# fetch_job_output — move a completed job's output files off the cluster (§23).
set -euo pipefail

export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import glob as _glob
import json
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.environ["SHARED_DIR"])
import job_helpers
from job_helpers import fail, resolve_job


def _expand_globs(output_dir: str, globs: list[str]) -> list[str]:
    """Expand each glob pattern relative to output_dir, return matched absolute file paths.

    We use Python's glob (not subprocess find) because it's hermetic, handles
    nested patterns identically across systems, and avoids quoting headaches
    when a pattern contains '*'. Result is sorted + de-duplicated.
    """
    seen: set[str] = set()
    out: list[str] = []
    for pat in globs:
        # Match files only (skip directories) at output_dir/<pat>.
        # Globs are intended as filename patterns — no recursive ** by default
        # (matches §23.2's "Filename globs relative to output_dir").
        for path in _glob.glob(os.path.join(output_dir, pat)):
            if path in seen:
                continue
            if os.path.isfile(path):
                seen.add(path)
                out.append(path)
    out.sort()
    return out


def main() -> None:
    args = json.loads(os.environ["STMC_ARGS_JSON"])

    # §18: identity is always $USER, never an arg.
    caller = os.environ.get("USER") or os.environ.get("LOGNAME")
    if not caller:
        fail("cannot determine caller identity (USER/LOGNAME unset)")

    # §3.4: lookup by registry_id OR work_dir.
    job = resolve_job(args)
    if not job:
        fail("job not found", lookup={k: args[k] for k in ("registry_id", "work_dir") if k in args})

    # §18.2 mode: own — refuse foreign rows.
    if job.get("user") != caller:
        fail(
            "permission denied: job belongs to another user",
            job_owner=job.get("user"),
            caller=caller,
        )

    output_dir = job.get("output_dir") or job.get("work_dir")
    if not output_dir or not os.path.isdir(output_dir):
        fail("output_dir missing on disk", output_dir=output_dir, registry_id=job["id"])

    # Defaults from schema — re-applied here because `bash script.sh` skips
    # JSON Schema validation (§7 note in the guide).
    globs: list[str] = list(args.get("files") or ["d3plot*"])
    max_total_bytes: int = int(args.get("max_total_bytes", 53687091200))
    destination: str | None = args.get("destination")

    if destination is None:
        fail(
            "`destination` is required (one of: local, rsync, presigned_url)",
            registry_id=job["id"],
        )
    if destination not in ("local", "rsync", "presigned_url"):
        fail(f"invalid destination: {destination!r}", registry_id=job["id"])

    # §23.3 pre-transfer size check — runs for EVERY destination so the cap
    # is enforced uniformly (local just verifies but still benefits from the
    # safety rail of refusing pathological globs).
    matched = _expand_globs(output_dir, globs)
    if not matched:
        fail(
            "no files matched the requested globs",
            output_dir=output_dir,
            globs=globs,
            registry_id=job["id"],
        )
    total = sum(os.path.getsize(p) for p in matched)
    if total > max_total_bytes:
        fail(
            f"transfer would exceed cap: {total} > {max_total_bytes}. "
            f"Narrow `files` or raise max_total_bytes.",
            total=total,
            cap=max_total_bytes,
            file_count=len(matched),
            registry_id=job["id"],
        )

    response: dict = {
        "ok": True,
        "tool": "fetch_job_output",
        "registry_id": job["id"],
        "owner": job.get("user"),
        "destination": destination,
        "output_dir": output_dir,
    }

    if destination == "local":
        # §23.4: return paths, no copy. Re-verify each file exists at print
        # time in case something raced between sizing and reporting.
        for p in matched:
            if not os.path.isfile(p):
                fail("file vanished between size check and reporting", path=p)
        response["paths"] = matched
        response["files_transferred"] = len(matched)
        response["bytes_transferred"] = total
        print(json.dumps(response, ensure_ascii=False))
        return

    if destination == "presigned_url":
        # §23.1: sidecar required, not deployed. Return ok:false cleanly.
        print(json.dumps({
            "ok": False,
            "tool": "fetch_job_output",
            "registry_id": job["id"],
            "owner": job.get("user"),
            "destination": destination,
            "reason": "presigned_url destination requires the storage sidecar — not deployed yet",
        }, ensure_ascii=False))
        sys.exit(1)

    # destination == "rsync"
    rsync_target = args.get("rsync_target")
    if not rsync_target:
        fail("rsync_target is required when destination=rsync", registry_id=job["id"])
    if shutil.which("rsync") is None:
        fail("rsync not found on PATH", registry_id=job["id"])

    # For local rsync_target (no host:), make sure the parent exists. rsync
    # will create the target dir itself if asked with a trailing /, but
    # creating a missing parent dir is friendlier and removes one common
    # failure mode. Skip for remote targets (we can't probe them locally).
    if ":" not in rsync_target.split("/", 1)[0]:
        os.makedirs(rsync_target, exist_ok=True)

    cmd = ["rsync", "-av", "--partial", "--progress", *matched, rsync_target]
    started = time.time()
    try:
        # Use the meta.yaml timeout_sec as the outer bound; keep this a bit
        # under it so we surface a clean Python error instead of being killed
        # by the runner. 3500s vs 3600s gives the JSON envelope a chance.
        r = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=3500,
            check=False,
        )
    except subprocess.TimeoutExpired as e:
        fail(
            f"rsync timed out after {e.timeout}s",
            registry_id=job["id"],
            cmd=cmd[:4] + ["...", rsync_target],
        )
    duration = time.time() - started

    log_lines = (r.stdout or "").splitlines()
    log_tail = "\n".join(log_lines[-20:])

    if r.returncode != 0:
        print(json.dumps({
            "ok": False,
            "tool": "fetch_job_output",
            "registry_id": job["id"],
            "owner": job.get("user"),
            "destination": destination,
            "rsync_target": rsync_target,
            "reason": f"rsync failed with rc={r.returncode}",
            "rsync_log_tail": log_tail,
            "rsync_stderr_tail": (r.stderr or "")[-500:],
            "duration_sec": round(duration, 2),
        }, ensure_ascii=False))
        sys.exit(1)

    response.update({
        "rsync_target": rsync_target,
        "files_transferred": len(matched),
        "bytes_transferred": total,
        "duration_sec": round(duration, 2),
        "rsync_log_tail": log_tail,
    })
    print(json.dumps(response, ensure_ascii=False))


try:
    main()
except SystemExit:
    raise
except Exception as e:  # noqa: BLE001
    fail(f"{type(e).__name__}: {e}")
PY
