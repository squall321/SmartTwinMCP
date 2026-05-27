#!/usr/bin/env bash
# scenario_full_reference — return full KooChainRun scenario.json schema reference
set -euo pipefail

python3 - <<'PY'
import json, os, sys

# Hardcoded reference — extracted by auditing Runner/CumulativeDesigner.py and
# Runner/AngleSourceParser.py in pyKooCAE repo. Keep in sync with KooChainRun upgrades.

SUBMIT_CLI_SCHEMA = {
    "_description": (
        "KooChainRun 'submit' CLI 옵션. single_drop_simulation/fullangle_drop_simulation의 "
        "`submit_cli_overrides` 인자로 전달하면 auto-tune 결과를 override합니다. "
        "auto-tune은 sinfo로 partition/nodes/jobs_per_node를 자동 계산하므로 "
        "특별한 이유 없으면 override 불필요."
    ),
    "submit_mode": {
        "type": "string", "enum": ["cumulative", "large-scale"], "default": "cumulative",
        "_note": "cumulative=DOE별 sbatch 1개씩, large-scale=LargeScaleDOEManager 배열 잡",
    },
    "nodes": {"type": "integer", "default": "(auto-tune)", "_note": "사용할 노드 수"},
    "jobs_per_node": {"type": "integer", "default": "(auto-tune)", "_note": "노드당 동시 잡 수"},
    "ncpu_per_job": {"type": "integer", "default": "(auto-tune)", "_note": "잡당 CPU. environment.ncpu와 별개 (이건 submit 시 override)"},
    "partition": {"type": "string", "default": "(auto-tune)", "_note": "submit_cli_overrides에 넣지 말고 top-level partition 인자로. 'list'면 탐색 모드"},
    "memory": {"type": "string", "pattern": "^[0-9]+[GM]$", "default": "(env.memory)", "_note": "submit 시 sbatch 메모리 override"},
    "time_limit": {"type": "string", "pattern": "^HH:MM:SS$", "default": "24:00:00"},
    "data_root": {"type": "string", "default": "/data"},
    "sequential": {
        "type": "boolean", "default": False,
        "_note": "이건 submit_cli_overrides 안이 아니라 top-level `sequential` 인자로 전달. 노드당 1잡씩 + 잡 안에서 여러 DOE 순차 실행 (안전 모드).",
    },
    "_auto_tune_algorithm": (
        "sinfo로 partition 자동 발견 → "
        "score=idle_nodes*100 + cpus_per_node + default_bonus(10)로 ranking → "
        "최고 점수 partition 선택. GPU partition은 Gres로 자동 제외. "
        "STMC_PARTITION_EXCLUDE='name1,name2' env로 추가 제외 가능. "
        "sinfo 실패 시 KooChainRun default(nodes=2, jobs_per_node=4) fallback."
    ),
}

