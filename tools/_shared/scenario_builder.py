#!/usr/bin/env python3
"""KooChainRun scenario.json builder — used by drop simulation MCP tools.

Builds a complete scenario.json from minimal high-level args + sensible defaults.
Defaults match Examples/portable_bundle/ verified scenarios.
"""
from __future__ import annotations

import json
import os
import sys


DEFAULT_LSDYNA_PATH = "/opt/ls-dyna/lsdyna_R16.1.1"
DEFAULT_KOOMESHMODIFIER_PATH = "/opt/SmartTwinPreprocessor/bin/KooMeshModifier"
DEFAULT_KOOCHAINRUN_PATH = "/data/SmartTwinPreprocessor/bin/KooChainRun"
DEFAULT_APPTAINER_SIF_PREP = "/opt/apptainers/SmartTwinPreprocessor.sif"
DEFAULT_APPTAINER_SIF_DYNA = "/opt/apptainers/LSDynaBasic_aocc420_ompi4.0.5_mpp_s.sif"
DEFAULT_APPTAINER_SIF_POST = "/opt/apptainers/SmartTwinPostprocessor.sif"


def _base_environment(lstc_ip: str, ncpu: int = 1, memory: str = "2G",
                      time_limit: str = "01:00:00") -> dict:
    return {
        "koomeshmodifier_path": DEFAULT_KOOMESHMODIFIER_PATH,
        "lsdyna_path": DEFAULT_LSDYNA_PATH,
        "mpi_path": "mpirun",
        "memory": memory,
        "lsdyna_memory": f"{int(memory.rstrip('Gg')) * 1000}m" if memory.endswith(("G", "g")) else "2000m",
        "apptainer_sif": DEFAULT_APPTAINER_SIF_PREP,
        "apptainer_bind": "/data:/data",
        "apptainer_env": {},
        "lsdyna_apptainer_sif": DEFAULT_APPTAINER_SIF_DYNA,
        "lsdyna_apptainer_bind": "/data:/data",
        "lsdyna_apptainer_env": {
            "LSTC_FILE": "/opt/ls-dyna_license/LSTC_FILE",
            "LSTC_LICENSE_SERVER": lstc_ip,
            "FI_PROVIDER": "tcp",
            "I_MPI_FABRICS": "ofi",
            "LD_LIBRARY_PATH": "/opt/openmpi/lib",
        },
        "apptainer_tmpdir": "/data/tmp",
        "nodes_per_job": 1,
        "mpi_launcher": "mpirun",
        "mpi_enabled": True,
        "ncpu": ncpu,
        "koochainrun_path": DEFAULT_KOOCHAINRUN_PATH,
        "time_limit": time_limit,
    }


def _base_simulation_params(
    height_mm: float = 1500,
    t_final_s: float = 0.005,
    dt_s: float = 1e-06,
    drop_surface_type: str = "Plane",
) -> dict:
    """drop_surface_type: Plane / PlaneGraded / RigidWall / PlanewithRoughness."""
    if drop_surface_type == "RigidWall":
        surface = {"type": "RigidWall"}
    else:
        surface = {
            "type": drop_surface_type,
            "size": [300, 300, 20],
            "mesh": [30, 30, 2],
            "deformable_to_rigid": False,
        }
    return {
        "height": height_mm,
        "tFinal": t_final_s,
        "dt": dt_s,
        "density": 7850,
        "youngs_modulus": 200_000_000_000,
        "poisson_ratio": 0.3,
        "drop_surface": surface,
    }


def deep_merge(base: dict, overrides: dict | None) -> dict:
    """Recursively merge `overrides` into `base`. Lists in overrides REPLACE base lists.

    Used to apply user-supplied `extra_scenario_overrides` on top of the Tier 1 scenario.
    """
    if not overrides:
        return base
    for k, v in overrides.items():
        if k in base and isinstance(base[k], dict) and isinstance(v, dict):
            deep_merge(base[k], v)
        else:
            base[k] = v
    return base


