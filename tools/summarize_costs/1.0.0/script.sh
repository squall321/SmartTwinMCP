#!/usr/bin/env bash
# summarize_costs — aggregate realized cost over caller's registry rows.
# AGENT_GUIDE.md §28. mode: own (§18.2). No side effects (§25.3).
set -euo pipefail
export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import json
import os
import sys
import time

sys.path.insert(0, os.environ["SHARED_DIR"])
import registry


def fail(reason, **extra):
    print(json.dumps(
        {"ok": False, "tool": "summarize_costs", "reason": reason, **extra},
        ensure_ascii=False,
    ))
    sys.exit(1)


def parse_time_limit(s: str):
    """HH:MM:SS -> hours (float). Returns None on malformed input."""
    if not isinstance(s, str):
        return None
    parts = s.split(":")
    if len(parts) != 3:
        return None
    try:
        h, m, sec = (int(p) for p in parts)
    except ValueError:
        return None
    return h + m / 60.0 + sec / 3600.0


def coerce_number(n):
    """Currency amounts: emit int when integral, else round."""
    fn = float(n)
    return int(fn) if fn.is_integer() else round(fn, 4)


def main():
    # §18.1 — identity from environment.
    caller = os.environ.get("USER") or os.environ.get("LOGNAME")
    if not caller:
        fail("cannot determine caller identity (USER/LOGNAME unset)")

    args = json.loads(os.environ["STMC_ARGS_JSON"])

    now = int(time.time())
    thirty_days = 30 * 24 * 3600
    since = int(args.get("since", now - thirty_days))
    until = int(args.get("until", now))

    if since > until:
        fail("`since` is later than `until`", since=since, until=until)

    # §28.1: rates file path with test override.
    rates_path = os.environ.get("STMC_COST_RATES_FILE") \
        or "/data/SmartTwinMCP/cost_rates.yaml"

    if not os.path.exists(rates_path):
        fail(
            "cost_rates.yaml not deployed — ask ops to install it",
            expected_at=rates_path,
        )

    try:
        import yaml
    except ImportError:
        fail("PyYAML not available in runtime environment")

    try:
        with open(rates_path, "r", encoding="utf-8") as f:
            doc = yaml.safe_load(f)
    except (OSError, yaml.YAMLError) as e:
        fail(f"failed to load rates file: {type(e).__name__}: {e}",
             rates_path=rates_path)

    if not isinstance(doc, dict):
        fail("rates file is not a mapping", rates_path=rates_path)
    unit = doc.get("unit", "KRW")
    rates_map = doc.get("rates")
    if not isinstance(rates_map, dict):
        fail("rates file missing or malformed `rates:` map",
             rates_path=rates_path)

    # §18.3 — SQL-side user filter. `since` filters in SQL; `until` is post-filtered.
    # Use a large limit ceiling so we don't truncate a real month of jobs.
    raw_rows = registry.list_recent(limit=10000, user=caller, since=since)
    rows = [r for r in raw_rows if r.get("submitted_at", 0) <= until]

    total = 0.0
    by_tool: dict[str, dict] = {}
    by_partition: dict[str, dict] = {}
    jobs_counted = 0
    skipped = 0

    for row in rows:
        # §28: dry_run rows have no realized cost.
        if row.get("status") == "dry_run":
            skipped += 1
            continue

        extra = row.get("extra")
        if not isinstance(extra, dict):
            skipped += 1
            continue

        # partition lookup (§14.4 / §16.5): prefer gpu_partition, then partition.
        partition = extra.get("gpu_partition") or extra.get("partition")
        time_limit = extra.get("time_limit")
        hours = parse_time_limit(time_limit) if time_limit else None
        cpus = extra.get("cpus")
        gpus = extra.get("gpus", 0)

        if partition is None or hours is None or cpus is None:
            skipped += 1
            continue
        if partition not in rates_map:
            skipped += 1
            continue

        rate = rates_map[partition] or {}
        if not isinstance(rate, dict):
            skipped += 1
            continue

        try:
            cpus_i = int(cpus)
            gpus_i = int(gpus or 0)
        except (TypeError, ValueError):
            skipped += 1
            continue

        nodes = extra.get("nodes", 1)
        try:
            nodes_i = int(nodes)
        except (TypeError, ValueError):
            nodes_i = 1

        cpu_hour = float(rate.get("cpu_hour", 0))
        gpu_hour = float(rate.get("gpu_hour", 0))
        per_node = hours * (cpus_i * cpu_hour + gpus_i * gpu_hour)
        cost = per_node * nodes_i

        total += cost
        jobs_counted += 1

        tool_name = row.get("tool_name") or "<unknown>"
        bt = by_tool.setdefault(tool_name, {"tool": tool_name, "count": 0, "cost": 0.0})
        bt["count"] += 1
        bt["cost"] += cost

        bp = by_partition.setdefault(partition, {"partition": partition, "count": 0, "cost": 0.0})
        bp["count"] += 1
        bp["cost"] += cost

    # Sort by cost desc, then name asc for stable output.
    by_tool_list = [
        {"tool": v["tool"], "count": v["count"], "cost": coerce_number(v["cost"])}
        for v in sorted(by_tool.values(), key=lambda d: (-d["cost"], d["tool"]))
    ]
    by_partition_list = [
        {"partition": v["partition"], "count": v["count"], "cost": coerce_number(v["cost"])}
        for v in sorted(by_partition.values(), key=lambda d: (-d["cost"], d["partition"]))
    ]

    print(json.dumps({
        "ok": True,
        "tool": "summarize_costs",
        "period": {"since": since, "until": until},
        "unit": unit,
        "total": coerce_number(total),
        "by_tool": by_tool_list,
        "by_partition": by_partition_list,
        "jobs_counted": jobs_counted,
        "skipped": skipped,
        "caveat": "Realized cost uses each job's recorded time_limit (upper bound). Real wall-time may be lower.",
    }, ensure_ascii=False))


try:
    main()
except SystemExit:
    raise
except Exception as e:
    fail(f"{type(e).__name__}: {e}")
PY
