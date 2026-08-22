#!/usr/bin/env bash
# get_job_details — 단일 잡 + 디스크 상태. 자립형(§22.2): _shared 미전송이라 registry/audit 인라인.
# kind:ssh + host:${STMC_SLURM_SSH:-} — 비면 로컬 폴백(dev), 'stc'면 헤드에서 실행(cae00).
# 디스크 상태는 잡의 work_dir 가 있는 곳(헤드)에서 확인해야 하므로 이 도구가 거기서 도는 게 맞다.
set -euo pipefail

python3 - <<'PY'
import json, os, sqlite3, sys, datetime, glob, time, subprocess

DB = os.environ.get("STMC_JOBS_DB") or "/data/SmartTwinMCP/jobs.db"
AUDIT_DB = os.environ.get("STMC_AUDIT_DB") or "/data/SmartTwinMCP/audit.db"


def fail(reason):
    print(json.dumps({"ok": False, "reason": reason}, ensure_ascii=False))
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


def slurm_live(slurm_job_ids):
    """squeue 로 현재 slurm 상태를 조회한다(헤드에서 실행). 큐에 없으면 종료/미존재로 본다.
    레지스트리 status 는 제출 시점 값이라 갱신되지 않으므로, 살아있는 상태는 여기서 본다."""
    ids = [str(s) for s in (slurm_job_ids or [])]
    if not ids:
        return {"queried": False, "reason": "no slurm_job_ids"}
    try:
        r = subprocess.run(["squeue", "-h", "-o", "%i %T %M %R", "-j", ",".join(ids)],
                           capture_output=True, text=True, timeout=10)
    except FileNotFoundError:
        return {"queried": False, "reason": "squeue not on PATH"}
    except subprocess.TimeoutExpired:
        return {"queried": False, "reason": "squeue timed out"}
    states = {}
    for line in r.stdout.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) >= 2:
            states[parts[0]] = {"state": parts[1],
                                "elapsed": parts[2] if len(parts) > 2 else None,
                                "reason": parts[3] if len(parts) > 3 else None}
    in_queue = [i for i in ids if i in states]
    gone = [i for i in ids if i not in states]
    return {"queried": True, "in_queue": states, "finished_or_absent": gone,
            "any_active": bool(in_queue)}


def disk_state(job: dict) -> dict:
    wd = job.get("work_dir")
    od = job.get("output_dir")
    rc = job.get("runner_config_path")
    state = {
        "work_dir_exists": bool(wd) and os.path.isdir(wd),
        "output_dir_exists": bool(od) and os.path.isdir(od),
        "scenario_json_exists": bool(wd) and os.path.exists(os.path.join(wd, "scenario.json")),
        "runner_config_exists": bool(rc) and os.path.exists(rc),
    }
    if state["output_dir_exists"]:
        state["num_run_dirs"] = len(glob.glob(os.path.join(od, "Run_*")))
        state["sphere_report_html_exists"] = os.path.exists(os.path.join(od, "sphere_report.html"))
        state["sphere_report_json_exists"] = os.path.exists(os.path.join(od, "sphere_report.json"))
        state["num_finished_d3plot"] = len(glob.glob(os.path.join(od, "Run_*", "Output", "d3plot")))
        state["num_deep_reports"] = len(glob.glob(os.path.join(od, "Run_*", "Output", "report")))
        # 일반 dyna(평탄 work_dir)용 완료 신호도 함께 — Run_* 구조가 아닌 경우.
        state["flat_d3plot_exists"] = os.path.exists(os.path.join(od, "d3plot"))
        slurm_out = os.path.join(od, "lsdyna.slurm.out")
        state["slurm_out_exists"] = os.path.exists(slurm_out)
    return state


# §25.3.2 audit(inspect) — _shared 미전송이라 인라인. 함수명 record_event 는 L070 정적 grep 충족.
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
        fail("레지스트리에 잡이 없습니다. my_jobs 로 목록을 확인하세요.")

    ts = job.get("submitted_at")
    if ts:
        job["submitted_at_human"] = datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S")
    job["disk_state"] = disk_state(job)
    job["slurm_live"] = slurm_live(job.get("slurm_job_ids"))

    caller = os.environ.get("USER") or os.environ.get("LOGNAME") or "unknown"
    try:
        record_event(
            actor=caller,
            tool="get_job_details@1.0.0",
            action="inspect",
            summary=f"fetched details for job {job['id']} ({job.get('tool_name')})",
            target_kind="job",
            target_id=str(job["id"]),
            detail={"tool_inspected": job.get("tool_name"), "status_seen": job.get("status")},
        )
    except sqlite3.Error:
        pass  # audit 실패가 조회 성공을 막지 않는다.

    print(json.dumps({"ok": True, "job": job}, ensure_ascii=False, default=str))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        fail(f"{type(e).__name__}: {e}")
PY
