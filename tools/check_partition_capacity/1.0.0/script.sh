#!/usr/bin/env bash
# check_partition_capacity — sinfo+squeue verdict whether request fits now.
# AGENT_GUIDE.md §21.1, §21.3. mode: read-all (§18.2).
set -euo pipefail

python3 - <<'PY'
import json
import os
import re
import subprocess
import sys


def fail(reason, **extra):
    print(json.dumps({"ok": False, "tool": "check_partition_capacity",
                      "reason": reason, **extra}, ensure_ascii=False))
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
    """Bucket sinfo %T into idle/mixed/allocated/down (§21.3 mapping table).
    Strip trailing modifier chars (* ~ # % $ @) per §21.3.
    """
    s = re.sub(r"[^a-z]+$", "", raw_state.strip().lower())
    if s == "idle":
        return "idle"
    if s == "mixed":
        return "mixed"
    if s in ("allocated", "alloc", "completing"):
        return "allocated"
    return "down"


def parse_cpus_state(cpus_field: str) -> tuple[int, int]:
    """sinfo %C is A/I/O/T = Allocated/Idle/Other/Total. Return (idle, total)."""
    parts = cpus_field.split("/")
    if len(parts) != 4:
        return 0, 0
    try:
        _alloc, idle, _other, total = (int(p) for p in parts)
    except ValueError:
        return 0, 0
    return idle, total


def parse_gres_gpu_count(gres: str) -> int:
    """Extract a TOTAL GPU count from a sinfo %G string.
    Examples: 'gpu:a100:8', 'gpu:8', 'gpu:a100:8,nvme:1', '(null)'.
    Returns 0 if no gpu line.
    """
    if not gres or gres == "(null)":
        return 0
    total = 0
    for item in gres.split(","):
        item = item.strip()
        if not item.startswith("gpu"):
            continue
        # gpu:type:N OR gpu:N
        parts = item.split(":")
        if len(parts) < 2:
            continue
        # Last numeric token (could have a (S:0-...) suffix in some Slurms — strip it).
        last = parts[-1]
        last = re.sub(r"\(.*\)$", "", last)
        try:
            total += int(last)
        except ValueError:
            continue
    return total


def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])
    partition = args["partition"]
    gpus_req = int(args.get("gpus", 0))
    nodes_req = int(args.get("nodes", 1))
    cpus_req = int(args.get("cpus_per_node", 1))

    # sinfo: one row per node in the partition, with idle-aware CPU and GRES.
    # %n = node hostname, %T = state, %C = A/I/O/T cpus, %G = gres
    fmt = "%n|%T|%C|%G"
    out = run_slurm("sinfo", "-h", "-p", partition, "-N",
                    f"--format={fmt}")

    candidates = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        cols = line.split("|")
        if len(cols) < 4:
            continue
        node, state, cpus_field, gres = cols[:4]
        bucket = classify_state(state)
        if bucket not in ("idle", "mixed"):
            continue
        free_cpus, total_cpus = parse_cpus_state(cpus_field)
        # GRES is "total per node"; we don't know live free-GPU from sinfo alone.
        # Best-effort: assume idle nodes have all GPUs free; mixed nodes treat
        # as conservatively 0 (we can't tell without `scontrol show node`).
        total_gpus = parse_gres_gpu_count(gres)
        if bucket == "idle":
            free_gpus = total_gpus
        else:
            # MIXED: be conservative. Some GPUs may be allocated.
            free_gpus = 0
        if free_cpus < cpus_req:
            continue
        if free_gpus < gpus_req:
            continue
        candidates.append({
            "node": node,
            "free_gpus": free_gpus,
            "free_cpus": free_cpus,
        })

    available_now = len(candidates) >= nodes_req

    # squeue queue depth for the partition.
    sq_out = run_slurm("squeue", "-h", "-p", partition, "--format=%i")
    queue_depth = sum(1 for line in sq_out.splitlines() if line.strip())

    # Single-line natural-language verdict.
    if available_now:
        hint = (
            f"{len(candidates)} node(s) have the requested resources "
            f"({gpus_req} GPU + {cpus_req} CPU each) free now. "
            f"Expected start: immediate."
        )
    elif candidates:
        hint = (
            f"Only {len(candidates)} of {nodes_req} required nodes are free. "
            f"Job will queue (current queue depth: {queue_depth})."
        )
    else:
        hint = (
            f"No nodes in '{partition}' currently satisfy "
            f"{gpus_req} GPU + {cpus_req} CPU per node. "
            f"Job will queue (current queue depth: {queue_depth})."
        )

    print(json.dumps({
        "ok": True,
        "tool": "check_partition_capacity",
        "request": {
            "partition": partition,
            "gpus": gpus_req,
            "nodes": nodes_req,
            "cpus_per_node": cpus_req,
        },
        "available_now": available_now,
        "candidates": candidates,
        "queue_depth": queue_depth,
        "hint": hint,
    }, ensure_ascii=False))


try:
    main()
except SystemExit:
    raise
except Exception as e:
    fail(f"{type(e).__name__}: {e}")
PY
