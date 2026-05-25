#!/usr/bin/env bash
# list_slurm_partitions — sinfo wrapper returning structured per-partition summary.
# §21 (Slurm topology / partition status). mode: read-all, no caching.
set -euo pipefail

python3 - <<'PY'
import json
import os
import re
import subprocess
import sys


def fail(reason, **extra):
    print(json.dumps({"ok": False, "reason": reason, **extra}, ensure_ascii=False))
    sys.exit(1)


def run_slurm(*cmd_args, timeout=15):
    # §21.2 wrapper pattern.
    try:
        r = subprocess.run(
            list(cmd_args),
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError:
        fail(f"{cmd_args[0]} not on PATH — Slurm client not installed?")
    except subprocess.TimeoutExpired:
        fail(f"{cmd_args[0]} timed out after {timeout}s")
    if r.returncode != 0:
        fail(
            f"{cmd_args[0]} failed",
            rc=r.returncode,
            stderr=r.stderr[-500:],
        )
    return r.stdout


def classify_state(raw_state: str) -> str:
    """Bucket a sinfo %T value into idle/mixed/allocated/down.

    Slurm appends * (unreachable) / ~ (power saving) / # (powering up) etc.
    to base states. Strip non-alpha trailing chars before matching.
    """
    s = re.sub(r"[^a-z]+$", "", raw_state.strip().lower())
    if s in ("idle",):
        return "idle"
    if s in ("mixed",):
        return "mixed"
    if s in ("allocated", "alloc", "completing"):
        return "allocated"
    # down, drain, drained, draining, fail, failing, maint, reserved,
    # planned, power_down, powered_down, unknown, etc. all roll up to "down"
    # for the purpose of "is this node usable now?".
    return "down"


def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])
    partition_filter = args.get("partition_filter")
    include_down = bool(args.get("include_down", True))

    # §21.2: exact format string. -h drops the header row.
    fmt = "%P|%a|%l|%D|%T|%C|%G"
    out = run_slurm("sinfo", "-h", f"--format={fmt}")

    # Aggregate per partition: a partition can have multiple rows, one per
    # (state-group). We sum nodes_total and the per-bucket counters.
    parts: dict[str, dict] = {}

    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        cols = line.split("|")
        if len(cols) < 7:
            # Malformed row — skip rather than fail the whole call.
            continue
        raw_name, avail, timelimit, nodes_s, state, _cpus, gres = cols[:7]

        # Slurm marks the default partition with a trailing '*'.
        name = raw_name.rstrip("*")
        if not name:
            continue
        if partition_filter is not None and name != partition_filter:
            continue

        try:
            nodes = int(nodes_s)
        except ValueError:
            nodes = 0

        bucket = classify_state(state)

        p = parts.setdefault(
            name,
            {
                "name": name,
                "state": avail.strip() or "unknown",
                "default_time_limit": timelimit.strip() or None,
                "nodes_total": 0,
                "nodes_idle": 0,
                "nodes_mixed": 0,
                "nodes_allocated": 0,
                "nodes_down": 0,
                "gres_summary": None,
            },
        )
        p["nodes_total"] += nodes
        p[f"nodes_{bucket}"] += nodes

        # GRES: pick the first non-empty / non-"(null)" we see for the partition.
        if p["gres_summary"] in (None, "(null)"):
            g = gres.strip()
            if g and g != "(null)":
                p["gres_summary"] = g

    partitions = list(parts.values())

    if not include_down:
        partitions = [
            p for p in partitions
            if not (p["nodes_total"] > 0 and p["nodes_total"] == p["nodes_down"])
        ]

    # Stable ordering: keep sinfo's order (insertion order of dict).
    print(json.dumps(
        {
            "ok": True,
            "tool": "list_slurm_partitions",
            "partitions": partitions,
        },
        ensure_ascii=False,
    ))


if __name__ == "__main__":
    main()
PY
