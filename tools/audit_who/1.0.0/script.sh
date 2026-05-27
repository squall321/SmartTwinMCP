#!/usr/bin/env bash
# audit_who — §29.4 "who did action X" query over the §25 audit log.
# mode: read-all (§18.2 / §29.1). Observability only — never writes audit rows.
set -euo pipefail
export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import json
import os
import sys
import time


def fail(reason, **extra):
    print(json.dumps(
        {"ok": False, "tool": "audit_who", "reason": reason, **extra},
        ensure_ascii=False,
    ))
    sys.exit(1)


def main():
    # §18.1 — caller identity from environment.
    caller = os.environ.get("USER") or os.environ.get("LOGNAME")
    if not caller:
        fail("cannot determine caller identity (USER/LOGNAME unset)")

    args = json.loads(os.environ["STMC_ARGS_JSON"])

    sys.path.insert(0, os.environ["SHARED_DIR"])
    import audit  # noqa: E402

    db_existed_before = os.path.isfile(audit.DB_PATH)

    # Schema enforces `action` is present; defensively re-check.
    action = args.get("action")
    if not action:
        fail("`action` is required (see §29.4 / §29.6 anti-pattern)")

    target_id = args.get("target_id")

    now = int(time.time())
    seven_days = 7 * 24 * 3600
    since = int(args.get("since", now - seven_days))
    until = int(args.get("until", now))
    if since > until:
        fail("`since` is later than `until`", since=since, until=until)

    limit = int(args.get("limit", 50))

    # `audit.list_events` accepts (limit, since, actor, tool, action, target_id).
    # No `until`. We fetch a wide window then post-filter `until`. To make sure
    # `limit` semantics are respected AFTER `until` filtering, we ask for a
    # larger pool from the helper and slice at the end.
    pool = audit.list_events(
        limit=max(limit * 4, 200),
        since=since,
        action=action,
        target_id=target_id,
    )
    rows = [r for r in pool if r.get("occurred_at", 0) <= until]

    # `list_events` already returns newest-first (§25.4). Re-sort defensively
    # so the contract is explicit, then slice to limit.
    rows.sort(key=lambda r: (-int(r.get("occurred_at", 0) or 0), -int(r.get("id", 0) or 0)))
    rows = rows[:limit]

    response = {
        "ok": True,
        "tool": "audit_who",
        "action": action,
        "target_id": target_id,
        "period": {"since": since, "until": until},
        "count": len(rows),
        "events": rows,
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