FULL_SCHEMA = {
    "project_name": {"type": "string", "default": "CumulativeProject"},
    "base_dir": {"type": "string", "description": "Absolute path. scenario.json/runner_config.json/output/ live here."},

    "environment": {
        "_description": "Slurm + Apptainer + LS-DYNA + KooMeshModifier runtime settings.",
        "koomeshmodifier_path": {"type": "string", "default": "/opt/SmartTwinPreprocessor/bin/KooMeshModifier"},
        "lsdyna_path": {"type": "string", "default": "/opt/ls-dyna/lsdyna_R16.1.1"},
        "mpi_path": {"type": "string", "default": "mpirun"},
        "memory": {"type": "string", "default": "2G", "pattern": "^[0-9]+[GM]$"},
        "lsdyna_memory": {"type": "string", "default": "2000m"},
        "apptainer_sif": {"type": "string", "default": "/opt/apptainers/SmartTwinPreprocessor.sif"},
        "apptainer_bind": {"type": "string", "default": "/data:/data,/shared:/shared"},
        "apptainer_env": {"type": "object", "description": "Container-internal env vars."},
        "lsdyna_apptainer_sif": {"type": "string", "default": "/opt/apptainers/LSDynaBasic_aocc420_ompi4.0.5_mpp_s.sif"},
        "lsdyna_apptainer_bind": {"type": "string", "default": "/data:/data,/shared:/shared"},
        "lsdyna_apptainer_env": {
            "type": "object",
            "required_keys": ["LSTC_FILE", "LSTC_LICENSE_SERVER"],
            "default": {
                "LSTC_FILE": "/opt/ls-dyna_license/LSTC_FILE",
                "LSTC_LICENSE_SERVER": "192.168.122.1",
                "FI_PROVIDER": "tcp",
                "I_MPI_FABRICS": "ofi",
                "LD_LIBRARY_PATH": "/opt/openmpi/lib",
            },
        },
        "apptainer_tmpdir": {"type": "string", "default": "/data/tmp"},
        "nodes_per_job": {"type": "integer", "default": 1},
        "mpi_launcher": {"type": "string", "default": "mpirun"},
        "mpi_enabled": {"type": "boolean", "default": True},
        "ncpu": {"type": "integer", "default": 1},
        "koochainrun_path": {"type": "string", "default": "/data/SmartTwinPreprocessor/bin/KooChainRun"},
        "time_limit": {"type": "string", "default": "01:00:00", "pattern": "^[0-9]{1,3}:[0-5][0-9]:[0-5][0-9]$"},
        "timeout_per_step_seconds": {"type": "integer", "default": 604800, "description": "전체 1 step (KooMeshModifier+LS-DYNA+dynain) timeout (sec)."},
        "timeout_koomeshmodifier_seconds": {"type": "integer", "default": 604800},
        "timeout_dynain_seconds": {"type": "integer", "default": 604800},
        "stage_out_concurrency": {
            "type": "integer", "default": 8,
            "_note": "동시 stage-out rsync 개수 cap (semaphore). 작은 클러스터=8, 수십 노드=16~32, 100+ 노드=32~64. NFS 서버 부하 한계에 맞춰 조절."
        },
        "stage_out_timeout_seconds": {
            "type": "integer", "default": 120,
            "_note": "semaphore 토큰 획득 timeout. 잡 수 많고 stage-out 시간 길면 늘려야 함 (예: 350 노드 + 30초 rsync ≈ 22 batch × 30s = 11분 → 1800~7200 권장)."
        },
    },

    "simulation_params": {
        "_description": "물리 파라미터 + 바닥판 설정.",
        "height": {"type": "number", "default": 1500, "description": "낙하 높이 (mm)."},
        "tFinal": {"type": "number", "default": 0.005, "description": "시뮬 종료 시간 (s)."},
        "dt": {"type": "number", "default": 1e-6, "description": "Timestep (s). LS-DYNA가 더 작게 자동 조정 가능."},
        "density": {"type": "number", "default": 7850, "description": "kg/m³"},
        "youngs_modulus": {"type": "number", "default": 200e9, "description": "Pa"},
        "poisson_ratio": {"type": "number", "default": 0.3},
        "drop_surface": {
            "_description": "바닥판 타입. type별로 추가 옵션 다름.",
            "type_options": {
                "Plane": {
                    "size": [300, 300, 20],
                    "mesh": [30, 30, 2],
                    "deformable_to_rigid": False,
                },
                "PlaneGraded": {
                    "size": [300, 300, 20],
                    "mesh": [30, 30, 2],
                    "_note": "중심 균일 + 외곽 graded mesh, 외곽 요소 크기 자동 매칭",
                },
                "RigidWall": {
                    "_note": "강체 벽 (가장 단순, 가장 빠름, 변형 없음)",
                    "RWKSF": 0.1,
                    "RW_SOFT": False,
                    "RW_MASS": None,
                },
                "PlanewithRoughness": {
                    "size": [300, 300, 20],
                    "mesh": [30, 30, 2],
                    "_note": "거칠기 포함 평판",
                },
            },
        },
    },

    "scenarios": {
        "_description": "시나리오 배열. 보통 1개. 각 시나리오는 1개 모델 + 1개 각도 소스.",
        "_array_item_schema": {
            "scenario_name": {"type": "string"},
            "template": {"type": "string", "description": "base_dir 안의 .k 파일 이름"},
            "batch_koomeshmodifier": {"type": "boolean", "default": False, "description": "한 노드에서 여러 각도 KooMeshModifier 배치 처리"},
            "angle_source": "see angle_source section",
            "cumulative": "see cumulative section",
            "tolerance": "see tolerance section (optional)",
            "position_source": {"type": "object", "description": "낙하 위치 변화 (선택)"},
        },
    },

    "angle_source": {
        "_description": "각도 생성 방식. 5가지 source_type.",
        "source_type": {
            "type": "string",
            "enum": ["cuboid_geometry", "fibonacci_lattice", "pitching_sweep", "rolling_sweep", "case_txt_file"],
        },
        "cuboid_geometry": {
            "include_faces": True,
            "include_edges": True,
            "include_corners": True,
            "_note": "6F + 12E + 8C = 26방향",
        },
        "fibonacci_lattice": {
            "num_directions": 162,
            "num_points": 162,
            "_note": "구면 균등 분포. 표준 = 162. num_directions와 num_points는 alias.",
        },
        "pitching_sweep": {
            "pitch_min": -90.0,
            "pitch_max": 90.0,
            "pitch_step": 10.0,
            "roll_fixed": 0.0,
            "yaw_fixed": 0.0,
        },
        "rolling_sweep": {
            "roll_min": -180.0,
            "roll_max": 170.0,
            "roll_step": 10.0,
            "pitch_fixed": 0.0,
            "yaw_fixed": 0.0,
        },
        "case_txt_file": {
            "file_path": "/path/to/26case_6F12E8C_cuboid.txt",
            "selected_indices": None,
            "_note": "표준 11개 Case txt 파일. None=전체.",
        },
    },

    "cumulative": {
        "_description": "누적 시뮬 (멀티스텝). 단순 1방향 낙하는 num_steps=1.",
        "num_steps": {"type": "integer", "default": 1},
        "mode_sequence": {
            "type": "array",
            "default": ["DROP"],
            "items": {"enum": ["DROP", "VIBRATION_LOAD", "REMESH_TETRA", "RIGIDIFY_SMALL_DT", "BOUNDARY_NON_REFLECTING"]},
        },
        "base_angle_index": {"type": "integer", "default": 0},
        "angle_mixing": {
            "strategy": {"enum": ["same_angle", "cyclic", "random", "custom"], "default": "same_angle"},
            "custom_mapping": {"type": "object"},
            "cyclic_offset": {"type": "integer", "default": 1},
            "random_seed": {"type": "integer"},
        },
    },

    "tolerance": {
        "_description": "DOE — roll/pitch/yaw에 tolerance 범위 줘서 N개 sample 생성.",
        "_optional": True,
        "roll": {"min": -2.0, "max": 2.0},
        "pitch": {"min": -2.0, "max": 2.0},
        "yaw": {"min": -2.0, "max": 2.0},
        "doe_type": {"enum": ["lhs", "full_factorial", "random"], "default": "lhs"},
        "doe_count": {"type": "integer", "default": 10},
    },

    "postprocess": {
        "_description": "KooD3plotReader 자동 후처리.",
        "_optional": True,
        "enabled": {"type": "boolean", "default": False},
        "auto_deep": {"type": "boolean", "default": True},
        "auto_sphere": {"type": "boolean", "default": True},
        "auto_deep_mode": {"enum": ["inline", "separate_job"], "default": "inline"},
        "sif_path": {"type": "string", "default": "/opt/apptainers/SmartTwinPostprocessor.sif"},
        "yield_stress_mpa": {"type": "number", "default": 350},
        "section_view_axes": {"type": "array", "default": ["z"], "items": {"enum": ["x", "y", "z"]}},
        "section_view_fields": {"type": "array", "default": ["von_mises"]},
        "section_view_mode": {"enum": ["section", "section_3d", "iso_surface"], "default": "section"},
        "ua_threads": {"type": "integer", "default": 8},
        "sv_threads": {"type": "integer", "default": 8},
        "deep_timeout_seconds": {"type": "integer", "default": 7200},
        "deep_ncpu": {"type": "integer", "_note": "separate_job 모드. 미지정 시 env.ncpu fallback"},
        "deep_memory": {"type": "string", "_note": "separate_job 모드. 미지정 시 env.memory fallback"},
        "deep_time_limit": {"type": "string"},
        "sphere_ncpu": {"type": "integer", "_note": "미지정 시 env.ncpu fallback"},
        "sphere_memory": {"type": "string", "default": "16G"},
        "sphere_time_limit": {"type": "string", "default": "04:00:00"},
    },
}

