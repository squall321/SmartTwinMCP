#!/usr/bin/env bash
# estimate_cost — pre-flight cost calculator. AGENT_GUIDE.md §28.
# mode: read-all (§18.2). No registry/audit writes (§25.3).
set -euo pipefail

python3 - <<'PY'
import json
import os
import sys


def fail(reason, **extra):
    print(json.dumps(
        {"ok": False, "tool": "estimate_cost", "reason": reason, **extra},
        ensure_ascii=False,
    ))
    sys.exit(1)


def parse_time_limit(s: str) -> float:
    """HH:MM:SS (or HHH:MM:SS) -> hours as float. Schema already pattern-checked."""
    h_str, m_str, s_str = s.split(":")
    return int(h_str) + int(m_str) / 60.0 + int(s_str) / 3600.0


def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])
    partition = args["partition"]
    cpus = int(args.get("cpus", 1))
    gpus = int(args.get("gpus", 0))
    nodes = int(args.get("nodes", 1))
    time_limit = args["time_limit"]

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
    last_updated = doc.get("last_updated")
    # YAML can deserialize a date as a datetime.date; coerce to ISO string.
    if last_updated is not None and not isinstance(last_updated, str):
        try:
            last_updated = last_updated.isoformat()
        except AttributeError:
            last_updated = str(last_updated)

    rates_map = doc.get("rates")
    if not isinstance(rates_map, dict):
        fail("rates file missing or malformed `rates:` map",
             rates_path=rates_path)

    if partition not in rates_map:
        fail(
            f"unknown partition '{partition}' — no entry in cost_rates.yaml",
            partition=partition,
            known_partitions=sorted(rates_map.keys()),
            rates_path=rates_path,
        )

    rate = rates_map[partition] or {}
    if not isinstance(rate, dict):
        fail(f"rate entry for '{partition}' is not a mapping",
             partition=partition, rate=rate)

    cpu_hour = float(rate.get("cpu_hour", 0))
    gpu_hour = float(rate.get("gpu_hour", 0))

    hours = parse_time_limit(time_limit)

    # §28.3 formula
    cpu_hours_cost = hours * cpus * cpu_hour
    gpu_hours_cost = hours * gpus * gpu_hour
    per_node = cpu_hours_cost + gpu_hours_cost
    total = per_node * nodes

    # Costs are currency amounts; emit integers when the math lands on an integer
    # so the §28.4 example matches exactly (211200, not 211200.0).
    def _coerce(n: float):
        return int(n) if float(n).is_integer() else round(n, 4)

    print(json.dumps({
        "ok": True,
        "tool": "estimate_cost",
        "request": {
            "partition": partition,
            "cpus": cpus,
            "gpus": gpus,
            "nodes": nodes,
            "time_limit": time_limit,
        },
        "unit": unit,
        "hours": _coerce(hours),
        "breakdown": {
            # Per-node costs; node_multiplier scales them to estimated_total.
            "cpu_hours_cost": _coerce(cpu_hours_cost),
            "gpu_hours_cost": _coerce(gpu_hours_cost),
            "node_multiplier": nodes,
        },
        "estimated_total": _coerce(total),
        "rate_source_updated": last_updated,
        "caveat": "Wall-time estimate. Actual cost depends on job duration.",
    }, ensure_ascii=False))


try:
    main()
except SystemExit:
    raise
except Exception as e:
    fail(f"{type(e).__name__}: {e}")
PY
