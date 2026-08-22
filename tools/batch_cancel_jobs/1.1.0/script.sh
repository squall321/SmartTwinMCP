#!/usr/bin/env bash
# batch_cancel_jobs — 필터로 다건 취소(mode:own, dry_run 기본 true). 자립형(§22.2): _shared 인라인.
# kind:ssh + host:${STMC_SLURM_SSH:-} — 비면 로컬 폴백(dev), 'stc'면 헤드에서 실행(cae00).
# 후보 조회·scancel·상태갱신·audit 모두 jobs.db/slurm 이 있는 헤드에서 수행돼야 하므로 여기서 돈다.
set -euo pipefail

python3 - <<'PY'
import json, os, sqlite3, sys, subprocess, time

DB = os.environ.get("STMC_JOBS_DB") or "/data/SmartTwinMCP/jobs.db"
AUDIT_DB = os.environ.get("STMC_AUDIT_DB") or "/data/SmartTwinMCP/audit.db"
MAX_BATCH = 100


def fail(reason, **extra):
    print(json.dumps({"ok": False, "tool": "batch_cancel_jobs", "reason": reason, **extra}, ensure_ascii=False))
    sys.exit(1)


def _row(r):
    d = dict(r)
    for k in ("slurm_job_ids", "extra"):
        if d.get(k):
            try:
                d[k] = json.loads(d[k])
            except (json.JSONDecodeError, TypeError):
                pass
    return d


def _conn():
    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row
    return con


def get_by_id(rid):
    con = _conn()
    try:
        r = con.execute("SELECT * FROM jobs WHERE id = ?", (int(rid),)).fetchone()
        return _row(r) if r else None
    except sqlite3.OperationalError:
        return None
    finally:
        con.close()


def list_recent(limit, user=None, status=None, tool=None, project_like=None):
    where, params = [], []
    if user:
        where.append("user = ?"); params.append(user)
    if status:
        where.append("status = ?"); params.append(status)
    if tool:
        where.append("tool_name = ?"); params.append(tool)
    if project_like:
        where.append("project_name LIKE ?"); params.append(project_like)
    sql = "SELECT * FROM jobs"
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY submitted_at DESC LIMIT ?"
    params.append(limit)
    con = _conn()
    try:
        return [_row(r) for r in con.execute(sql, params)]
    except sqlite3.OperationalError:
        return []
    finally:
        con.close()


def update_status(job_id, status, notes=None):
    con = _conn()
    try:
        con.execute(
            "UPDATE jobs SET status = ?, last_checked_at = ?, notes = ? WHERE id = ?",
            (status, int(time.time()), notes, job_id),
        )
        con.commit()
    finally:
        con.close()


# §25.3.1 audit(cancel) — 인라인. record_event 명은 L070 정적 grep 충족(변경 도구 필수).
def record_event(actor, tool, action, summary, target_kind, target_id, detail):
    ac = sqlite3.connect(AUDIT_DB)
    try:
        ac.execute("""CREATE TABLE IF NOT EXISTS audit_events (
          id INTEGER PRIMARY KEY AUTOINCREMENT, occurred_at INTEGER NOT NULL,
          actor TEXT NOT NULL, tool TEXT NOT NULL, action TEXT NOT NULL,
          target_kind TEXT, target_id TEXT, summary TEXT NOT NULL, detail TEXT)""")
        ac.execute(
            "INSERT INTO audit_events (occurred_at, actor, tool, action, target_kind, target_id, summary, detail) VALUES (?,?,?,?,?,?,?,?)",
            (int(time.time()), actor, tool, action, target_kind, target_id, summary, json.dumps(detail)),
        )
        ac.commit()
    finally:
        ac.close()


def summarize(row):
    return {
        "registry_id": row["id"],
        "tool_name": row.get("tool_name"),
        "project_name": row.get("project_name"),
        "work_dir": row.get("work_dir"),
        "slurm_job_ids": row.get("slurm_job_ids") or [],
        "status": row.get("status"),
        "user": row.get("user"),
    }


