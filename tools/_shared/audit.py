#!/usr/bin/env python3
"""SQLite audit log — cross-tool LLM decision history (§25).

DB path: /data/SmartTwinMCP/audit.db
Auto-creates dir + schema on first use. WAL mode like `registry.py`.

This is the third table in `/data/SmartTwinMCP/`, sibling to `jobs.db` and the
webhook DB. Unlike `registry.notes` (per-row, freeform) or `extra` (per-tool),
audit rows persist a session-spanning record of *what the LLM decided to do*
so a user revisiting a session days later can reconstruct context (§25).

API:
  record_event(actor, tool, action, summary, target_kind=None, target_id=None,
               detail=None) → int (DB row id)
  list_events(limit=50, since=None, actor=None, tool=None, action=None,
              target_id=None) → [event_dict, ...]   (newest-first)
  session_seen(actor, tool, target_id, within_sec=300) → bool
                                  (for §25.3 inspect-dedup heuristic)
"""
from __future__ import annotations

import json
import os
import sqlite3
import time
from contextlib import contextmanager
from typing import Any

# Production path. Tests / §7 step-6 verification should set STMC_AUDIT_DB to a
# tmpfile to avoid polluting production state. Production callers leave it
# unset. Mirrors the STMC_JOBS_DB seam in `registry.py` (§9.2).
DB_PATH = os.environ.get("STMC_AUDIT_DB") or "/data/SmartTwinMCP/audit.db"
DB_DIR = os.path.dirname(DB_PATH)


# Schema is per §25.1. `action` is a free-text column at the SQL layer; the
# enum is enforced by the §25.5 `list_audit_events` schema and by the writer
# tools that call `record_event` — the table itself stays flexible so the
# audit log can be re-targeted if §25.2 grows a new action.
SCHEMA = """
CREATE TABLE IF NOT EXISTS audit_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    occurred_at INTEGER NOT NULL,
    actor TEXT NOT NULL,
    tool TEXT NOT NULL,
    action TEXT NOT NULL,
    target_kind TEXT,
    target_id TEXT,
    summary TEXT NOT NULL,
    detail TEXT
);

CREATE INDEX IF NOT EXISTS idx_audit_occurred ON audit_events(occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_actor ON audit_events(actor, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_action ON audit_events(action);
"""


def _ensure_db() -> None:
    os.makedirs(DB_DIR, exist_ok=True)
    with sqlite3.connect(DB_PATH) as con:
        con.execute("PRAGMA journal_mode=WAL")
        con.executescript(SCHEMA)


@contextmanager
def _conn():
    _ensure_db()
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    try:
        yield con
        con.commit()
    finally:
        con.close()


def _row_to_dict(row: sqlite3.Row) -> dict:
    d = dict(row)
    raw = d.get("detail")
    if raw:
        try:
            d["detail"] = json.loads(raw)
        except (json.JSONDecodeError, TypeError):
            # Leave the string in place if it isn't decodable — better than
            # dropping the field. Should never happen if rows came through
            # record_event, which json.dumps's its input.
            pass
    return d


def record_event(
    actor: str,
    tool: str,
    action: str,
    summary: str,
    target_kind: str | None = None,
    target_id: str | None = None,
    detail: dict | None = None,
) -> int:
    """Insert one audit row. Returns the DB primary key.

    `actor` must be the calling OS user (§25.1 — never an arg). `tool` is the
    fully qualified name (e.g. "submit_lsdyna_job@1.0.0"). `action` should be
    one of the §25.2 enum values. `detail` is a Python dict; it is JSON-
    encoded internally. Pick 3–5 fields the LLM will want to recall — don't
    dump the full response (§25.7 anti-pattern).
    """
    now = int(time.time())
    with _conn() as con:
        cur = con.execute(
            """INSERT INTO audit_events (
                occurred_at, actor, tool, action,
                target_kind, target_id, summary, detail
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                now, actor, tool, action,
                target_kind, target_id, summary,
                json.dumps(detail) if detail else None,
            ),
        )
        return cur.lastrowid


def list_events(
    limit: int = 50,
    since: int | None = None,
    actor: str | None = None,
    tool: str | None = None,
    action: str | None = None,
    target_id: str | None = None,
) -> list[dict]:
    """Newest-first list with AND filters. JSON `detail` is decoded.

    Used by the §25.5 `list_audit_events` MCP tool. Callers that need a
    `mode: own` view pass `actor=$USER` (the default in the query tool's
    schema). Pass `actor=None` only for ops/admin views — the surface today
    isn't exposed to the LLM.
    """
    where = []
    params: list[Any] = []
    if since is not None:
        where.append("occurred_at >= ?")
        params.append(int(since))
    if actor:
        where.append("actor = ?")
        params.append(actor)
    if tool:
        where.append("tool = ?")
        params.append(tool)
    if action:
        where.append("action = ?")
        params.append(action)
    if target_id:
        where.append("target_id = ?")
        params.append(target_id)

    sql = "SELECT * FROM audit_events"
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY occurred_at DESC, id DESC LIMIT ?"
    params.append(int(limit))

    with _conn() as con:
        return [_row_to_dict(r) for r in con.execute(sql, params)]


def session_seen(
    actor: str,
    tool: str,
    target_id: str,
    within_sec: int = 300,
) -> bool:
    """True iff (actor, tool, target_id) already has a row in the last
    `within_sec` seconds. §25.3 dedup heuristic for inspection tools —
    use this to decide whether a `job_status`/`job_logs`/... call should
    *also* write an `inspect` audit row, or skip to avoid flooding.
    """
    cutoff = int(time.time()) - int(within_sec)
    with _conn() as con:
        row = con.execute(
            """SELECT 1 FROM audit_events
               WHERE actor = ? AND tool = ? AND target_id = ?
                 AND occurred_at >= ?
               LIMIT 1""",
            (actor, tool, target_id, cutoff),
        ).fetchone()
        return row is not None


if __name__ == "__main__":
    # quick self-test
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "test":
        eid = record_event(
            actor="self_test",
            tool="audit.py@selftest",
            action="submit",
            summary="self-test row",
            target_kind="job",
            target_id="stmc-test",
            detail={"foo": "bar"},
        )
        print(f"inserted id={eid}")
        rows = list_events(limit=5, actor="self_test")
        print(f"recent: {len(rows)} rows")
        for r in rows:
            print(f"  id={r['id']} action={r['action']} target_id={r['target_id']} "
                  f"detail={r['detail']}")
    else:
        print("Usage: audit.py test")
