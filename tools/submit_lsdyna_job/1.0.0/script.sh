#!/usr/bin/env bash
# submit_lsdyna_job — raw .k file → sbatch (no KooChainRun)
set -euo pipefail

export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import json, os, sys, subprocess, re

sys.path.insert(0, os.environ["SHARED_DIR"])
import registry


def fail(reason: str, **extra):
    print(json.dumps({"ok": False, "reason": reason, **extra}, ensure_ascii=False))
    sys.exit(1)


SBATCH_TEMPLATE = """#!/bin/bash
#SBATCH --job-name={job_name}
#SBATCH --output={work_dir}/lsdyna.slurm.out
#SBATCH --error={work_dir}/lsdyna.slurm.err
#SBATCH --ntasks=1
#SBATCH --cpus-per-task={ncpu}
#SBATCH --mem={memory}
#SBATCH --time={time_limit}
{partition_line}
cd {work_dir}

apptainer exec \\
  --bind /data:/data,/shared:/shared,{work_dir}:{work_dir} \\
  --env LSTC_FILE=/opt/ls-dyna_license/LSTC_FILE \\
  --env LSTC_LICENSE_SERVER={lstc_ip} \\
  --env FI_PROVIDER=tcp \\
  --env I_MPI_FABRICS=ofi \\
  --env LD_LIBRARY_PATH=/opt/openmpi/lib \\
  {lsdyna_sif} \\
  mpirun -n {ncpu} /opt/ls-dyna/lsdyna_R16.1.1 i={k_filename} memory={lsdyna_memory_words}
"""


def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])

    k_file = args["k_file"]
    if not os.path.exists(k_file):
        fail(f"k_file not found: {k_file}")

    lstc_ip = args["lstc_license_ip"]
    ncpu = int(args.get("ncpu", 1))
    memory = args.get("memory", "2G")
    time_limit = args.get("time_limit", "01:00:00")
    lsdyna_mem = args.get("lsdyna_memory_words", "2000m")
    partition = args.get("partition", "")
    lsdyna_sif = args.get("lsdyna_sif",
                          "/opt/apptainers/LSDynaBasic_aocc420_ompi4.0.5_mpp_s.sif")
    dry_run = bool(args.get("dry_run", False))

    work_dir = os.path.dirname(os.path.abspath(k_file))
    k_filename = os.path.basename(k_file)
    job_name = args.get("job_name") or f"raw_lsdyna_{os.path.splitext(k_filename)[0]}"

    partition_line = f"#SBATCH --partition={partition}\n" if partition else ""

    sbatch_text = SBATCH_TEMPLATE.format(
        job_name=job_name,
        work_dir=work_dir,
        ncpu=ncpu,
        memory=memory,
        time_limit=time_limit,
        partition_line=partition_line,
        lstc_ip=lstc_ip,
        lsdyna_sif=lsdyna_sif,
        k_filename=k_filename,
        lsdyna_memory_words=lsdyna_mem,
    )
    sbatch_path = os.path.join(work_dir, f"{job_name}.sbatch")
    with open(sbatch_path, "w") as f:
        f.write(sbatch_text)
    os.chmod(sbatch_path, 0o755)

    slurm_ids = []
    status = "dry_run"
    if not dry_run:
        try:
            r = subprocess.run(
                ["sbatch", sbatch_path],
                capture_output=True, text=True, check=True, timeout=60,
            )
        except subprocess.CalledProcessError as e:
            fail(f"sbatch failed: rc={e.returncode}",
                 stderr=e.stderr[-500:], stdout=e.stdout[-500:])
        m = re.search(r"Submitted batch job (\d+)", r.stdout)
        if m:
            slurm_ids.append(m.group(1))
        status = "submitted"

    reg_id = registry.record_submission(
        tool_name="submit_lsdyna_job",
        work_dir=work_dir,
        output_dir=work_dir,  # raw lsdyna 결과(d3plot)는 work_dir에 그대로 떨어짐
        project_name=job_name,
        runner_config_path=None,
        slurm_job_ids=slurm_ids or None,
        num_angles=None,
        status=status,
        extra={
            "k_file": k_file,
            "sbatch_path": sbatch_path,
            "ncpu": ncpu,
            "memory": memory,
        },
    )

    print(json.dumps({
        "ok": True,
        "registry_id": reg_id,
        "tool": "submit_lsdyna_job",
        "work_dir": work_dir,
        "output_dir": work_dir,
        "k_file": k_file,
        "sbatch_path": sbatch_path,
        "slurm_job_ids": slurm_ids,
        "status": status,
        "follow_up_hint": (
            "raw LS-DYNA 잡: KooChainRun status/rerun 등은 동작 X (KooChainRun 메타 없음). "
            "Slurm 직접 명령(squeue, scancel <jid>) 사용. d3plot은 work_dir에 생성됨."
        ),
    }, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        fail(f"unhandled exception: {type(e).__name__}: {e}")
PY
