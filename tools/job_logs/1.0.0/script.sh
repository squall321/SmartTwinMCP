#!/usr/bin/env bash
# job_logs — 잡의 Slurm stdout/stderr 마지막 N줄. 자립형(§22.2): _shared 미전송이라 인라인.
# kind:ssh + host:${STMC_SLURM_SSH:-} — 비면 로컬 폴백(dev), 'stc'면 헤드에서 실행(cae00).
# 로그 파일이 헤드의 work_dir 에 있으므로 이 도구가 거기서 도는 게 맞다.
set -euo pipefail

python3 - <<'PY'
import json, os, sqlite3, sys, time

DB = os.environ.get("STMC_JOBS_DB") or "/data/SmartTwinMCP/jobs.db"
AUDIT_DB = os.environ.get("STMC_AUDIT_DB") or "/data/SmartTwinMCP/audit.db"


def fail(reason, **extra):
    print(json.dumps({"ok": False, "tool": "job_logs", "reason": reason, **extra}, ensure_ascii=False))
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


def resolve(args):
    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row
    try:
        if "registry_id" in args:
            r = con.execute("SELECT * FROM jobs WHERE id = ?", (int(args["registry_id"]),)).fetchone()
            return _row(r) if r else None
        if "work_dir" in args:
            wd = args["work_dir"].rstrip("/")
            for r in con.execute("SELECT * FROM jobs ORDER BY submitted_at DESC LIMIT 500"):
                if (r["work_dir"] or "").rstrip("/") == wd:
                    return _row(r)
        return None
    except sqlite3.OperationalError:
        return None
    finally:
        con.close()


def tail_file(path, n):
    if not os.path.exists(path):
        return False, ""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError as e:
        return True, f"<read error: {type(e).__name__}: {e}>"
    return True, "".join(lines[-n:])


# §25.3.3 audit(inspect) — 인라인. record_event 명은 L070 정적 grep 충족.
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


def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])
    job = resolve(args)
    if not job:
        fail("레지스트리에 잡이 없습니다.", lookup=args)

    work_dir = job.get("work_dir") or ""
    if not work_dir:
        fail("레지스트리 행에 work_dir 가 없습니다.", registry_id=job.get("id"))

    n = int(args.get("lines", 50))
    stdout_path = os.path.join(work_dir, "lsdyna.slurm.out")
    stderr_path = os.path.join(work_dir, "lsdyna.slurm.err")
    out_exists, out_tail = tail_file(stdout_path, n)
    err_exists, err_tail = tail_file(stderr_path, n)

    caller = os.environ.get("USER") or os.environ.get("LOGNAME") or "unknown"
    try:
        record_event(
            actor=caller,
            tool="job_logs@1.0.0",
            action="inspect",
            summary=f"tailed logs for job {job['id']} ({n} lines)",
            target_kind="job",
            target_id=str(job["id"]),
            detail={"lines": n, "stdout_exists": out_exists, "stderr_exists": err_exists},
        )
    except sqlite3.Error:
        pass

    print(json.dumps({
        "ok": True,
        "tool": "job_logs",
        "registry_id": job["id"],
        "work_dir": work_dir,
        "stdout_path": stdout_path,
        "stderr_path": stderr_path,
        "stdout_exists": out_exists,
        "stderr_exists": err_exists,
        "stdout_tail": out_tail,
        "stderr_tail": err_tail,
        "lines": n,
    }, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        fail(f"{type(e).__name__}: {e}")
PY
