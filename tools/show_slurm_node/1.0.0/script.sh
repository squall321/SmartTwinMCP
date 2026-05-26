#!/usr/bin/env bash
# show_slurm_node — wrap `scontrol show node <name>` (AGENT_GUIDE.md §21.1, §21.2)
# mode: read-all (§18.2). Observability only, no mutation, no user filtering.
set -euo pipefail

python3 - <<'PY'
import json
import os
import re
import subprocess
import sys


def fail(reason, **extra):
    print(json.dumps({"ok": False, "tool": "show_slurm_node",
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


# `scontrol show node` produces space-separated key=value tokens spanning
# multiple lines. The trick is that some VALUES contain whitespace (e.g.
# "Reason=Node unresponsive [slurm@2026-05-25T10:00:00]") AND some values
# contain '=' (e.g. comments). We accept the standard Slurm format where
# tokens are separated by whitespace and each token is "Key=Value". The
# Reason field can have trailing free text; we capture it best-effort.
#
# Strategy: tokenize on whitespace, split each token on the FIRST '=' only.
# If a token has no '=' it's treated as a continuation of the previous
# value (handles the Reason free-text trailing case).
KV_RE = re.compile(r"^([A-Za-z][A-Za-z0-9_]*)=(.*)$", re.DOTALL)


def parse_scontrol_node(text: str) -> dict:
    fields: dict = {}
    last_key = None
    for raw_tok in text.split():
        m = KV_RE.match(raw_tok)
        if m:
            k, v = m.group(1), m.group(2)
            fields[k] = v
            last_key = k
        else:
            # Continuation of the previous value (e.g. Reason free text).
            if last_key is not None:
                fields[last_key] = f"{fields[last_key]} {raw_tok}"
    return fields


def parse_cpu_alloc_idle(kv: dict) -> tuple[int | None, int | None]:
    """Slurm shows `CPUAlloc=N` and `CPUTot=N` separately, but also a
    composite `CPUsLoad`/`CPUs=...`. We trust CPUAlloc and CPUTot when
    present and derive idle = total - alloc.
    """
    def to_int(s):
        try:
            return int(s)
        except (TypeError, ValueError):
            return None

    alloc = to_int(kv.get("CPUAlloc"))
    total = to_int(kv.get("CPUTot"))
    return alloc, total


def parse_jobs(kv: dict) -> list[str]:
    """JobList= or JobIDs= or Jobs= — Slurm differs across versions.
    Format is usually 'jobid,jobid,...' or 'jobid jobid ...' (space-sep).
    Empty / 'None' / '(null)' all mean no jobs.
    """
    for key in ("JobList", "JobIDs", "Jobs"):
        if key in kv:
            raw = kv[key].strip()
            if not raw or raw.lower() in ("none", "(null)"):
                return []
            # Split on common separators.
            parts = re.split(r"[,\s]+", raw)
            return [p for p in parts if p]
    return []


def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])
    node_name = args["node_name"]

    out = run_slurm("scontrol", "show", "node", node_name)
    kv = parse_scontrol_node(out)
    if not kv:
        fail("scontrol returned no parseable output",
             node_name=node_name,
             raw=out[:500])

    # Slurm uses "NodeName=..." as the canonical key.
    canonical_name = kv.get("NodeName", node_name)
    state = kv.get("State", "").strip() or None

    alloc, total = parse_cpu_alloc_idle(kv)
    idle = (total - alloc) if (alloc is not None and total is not None) else None

    def to_int(s):
        try:
            return int(s)
        except (TypeError, ValueError):
            return None

    mem_total_mb = to_int(kv.get("RealMemory"))
    mem_alloc_mb = to_int(kv.get("AllocMem"))
    gres = kv.get("Gres") or kv.get("AvailableFeatures") or None
    if gres in ("(null)",):
        gres = None

    current_jobs = parse_jobs(kv)

    structured = {
        "node_name": canonical_name,
        "state": state,
        "cpus_total": total,
        "cpus_alloc": alloc,
        "cpus_idle": idle,
        "mem_total_mb": mem_total_mb,
        "mem_alloc_mb": mem_alloc_mb,
        "gres": gres,
        "current_jobs": current_jobs,
    }

    # Stash everything not already surfaced in `raw_extras`.
    consumed = {
        "NodeName", "State", "CPUAlloc", "CPUTot", "RealMemory", "AllocMem",
        "Gres", "JobList", "JobIDs", "Jobs",
    }
    raw_extras = {k: v for k, v in kv.items() if k not in consumed}

    print(json.dumps({
        "ok": True,
        "tool": "show_slurm_node",
        "node": structured,
        "raw_extras": raw_extras,
    }, ensure_ascii=False))


try:
    main()
except SystemExit:
    raise
except Exception as e:
    fail(f"{type(e).__name__}: {e}")
PY
