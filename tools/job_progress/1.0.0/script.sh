#!/usr/bin/env bash
# job_progress — derive 0..100% progress estimate for a long-running job from on-disk signals.
# Reference impl for AGENT_GUIDE §19.
set -euo pipefail

export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import glob
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.environ["SHARED_DIR"])
import audit
from job_helpers import resolve_job, fail, KOOCHAINRUN


# ---------------------------------------------------------------------------
# Signal 1: KooChainRun status JSON
# ---------------------------------------------------------------------------
def try_koochainrun_signal(runner_config_path: str) -> dict | None:
    """Run `KooChainRun status <runner_config>`. Parse JSON stdout for `progress`.

    Returns a dict with progress info, or None if the binary is missing / runner_config
    is None / the output didn't yield a usable number.
    """
    if not runner_config_path:
        return None
    if not os.path.exists(KOOCHAINRUN):
        return None
    if not os.path.exists(runner_config_path):
        return None
    try:
        r = subprocess.run(
            [KOOCHAINRUN, "status", runner_config_path],
            capture_output=True, text=True, timeout=30,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None
    if r.returncode != 0:
        return None
    # Try to parse stdout as JSON and find a 'progress' field.
    try:
        data = json.loads(r.stdout)
    except json.JSONDecodeError:
        return None
    prog = _find_progress(data)
    if prog is None:
        return None
    # Normalize: KooChainRun may emit 0..1 or 0..100; clamp/scale to 0..100.
    pct = float(prog)
    if 0.0 <= pct <= 1.0:
        pct *= 100.0
    pct = max(0.0, min(100.0, pct))
    return {
        "progress_pct": round(pct, 2),
        "signal_used": "koochainrun_status",
        "detail": {"raw_progress": prog},
    }


def _find_progress(obj):
    """Walk a JSON tree looking for a numeric 'progress' field. Returns the first found."""
    if isinstance(obj, dict):
        if "progress" in obj and isinstance(obj["progress"], (int, float)):
            return obj["progress"]
        for v in obj.values():
            r = _find_progress(v)
            if r is not None:
                return r
    elif isinstance(obj, list):
        for v in obj:
            r = _find_progress(v)
            if r is not None:
                return r
    return None


# ---------------------------------------------------------------------------
# Signal 2: completed angle directories vs num_angles
# ---------------------------------------------------------------------------
def try_angle_count_signal(output_dir: str, num_angles: int | None) -> dict | None:
    """Count <output_dir>/angle_*/d3plot files vs total num_angles."""
    if not output_dir or not num_angles or num_angles < 1:
        return None
    if not os.path.isdir(output_dir):
        return None
    pattern = os.path.join(output_dir, "angle_*", "d3plot")
    matches = glob.glob(pattern)
    completed = len(matches)
    total = int(num_angles)
    if completed == 0:
        # 0/N is ambiguous with "queued, nothing started yet". Defer to the
        # queued-vs-no-signal logic in the caller instead of reporting a hard 0%.
        return None
    pct = (completed / total) * 100.0 if total > 0 else 0.0
    pct = max(0.0, min(100.0, pct))
    detail = {"completed": completed, "total": total}
    if matches:
        try:
            detail["latest_completed_at"] = int(max(os.path.getmtime(m) for m in matches))
        except OSError:
            pass
    return {
        "progress_pct": round(pct, 2),
        "signal_used": "completed_angles",
        "detail": detail,
    }


# ---------------------------------------------------------------------------
# Signal 3: parse mes0000 / d3hsp for `current time` lines
# ---------------------------------------------------------------------------
# LS-DYNA "current time" line typical shapes:
#   "   1 t 1.0000E-06 dt 1.00E-06   ...  current time =   1.000000E-06"
# The robust thing is to look for the last 'current time' (case-insensitive) on
# the line and grab the trailing scientific-notation number.
_CURRENT_TIME_RE = re.compile(r"current\s+time\s*[=:]?\s*([0-9eE+\-.]+)", re.IGNORECASE)


def _read_tail(path: str, max_bytes: int = 1_000_000) -> str:
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size > max_bytes:
                f.seek(size - max_bytes)
            data = f.read()
    except OSError:
        return ""
    return data.decode("utf-8", errors="replace")


def _parse_t_final_from_runner_config(runner_config_path: str | None) -> float | None:
    if not runner_config_path or not os.path.exists(runner_config_path):
        return None
    try:
        with open(runner_config_path, "r", encoding="utf-8", errors="replace") as f:
            cfg = json.load(f)
    except (OSError, json.JSONDecodeError):
        return None
    # Walk for "tFinal" or "t_final" or "t_final_s".
    return _find_key_numeric(cfg, ("tFinal", "t_final", "t_final_s"))


def _find_key_numeric(obj, keys):
    if isinstance(obj, dict):
        for k in keys:
            if k in obj and isinstance(obj[k], (int, float)):
                return float(obj[k])
        for v in obj.values():
            r = _find_key_numeric(v, keys)
            if r is not None:
                return r
    elif isinstance(obj, list):
        for v in obj:
            r = _find_key_numeric(v, keys)
            if r is not None:
                return r
    return None


def try_mes_time_signal(work_dir: str, t_final: float | None) -> dict | None:
    if not work_dir or not t_final or t_final <= 0:
        return None
    candidates = [
        os.path.join(work_dir, "mes0000"),
        os.path.join(work_dir, "d3hsp"),
    ]
    # Some multi-angle runs have these under angle subdirs; if direct files
    # missing, peek at the most recent angle_*/mes0000.
    if not any(os.path.exists(p) for p in candidates):
        angle_mes = sorted(glob.glob(os.path.join(work_dir, "angle_*", "mes0000")))
        if angle_mes:
            candidates = [angle_mes[-1]]
    last_time = None
    src = None
    for p in candidates:
        if not os.path.exists(p):
            continue
        text = _read_tail(p)
        if not text:
            continue
        for m in _CURRENT_TIME_RE.finditer(text):
            try:
                t = float(m.group(1))
                last_time = t
            except ValueError:
                continue
        if last_time is not None:
            src = p
            break
    if last_time is None:
        return None
    pct = (last_time / t_final) * 100.0
    pct = max(0.0, min(100.0, pct))
    return {
        "progress_pct": round(pct, 2),
        "signal_used": "mes_time",
        "detail": {
            "current_time": last_time,
            "t_final": t_final,
            "source_file": src,
        },
    }


# ---------------------------------------------------------------------------
# Queued detection: output_dir empty + no slurm log file
# ---------------------------------------------------------------------------
def looks_queued(work_dir: str, output_dir: str) -> bool:
    log_candidates = [
        os.path.join(work_dir or "", "lsdyna.slurm.out"),
        os.path.join(work_dir or "", "lsdyna.slurm.err"),
    ]
    has_log = any(os.path.exists(p) and os.path.getsize(p) > 0 for p in log_candidates)
    if has_log:
        return False
    if output_dir and os.path.isdir(output_dir):
        try:
            entries = [e for e in os.listdir(output_dir) if not e.startswith(".")]
        except OSError:
            entries = []
        if entries:
            return False
    return True


# ---------------------------------------------------------------------------
# ETA estimation (only for angle-count signal — §19.4 anti-pattern: don't ETA on mes_time alone)
# ---------------------------------------------------------------------------
def estimate_eta(signal: dict, submitted_at: int | None) -> tuple[int | None, str | None, int | None]:
    """Return (eta_sec, eta_confidence, elapsed_sec). Only emits ETA for angle signal
    where completed/total + elapsed give a defensible rate. Returns (None, None, elapsed)
    for other signals or when we can't compute it."""
    elapsed = None
    if submitted_at:
        elapsed = max(0, int(time.time()) - int(submitted_at))
    if signal.get("signal_used") != "completed_angles":
        return None, None, elapsed
    detail = signal.get("detail") or {}
    completed = detail.get("completed") or 0
    total = detail.get("total") or 0
    if completed <= 0 or total <= 0 or completed >= total:
        return None, None, elapsed
    if elapsed is None or elapsed <= 0:
        return None, None, elapsed
    remaining = total - completed
    per_angle = elapsed / completed
    eta = int(per_angle * remaining)
    # Confidence: more completed angles → higher confidence.
    if completed >= 20:
        conf = "high"
    elif completed >= 5:
        conf = "medium"
    else:
        conf = "low"
    return eta, conf, elapsed


# ---------------------------------------------------------------------------
def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])

    # §18: enforce caller identity, mode: own.
    caller = os.environ.get("USER") or os.environ.get("LOGNAME")
    if not caller:
        fail("cannot determine caller identity (USER/LOGNAME unset)")

    job = resolve_job(args)
    if not job:
        fail("job not found in registry", lookup=args)

    owner = job.get("user")
    if owner and owner != caller:
        fail(
            "permission denied: job belongs to another user",
            job_owner=owner,
            caller=caller,
        )

    work_dir = job.get("work_dir") or ""
    output_dir = job.get("output_dir") or ""
    runner_config_path = job.get("runner_config_path")
    num_angles = job.get("num_angles")
    submitted_at = job.get("submitted_at")

    # Try signals in priority order (§19.1).
    signal = (
        try_koochainrun_signal(runner_config_path)
        or try_angle_count_signal(output_dir, num_angles)
        or try_mes_time_signal(work_dir, _parse_t_final_from_runner_config(runner_config_path))
    )

    base = {
        "ok": True,
        "tool": "job_progress",
        "registry_id": job["id"],
        "owner": owner,
        "work_dir": work_dir,
    }

    if signal is None:
        # Queued vs no-signal-at-all (§19.4).
        if looks_queued(work_dir, output_dir):
            base.update({
                "progress_pct": 0,
                "signal_used": None,
                "reason": "queued",
            })
        else:
            base.update({
                "progress_pct": None,
                "signal_used": None,
                "reason": "no usable progress signal (no KooChainRun status, no angle_*/d3plot, no parseable mes0000/d3hsp)",
            })
        _audit_inspect(caller, job, base.get("signal_used"), base.get("progress_pct"))
        print(json.dumps(base, ensure_ascii=False, default=str))
        return

    # Have a signal — assemble full response with optional ETA.
    eta_sec, eta_conf, elapsed_sec = estimate_eta(signal, submitted_at)
    base.update(signal)
    if elapsed_sec is not None:
        base["elapsed_sec"] = elapsed_sec
    if eta_sec is not None:
        base["eta_sec"] = eta_sec
        base["eta_confidence"] = eta_conf

    _audit_inspect(caller, job, base.get("signal_used"), base.get("progress_pct"))
    print(json.dumps(base, ensure_ascii=False, default=str))


def _audit_inspect(caller: str, job: dict, signal_used, progress_pct):
    """§25.3.3 inspection audit with 5-min session_seen dedup guard."""
    tool_qn = "job_progress@1.0.0"
    target_id = str(job["id"])
    if audit.session_seen(caller, tool_qn, target_id, within_sec=300):
        return
    audit.record_event(
        actor=caller,
        tool=tool_qn,
        action="inspect",
        summary=f"checked progress for job {target_id} (signal={signal_used}, pct={progress_pct})",
        target_kind="job",
        target_id=target_id,
        detail={
            "signal_used": signal_used,
            "progress_pct": progress_pct,
        },
    )


try:
    main()
except SystemExit:
    raise
except Exception as e:
    fail(f"unhandled exception: {type(e).__name__}: {e}")
PY
