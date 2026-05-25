#!/usr/bin/env python3
"""Slurm partition discovery + auto-tune nodes/jobs_per_node from sinfo.

Partition-name-agnostic: no hardcoded names. Selection by:
  - state (idle/mixed/allocated allowed, others excluded)
  - Gres (GPU partitions auto-excluded — our LS-DYNA SIF is CPU-only)
  - score = idle_nodes*100 + cpus_per_node + default_bonus(10)
  - user filter via env STMC_PARTITION_EXCLUDE="name1,name2,..."

API:
  discover_partitions() → list[PartitionInfo]
  select_partition(user_partition=None) → SelectionResult
  auto_tune_submit(num_angles, user_partition=None, user_ncpu=None) → TuneResult

All return dicts (JSON-friendly) — no dataclass to keep dependencies zero.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
from typing import Any


SINFO_FMT = "%P|%D|%T|%C|%m|%a|%G"   # partition(default marked *)|nodes|state|cpus(A/I/O/T)|mem|avail|gres
USABLE_STATES = {"idle", "mixed", "allocated"}
FALLBACK_NODES = 2
FALLBACK_JOBS_PER_NODE = 4


def _parse_sinfo() -> list[dict]:
    """Run sinfo, parse each row. Returns list of dicts (one per partition row).

    A single partition can appear in multiple rows when nodes are in different states
    — caller aggregates by partition name.
    """
    if not shutil.which("sinfo"):
        return []
    try:
        r = subprocess.run(
            ["sinfo", "-h", "-o", SINFO_FMT],
            capture_output=True, text=True, timeout=10, check=True,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return []

    out = []
    for line in r.stdout.strip().splitlines():
        parts = line.split("|")
        if len(parts) < 7:
            continue
        name_raw, nodes_s, state, cpus_aiot, mem, avail, gres = parts
        # name might end with * to mark default partition
        is_default = name_raw.endswith("*")
        name = name_raw.rstrip("*")
        # state may end with * (e.g. unknown*) — strip
        state_clean = state.rstrip("*").lower()
        # cpus format: Allocated/Idle/Other/Total
        cpu_parts = cpus_aiot.split("/")
        cpus_idle = int(cpu_parts[1]) if len(cpu_parts) >= 2 and cpu_parts[1].isdigit() else 0
        cpus_total = int(cpu_parts[3]) if len(cpu_parts) >= 4 and cpu_parts[3].isdigit() else 0
        try:
            nodes = int(nodes_s)
        except ValueError:
            nodes = 0
        cpus_per_node = (cpus_total // nodes) if nodes else 0
        out.append({
            "name": name,
            "is_default": is_default,
            "nodes": nodes,
            "state": state_clean,
            "cpus_idle": cpus_idle,
            "cpus_total": cpus_total,
            "cpus_per_node": cpus_per_node,
            "memory_mb": mem.rstrip("+"),
            "avail": avail.lower(),
            "gres": gres,
        })
    return out


def _aggregate_by_partition(rows: list[dict]) -> dict[str, dict]:
    """Same partition may have multiple state rows (e.g. some idle, some down).
    Sum nodes per state, keep partition-level constants (gres/default/avail).
    """
    by_name: dict[str, dict] = {}
    for r in rows:
        nm = r["name"]
        if nm not in by_name:
            by_name[nm] = {
                "name": nm,
                "is_default": r["is_default"],
                "avail": r["avail"],
                "gres": r["gres"],
                "cpus_per_node": r["cpus_per_node"],
                "states": {},        # state -> nodes
                "total_nodes": 0,
                "idle_nodes": 0,
            }
        agg = by_name[nm]
        agg["states"][r["state"]] = agg["states"].get(r["state"], 0) + r["nodes"]
        agg["total_nodes"] += r["nodes"]
        if r["state"] in USABLE_STATES:
            agg["idle_nodes"] += r["nodes"]
        # keep highest cpus_per_node across rows (some rows may have 0 if state was wonky)
        if r["cpus_per_node"] > agg["cpus_per_node"]:
            agg["cpus_per_node"] = r["cpus_per_node"]
        # default flag: any row marked default wins
        if r["is_default"]:
            agg["is_default"] = True
    return by_name


def _user_excluded() -> set[str]:
    """STMC_PARTITION_EXCLUDE='name1,name2' env var → set."""
    raw = os.environ.get("STMC_PARTITION_EXCLUDE", "").strip()
    if not raw:
        return set()
    return {x.strip() for x in raw.split(",") if x.strip()}


def discover_partitions() -> dict:
    """Full sinfo snapshot, parsed + aggregated. Always safe to call."""
    rows = _parse_sinfo()
    if not rows:
        return {"sinfo_available": False, "partitions": {}}
    return {"sinfo_available": True, "partitions": _aggregate_by_partition(rows)}


def select_partition(user_partition: str | None = None) -> dict:
    """Return {selected, candidates, excluded, sinfo_available}.

    user_partition:
      - None → auto-select (highest score)
      - "list" → return discovery only (caller decides not to submit)
      - "<name>" → use that partition explicitly (validated against sinfo)
    """
    disc = discover_partitions()
    result: dict[str, Any] = {
        "sinfo_available": disc["sinfo_available"],
        "user_partition": user_partition,
        "selected": None,
        "candidates": [],
        "excluded": [],
        "discovery_only": False,
    }

    if not disc["sinfo_available"]:
        result["error"] = "sinfo not available — will fall back to KooChainRun defaults"
        return result

    by_name = disc["partitions"]
    excluded_by_user = _user_excluded()
    result["user_exclude_list"] = sorted(excluded_by_user)

    # discovery-only mode
    if user_partition == "list":
        result["discovery_only"] = True
        result["all_partitions"] = list(by_name.values())
        return result

    # explicit user choice
    if user_partition:
        if user_partition not in by_name:
            result["error"] = f"Partition '{user_partition}' not found. Available: {sorted(by_name.keys())}"
            return result
        chosen = by_name[user_partition]
        # warn but allow even if state weird / GPU partition
        warnings = []
        if chosen["idle_nodes"] == 0:
            warnings.append(f"no idle nodes (states={chosen['states']})")
        if "gpu" in chosen["gres"].lower():
            warnings.append("GPU partition (Gres contains 'gpu') — ensure your SIF supports GPU")
        if chosen["avail"] != "up":
            warnings.append(f"avail={chosen['avail']}")
        result["selected"] = chosen
        result["selected_reason"] = f"user-specified partition '{user_partition}'"
        result["warnings"] = warnings
        return result

    # auto-select: filter then score
    for nm, info in by_name.items():
        if info["avail"] != "up":
            result["excluded"].append({"name": nm, "reason": f"avail={info['avail']}"})
            continue
        if info["idle_nodes"] == 0:
            result["excluded"].append({"name": nm, "reason": f"no idle nodes (states={info['states']})"})
            continue
        if "gpu" in info["gres"].lower():
            result["excluded"].append({"name": nm, "reason": f"GPU partition (gres={info['gres']}) — auto-excluded"})
            continue
        if nm in excluded_by_user:
            result["excluded"].append({"name": nm, "reason": "in STMC_PARTITION_EXCLUDE env var"})
            continue
        score = info["idle_nodes"] * 100 + info["cpus_per_node"]
        if info["is_default"]:
            score += 10
        candidate = {**info, "score": score}
        result["candidates"].append(candidate)

    if not result["candidates"]:
        result["error"] = "no usable partitions found after filtering"
        return result

    result["candidates"].sort(key=lambda x: (-x["score"], x["name"]))
    result["selected"] = result["candidates"][0]
    sel = result["selected"]
    bonus = " + default_bonus(10)" if sel["is_default"] else ""
    result["selected_reason"] = (
        f"highest score: idle_nodes({sel['idle_nodes']})*100 "
        f"+ cpus_per_node({sel['cpus_per_node']}){bonus} = {sel['score']}"
    )
    return result


def auto_tune_submit(
    num_angles: int,
    user_partition: str | None = None,
    user_ncpu: int | None = None,
) -> dict:
    """Compute (nodes, jobs_per_node, ncpu_per_job, partition) from sinfo.

    Returns dict with keys:
      applied: bool — whether auto-tune produced concrete numbers
      nodes, jobs_per_node, ncpu_per_job, partition
      partition_discovery: full select_partition output (transparency)
      reason: human-readable summary
      fallback_used: bool — true if sinfo failed
    """
    sel = select_partition(user_partition)
    out: dict[str, Any] = {
        "applied": False,
        "partition_discovery": sel,
        "fallback_used": False,
    }

    # discovery-only request short-circuits — caller asks for "list" not real submission
    if sel.get("discovery_only"):
        out["reason"] = "partition=list — discovery only, no submission tune"
        return out

    # sinfo failure → KooChainRun defaults
    if not sel["sinfo_available"] or sel.get("error") or not sel.get("selected"):
        out["fallback_used"] = True
        out["nodes"] = FALLBACK_NODES
        out["jobs_per_node"] = FALLBACK_JOBS_PER_NODE
        out["ncpu_per_job"] = user_ncpu or 1
        out["partition"] = user_partition  # may be None — KooChainRun will use its default
        out["reason"] = sel.get("error") or "sinfo not available — using KooChainRun defaults"
        return out

    chosen = sel["selected"]
    pname = chosen["name"]
    nodes_avail = chosen["idle_nodes"]
    cpus_per_node = max(1, chosen["cpus_per_node"])
    ncpu_per_job = user_ncpu or 1

    # cap ncpu_per_job to cpus_per_node (Slurm rejects otherwise)
    if ncpu_per_job > cpus_per_node:
        out["warning_ncpu_capped"] = (
            f"requested ncpu_per_job={ncpu_per_job} > cpus_per_node={cpus_per_node}, "
            f"capping to {cpus_per_node}"
        )
        ncpu_per_job = cpus_per_node

    max_jobs_per_node = max(1, cpus_per_node // ncpu_per_job)
    max_parallel = nodes_avail * max_jobs_per_node

    if num_angles <= 1:
        nodes = 1
        jobs_per_node = 1
    elif num_angles <= max_parallel:
        # fit all angles in parallel — distribute evenly
        nodes = min(nodes_avail, num_angles)
        jobs_per_node = max(1, -(-num_angles // nodes))   # ceil
        jobs_per_node = min(jobs_per_node, max_jobs_per_node)
    else:
        # more angles than slots — use full capacity, queue the rest
        nodes = nodes_avail
        jobs_per_node = max_jobs_per_node

    out["applied"] = True
    out["nodes"] = nodes
    out["jobs_per_node"] = jobs_per_node
    out["ncpu_per_job"] = ncpu_per_job
    out["partition"] = pname
    out["reason"] = (
        f"partition={pname}: {nodes_avail} idle nodes × {cpus_per_node} cpus "
        f"= {max_parallel} parallel slots. {num_angles} angles → "
        f"nodes={nodes}, jobs_per_node={jobs_per_node}, ncpu_per_job={ncpu_per_job}"
        + (" (will queue)" if num_angles > max_parallel else "")
    )
    return out


if __name__ == "__main__":
    import json, sys
    if len(sys.argv) > 1 and sys.argv[1] == "discover":
        print(json.dumps(select_partition(), indent=2, default=str))
    elif len(sys.argv) > 1 and sys.argv[1] == "list":
        print(json.dumps(select_partition("list"), indent=2, default=str))
    else:
        n = int(sys.argv[1]) if len(sys.argv) > 1 else 5
        up = sys.argv[2] if len(sys.argv) > 2 else None
        print(json.dumps(auto_tune_submit(n, user_partition=up), indent=2, default=str))