def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])
    caller = os.environ.get("USER") or os.environ.get("LOGNAME")
    if not caller:
        fail("호출자 신원을 알 수 없습니다(USER/LOGNAME 미설정).")

    dry_run = bool(args.get("dry_run", True))

    # --- 후보 수집: 항상 user=caller 로 먼저 좁힌다 ---
    if "registry_ids" in args:
        candidates, skipped_not_owner, missing = [], 0, []
        for rid in args["registry_ids"]:
            row = get_by_id(rid)
            if row is None:
                missing.append(rid); continue
            if row.get("user") != caller:
                skipped_not_owner += 1; continue
            candidates.append(row)
    else:
        skipped_not_owner, missing = 0, []
        submitted_before = args.get("submitted_before")
        fetch_limit = (MAX_BATCH * 5 + 1) if submitted_before is not None else (MAX_BATCH + 1)
        candidates = list_recent(
            limit=fetch_limit, user=caller,
            status=args.get("status"), tool=args.get("tool_name"),
            project_like=args.get("project_like"),
        )
        if submitted_before is not None:
            candidates = [c for c in candidates if (c.get("submitted_at") or 0) < int(submitted_before)]

    if len(candidates) > MAX_BATCH:
        fail(
            f"배치가 너무 큽니다: {len(candidates)} > MAX_BATCH={MAX_BATCH}. "
            f"필터를 좁히거나(submitted_before·project_like) 나눠서 요청하세요.",
            matched=len(candidates), max_batch=MAX_BATCH,
        )

    out = {"ok": True, "tool": "batch_cancel_jobs", "dry_run": dry_run,
           "would_cancel": [], "cancelled": [], "failures": []}

    if dry_run:
        out["would_cancel"] = [summarize(r) for r in candidates]
    else:
        for row in candidates:
            slurm_ids = row.get("slurm_job_ids") or []
            entry = summarize(row)
            if not slurm_ids:
                update_status(row["id"], "cancelled", notes="cancelled via batch_cancel_jobs (no slurm ids)")
                out["cancelled"].append(entry)
                continue
            try:
                r = subprocess.run(["scancel"] + [str(s) for s in slurm_ids],
                                   capture_output=True, text=True, timeout=30)
            except FileNotFoundError:
                entry["reason"] = "scancel not found on PATH"; out["failures"].append(entry); continue
            except subprocess.TimeoutExpired:
                entry["reason"] = "scancel timed out after 30s"; out["failures"].append(entry); continue
            if r.returncode == 0:
                update_status(row["id"], "cancelled", notes="cancelled via batch_cancel_jobs")
                entry["scancel_stderr"] = (r.stderr or "")[-200:]
                out["cancelled"].append(entry)
            else:
                entry["reason"] = f"scancel rc={r.returncode}"
                entry["scancel_stderr"] = (r.stderr or "")[-500:]
                out["failures"].append(entry)

    out["summary"] = {
        "matched": len(candidates),
        "cancelled": len(out["cancelled"]),
        "failed": len(out["failures"]),
        "skipped_not_owner": skipped_not_owner,
    }
    if missing:
        out["summary"]["missing_registry_ids"] = missing

    # 실제 취소가 발생했을 때만 audit(dry_run 은 미리보기라 감사행 없음).
    if not dry_run and out["cancelled"]:
        cancelled_ids = [e["registry_id"] for e in out["cancelled"]]
        try:
            record_event(
                actor=caller,
                tool="batch_cancel_jobs@1.1.0",
                action="cancel",
                summary=f"batch_cancel: cancelled {len(out['cancelled'])} jobs (matched={len(candidates)}, failed={len(out['failures'])})",
                target_kind="job",
                target_id=",".join(str(i) for i in cancelled_ids[:10]) + ("..." if len(cancelled_ids) > 10 else ""),
                detail={
                    "matched": len(candidates),
                    "cancelled_ids": cancelled_ids,
                    "failed_count": len(out["failures"]),
                    "filter": {k: args.get(k) for k in ("status", "tool_name", "project_like", "submitted_before") if args.get(k) is not None},
                },
            )
        except sqlite3.Error:
            pass  # audit 실패가 취소 성공을 되돌리지 않는다.

    print(json.dumps(out, ensure_ascii=False, default=str))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        fail(f"{type(e).__name__}: {e}")
PY
