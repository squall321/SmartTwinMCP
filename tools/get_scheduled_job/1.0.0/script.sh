#!/usr/bin/env bash
# get_scheduled_job — fetch one cron-spec YAML body (AGENT_GUIDE.md §27)
set -euo pipefail

python3 - <<'PY'
import json, os, sys
import yaml

CRON_DIR = os.environ.get("STMC_CRON_DIR", "/data/SmartTwinMCP/cron/")


def fail(reason, **extra):
    print(json.dumps({"ok": False, "tool": "get_scheduled_job",
                      "reason": reason, **extra}, ensure_ascii=False))
    sys.exit(1)


def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])
    name = args["name"]

    path = os.path.join(CRON_DIR, f"{name}.yaml")
    if not os.path.exists(path):
        fail("cron spec not found", name=name, expected_at=path)

    try:
        with open(path) as f:
            spec = yaml.safe_load(f)
    except (yaml.YAMLError, OSError) as e:
        fail(f"failed to parse cron spec: {type(e).__name__}: {e}",
             path=path)

    if not isinstance(spec, dict):
        fail("cron spec is not a YAML mapping", path=path)

    # Pass body through verbatim — _runtime: keys in args stay opaque per §27.3.
    print(json.dumps({
        "ok": True,
        "tool": "get_scheduled_job",
        "scheduled": spec,
    }, ensure_ascii=False))


try:
    main()
except SystemExit:
    raise
except Exception as e:
    fail(f"{type(e).__name__}: {e}")
PY
