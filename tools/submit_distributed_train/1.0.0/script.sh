#!/usr/bin/env bash
# submit_distributed_train — multi-node multi-GPU PyTorch distributed training via Slurm + srun + apptainer.
set -euo pipefail

export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import json, os, sys, subprocess, re, shlex

sys.path.insert(0, os.environ["SHARED_DIR"])
import registry
import job_helpers


SBATCH_TEMPLATE = """#!/bin/bash
#SBATCH --job-name={job_name}
#SBATCH --output={work_dir}/train.slurm.out
#SBATCH --error={work_dir}/train.slurm.err
#SBATCH --partition={gpu_partition}
#SBATCH --nodes={nodes}
#SBATCH --ntasks-per-node={ntasks_per_node}
#SBATCH --cpus-per-task={cpus_per_task}
#SBATCH --mem-per-cpu={mem_per_cpu}
#SBATCH --time={time_limit}
#SBATCH --exclusive
#SBATCH --gres=gpu:{gres_spec}
cd {work_dir}

srun --mpi=pmix \\
  apptainer exec \\
    --nv \\
    --bind /data:/data,/shared:/shared,{work_dir}:{work_dir} \\
    --env NVIDIA_VISIBLE_DEVICES=all \\
    --env CUDA_DEVICE_ORDER=PCI_BUS_ID \\
{nccl_env}{fabric_env}    {apptainer_sif} \\
    python3 {train_script} {extra_args_quoted}
"""


def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])

    # --- domain pre-conditions (JSON Schema can't check these) ---
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

    time_limit = args.get("time_limit", "08:00:00")
    mem_per_cpu = args.get("mem_per_cpu", "4G")
    dry_run = bool(args.get("dry_run", True))

    # --- §14.1 GPU cross-validation (purpose-built GPU tool — reject gpus=0) ---
    gpus = int(args.get("gpus", 0))
    gpu_type = args.get("gpu_type", "any")
    gpu_partition = args.get("gpu_partition")

    if gpus < 1:
        job_helpers.fail(
            "this tool is purpose-built GPU; gpus must be >= 1 (see AGENT_GUIDE §14.1)",
            got_gpus=gpus,
        )
    if not gpu_partition:
        job_helpers.fail("gpu_partition is required (this tool only targets GPU partitions)", got=args)

    # --- §16.1 multi-node cross-validation (reject nodes=1; see description) ---
    nodes = int(args.get("nodes", 1))
    ntasks_per_node = int(args.get("ntasks_per_node", 1))
    mpi_fabric = args.get("mpi_fabric", "auto")

    if nodes < 2:
        job_helpers.fail(
            "this tool requires nodes >= 2 (single-node should use train_pytorch_gpu)",
            got_nodes=nodes,
            hint="see AGENT_GUIDE §16 + tool description",
        )

    total_ranks = nodes * ntasks_per_node

    # gres per-node (§14.2): "<type>:<N>" or "<N>" if gpu_type=="any"
    gres_spec = f"{gpus}" if gpu_type == "any" else f"{gpu_type}:{gpus}"

    # cpus-per-task: default 8 per GPU per rank, scaled. Multi-node uses
    # --mem-per-cpu (NOT --mem) per §16.2.
    cpus_per_task = 8

    job_name = f"ddp_{os.path.splitext(os.path.basename(train_script))[0]}"

    # --- §16.4 NCCL env (multi-node; always set since nodes >= 2 here) ---
    nccl_env = (
        "    --env NCCL_SOCKET_IFNAME=^docker0,lo,bond0 \\\n"
        "    --env NCCL_IB_DISABLE=0 \\\n"
        "    --env NCCL_DEBUG=WARN \\\n"
        "    --env NCCL_ASYNC_ERROR_HANDLING=1 \\\n"
    )

    # --- §16.4 MPI fabric env based on mpi_fabric arg ---
    if mpi_fabric in ("ofi", "auto"):
        fabric_env = (
            "    --env FI_PROVIDER=verbs,tcp \\\n"
            "    --env I_MPI_FABRICS=ofi \\\n"
        )
    elif mpi_fabric == "ucx":
        fabric_env = (
            "    --env UCX_TLS=rc,tcp \\\n"
            "    --env I_MPI_FABRICS=ucx \\\n"
        )
    elif mpi_fabric == "tcp":
        fabric_env = (
            "    --env FI_PROVIDER=tcp \\\n"
            "    --env I_MPI_FABRICS=tcp \\\n"
            "    --env OMPI_MCA_btl=tcp,self \\\n"
        )
    else:
        # Schema enum already rejects this, but guard anyway.
        job_helpers.fail(f"unknown mpi_fabric: {mpi_fabric}")

    extra_args_quoted = " ".join(shlex.quote(a) for a in extra_args)

    sbatch_text = SBATCH_TEMPLATE.format(
        job_name=job_name,
        work_dir=work_dir,
        gpu_partition=gpu_partition,
        nodes=nodes,
        ntasks_per_node=ntasks_per_node,
        cpus_per_task=cpus_per_task,
        mem_per_cpu=mem_per_cpu,
        time_limit=time_limit,
        gres_spec=gres_spec,
        nccl_env=nccl_env,
        fabric_env=fabric_env,
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
        "nodes": nodes,
        "ntasks_per_node": ntasks_per_node,
        "gres": gres_spec,
        "cpus_per_task": cpus_per_task,
        "mem_per_cpu": mem_per_cpu,
        "time_limit": time_limit,
    }

    reg_id = registry.record_submission(
        tool_name="submit_distributed_train",
        work_dir=work_dir,
        output_dir=work_dir,
        project_name=job_name,
        runner_config_path=None,
        slurm_job_ids=slurm_ids or None,
        num_angles=None,
        status=status,
        extra={
            # §14.4 GPU fields
            "gpus": gpus,
            "gpu_type": gpu_type,
            "gpu_partition": gpu_partition,
            # §16.5 MPI fields
            "nodes": nodes,
            "ntasks_per_node": ntasks_per_node,
            "total_ranks": total_ranks,
            "mpi_fabric": mpi_fabric,
            # tool-specific
            "framework": "pytorch",
            "train_script": train_script,
            "apptainer_sif": apptainer_sif,
            "extra_args": extra_args,
            "sbatch_path": sbatch_path,
            "sbatch_params": sbatch_params,
        },
    )

    print(json.dumps({
        "ok": True,
        "registry_id": reg_id,
        "tool": "submit_distributed_train",
        "work_dir": work_dir,
        "sbatch_path": sbatch_path,
        "slurm_job_ids": slurm_ids,
        "status": status,
        "total_ranks": total_ranks,
        "sbatch_params": sbatch_params,
        "gpu": {
            "gpus": gpus,
            "gpu_type": gpu_type,
            "gpu_partition": gpu_partition,
        },
        "mpi": {
            "nodes": nodes,
            "ntasks_per_node": ntasks_per_node,
            "mpi_fabric": mpi_fabric,
            "total_ranks": total_ranks,
        },
        "follow_up_hint": (
            "Multi-node DDP PyTorch job. Use job_status / job_logs with registry_id "
            "to monitor. Slurm allocates CUDA_VISIBLE_DEVICES per task — do not "
            "override it inside your script. World size = total_ranks."
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