EXAMPLES = [
    {
        "title": "Tolerance DOE 적용 (roll±2도 LHS 50개)",
        "extra_scenario_overrides": {
            "scenarios": [{
                "tolerance": {
                    "roll": {"min": -2.0, "max": 2.0},
                    "pitch": {"min": -2.0, "max": 2.0},
                    "doe_type": "lhs",
                    "doe_count": 50,
                }
            }]
        }
    },
    {
        "title": "RigidWall 바닥판으로 변경 (가장 빠른 시뮬)",
        "extra_scenario_overrides": {
            "simulation_params": {"drop_surface": {"type": "RigidWall"}}
        }
    },
    {
        "title": "Step별 timeout 길게 (대형 모델)",
        "extra_scenario_overrides": {
            "environment": {
                "timeout_per_step_seconds": 86400,
                "timeout_koomeshmodifier_seconds": 3600,
                "timeout_dynain_seconds": 1800
            }
        }
    },
    {
        "title": "후처리 section view 3축 + sphere 메모리 증대",
        "extra_scenario_overrides": {
            "postprocess": {
                "section_view_axes": ["x", "y", "z"],
                "sphere_memory": "32G",
                "sphere_ncpu": 8
            }
        }
    },
    {
        "title": "batch_koomeshmodifier 활성화 (한 노드에서 여러 각도 일괄 처리)",
        "extra_scenario_overrides": {
            "scenarios": [{"batch_koomeshmodifier": True}]
        }
    },
]


def main():
    args = json.loads(os.environ.get("STMC_ARGS_JSON", "{}"))
    section = args.get("section", "all")
    # Combine scenario.json schema + submit CLI schema
    combined = {**FULL_SCHEMA, "submit_cli": SUBMIT_CLI_SCHEMA}
    if section == "all":
        out_schema = combined
    elif section in combined:
        out_schema = {section: combined[section]}
    else:
        print(json.dumps({"ok": False, "reason": f"Unknown section '{section}'. Valid: all, {', '.join(combined.keys())}"}))
        sys.exit(1)

    print(json.dumps({
        "ok": True,
        "section_filter": section,
        "_note": "Use these options under `extra_scenario_overrides` in single_drop_simulation or fullangle_drop_simulation. Tier 1 args (ncpu, memory, drop_surface_type 등) cover most use cases.",
        "schema": out_schema,
        "examples": EXAMPLES,
    }, ensure_ascii=False, indent=2))


try: main()
except Exception as e:
    print(json.dumps({"ok": False, "reason": f"{type(e).__name__}: {e}"}))
    sys.exit(1)
PY
