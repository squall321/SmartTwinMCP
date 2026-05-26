#!/usr/bin/env bash
# ack_inbound_webhook — mark a sidecar-written row consumed/error (AGENT_GUIDE.md §17)
set -euo pipefail

export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import json, os, sqlite3, sys, time

sys.path.insert(0, os.environ["SHARED_DIR"])
import audit

# Default DB path per AGENT_GUIDE.md §17.1.
# STMC_WEBHOOK_DB is a TEST OVERRIDE (see meta.yaml). Production callers must not set it.
DB_PATH = os.environ.get("STMC_WEBHOOK_DB", "/data/SmartTwinMCP/inbound_webhooks.db")


def fail(reason, **extra):
    print(json.dumps({"ok": False, "tool": "ack_inbound_webhook",
                      "reason": reason, **extra}, ensure_ascii=False))
    sys.exit(1)


def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])
    webhook_id = int(args["webhook_id"])
    outcome = args["outcome"]
    note = args.get("note")

    if not os.path.exists(DB_PATH):
        fail("inbound webhook DB missing — sidecar not deployed or wrong host "
             "(see AGENT_GUIDE.md §17.1)",
             expected_at=DB_PATH)

    con = sqlite3.connect(DB_PATH)
    try:
        con.row_factory = sqlite3.Row
        row = con.execute(
            "SELECT id, ack_status, ack_note FROM inbound_webhooks WHERE id = ?",
            (webhook_id,),
        ).fetchone()
        if row is None:
            fail("webhook row not found", webhook_id=webhook_id)

        previous = row["ack_status"]

        # Idempotency: same outcome AND same note (or no new note) → no-op.
        # We only treat it as idempotent if the desired state already matches.
        # If caller provides a new note, always write it through so notes can be updated.
        if previous == outcome and note is None:
            print(json.dumps({
                "ok": True,
                "tool": "ack_inbound_webhook",
                "webhook_id": webhook_id,
                "previous_ack_status": previous,
                "ack_status": outcome,
                "idempotent": True,
            }, ensure_ascii=False))
            return

        now = int(time.time())
        if note is not None:
            con.execute(
                "UPDATE inbound_webhooks "
                "SET ack_status = ?, ack_at = ?, ack_note = ? "
                "WHERE id = ?",
                (outcome, now, note, webhook_id),
            )
        else:
            con.execute(
                "UPDATE inbound_webhooks "
                "SET ack_status = ?, ack_at = ? "
                "WHERE id = ?",
                (outcome, now, webhook_id),
            )
        con.commit()

        # §25.3.1 audit row (non-idempotent state change only).
        actor = os.environ.get("USER") or os.environ.get("LOGNAME") or "unknown"
        audit.record_event(
            actor=actor,
            tool="ack_inbound_webhook@1.1.0",
            action="acknowledge",
            summary=f"acked webhook {webhook_id}: {previous} -> {outcome}",
            target_kind="webhook",
            target_id=str(webhook_id),
            detail={
                "outcome": outcome,
                "previous_ack_status": previous,
                "note": note,
            },
        )

        print(json.dumps({
            "ok": True,
            "tool": "ack_inbound_webhook",
            "webhook_id": webhook_id,
            "previous_ack_status": previous,
            "ack_status": outcome,
            "idempotent": False,
        }, ensure_ascii=False))
    finally:
        con.close()


try:
    main()
except SystemExit:
    raise
except Exception as e:
    fail(f"{type(e).__name__}: {e}")
PY
