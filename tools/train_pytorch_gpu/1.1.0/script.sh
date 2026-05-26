#!/usr/bin/env bash
# train_pytorch_gpu — submit a PyTorch training script to a Slurm GPU partition.
set -euo pipefail

export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import json, os, sys, subprocess, re, shlex

sys.path.insert(0, os.environ["SHARED_DIR"])
import registry
import job_helpers
import audit


SBATCH_TEMPLATE = """#!/bin/bash
#SBATCH --job-name={job_name}
#SBATCH --output={work_dir}/train.slurm.out
#SBATCH --error={work_dir}/train.slurm.err
#SBATCH --partition={gpu_partition}
#SBATCH --gres=gpu:{gres_spec}
#SBATCH --ntasks=1
#SBATCH --cpus-per-task={cpus_per_task}
#SBATCH --mem={mem}
#SBATCH --time={time_limit}
cd {work_dir}

apptainer exec \\
  --nv \\
  --bind /data:/data,/shared:/shared,{work_dir}:{work_dir} \\
  --env NVIDIA_VISIBLE_DEVICES=all \\
  --env CUDA_DEVICE_ORDER=PCI_BUS_ID \\
{multi_gpu_env}  {apptainer_sif} \\
  python3 {train_script} {extra_args_quoted}
"""


def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])

    train_script = args["train_script"]
    if not os.path.isfile(train_script):
        job_helpers.fail(f"train_script not found: {train_script}")

    work_dir = args["work_dir"]
    if not os.path.isdir(work_dir):
        job_helpers.fail(f"work_dir does not exist: {work_dir}")
    if not os.access(work_dir, os.W_OK):
        job_helpers.fail(f"work_dir not writable: {work_dir}")

    apptainer_sif = args.get("apptainer_sif", "/opt/apptainers/pytorch_cuda12.sif")
    extra_args = args.get("extra_args", []) or []
    if not isinstance(extra_args, list):
        job_helpers.fail("extra_args must be a list of strings", got=type(extra_args).__name__)

    time_limit = args.get("time_limit", "04:00:00")
    dry_run = bool(args.get("dry_run", True))

    # --- §14.1 cross-validation ---
    gpus = int(args.get("gpus", 0))
    gpu_type = args.get("gpu_type", "any")
    gpu_partition = args.get("gpu_partition")

    if gpus >= 1 and not gpu_partition:
        job_helpers.fail("gpu_partition is required when gpus >= 1", got=args)
    if gpus == 0 and gpu_partition and gpu_partition.startswith("gpu-"):
        job_helpers.fail(
            "gpu_partition set but gpus=0 — pass gpus >= 1 or drop the partition",
            got=args,
        )

    # --- §14.2 sbatch directive values ---
    # gres_spec: "<type>:<N>" or "<N>" if gpu_type=="any"
    n_gpus_for_alloc = max(gpus, 1)  # we still need >=1 GPU when requesting a GPU partition
    gres_spec = f"{n_gpus_for_alloc}" if gpu_type == "any" else f"{gpu_type}:{n_gpus_for_alloc}"

    # Defaults scale linearly with gpus (multiplier = max(gpus, 1) so CPU-only runs still get
    # a sane single-slot allocation if someone happens to use this on a CPU partition).
    mult = max(gpus, 1)
    cpus_per_task = 8 * mult
    mem = f"{32 * mult}G"

    job_name = f"pytorch_{os.path.splitext(os.path.basename(train_script))[0]}"

    # --- §14.3 multi-GPU NCCL env (only when gpus >= 2) ---
    if gpus >= 2:
        multi_gpu_env = (
            "  --env NCCL_DEBUG=WARN \\\n"
            "  --env NCCL_SOCKET_IFNAME=^docker0,lo \\\n"
        )
    else:
        multi_gpu_env = ""

    extra_args_quoted = " ".join(shlex.quote(a) for a in extra_args)

    # GPU jobs only — bail if no gpu_partition (the §14 spec is GPU-targeted).
    if not gpu_partition:
        job_helpers.fail(
            "this tool targets GPU partitions; set gpus>=1 and gpu_partition",
            hint="see AGENT_GUIDE §14",
        )

    sbatch_text = SBATCH_TEMPLATE.format(
        job_name=job_name,
        work_dir=work_dir,
        gpu_partition=gpu_partition,
        gres_spec=gres_spec,
        cpus_per_task=cpus_per_task,
        mem=mem,
        time_limit=time_limit,
        multi_gpu_env=multi_gpu_env,
        apptainer_sif=apptainer_sif,
        train_script=train_script,
        extra_args_quoted=extra_args_quoted,
    )

    sbatch_path = os.path.join(work_dir, "train.sbatch")
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
        except FileNotFoundError:
            job_helpers.fail("sbatch binary not found on this host", sbatch_path=sbatch_path)
        except subprocess.CalledProcessError as e:
            job_helpers.fail(
                f"sbatch failed: rc={e.returncode}",
                stderr=(e.stderr or "")[-500:],
                stdout=(e.stdout or "")[-500:],
            )
        m = re.search(r"Submitted batch job (\d+)", r.stdout)
        if m:
            slurm_ids.append(m.group(1))
        status = "submitted"

    sbatch_params = {
        "partition": gpu_partition,
        "gres": gres_spec,
        "cpus_per_task": cpus_per_task,
        "mem": mem,
        "time_limit": time_limit,
    }

    reg_id = registry.record_submission(
        tool_name="train_pytorch_gpu",
        work_dir=work_dir,
        output_dir=work_dir,
        project_name=job_name,
        runner_config_path=None,
        slurm_job_ids=slurm_ids or None,
        num_angles=None,
        status=status,
        extra={
            "gpus": gpus,
            "gpu_type": gpu_type,
            "gpu_partition": gpu_partition,
            "framework": "pytorch",
            "train_script": train_script,
            "apptainer_sif": apptainer_sif,
            "extra_args": extra_args,
            "sbatch_path": sbatch_path,
            "sbatch_params": sbatch_params,
        },
    )

    # §25.3.1 audit row (success path only; failures stay silent per §25.3).
    actor = os.environ.get("USER") or os.environ.get("LOGNAME") or "unknown"
    audit.record_event(
        actor=actor,
        tool="train_pytorch_gpu@1.1.0",
        action="submit",
        summary=f"submitted pytorch GPU train {train_script} ({gpus} {gpu_type} on {gpu_partition}) -> slurm {slurm_ids or '[]'}",
        target_kind="job",
        target_id=str(reg_id),
        detail={
            "train_script": train_script,
            "gpus": gpus,
            "gpu_type": gpu_type,
            "gpu_partition": gpu_partition,
            "slurm_job_ids": slurm_ids,
            "dry_run": dry_run,
        },
    )

    print(json.dumps({
        "ok": True,
        "registry_id": reg_id,
        "tool": "train_pytorch_gpu",
        "work_dir": work_dir,
        "sbatch_path": sbatch_path,
        "slurm_job_ids": slurm_ids,
        "status": status,
        "sbatch_params": sbatch_params,
        "gpu": {
            "gpus": gpus,
            "gpu_type": gpu_type,
            "gpu_partition": gpu_partition,
        },
        "follow_up_hint": (
            "PyTorch GPU training job. Use job_status / job_logs with registry_id "
            "to monitor. Slurm allocates CUDA_VISIBLE_DEVICES per task — do not "
            "override it inside your script."
        ),
    }, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        job_helpers.fail(f"unhandled exception: {type(e).__name__}: {e}")
PY
