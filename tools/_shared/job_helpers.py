#!/usr/bin/env python3
"""Shared helpers for follow-up MCP tools (job_status, job_stop, etc).

Pattern: resolve registry_id|work_dir → runner_config_path → call KooChainRun subcommand.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import Any

import registry


KOOCHAINRUN = "/data/SmartTwinPreprocessor/bin/KooChainRun"


def resolve_job(args: dict) -> dict | None:
    """Look up job by registry_id or work_dir."""
    if "registry_id" in args:
        return registry.get_by_id(int(args["registry_id"]))
    if "work_dir" in args:
        wd = args["work_dir"].rstrip("/")
        rows = [r for r in registry.list_recent(limit=500)
                if r.get("work_dir", "").rstrip("/") == wd]
        if rows:
            return rows[0]
    return None


def fail(reason: str, **extra):
    print(json.dumps({"ok": False, "reason": reason, **extra}, ensure_ascii=False))
    sys.exit(1)


def run_koochainrun(subcommand: str, *extra_args: str, timeout: int = 300) -> tuple[int, str, str]:
    """Run KooChainRun subcommand, return (rc, stdout, stderr)."""
    if not os.path.exists(KOOCHAINRUN):
        fail(f"KooChainRun not found at {KOOCHAINRUN}")
    cmd = [KOOCHAINRUN, subcommand, *extra_args]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        fail(f"KooChainRun {subcommand} timed out after {timeout}s")


def slurm_queue_for(slurm_job_ids: list[str]) -> dict:
    """Query squeue for the given Slurm job IDs."""
    if not slurm_job_ids:
        return {}
    try:
        r = subprocess.run(
            ["squeue", "-h", "-o", "%i %T %j %R", "-j", ",".join(slurm_job_ids)],
            capture_output=True, text=True, timeout=10,
        )
    except Exception:
        return {}
    out = {}
    for line in r.stdout.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) >= 2:
            out[parts[0]] = {
                "state": parts[1],
                "name": parts[2] if len(parts) > 2 else None,
                "reason": parts[3] if len(parts) > 3 else None,
            }
    return out