def build_single_angle_scenario(
    project_name: str,
    base_dir: str,
    model_file: str,
    lstc_ip: str,
    roll_deg: float = 0.0,
    pitch_deg: float = 0.0,
    yaw_deg: float = 0.0,
    height_mm: float = 1500,
    t_final_s: float = 0.005,
    ncpu: int = 1,
    memory: str = "2G",
    time_limit: str = "01:00:00",
    drop_surface_type: str = "Plane",
    extra_overrides: dict | None = None,
) -> dict:
    """1방향 지정각도 낙하 시나리오.

    KooChainRun에 'manual' source_type이 없으므로 pitching_sweep을
    pitch_min=pitch_max로 1방향만 만드는 트릭 사용. roll/yaw는 fixed로 지정.

    extra_overrides: Tier 2 옵션 (scenarios[0].batch_koomeshmodifier, tolerance, 등) 통과용.
    """
    scenario = {
        "project_name": project_name,
        "base_dir": base_dir,
        "environment": _base_environment(lstc_ip, ncpu, memory, time_limit),
        "simulation_params": _base_simulation_params(height_mm, t_final_s,
                                                     drop_surface_type=drop_surface_type),
        "scenarios": [
            {
                "scenario_name": f"Single_R{roll_deg}_P{pitch_deg}_Y{yaw_deg}",
                "template": model_file,
                "angle_source": {
                    "source_type": "pitching_sweep",
                    "pitching_sweep": {
                        "pitch_min": pitch_deg,
                        "pitch_max": pitch_deg,
                        "pitch_step": 1,
                        "roll_fixed": roll_deg,
                        "yaw_fixed": yaw_deg,
                    },
                },
                "cumulative": {
                    "num_steps": 1,
                    "mode_sequence": ["DROP"],
                    "base_angle_index": 0,
                    "angle_mixing": {"strategy": "same_angle"},
                },
            }
        ],
    }
    return deep_merge(scenario, extra_overrides)


def build_fullangle_scenario(
    project_name: str,
    base_dir: str,
    model_file: str,
    lstc_ip: str,
    num_directions: int = 162,
    height_mm: float = 1500,
    t_final_s: float = 0.005,
    ncpu: int = 2,
    memory: str = "4G",
    time_limit: str = "12:00:00",
    drop_surface_type: str = "Plane",
    enable_postprocess: bool = True,
    auto_deep: bool = True,
    auto_sphere: bool = True,
    auto_deep_mode: str = "inline",
    yield_stress_mpa: float = 350,
    sif_path_postprocessor: str | None = None,
    extra_overrides: dict | None = None,
) -> dict:
    """Fibonacci 전각도 낙하 + 자동 후처리.

    extra_overrides: Tier 2 옵션 통과용 (예: tolerance, batch_koomeshmodifier, custom timeouts).
    """
    scenario = {
        "project_name": project_name,
        "base_dir": base_dir,
        "environment": _base_environment(lstc_ip, ncpu, memory, time_limit),
        "simulation_params": _base_simulation_params(height_mm, t_final_s,
                                                     drop_surface_type=drop_surface_type),
        "scenarios": [
            {
                "scenario_name": f"Fib{num_directions}",
                "template": model_file,
                "angle_source": {
                    "source_type": "fibonacci_lattice",
                    "fibonacci_lattice": {"num_directions": num_directions},
                },
                "cumulative": {
                    "num_steps": 1,
                    "mode_sequence": ["DROP"],
                    "base_angle_index": 0,
                    "angle_mixing": {"strategy": "same_angle"},
                },
            }
        ],
    }

    if enable_postprocess:
        pp = {
            "enabled": True,
            "auto_deep": auto_deep,
            "auto_sphere": auto_sphere,
            "yield_stress_mpa": yield_stress_mpa,
            "section_view_axes": ["z"],
            "section_view_fields": ["von_mises"],
            "section_view_mode": "section",
            "ua_threads": 4,
            "sv_threads": 4,
            "deep_timeout_seconds": 3600,
            "sphere_time_limit": "04:00:00",
        }
        if auto_deep_mode == "separate_job":
            pp["auto_deep_mode"] = "separate_job"
        if sif_path_postprocessor:
            pp["sif_path"] = sif_path_postprocessor
        scenario["postprocess"] = pp

    return deep_merge(scenario, extra_overrides)


def write_scenario(scenario: dict, path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(scenario, f, indent=2)


if __name__ == "__main__":
    # CLI for testing
    print("scenario_builder.py — import as module")
    sys.exit(0)
