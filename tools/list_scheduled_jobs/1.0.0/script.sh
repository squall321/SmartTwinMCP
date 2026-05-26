#!/usr/bin/env bash
# list_scheduled_jobs — page through cron-spec YAMLs (AGENT_GUIDE.md §27)
set -euo pipefail

python3 - <<'PY'
import json, os, sys, glob
import yaml

# Default cron dir per AGENT_GUIDE.md §27.1.
# STMC_CRON_DIR is a TEST OVERRIDE (see meta.yaml). Production callers must not set it.
CRON_DIR = os.environ.get("STMC_CRON_DIR", "/data/SmartTwinMCP/cron/")


def fail(reason, **extra):
    print(json.dumps({"ok": False, "tool": "list_scheduled_jobs",
                      "reason": reason, **extra}, ensure_ascii=False))
    sys.exit(1)


def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])
    enabled_filter = args.get("enabled")  # may be None / True / False
    tool_filter = args.get("tool")

    # Missing dir → empty result (sidecar may not be deployed yet).
    if not os.path.isdir(CRON_DIR):
        print(json.dumps({
            "ok": True,
            "tool": "list_scheduled_jobs",
            "count": 0,
            "scheduled": [],
        }, ensure_ascii=False))
        return

    rows = []
    for path in sorted(glob.glob(os.path.join(CRON_DIR, "*.yaml"))):
        try:
            with open(path) as f:
                spec = yaml.safe_load(f)
        except (yaml.YAMLError, OSError) as e:
            fail(f"failed to parse cron spec: {type(e).__name__}: {e}",
                 path=path)

        if not isinstance(spec, dict):
            fail("cron spec is not a YAML mapping", path=path)

        name = spec.get("name")
        if not name:
            fail("cron spec missing 'name'", path=path)

        spec_enabled = bool(spec.get("enabled", False))
        spec_tool = spec.get("tool")

        if enabled_filter is not None and spec_enabled != enabled_filter:
            continue
        if tool_filter is not None and spec_tool != tool_filter:
            continue

        rows.append({
            "name": name,
            "schedule": spec.get("schedule"),
            "tool": spec_tool,
            "enabled": spec_enabled,
            "last_run_at": spec.get("last_run_at"),
            "last_run_status": spec.get("last_run_status"),
            "created_by": spec.get("created_by"),
        })

    # Stable order: by name asc.
    rows.sort(key=lambda r: r["name"])

    print(json.dumps({
        "ok": True,
        "tool": "list_scheduled_jobs",
        "count": len(rows),
        "scheduled": rows,
    }, ensure_ascii=False))


try:
    main()
except SystemExit:
    raise
except Exception as e:
    fail(f"{type(e).__name__}: {e}")
PY
