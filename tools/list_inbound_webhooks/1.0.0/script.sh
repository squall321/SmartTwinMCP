#!/usr/bin/env bash
# list_inbound_webhooks — page through the sidecar-written queue (AGENT_GUIDE.md §17)
set -euo pipefail

python3 - <<'PY'
import json, os, sqlite3, sys

# Default DB path per AGENT_GUIDE.md §17.1.
# STMC_WEBHOOK_DB is a TEST OVERRIDE (see meta.yaml). Production callers must not set it.
DB_PATH = os.environ.get("STMC_WEBHOOK_DB", "/data/SmartTwinMCP/inbound_webhooks.db")


def fail(reason, **extra):
    print(json.dumps({"ok": False, "tool": "list_inbound_webhooks",
                      "reason": reason, **extra}, ensure_ascii=False))
    sys.exit(1)


def row_to_dict(r):
    d = dict(r)
    # Rename id -> webhook_id per §17.5 response shape contract.
    d["webhook_id"] = d.pop("id")
    for k in ("payload", "headers"):
        if d.get(k):
            try:
                d[k] = json.loads(d[k])
            except (json.JSONDecodeError, TypeError):
                # Leave the raw string in place if it isn't valid JSON.
                pass
    return d


def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])

    source = args.get("source")
    event_type = args.get("event_type")
    ack_status = args.get("ack_status", "pending")
    since = args.get("since")
    limit = int(args.get("limit", 50))

    if not os.path.exists(DB_PATH):
        fail("inbound webhook DB missing — sidecar not deployed or wrong host "
             "(see AGENT_GUIDE.md §17.1)",
             expected_at=DB_PATH)

    where = ["ack_status = ?"]
    params = [ack_status]
    if source is not None:
        where.append("source = ?")
        params.append(source)
    if event_type is not None:
        where.append("event_type = ?")
        params.append(event_type)
    if since is not None:
        where.append("received_at >= ?")
        params.append(int(since))

    sql = (
        "SELECT id, received_at, source, event_type, headers, payload, "
        "signature_verified, ack_status, ack_at, ack_note "
        "FROM inbound_webhooks "
        "WHERE " + " AND ".join(where) + " "
        "ORDER BY received_at DESC, id DESC "
        "LIMIT ?"
    )
    params.append(limit)

    con = sqlite3.connect(DB_PATH)
    try:
        con.row_factory = sqlite3.Row
        rows = [row_to_dict(r) for r in con.execute(sql, params).fetchall()]
    finally:
        con.close()

    print(json.dumps({
        "ok": True,
        "tool": "list_inbound_webhooks",
        "count": len(rows),
        "webhooks": rows,
    }, ensure_ascii=False))


try:
    main()
except SystemExit:
    raise
except Exception as e:
    fail(f"{type(e).__name__}: {e}")
PY
