#!/usr/bin/env bash
# audit_trail — §29.3 chronological audit history of one target.
# mode: read-all (§18.2 / §29.1). Observability only — never writes audit rows.
set -euo pipefail
export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import json
import os
import sys


def fail(reason, **extra):
    print(json.dumps(
        {"ok": False, "tool": "audit_trail", "reason": reason, **extra},
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

    target_id = args["target_id"]            # required by schema
    target_kind = args.get("target_kind")    # optional
    limit = int(args.get("limit", 100))

    # `audit.list_events` filters by target_id at SQL level (§25.4 signature).
    # It returns newest-first; we'll reverse to oldest-first per §29.3.
    rows = audit.list_events(limit=limit, target_id=target_id)

    if target_kind:
        rows = [r for r in rows if r.get("target_kind") == target_kind]

    # §29.3: timeline = oldest first.
    rows.sort(key=lambda r: (r.get("occurred_at", 0), r.get("id", 0)))

    # `target_kind_seen` — deduped list of target_kind values across the
    # returned rows (§29.3 — helps the LLM spot cross-kind id collisions).
    seen = []
    for r in rows:
        tk = r.get("target_kind")
        if tk is not None and tk not in seen:
            seen.append(tk)

    response = {
        "ok": True,
        "tool": "audit_trail",
        "target_id": target_id,
        "target_kind_seen": seen,
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
