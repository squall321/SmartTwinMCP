#!/usr/bin/env python3
"""SQLite job registry — persistent across MCP sessions.

DB path: /data/SmartTwinMCP/jobs.db
Auto-creates dir + schema on first use.

API:
  record_submission(...) → job_id (DB primary key, NOT slurm job id)
  list_recent(limit=20, status=None, tool=None, since=None, project_like=None) → [row, ...]
  get_by_id(job_id) → row dict
  update_status(job_id, status, notes=None) → bool
  search(query, limit=20) → [row, ...]  (LIKE-based; FTS5 optional later)
"""
from __future__ import annotations

import json
import os
import sqlite3
import time
from contextlib import contextmanager
from typing import Any, Iterable

DB_DIR = "/data/SmartTwinMCP"
DB_PATH = os.path.join(DB_DIR, "jobs.db")


SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    submitted_at INTEGER NOT NULL,
    tool_name TEXT NOT NULL,
    project_name TEXT,
    work_dir TEXT NOT NULL,
    output_dir TEXT NOT NULL,
    runner_config_path TEXT,
    slurm_job_ids TEXT,                    -- JSON array
    sphere_job_id TEXT,
    num_angles INTEGER,
    status TEXT DEFAULT 'submitted',       -- submitted/running/completed/failed/cancelled/dry_run
    last_checked_at INTEGER,
    notes TEXT,
    user TEXT,
    extra TEXT                              -- JSON blob for tool-specific data
);

CREATE INDEX IF NOT EXISTS idx_submitted_at ON jobs(submitted_at DESC);
CREATE INDEX IF NOT EXISTS idx_status ON jobs(status);
CREATE INDEX IF NOT EXISTS idx_tool ON jobs(tool_name);
CREATE INDEX IF NOT EXISTS idx_project ON jobs(project_name);
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
    # decode JSON fields
    for k in ("slurm_job_ids", "extra"):
        if d.get(k):
            try:
                d[k] = json.loads(d[k])
            except (json.JSONDecodeError, TypeError):
                pass
    return d


def record_submission(
    tool_name: str,
    work_dir: str,
    output_dir: str,
    project_name: str | None = None,
    runner_config_path: str | None = None,
    slurm_job_ids: list[str] | None = None,
    sphere_job_id: str | None = None,
    num_angles: int | None = None,
    status: str = "submitted",
    notes: str | None = None,
    extra: dict | None = None,
) -> int:
    """Insert a row, return the DB primary key (NOT Slurm job ID)."""
    now = int(time.time())
    user = os.environ.get("USER") or os.environ.get("LOGNAME")
    with _conn() as con:
        cur = con.execute(
            """INSERT INTO jobs (
                submitted_at, tool_name, project_name, work_dir, output_dir,
                runner_config_path, slurm_job_ids, sphere_job_id, num_angles,
                status, notes, user, extra
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                now, tool_name, project_name, work_dir, output_dir,
                runner_config_path,
                json.dumps(slurm_job_ids) if slurm_job_ids else None,
                sphere_job_id, num_angles,
                status, notes, user,
                json.dumps(extra) if extra else None,
            ),
        )
        return cur.lastrowid


def list_recent(
    limit: int = 20,
    status: str | None = None,
    tool: str | None = None,
    since: int | None = None,
    project_like: str | None = None,
    user: str | None = None,
) -> list[dict]:
    """Page through recent jobs. Filters are ANDed."""
    where = []
    params: list[Any] = []
    if status:
        where.append("status = ?")
        params.append(status)
    if tool:
        where.append("tool_name = ?")
        params.append(tool)
    if since:
        where.append("submitted_at >= ?")
        params.append(since)
    if project_like:
        where.append("project_name LIKE ?")
        params.append(project_like)
    if user:
        where.append("user = ?")
        params.append(user)

    sql = "SELECT * FROM jobs"
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY submitted_at DESC LIMIT ?"
    params.append(limit)

    with _conn() as con:
        return [_row_to_dict(r) for r in con.execute(sql, params)]


def get_by_id(job_id: int) -> dict | None:
    with _conn() as con:
        row = con.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
        return _row_to_dict(row) if row else None


def update_status(job_id: int, status: str, notes: str | None = None) -> bool:
    with _conn() as con:
        params: list[Any] = [status, int(time.time())]
        sql = "UPDATE jobs SET status = ?, last_checked_at = ?"
        if notes is not None:
            sql += ", notes = ?"
            params.append(notes)
        sql += " WHERE id = ?"
        params.append(job_id)
        cur = con.execute(sql, params)
        return cur.rowcount > 0


def search(query: str, limit: int = 20) -> list[dict]:
    """LIKE search on project_name, work_dir, notes. Case-insensitive."""
    q = f"%{query}%"
    sql = """SELECT * FROM jobs
             WHERE project_name LIKE ? COLLATE NOCASE
                OR work_dir LIKE ? COLLATE NOCASE
                OR notes LIKE ? COLLATE NOCASE
             ORDER BY submitted_at DESC LIMIT ?"""
    with _conn() as con:
        return [_row_to_dict(r) for r in con.execute(sql, (q, q, q, limit))]


if __name__ == "__main__":
    # quick self-test
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "test":
        jid = record_submission(
            tool_name="test_tool",
            work_dir="/tmp/test",
            output_dir="/tmp/test/output",
            project_name="self_test",
            slurm_job_ids=["999", "1000"],
            num_angles=1,
            status="dry_run",
        )
        print(f"inserted id={jid}")
        rows = list_recent(limit=5, tool="test_tool")
        print(f"recent: {len(rows)} rows")
        for r in rows:
            print(f"  id={r['id']} work_dir={r['work_dir']} slurm_ids={r['slurm_job_ids']}")
    else:
        print("Usage: registry.py test")
