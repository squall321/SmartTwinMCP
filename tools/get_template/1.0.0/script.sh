#!/usr/bin/env bash
# get_template — fetch one YAML preset by name (AGENT_GUIDE.md §26)
set -euo pipefail

python3 - <<'PY'
import json, os, sys

# Default path per AGENT_GUIDE.md §26.1.
# STMC_TEMPLATES_DIR is a TEST OVERRIDE (see meta.yaml). Production callers must not set it.
TEMPLATES_DIR = os.environ.get("STMC_TEMPLATES_DIR", "/data/SmartTwinMCP/templates/")


def fail(reason, **extra):
    print(json.dumps({"ok": False, "tool": "get_template",
                      "reason": reason, **extra}, ensure_ascii=False))
    sys.exit(1)


def main():
    import yaml  # PyYAML — bundled with the venv

    args = json.loads(os.environ["STMC_ARGS_JSON"])
    name = args["name"]

    if not os.path.isdir(TEMPLATES_DIR):
        fail("templates dir not initialized — ops must populate it (see AGENT_GUIDE.md §26.1)",
             templates_dir=TEMPLATES_DIR)

    # Try .yaml first, then .yml. Schema pattern blocks slashes so no traversal risk.
    candidate = None
    for ext in (".yaml", ".yml"):
        path = os.path.join(TEMPLATES_DIR, name + ext)
        if os.path.isfile(path):
            candidate = path
            break

    if candidate is None:
        fail("template not found", name=name, templates_dir=TEMPLATES_DIR)

    try:
        with open(candidate, "r", encoding="utf-8") as fh:
            data = yaml.safe_load(fh)
    except (yaml.YAMLError, OSError) as e:
        fail(f"failed to parse template: {type(e).__name__}: {e}",
             name=name, path=candidate)

    if not isinstance(data, dict):
        fail("template YAML top-level is not a mapping",
             name=name, path=candidate)

    # default=str so YAML-derived datetime values serialize as ISO strings.
    print(json.dumps({
        "ok": True,
        "tool": "get_template",
        "template": data,
    }, ensure_ascii=False, default=str))


try:
    main()
except SystemExit:
    raise
except Exception as e:
    fail(f"{type(e).__name__}: {e}")
PY
