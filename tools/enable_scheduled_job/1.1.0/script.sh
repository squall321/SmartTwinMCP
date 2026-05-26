#!/usr/bin/env bash
# enable_scheduled_job — flip 'enabled' flag on a cron-spec YAML (AGENT_GUIDE.md §27)
# mode: own — only the spec's created_by user may flip its switch.
set -euo pipefail

export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import json, os, sys
import yaml

sys.path.insert(0, os.environ["SHARED_DIR"])
import audit

CRON_DIR = os.environ.get("STMC_CRON_DIR", "/data/SmartTwinMCP/cron/")


def fail(reason, **extra):
    print(json.dumps({"ok": False, "tool": "enable_scheduled_job",
                      "reason": reason, **extra}, ensure_ascii=False))
    sys.exit(1)


def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])
    name = args["name"]
    desired = args["enabled"]
    if not isinstance(desired, bool):
        fail("'enabled' must be a boolean", got=type(desired).__name__)

    # Identity from env per AGENT_GUIDE.md §18.1 — never a JSON arg.
    caller = os.environ.get("USER") or os.environ.get("LOGNAME")
    if not caller:
        fail("cannot determine caller identity (USER/LOGNAME unset)")

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

    owner = spec.get("created_by")
    # Multi-tenant per §27.5 / §18 mode-own.
    if owner != caller:
        fail("permission denied: spec belongs to another user",
             name=name, spec_owner=owner, caller=caller)

    previous = bool(spec.get("enabled", False))

    if previous == desired:
        # No-op: idempotent.
        print(json.dumps({
            "ok": True,
            "tool": "enable_scheduled_job",
            "name": name,
            "previous_enabled": previous,
            "enabled": desired,
            "idempotent": True,
        }, ensure_ascii=False))
        return

    spec["enabled"] = desired

    # Atomic write via temp + rename so a crash mid-write can't leave a half-file.
    tmp_path = path + ".tmp"
    try:
        with open(tmp_path, "w") as f:
            yaml.safe_dump(spec, f, default_flow_style=False, sort_keys=False,
                           allow_unicode=True)
        os.replace(tmp_path, path)
    except OSError as e:
        # Best-effort cleanup of the tmp file.
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        fail(f"failed to write cron spec: {type(e).__name__}: {e}", path=path)

    # §25.3.1 audit row (non-idempotent state change only).
    audit.record_event(
        actor=caller,
        tool="enable_scheduled_job@1.1.0",
        action="config_toggle",
        summary=f"cron spec '{name}': enabled {previous} -> {desired}",
        target_kind="cron",
        target_id=name,
        detail={
            "name": name,
            "previous_enabled": previous,
            "enabled": desired,
            "path": path,
        },
    )

    print(json.dumps({
        "ok": True,
        "tool": "enable_scheduled_job",
        "name": name,
        "previous_enabled": previous,
        "enabled": desired,
        "idempotent": False,
    }, ensure_ascii=False))


try:
    main()
except SystemExit:
    raise
except Exception as e:
    fail(f"{type(e).__name__}: {e}")
PY
