#!/usr/bin/env bash
# apply_template_args — merge overrides onto a named template's args (AGENT_GUIDE.md §26)
set -euo pipefail

python3 - <<'PY'
import json, os, sys

# Default path per AGENT_GUIDE.md §26.1.
# STMC_TEMPLATES_DIR is a TEST OVERRIDE (see meta.yaml). Production callers must not set it.
TEMPLATES_DIR = os.environ.get("STMC_TEMPLATES_DIR", "/data/SmartTwinMCP/templates/")


def fail(reason, **extra):
    print(json.dumps({"ok": False, "tool": "apply_template_args",
                      "reason": reason, **extra}, ensure_ascii=False))
    sys.exit(1)


def deep_merge(base, overrides):
    """Recursively merge `overrides` into `base`. Dicts merge; lists/scalars replace.
    Mirrors scenario_builder.deep_merge so behavior is consistent across the catalog.
    `base` is mutated and returned."""
    if not isinstance(overrides, dict):
        return overrides
    for k, v in overrides.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            base[k] = deep_merge(base[k], v)
        else:
            base[k] = v
    return base


def main():
    import yaml  # PyYAML

    args = json.loads(os.environ["STMC_ARGS_JSON"])
    name = args["name"]
    overrides = args.get("overrides") or {}
    if not isinstance(overrides, dict):
        fail("overrides must be an object", got_type=type(overrides).__name__)

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
            template = yaml.safe_load(fh)
    except (yaml.YAMLError, OSError) as e:
        fail(f"failed to parse template: {type(e).__name__}: {e}",
             name=name, path=candidate)

    if not isinstance(template, dict):
        fail("template YAML top-level is not a mapping",
             name=name, path=candidate)

    base_args = template.get("args") or {}
    if not isinstance(base_args, dict):
        fail("template `args` field is not a mapping",
             name=name, args_type=type(base_args).__name__)

    # Use a deepcopy so the file's data is not mutated through references.
    import copy
    merged = deep_merge(copy.deepcopy(base_args), overrides)

    compatible = template.get("applies_to") or []
    if not isinstance(compatible, list):
        compatible = []

    # default=str so YAML-derived datetime values serialize as ISO strings.
    print(json.dumps({
        "ok": True,
        "tool": "apply_template_args",
        "template_name": template.get("name") or name,
        "compatible_tools": compatible,
        "args": merged,
        "applied_overrides": overrides,
        "hint": "Pass `args` directly to one of compatible_tools.",
    }, ensure_ascii=False, default=str))


try:
    main()
except SystemExit:
    raise
except Exception as e:
    fail(f"{type(e).__name__}: {e}")
PY
