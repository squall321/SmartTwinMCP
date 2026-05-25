#!/usr/bin/env bash
# single_drop_simulation — KooChainRun manual-angle drop
set -euo pipefail

SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"
export PYTHONPATH="$SHARED_DIR:${PYTHONPATH:-}"

python3 - <<'PY'
import json, os, sys, shutil, subprocess

# scenario_builder + registry are in tools/_shared/
sys.path.insert(0, os.environ["SHARED_DIR"]) if "SHARED_DIR" in os.environ else None
from scenario_builder import build_single_angle_scenario, write_scenario
import registry
import auto_tune

KOOCHAINRUN = "/data/SmartTwinPreprocessor/bin/KooChainRun"


def fail(reason: str, **extra):
    print(json.dumps({"ok": False, "reason": reason, **extra}, ensure_ascii=False))
    sys.exit(1)


def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])

    work_dir = args["work_dir"]
    lstc_ip = args["lstc_license_ip"]
    model_file = args.get("model_file", "MinimumModel.k")
    model_file_path = args.get("model_file_path")
    roll = float(args.get("roll_deg", 0))
    pitch = float(args.get("pitch_deg", 0))
    yaw = float(args.get("yaw_deg", 0))
    height_mm = float(args.get("drop_height_mm", 1500))
    t_final = float(args.get("simulation_time_s", 0.005))
    ncpu = int(args.get("ncpu", 1))
    memory = args.get("memory", "2G")
    time_limit = args.get("time_limit", "01:00:00")
    project_name = args.get("project_name") or f"SingleDrop_R{int(roll)}_P{int(pitch)}_Y{int(yaw)}"
    drop_surface_type = args.get("drop_surface_type", "Plane")
    extra_overrides = args.get("extra_scenario_overrides")
    sequential = bool(args.get("sequential", False))
    partition_arg = args.get("partition")
    submit_overrides = args.get("submit_cli_overrides") or {}
    dry_run = bool(args.get("dry_run", False))

    # Preflight
    if not os.path.exists(KOOCHAINRUN):
        fail(f"KooChainRun not found at {KOOCHAINRUN}")
    os.makedirs(work_dir, exist_ok=True)

    model_target = os.path.join(work_dir, model_file)
    if not os.path.exists(model_target):
        if model_file_path and os.path.exists(model_file_path):
            shutil.copy(model_file_path, model_target)
        else:
            fail(f"Model file missing: {model_target} (and no valid model_file_path provided)")

    # Build scenario
    scenario = build_single_angle_scenario(
        project_name=project_name,
        base_dir=work_dir,
        model_file=model_file,
        lstc_ip=lstc_ip,
        roll_deg=roll, pitch_deg=pitch, yaw_deg=yaw,
        height_mm=height_mm, t_final_s=t_final,
        ncpu=ncpu, memory=memory, time_limit=time_limit,
        drop_surface_type=drop_surface_type,
        extra_overrides=extra_overrides,
    )
    scenario_path = os.path.join(work_dir, "scenario.json")
    write_scenario(scenario, scenario_path)

    # prepare
    runner_config_path = os.path.join(work_dir, "runner_config.json")
    try:
        r = subprocess.run(
            [KOOCHAINRUN, "prepare", scenario_path],
            capture_output=True, text=True, timeout=60, check=True,
        )
    except subprocess.CalledProcessError as e:
        fail(f"KooChainRun prepare failed: rc={e.returncode}",
             stderr=e.stderr[-500:], stdout=e.stdout[-500:])

    output_dir = os.path.join(work_dir, "output")

    # Auto-tune partition + nodes/jobs_per_node (single angle → minimal)
    tune = auto_tune.auto_tune_submit(
        num_angles=1,
        user_partition=partition_arg,
        user_ncpu=submit_overrides.get("ncpu_per_job") or ncpu,
    )

    # partition=list: discovery-only — no submission
    if tune["partition_discovery"].get("discovery_only"):
        print(json.dumps({
            "ok": True, "discovery_only": True,
            "available_partitions": tune["partition_discovery"]["all_partitions"],
            "hint": "Pick a partition name and re-call with partition='<name>'.",
        }, ensure_ascii=False, default=str))
        return

    # Build submit args: auto-tune → override → sequential flag
    submit_args = [KOOCHAINRUN, "submit", runner_config_path]
    cli = {}
    if tune.get("applied") or tune.get("fallback_used"):
        if tune.get("nodes"):          cli["--nodes"] = str(tune["nodes"])
        if tune.get("jobs_per_node"):  cli["--jobs-per-node"] = str(tune["jobs_per_node"])
        if tune.get("ncpu_per_job"):   cli["--ncpu-per-job"] = str(tune["ncpu_per_job"])
        if tune.get("partition"):      cli["--partition"] = tune["partition"]
    # apply user overrides (highest priority)
    override_map = {
        "nodes": "--nodes", "jobs_per_node": "--jobs-per-node",
        "ncpu_per_job": "--ncpu-per-job", "memory": "--memory",
        "time_limit": "--time-limit", "submit_mode": "--mode",
        "data_root": "--data-root",
    }
    for k, flag in override_map.items():
        if k in submit_overrides:
            cli[flag] = str(submit_overrides[k])
    if "partition" in submit_overrides:
        cli["--partition"] = submit_overrides["partition"]
    for flag, val in cli.items():
        submit_args.extend([flag, val])
    if sequential:
        submit_args.append("--sequential")

    slurm_ids = []
    status = "dry_run"
    if not dry_run:
        try:
            r = subprocess.run(
                submit_args, capture_output=True, text=True, timeout=120, check=True,
            )
        except subprocess.CalledProcessError as e:
            fail(f"KooChainRun submit failed: rc={e.returncode}",
                 stderr=e.stderr[-500:], stdout=e.stdout[-500:],
                 submit_args=submit_args)
        import re
        for line in r.stdout.splitlines():
            m = re.search(r"submitted \(job (\d+)\)", line)
            if m:
                slurm_ids.append(m.group(1))
        status = "submitted"

    # Record in registry
    reg_id = registry.record_submission(
        tool_name="single_drop_simulation",
        work_dir=work_dir,
        output_dir=output_dir,
        project_name=project_name,
        runner_config_path=runner_config_path,
        slurm_job_ids=slurm_ids or None,
        num_angles=1,
        status=status,
        extra={
            "angle": {"roll": roll, "pitch": pitch, "yaw": yaw},
            "drop_height_mm": height_mm,
            "simulation_time_s": t_final,
        },
    )

    print(json.dumps({
        "ok": True,
        "registry_id": reg_id,
        "tool": "single_drop_simulation",
        "work_dir": work_dir,
        "output_dir": output_dir,
        "scenario_path": scenario_path,
        "runner_config_path": runner_config_path,
        "slurm_job_ids": slurm_ids,
        "angle": {"roll": roll, "pitch": pitch, "yaw": yaw},
        "status": status,
        "submit_cli_used": " ".join(submit_args[2:]),
        "auto_tune": {
            "applied": tune.get("applied"),
            "fallback_used": tune.get("fallback_used"),
            "partition": tune.get("partition"),
            "nodes": tune.get("nodes"),
            "jobs_per_node": tune.get("jobs_per_node"),
            "reason": tune.get("reason"),
            "partition_selected_reason": tune["partition_discovery"].get("selected_reason"),
            "excluded_partitions": tune["partition_discovery"].get("excluded", []),
        },
        "follow_up_hint": (
            "Use registry_id or work_dir with job_status, job_stop, job_diagnose, "
            "job_postprocess, job_collect tools. list_recent_jobs to find again across sessions."
        ),
    }, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        fail(f"unhandled exception: {type(e).__name__}: {e}")
PY
