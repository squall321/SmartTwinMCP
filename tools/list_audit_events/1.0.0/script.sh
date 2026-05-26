#!/usr/bin/env bash
# list_audit_events — §25 audit-log query. mode: own (actor defaults to $USER).
set -euo pipefail
export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import json, os, sys


def fail(reason, **extra):
    print(json.dumps({"ok": False, "reason": reason, **extra}, ensure_ascii=False))
    sys.exit(1)


def main():
    # §18.1 / §25.1: caller identity is from the environment, never an arg.
    caller = os.environ.get("USER") or os.environ.get("LOGNAME")
    if not caller:
        fail("cannot determine caller identity (USER/LOGNAME unset)")

    args = json.loads(os.environ["STMC_ARGS_JSON"])

    sys.path.insert(0, os.environ["SHARED_DIR"])
    # Capture DB-existed-before-import before audit's first connect side-
    # effects so we can attach the forgiving §25 "not initialized yet"
    # reason. The helper itself auto-creates DB+table on first call.
    import audit  # noqa: E402
    db_existed_before = os.path.isfile(audit.DB_PATH)

    limit = int(args.get("limit", 50))
    since = args.get("since")
    if since is not None:
        since = int(since)

    # §25.5: actor defaults to caller. Explicit override allowed (this is an
    # observability read; identity is still enforced by the env, the LLM can't
    # spoof who *it* is — it can only ask "show me alice's history").
    actor = args.get("actor", caller)
    tool = args.get("tool")
    action = args.get("action")
    target_id = args.get("target_id")

    events = audit.list_events(
        limit=limit,
        since=since,
        actor=actor,
        tool=tool,
        action=action,
        target_id=target_id,
    )

    response = {
        "ok": True,
        "tool": "list_audit_events",
        "count": len(events),
        "events": events,
    }
    if not db_existed_before:
        response["reason"] = (
            "audit DB not initialized — no events recorded yet"
        )

    print(json.dumps(response, ensure_ascii=False, default=str))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        fail(f"{type(e).__name__}: {e}")
PY
