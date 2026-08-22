#!/usr/bin/env bash
# sync_job_output — 실행 중 잡의 중간 결과를 이 호스트로 증분 동기화(pull).
# local 트랜스포트로 MCP 호스트(cae00/dev)에서 돈다. STMC_SLURM_SSH 로 원격/로컬 분기.
set -euo pipefail

python3 - <<'PY'
import json, os, shlex, socket, subprocess, sys

def out(**kw):
    print(json.dumps(kw, ensure_ascii=False)); 

def fail(reason, **extra):
    out(ok=False, tool="sync_job_output", reason=reason, host=socket.gethostname(), **extra)
    sys.exit(1)

try:
    args = json.loads(os.environ["STMC_ARGS_JSON"])
except (KeyError, json.JSONDecodeError) as e:
    fail(f"STMC_ARGS_JSON missing/invalid: {e}")

rid = args.get("registry_id")
if not isinstance(rid, int):
    fail("registry_id(정수)가 필요합니다.")

ssh = (os.environ.get("STMC_SLURM_SSH") or "").strip()
jobs_db = os.environ.get("STMC_JOBS_DB") or "/data/SmartTwinMCP/jobs.db"
sync_root = os.environ.get("STMC_SYNC_DIR") or "/data/SmartTwinMCP/sync"
dest = args.get("dest") or os.path.join(sync_root, str(rid))
full = bool(args.get("full", False))

def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)

# work_dir·status 를 jobs.db 에서 읽는다. jobs.db 는 슬럼 호스트에 있다 — 로컬(dev)이면
# 같은 프로세스에서 sqlite 직접 읽고, 원격(cae00)이면 작은 파이썬을 ssh 로 보내 읽는다.
if ssh:
    prog = ("import json,os,sqlite3,sys\n"
            "db=os.environ.get('STMC_JOBS_DB','')\n"
            "try:\n"
            " c=sqlite3.connect(db); c.row_factory=sqlite3.Row\n"
            " r=c.execute('SELECT work_dir,status FROM jobs WHERE id=?',(%d,)).fetchone()\n"
            "except Exception as e:\n"
            " print(json.dumps({'err':str(e)})); sys.exit(0)\n"
            "print(json.dumps({'work_dir':r['work_dir'],'status':r['status']} if r else {'err':'not_found'}))\n"
            % rid)
    remote = f"STMC_JOBS_DB={shlex.quote(jobs_db)} python3 -c {shlex.quote(prog)}"
    p = sh(["ssh", "-o", "BatchMode=yes", ssh, remote])
    if p.returncode != 0:
        fail("원격 work_dir 조회 실패(ssh)", stderr=p.stderr[-400:])
    try:
        info = json.loads((p.stdout.strip().splitlines() or ["{}"])[-1])
    except Exception:
        fail("work_dir 조회 응답 파싱 실패", stdout=p.stdout[-400:])
else:
    import sqlite3 as _sq
    try:
        c = _sq.connect(jobs_db); c.row_factory = _sq.Row
        row = c.execute("SELECT work_dir,status FROM jobs WHERE id=?", (rid,)).fetchone()
        info = {"work_dir": row["work_dir"], "status": row["status"]} if row else {"err": "not_found"}
    except Exception as e:
        fail(f"jobs.db 열기 실패: {e}")

if info.get("err") == "not_found":
    fail(f"registry_id {rid} 없음")
if info.get("err"):
    fail(f"jobs.db 조회 오류: {info['err']}")
work_dir = info["work_dir"]; status = info.get("status")

os.makedirs(dest, exist_ok=True)

# 진행 파일 기본셋(경량) vs 전체.
if args.get("patterns"):
    includes = list(args["patterns"])
elif full:
    includes = ["*"]
else:
    includes = ["glstat*", "messag*", "d3hsp*", "*.out", "*.log", "status*", "bg_switch*", "*.csv"]

# rsync: 원격이면 ssh:work_dir, 로컬이면 로컬 경로. 증분(-a --update), 대용량 아니면 include 필터.
src = f"{ssh}:{work_dir}/" if ssh else f"{work_dir.rstrip('/')}/"
cmd = ["rsync", "-a", "--update", "--prune-empty-dirs"]
if includes != ["*"]:
    for pat in includes:
        cmd += ["--include", pat]
    cmd += ["--include", "*/", "--exclude", "*"]
cmd += [src, dest + "/"]
r = sh(cmd)
if r.returncode not in (0, 24):  # 24 = 전송 중 사라진 파일(실행 중이면 정상)
    fail("rsync 실패", stderr=r.stderr[-500:], cmd=" ".join(cmd[:6]) + " …")

# 받은 파일 요약.
synced = []
for root, _, files in os.walk(dest):
    for fn in files:
        fp = os.path.join(root, fn)
        try:
            synced.append({"file": os.path.relpath(fp, dest), "bytes": os.path.getsize(fp)})
        except OSError:
            pass
synced.sort(key=lambda x: x["file"])
out(ok=True, tool="sync_job_output", registry_id=rid, job_status=status,
    mode="ssh-pull" if ssh else "local", work_dir=work_dir, dest=dest,
    n_files=len(synced), files=synced[:200],
    note="중간 동기화(증분). 완료 전이면 다시 호출해 갱신본을 받으세요." )
PY
