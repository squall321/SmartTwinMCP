#!/usr/bin/env bash
# submit_lsdyna_remote — raw .k → sbatch on a remote cluster head over SSH.
#
# This script runs on the REMOTE host (the runner pipes it over `ssh ... bash -s`).
# Per §22.2 of AGENT_GUIDE.md, _shared/ is NOT shipped to the remote, so registry
# logic is INLINED below — we open /data/SmartTwinMCP/jobs.db (or $STMC_JOBS_DB)
# directly with sqlite3.
set -euo pipefail

# Probe the shared mount on the remote (§22.7). Fail clearly if not present.
if [ ! -d /data/SmartTwinMCP ]; then
  python3 -c 'import json; print(json.dumps({"ok": False, "tool": "submit_lsdyna_remote", "reason": "/data/SmartTwinMCP not mounted on remote head — shared filesystem missing or wrong host", "remote_host": __import__("socket").gethostname()}))'
  exit 1
fi

python3 - <<'PY'
import json, os, re, socket, sqlite3, subprocess, sys, time

REMOTE_HOST = socket.gethostname()


def fail(reason, **extra):
    payload = {"ok": False, "tool": "submit_lsdyna_remote", "remote_host": REMOTE_HOST, "reason": reason}
    payload.update(extra)
    print(json.dumps(payload, ensure_ascii=False))
    sys.exit(1)


# --- args ---
try:
    args = json.loads(os.environ["STMC_ARGS_JSON"])
except (KeyError, json.JSONDecodeError) as e:
    fail(f"STMC_ARGS_JSON missing or invalid: {e}")

k_file = args["k_file"]
if not os.path.exists(k_file):
    fail(f"k_file not found on remote at {k_file} — is the shared filesystem mounted?")

lstc_ip = args["lstc_license_ip"]
ncpu = int(args.get("ncpu", 1))
memory = args.get("memory", "2G")
time_limit = args.get("time_limit", "01:00:00")
dry_run = bool(args.get("dry_run", True))

work_dir = os.path.dirname(os.path.abspath(k_file))
k_filename = os.path.basename(k_file)
job_name = f"raw_lsdyna_{os.path.splitext(k_filename)[0]}"

# --- inlined registry (§22.2): open jobs.db directly ---
DB_PATH = os.environ.get("STMC_JOBS_DB") or "/data/SmartTwinMCP/jobs.db"
DB_DIR = os.path.dirname(DB_PATH)

SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    submitted_at INTEGER NOT NULL,
    tool_name TEXT NOT NULL,
    project_name TEXT,
    work_dir TEXT NOT NULL,
    output_dir TEXT NOT NULL,
    runner_config_path TEXT,
    slurm_job_ids TEXT,
    sphere_job_id TEXT,
    num_angles INTEGER,
    status TEXT DEFAULT 'submitted',
    last_checked_at INTEGER,
    notes TEXT,
    user TEXT,
    extra TEXT
);
CREATE INDEX IF NOT EXISTS idx_submitted_at ON jobs(submitted_at DESC);
CREATE INDEX IF NOT EXISTS idx_status ON jobs(status);
CREATE INDEX IF NOT EXISTS idx_tool ON jobs(tool_name);
CREATE INDEX IF NOT EXISTS idx_project ON jobs(project_name);
"""


def db_connect():
    try:
        os.makedirs(DB_DIR, exist_ok=True)
    except OSError as e:
        fail(f"cannot create registry dir {DB_DIR}: {e}")
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    con.executescript(SCHEMA)
    return con


# --- §22.6 idempotency: same k_file, last 60s, non-empty slurm_job_ids ---
def find_recent_duplicate(con):
    since = int(time.time()) - 60
    rows = con.execute(
        """SELECT id, slurm_job_ids, status FROM jobs
           WHERE tool_name = ? AND submitted_at >= ?
             AND slurm_job_ids IS NOT NULL AND slurm_job_ids != ''
           ORDER BY submitted_at DESC""",
        ("submit_lsdyna_remote", since),
    ).fetchall()
    for r in rows:
        # extra is JSON with k_file; check that
        extra_row = con.execute("SELECT extra FROM jobs WHERE id = ?", (r["id"],)).fetchone()
        if not extra_row or not extra_row["extra"]:
            continue
        try:
            extra = json.loads(extra_row["extra"])
        except json.JSONDecodeError:
            continue
        if extra.get("k_file") == k_file:
            try:
                ids = json.loads(r["slurm_job_ids"])
            except (json.JSONDecodeError, TypeError):
                ids = []
            if ids:
                return r["id"], ids
    return None, None


con = db_connect()

dup_id, dup_ids = find_recent_duplicate(con)
if dup_ids:
    print(json.dumps({
        "ok": True,
        "tool": "submit_lsdyna_remote",
        "registry_id": dup_id,
        "remote_host": REMOTE_HOST,
        "work_dir": work_dir,
        "output_dir": work_dir,
        "k_file": k_file,
        "slurm_job_ids": dup_ids,
        "status": "submitted",
        "note": "duplicate submission suppressed",
    }, ensure_ascii=False))
    sys.exit(0)


# --- sbatch script (matches submit_lsdyna_job template) ---
SBATCH_TEMPLATE = """#!/bin/bash
#SBATCH --job-name={job_name}
#SBATCH --output={work_dir}/lsdyna.slurm.out
#SBATCH --error={work_dir}/lsdyna.slurm.err
#SBATCH --ntasks=1
#SBATCH --cpus-per-task={ncpu}
#SBATCH --mem={memory}
#SBATCH --time={time_limit}
cd {work_dir}

