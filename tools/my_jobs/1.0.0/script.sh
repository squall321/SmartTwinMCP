#!/usr/bin/env bash
# my_jobs — 호출자($USER) 소유 잡 목록. 자립형(§22.2): _shared 미전송이라 registry SQL 인라인.
# kind:ssh + host:${STMC_SLURM_SSH:-} — 비면 러너가 로컬 폴백(dev), 'stc'면 헤드에서 실행(cae00).
set -euo pipefail

python3 - <<'PY'
import json, os, sqlite3, sys

DB = os.environ.get("STMC_JOBS_DB") or "/data/SmartTwinMCP/jobs.db"


def fail(reason, **extra):
    print(json.dumps({"ok": False, "tool": "my_jobs", "reason": reason, **extra}, ensure_ascii=False))
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


def main():
    # §18.1: 신원은 환경($USER)에서, 인자로 받지 않는다. 원격이면 여기의 USER = ssh 계정(stcx)이라
    # submit 이 기록한 소유자와 일치한다(cae00 단일 계정 모델).
    caller = os.environ.get("USER") or os.environ.get("LOGNAME")
    if not caller:
        fail("호출자 신원을 알 수 없습니다(USER/LOGNAME 미설정).")

    args = json.loads(os.environ["STMC_ARGS_JSON"])
    limit = int(args.get("limit", 20))
    status = args.get("status")
    tool_name = args.get("tool_name")
    since = args.get("since")

    where = ["user = ?"]
    params = [caller]
    if status:
        where.append("status = ?"); params.append(status)
    if tool_name:
        where.append("tool_name = ?"); params.append(tool_name)
    if since is not None:
        where.append("submitted_at >= ?"); params.append(int(since))
    sql = "SELECT * FROM jobs WHERE " + " AND ".join(where) + " ORDER BY submitted_at DESC LIMIT ?"
    params.append(limit)

    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row
    try:
        rows = [_row(r) for r in con.execute(sql, params)]
    except sqlite3.OperationalError:
        # 아직 jobs 테이블이 없음(빈 레지스트리) → 소유 잡 0건.
        rows = []
    finally:
        con.close()

    for r in rows:
        r.setdefault("user", None)

    print(json.dumps({
        "ok": True,
        "tool": "my_jobs",
        "caller": caller,
        "count": len(rows),
        "jobs": rows,
    }, ensure_ascii=False, default=str))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        fail(f"{type(e).__name__}: {e}")
PY
