#!/usr/bin/env bash
# audit_summary — §29.2 period aggregate over the §25 audit log.
# mode: read-all (§18.2 / §29.1). Observability only — never writes audit rows.
set -euo pipefail
export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import json
import os
import sys
import time
from datetime import datetime, timezone


def fail(reason, **extra):
    print(json.dumps(
        {"ok": False, "tool": "audit_summary", "reason": reason, **extra},
        ensure_ascii=False,
    ))
    sys.exit(1)


def main():
    # §18.1 — caller identity from environment, never an arg.
    caller = os.environ.get("USER") or os.environ.get("LOGNAME")
    if not caller:
        fail("cannot determine caller identity (USER/LOGNAME unset)")

    args = json.loads(os.environ["STMC_ARGS_JSON"])

    sys.path.insert(0, os.environ["SHARED_DIR"])
    import audit  # noqa: E402

    db_existed_before = os.path.isfile(audit.DB_PATH)

    now = int(time.time())
    seven_days = 7 * 24 * 3600
    since = int(args.get("since", now - seven_days))
    until = int(args.get("until", now))
    if since > until:
        fail("`since` is later than `until`", since=since, until=until)

    # §29.2 default actor = caller. The `actor` arg is a query knob; identity
    # itself is from the env.
    actor = args.get("actor", caller)
    group_by = args.get("group_by", ["action"])

    # `audit.list_events` (§25.4) accepts (limit, since, actor, tool, action,
    # target_id). It has no `until`, so we fetch a wide window with a generous
    # limit and post-filter `until` in Python (per the §29 spec note — extra
    # query power is Python-side, not in the helper).
    raw = audit.list_events(limit=100000, since=since, actor=actor)
    rows = [r for r in raw if r.get("occurred_at", 0) <= until]

    # §29.2 gap fix: empty group_by → no aggregation, groups stays [].
    # Caller already gets total_events for the bare-total case.
    if not group_by:
        out_groups = []
    else:
        groups: dict[tuple, int] = {}
        for r in rows:
            key_parts = []
            for dim in group_by:
                if dim == "actor":
                    key_parts.append(("actor", r.get("actor")))
                elif dim == "action":
                    key_parts.append(("action", r.get("action")))
                elif dim == "tool":
                    key_parts.append(("tool", r.get("tool")))
                elif dim == "day":
                    ts = r.get("occurred_at") or 0
                    day = datetime.fromtimestamp(int(ts), tz=timezone.utc).strftime("%Y-%m-%d")
                    key_parts.append(("day", day))
                else:
                    # Schema enum already prevents this, but be defensive.
                    fail(f"unknown group_by dimension: {dim}", group_by=group_by)
            k = tuple(key_parts)
            groups[k] = groups.get(k, 0) + 1

        # Sort by count desc, then key asc for stable output.
        sorted_groups = sorted(
            groups.items(),
            key=lambda kv: (-kv[1], tuple(str(v) for _, v in kv[0])),
        )

        out_groups = [
            {"key": {dim: val for dim, val in k}, "count": c}
            for k, c in sorted_groups
        ]

    response = {
        "ok": True,
        "tool": "audit_summary",
        "period": {"since": since, "until": until},
        "actor": actor,
        "group_by": group_by,
        "total_events": len(rows),
        "groups": out_groups,
    }
    if not db_existed_before:
        response["reason"] = "audit DB not initialized — no events recorded yet"

    print(json.dumps(response, ensure_ascii=False, default=str))


try:
    main()
except SystemExit:
    raise
except Exception as e:
    fail(f"{type(e).__name__}: {e}")
PY
