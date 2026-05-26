#!/usr/bin/env bash
# list_templates — list YAML preset files under STMC_TEMPLATES_DIR (AGENT_GUIDE.md §26)
set -euo pipefail

python3 - <<'PY'
import json, os, sys

# Default path per AGENT_GUIDE.md §26.1.
# STMC_TEMPLATES_DIR is a TEST OVERRIDE (see meta.yaml). Production callers must not set it.
TEMPLATES_DIR = os.environ.get("STMC_TEMPLATES_DIR", "/data/SmartTwinMCP/templates/")


def fail(reason, **extra):
    print(json.dumps({"ok": False, "tool": "list_templates",
                      "reason": reason, **extra}, ensure_ascii=False))
    sys.exit(1)


def main():
    import yaml  # PyYAML — bundled with the venv per pyproject.toml

    args = json.loads(os.environ["STMC_ARGS_JSON"])
    applies_to = args.get("applies_to")
    tag = args.get("tag")

    if not os.path.isdir(TEMPLATES_DIR):
        # Per spec: a missing dir is NOT an error; just an empty result.
        print(json.dumps({
            "ok": True,
            "tool": "list_templates",
            "count": 0,
            "templates": [],
            "reason": "templates dir not initialized",
            "templates_dir": TEMPLATES_DIR,
        }, ensure_ascii=False))
        return

    summaries = []
    for fname in sorted(os.listdir(TEMPLATES_DIR)):
        if not (fname.endswith(".yaml") or fname.endswith(".yml")):
            continue
        path = os.path.join(TEMPLATES_DIR, fname)
        if not os.path.isfile(path):
            continue
        try:
            with open(path, "r", encoding="utf-8") as fh:
                data = yaml.safe_load(fh)
        except (yaml.YAMLError, OSError) as e:
            # Skip un-parseable files; surfacing each one as a hard fail
            # would defeat the whole list — but log to stderr for diagnostics.
            print(f"skip {fname}: {type(e).__name__}: {e}", file=sys.stderr)
            continue
        if not isinstance(data, dict):
            print(f"skip {fname}: top-level not a mapping", file=sys.stderr)
            continue

        # Derive name: prefer the YAML `name` field, fall back to filename stem.
        # (§26.1's spec puts `name` in the YAML; we treat the file stem as backup.)
        stem = os.path.splitext(fname)[0]
        name = data.get("name") or stem

        applies = data.get("applies_to") or []
        if not isinstance(applies, list):
            applies = []
        tags_field = data.get("tags") or []
        if not isinstance(tags_field, list):
            tags_field = []

        # Apply filters.
        if applies_to is not None and applies_to not in applies:
            continue
        if tag is not None and tag not in tags_field:
            continue

        summaries.append({
            "name": name,
            "description": data.get("description"),
            "applies_to": applies,
            "created_at": data.get("created_at"),
            "created_by": data.get("created_by"),
        })

    # default=str so YAML-derived datetime values (created_at, etc.) serialize
    # cleanly as ISO strings instead of raising TypeError.
    print(json.dumps({
        "ok": True,
        "tool": "list_templates",
        "count": len(summaries),
        "templates": summaries,
    }, ensure_ascii=False, default=str))


try:
    main()
except SystemExit:
    raise
except Exception as e:
    fail(f"{type(e).__name__}: {e}")
PY