apptainer exec \\
  --bind /data:/data,/shared:/shared,{work_dir}:{work_dir} \\
  --env LSTC_FILE=/opt/ls-dyna_license/LSTC_FILE \\
  --env LSTC_LICENSE_SERVER={lstc_ip} \\
  --env FI_PROVIDER=tcp \\
  --env I_MPI_FABRICS=ofi \\
  --env LD_LIBRARY_PATH=/opt/openmpi/lib \\
  /opt/apptainers/LSDynaBasic_aocc420_ompi4.0.5_mpp_s.sif \\
  mpirun -n {ncpu} /opt/ls-dyna/lsdyna_R16.1.1 i={k_filename} memory=2000m
"""

sbatch_text = SBATCH_TEMPLATE.format(
    job_name=job_name,
    work_dir=work_dir,
    ncpu=ncpu,
    memory=memory,
    time_limit=time_limit,
    lstc_ip=lstc_ip,
    k_filename=k_filename,
)
sbatch_path = os.path.join(work_dir, f"{job_name}.sbatch")
try:
    with open(sbatch_path, "w") as f:
        f.write(sbatch_text)
    os.chmod(sbatch_path, 0o755)
except OSError as e:
    fail(f"cannot write sbatch script {sbatch_path}: {e}")

slurm_ids = []
status = "dry_run"
if not dry_run:
    try:
        r = subprocess.run(
            ["sbatch", sbatch_path],
            capture_output=True, text=True, check=True, timeout=60,
        )
    except FileNotFoundError:
        fail("sbatch not on PATH on remote head — Slurm CLI not installed?")
    except subprocess.TimeoutExpired:
        fail("sbatch timed out after 60s on remote head")
    except subprocess.CalledProcessError as e:
        fail(f"sbatch failed: rc={e.returncode}",
             stderr=(e.stderr or "")[-500:], stdout=(e.stdout or "")[-500:])
    m = re.search(r"Submitted batch job (\d+)", r.stdout)
    if m:
        slurm_ids.append(m.group(1))
    status = "submitted"

# --- record in registry (inlined; mirrors registry.record_submission) ---
now = int(time.time())
caller = os.environ.get("USER") or os.environ.get("LOGNAME")
extra_blob = json.dumps({
    "k_file": k_file,
    "sbatch_path": sbatch_path,
    "ncpu": ncpu,
    "memory": memory,
    "remote_host": REMOTE_HOST,
    "transport": "ssh",
})

try:
    cur = con.execute(
        """INSERT INTO jobs (
            submitted_at, tool_name, project_name, work_dir, output_dir,
            runner_config_path, slurm_job_ids, sphere_job_id, num_angles,
            status, notes, user, extra
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            now, "submit_lsdyna_remote", job_name, work_dir, work_dir,
            None,
            json.dumps(slurm_ids) if slurm_ids else None,
            None, None,
            status, None, caller,
            extra_blob,
        ),
    )
    reg_id = cur.lastrowid
    con.commit()
except sqlite3.Error as e:
    fail(f"registry insert failed: {e}")
finally:
    con.close()

print(json.dumps({
    "ok": True,
    "registry_id": reg_id,
    "tool": "submit_lsdyna_remote",
    "remote_host": REMOTE_HOST,
    "work_dir": work_dir,
    "output_dir": work_dir,
    "k_file": k_file,
    "sbatch_path": sbatch_path,
    "slurm_job_ids": slurm_ids,
    "status": status,
}, ensure_ascii=False))
PY
