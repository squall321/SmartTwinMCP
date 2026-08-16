#!/usr/bin/env bash
# cuboid_scatter_drop_simulation — KooChainRun 26방향 섭동 스캐터 낙하 + 자동 후처리
set -euo pipefail

export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import json, os, sys, shutil, subprocess, re

sys.path.insert(0, os.environ["SHARED_DIR"])
from scenario_builder import build_cuboid_scatter_scenario, cuboid_base_count, write_scenario
import registry
import auto_tune
import audit

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
    tol_deg = float(args.get("tolerance_deg", 2.0))
    doe_count = int(args.get("doe_count", 5))
    doe_type = args.get("doe_type", "lhs")
    inc_faces = bool(args.get("include_faces", True))
    inc_edges = bool(args.get("include_edges", True))
    inc_corners = bool(args.get("include_corners", True))
    height_mm = float(args.get("drop_height_mm", 1500))
    t_final = float(args.get("simulation_time_s", 0.005))
    ncpu = int(args.get("ncpu", 2))
    memory = args.get("memory", "4G")
    time_limit = args.get("time_limit", "12:00:00")
    enable_pp = bool(args.get("enable_postprocess", True))
    auto_deep = bool(args.get("auto_deep", True))
    auto_sphere = bool(args.get("auto_sphere", True))
    auto_deep_mode = args.get("auto_deep_mode", "inline")
    yield_stress = float(args.get("yield_stress_mpa", 350))
    drop_surface_type = args.get("drop_surface_type", "Plane")
    sif_post = args.get("sif_path_postprocessor")
    extra_overrides = args.get("extra_scenario_overrides")
    sequential = bool(args.get("sequential", False))
    partition_arg = args.get("partition")
    submit_overrides = args.get("submit_cli_overrides") or {}
    dry_run = bool(args.get("dry_run", False))

    n_bases = cuboid_base_count(inc_faces, inc_edges, inc_corners)
    if n_bases == 0:
        fail("기준 방향이 없습니다 — include_faces/edges/corners 중 하나 이상 true 여야 합니다.")
    total_runs = n_bases * doe_count
    project_name = args.get("project_name") or f"Cuboid{n_bases}_scatter_d{doe_count}"

    if not os.path.exists(KOOCHAINRUN):
        fail(f"KooChainRun not found at {KOOCHAINRUN}")
    os.makedirs(work_dir, exist_ok=True)

    model_target = os.path.join(work_dir, model_file)
    if not os.path.exists(model_target):
        if model_file_path and os.path.exists(model_file_path):
            shutil.copy(model_file_path, model_target)
        else:
            fail(f"Model file missing: {model_target}")

    scenario = build_cuboid_scatter_scenario(
        project_name=project_name,
        base_dir=work_dir,
        model_file=model_file,
        lstc_ip=lstc_ip,
        tol_deg=tol_deg, doe_count=doe_count, doe_type=doe_type,
        include_faces=inc_faces, include_edges=inc_edges, include_corners=inc_corners,
        height_mm=height_mm, t_final_s=t_final,
        ncpu=ncpu, memory=memory, time_limit=time_limit,
        drop_surface_type=drop_surface_type,
        enable_postprocess=enable_pp,
        auto_deep=auto_deep, auto_sphere=auto_sphere, auto_deep_mode=auto_deep_mode,
        yield_stress_mpa=yield_stress, sif_path_postprocessor=sif_post,
        extra_overrides=extra_overrides,
    )
    scenario_path = os.path.join(work_dir, "scenario.json")
    write_scenario(scenario, scenario_path)

    runner_config_path = os.path.join(work_dir, "runner_config.json")
    try:
        subprocess.run(
            [KOOCHAINRUN, "prepare", scenario_path],
            capture_output=True, text=True, timeout=120, check=True,
        )
    except subprocess.CalledProcessError as e:
        fail(f"KooChainRun prepare failed: rc={e.returncode}",
             stderr=e.stderr[-500:], stdout=e.stdout[-500:])

    output_dir = os.path.join(work_dir, "output")

    # auto_tune 은 총 run 수로 Slurm 규모를 잡는다 (fibonacci 의 num_angles 자리).
    tune = auto_tune.auto_tune_submit(
        num_angles=total_runs,
        user_partition=partition_arg,
        user_ncpu=submit_overrides.get("ncpu_per_job") or ncpu,
    )

    if tune["partition_discovery"].get("discovery_only"):
        print(json.dumps({
            "ok": True, "discovery_only": True,
            "available_partitions": tune["partition_discovery"]["all_partitions"],
            "hint": "Pick a partition name and re-call with partition='<name>'.",
        }, ensure_ascii=False, default=str))
        return

    submit_args = [KOOCHAINRUN, "submit", runner_config_path]
    cli = {}
    if tune.get("applied") or tune.get("fallback_used"):
        if tune.get("nodes"):          cli["--nodes"] = str(tune["nodes"])
        if tune.get("jobs_per_node"):  cli["--jobs-per-node"] = str(tune["jobs_per_node"])
        if tune.get("ncpu_per_job"):   cli["--ncpu-per-job"] = str(tune["ncpu_per_job"])
        if tune.get("partition"):      cli["--partition"] = tune["partition"]
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
    sphere_job_id = None
    status = "dry_run"
    if not dry_run:
        try:
            r = subprocess.run(
                submit_args, capture_output=True, text=True, timeout=600, check=True,
            )
        except subprocess.CalledProcessError as e:
            fail(f"KooChainRun submit failed: rc={e.returncode}",
                 stderr=e.stderr[-1000:], stdout=e.stdout[-1000:], submit_args=submit_args)
        for line in r.stdout.splitlines():
            m = re.search(r"submitted \(job (\d+)\)", line)
            if m:
                slurm_ids.append(m.group(1))
            m = re.search(r"Sphere Job ID: (\d+)", line)
            if m:
                sphere_job_id = m.group(1)
        status = "submitted"

    expected_runtime_hours = max(1, total_runs * t_final * 200 / 3600)

    reg_id = registry.record_submission(
        tool_name="cuboid_scatter_drop_simulation",
        work_dir=work_dir,
        output_dir=output_dir,
        project_name=project_name,
        runner_config_path=runner_config_path,
        slurm_job_ids=slurm_ids or None,
        sphere_job_id=sphere_job_id,
        num_angles=total_runs,
        status=status,
        extra={
            "n_bases": n_bases, "doe_count": doe_count, "doe_type": doe_type,
            "tolerance_deg": tol_deg,
            "drop_height_mm": height_mm, "simulation_time_s": t_final,
            "auto_deep_mode": auto_deep_mode, "enable_postprocess": enable_pp,
            "yield_stress_mpa": yield_stress,
        },
    )

    actor = os.environ.get("USER") or os.environ.get("LOGNAME") or "unknown"
    audit.record_event(
        actor=actor,
        tool="cuboid_scatter_drop_simulation@1.0.0",
        action="submit",
        summary=f"submitted cuboid scatter {project_name} ({n_bases}dir x {doe_count}, tol±{tol_deg}deg) -> {len(slurm_ids)} slurm jobs, sphere {sphere_job_id}",
        target_kind="job",
        target_id=str(reg_id),
        detail={
            "project_name": project_name, "n_bases": n_bases, "doe_count": doe_count,
            "total_runs": total_runs, "tolerance_deg": tol_deg,
            "slurm_job_ids": slurm_ids, "sphere_job_id": sphere_job_id, "dry_run": dry_run,
        },
    )

    print(json.dumps({
        "ok": True,
        "registry_id": reg_id,
        "tool": "cuboid_scatter_drop_simulation",
        "work_dir": work_dir,
        "output_dir": output_dir,
        "scenario_path": scenario_path,
        "runner_config_path": runner_config_path,
        "slurm_job_ids": slurm_ids,
        "sphere_job_id": sphere_job_id,
        "n_bases": n_bases,
        "doe_count": doe_count,
        "total_runs": total_runs,
        "tolerance_deg": tol_deg,
        "status": status,
        "auto_deep_mode": auto_deep_mode,
        "expected_runtime_hours": round(expected_runtime_hours, 1),
        "sphere_report_path": os.path.join(output_dir, "sphere_report.html"),
        "submit_cli_used": " ".join(submit_args[2:]),
        "auto_tune": {
            "applied": tune.get("applied"),
            "fallback_used": tune.get("fallback_used"),
            "partition": tune.get("partition"),
            "nodes": tune.get("nodes"),
            "jobs_per_node": tune.get("jobs_per_node"),
            "ncpu_per_job": tune.get("ncpu_per_job"),
            "reason": tune.get("reason"),
        },
        "follow_up_hint": (
            "sphere_report.html 을 DynaForge 에 인제스트 후 report_scatter 로 26방향 산포/민감도 분석. "
            "job_status/job_diagnose/job_collect 로 진행 추적."
        ),
    }, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        fail(f"unhandled exception: {type(e).__name__}: {e}")
PY
