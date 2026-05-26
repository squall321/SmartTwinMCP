#!/usr/bin/env bash
# get_inbound_webhook — fetch one sidecar-written row by id (AGENT_GUIDE.md §17)
set -euo pipefail

python3 - <<'PY'
import json, os, sqlite3, sys

# Default DB path per AGENT_GUIDE.md §17.1.
# STMC_WEBHOOK_DB is a TEST OVERRIDE (see meta.yaml). Production callers must not set it.
DB_PATH = os.environ.get("STMC_WEBHOOK_DB", "/data/SmartTwinMCP/inbound_webhooks.db")


def fail(reason, **extra):
    print(json.dumps({"ok": False, "tool": "get_inbound_webhook",
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
    webhook_id = int(args["webhook_id"])

    if not os.path.exists(DB_PATH):
        fail("inbound webhook DB missing — sidecar not deployed or wrong host "
             "(see AGENT_GUIDE.md §17.1)",
             expected_at=DB_PATH)

    con = sqlite3.connect(DB_PATH)
    try:
        con.row_factory = sqlite3.Row
        row = con.execute(
            "SELECT id, received_at, source, event_type, headers, payload, "
            "signature_verified, ack_status, ack_at, ack_note "
            "FROM inbound_webhooks WHERE id = ?",
            (webhook_id,),
        ).fetchone()
    finally:
        con.close()

    if row is None:
        fail("webhook row not found", webhook_id=webhook_id)

    print(json.dumps({
        "ok": True,
        "tool": "get_inbound_webhook",
        "webhook": row_to_dict(row),
    }, ensure_ascii=False))


try:
    main()
except SystemExit:
    raise
except Exception as e:
    fail(f"{type(e).__name__}: {e}")
PY
