#!/usr/bin/env bash
# job_logs_mpi — parse multi-rank MPI output and return rank-tagged tails.
# Reference impl for AGENT_GUIDE §24.
set -euo pipefail

export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import json
import os
import re
import sys
from collections import defaultdict

sys.path.insert(0, os.environ["SHARED_DIR"])
import audit
from job_helpers import resolve_job, fail


# ---------------------------------------------------------------------------
# Highlight regexes (§24.2)
# ---------------------------------------------------------------------------
HIGHLIGHT_PATTERNS = {
    "errors": re.compile(r"(?i)(ERROR|Traceback|CUDA_ERROR|RuntimeError|Exception)"),
    "ncc":    re.compile(r"(?i)NCCL\s+(WARN|ERROR)"),
    "oom":    re.compile(r"(?i)(out of memory|OOM|cuda.+out of memory)"),
    "none":   None,
}

# §24.1: unlabeled-mode rank inference regex.
_INLINE_RANK_RE = re.compile(r"\b(?:rank|RANK|MPI_RANK)[=: ]\s*(\d+)\b")

# §24.1: labeled-mode prefix.
_LABELED_PREFIX_RE = re.compile(r"^(\d+):\s?(.*)$")

# Candidate unified-stream filenames to try, in priority order.
UNIFIED_CANDIDATES = ("slurm.out", "lsdyna.slurm.out", "slurm.err", "lsdyna.slurm.err")

# Per-rank file pattern: rank.<N>.log
_RANK_FILE_RE = re.compile(r"^rank\.(\d+)\.log$")


# ---------------------------------------------------------------------------
# Source-format detection (§24.1)
# ---------------------------------------------------------------------------
def detect_source_format(work_dir: str) -> tuple[str, dict]:
    """Return (source_format, ctx).

    ctx contents per format:
      per_rank_file: {"rank_files": {rank_int: path}}
      labeled:       {"unified_path": path}
      unlabeled:     {"unified_path": path or None}
    """
    # 1. per_rank_file
    rank_files: dict[int, str] = {}
    try:
        entries = os.listdir(work_dir)
    except OSError:
        entries = []
    for name in entries:
        m = _RANK_FILE_RE.match(name)
        if m:
            rank_files[int(m.group(1))] = os.path.join(work_dir, name)
    if rank_files:
        return "per_rank_file", {"rank_files": rank_files}

    # 2/3. unified stream — pick first existing candidate
    unified_path = None
    for fname in UNIFIED_CANDIDATES:
        p = os.path.join(work_dir, fname)
        if os.path.exists(p):
            unified_path = p
            break
    if unified_path is None:
        # No log file at all; treat as unlabeled with no source.
        return "unlabeled", {"unified_path": None}

    # Sample non-empty lines; if >= 80% match labeled prefix, it's labeled.
    nonempty = 0
    labeled = 0
    try:
        with open(unified_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                s = line.rstrip("\n")
                if not s.strip():
                    continue
                nonempty += 1
                if _LABELED_PREFIX_RE.match(s):
                    labeled += 1
                if nonempty >= 1000:
                    break
    except OSError:
        return "unlabeled", {"unified_path": unified_path}

    if nonempty > 0 and (labeled / nonempty) >= 0.8:
        return "labeled", {"unified_path": unified_path}
    return "unlabeled", {"unified_path": unified_path}


# ---------------------------------------------------------------------------
# Per-format reader: returns {rank_int: [lines...]}  (lines == tail of `n_lines`)
# For unlabeled, all unmatched lines are bucketed under the sentinel key -2
# ("unknown"). Caller maps -2 → "unknown" in the response.
# ---------------------------------------------------------------------------
UNKNOWN_RANK = -2


def read_per_rank_file(rank_files: dict[int, str], n_lines: int) -> dict[int, list[str]]:
    out: dict[int, list[str]] = {}
    for rank, path in rank_files.items():
        out[rank] = _tail_lines(path, n_lines)
    return out


def read_labeled(unified_path: str, n_lines: int) -> dict[int, list[str]]:
    """Bucket each line by its `<rank>:` prefix, then tail per rank."""
    buckets: dict[int, list[str]] = defaultdict(list)
    try:
        with open(unified_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                s = line.rstrip("\n")
                m = _LABELED_PREFIX_RE.match(s)
                if m:
                    rank = int(m.group(1))
                    buckets[rank].append(m.group(2))
                else:
                    buckets[UNKNOWN_RANK].append(s)
    except OSError:
        return {}
    return {r: lst[-n_lines:] for r, lst in buckets.items()}


def read_unlabeled(unified_path: str | None, n_lines: int) -> dict[int, list[str]]:
    """Use inline 'rank=N' tags where present; everything else goes to UNKNOWN_RANK."""
    if not unified_path:
        return {UNKNOWN_RANK: []}
    buckets: dict[int, list[str]] = defaultdict(list)
    try:
        with open(unified_path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                s = line.rstrip("\n")
                m = _INLINE_RANK_RE.search(s)
                if m:
                    rank = int(m.group(1))
                    buckets[rank].append(s)
                else:
                    buckets[UNKNOWN_RANK].append(s)
    except OSError:
        return {UNKNOWN_RANK: []}
    return {r: lst[-n_lines:] for r, lst in buckets.items()}


def _tail_lines(path: str, n: int) -> list[str]:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError as e:
        return [f"<read error: {type(e).__name__}: {e}>"]
    return [ln.rstrip("\n") for ln in lines[-n:]]


# ---------------------------------------------------------------------------
# Highlight scanning + representative selection (§24.3)
# ---------------------------------------------------------------------------
def scan_highlight(tail: list[str], pattern: re.Pattern | None) -> tuple[bool, str | None]:
    """Return (matched, signature_or_None). Signature = the captured group from
    the LAST matching line in the tail, normalized lowercase for grouping.
    For 'errors', if 'out of memory' appears, prefer the longer phrase so the
    LLM gets a meaningful signature."""
    if pattern is None:
        return False, None
    matched = False
    sig = None
    for line in tail:
        m = pattern.search(line)
        if m:
            matched = True
            # Prefer the more descriptive phrase if present in the line.
            low = line.lower()
            for phrase in ("cuda out of memory", "out of memory"):
                if phrase in low:
                    sig = phrase
                    break
            else:
                sig = m.group(0).strip()
    return matched, sig


def pick_representatives(
    per_rank_tails: dict[int, list[str]],
    highlight_name: str,
    pattern: re.Pattern | None,
) -> dict[int, dict]:
    """Build {rank: {representative, because, matched_highlight, highlight_signature}}.

    Always includes rank 0. For other ranks: up to 3 additional ranks whose tail
    matches highlight, lowest-rank-first per distinct error signature.
    For highlight=='none', only rank 0 is auto-selected.
    """
    decisions: dict[int, dict] = {}

    # Pre-compute matches for ALL real ranks (skip UNKNOWN_RANK from auto-pick).
    real_ranks = sorted(r for r in per_rank_tails.keys() if r >= 0)

    match_info: dict[int, tuple[bool, str | None]] = {}
    for r in real_ranks:
        match_info[r] = scan_highlight(per_rank_tails[r], pattern)

    # Rank 0 always representative if present.
    if 0 in per_rank_tails:
        matched, sig = match_info.get(0, (False, None))
        decisions[0] = {
            "representative": True,
            "because": "orchestrator (rank 0)",
            "matched_highlight": matched,
            "highlight_signature": sig,
        }

    # If highlight == none, no further auto-selection.
    if highlight_name != "none" and pattern is not None:
        # Group matching ranks by signature; take lowest rank per signature, max 3.
        seen_sigs: set[str | None] = set()
        added = 0
        for r in real_ranks:
            if r == 0:
                continue
            matched, sig = match_info[r]
            if not matched:
                continue
            key = sig or "<unspecified>"
            if key in seen_sigs:
                continue
            seen_sigs.add(key)
            decisions[r] = {
                "representative": True,
                "because": f"first rank matching highlight: '{sig}'" if sig else "first rank matching highlight",
                "matched_highlight": True,
                "highlight_signature": sig,
            }
            added += 1
            if added >= 3:
                break

    # Fill in non-representative entries for ranks NOT auto-selected, so
    # downstream code can construct full per-rank metadata regardless.
    for r in real_ranks:
        if r in decisions:
            continue
        matched, sig = match_info[r]
        decisions[r] = {
            "representative": False,
            "because": "not selected by heuristic",
            "matched_highlight": matched,
            "highlight_signature": sig,
        }

    # Unknown bucket if present — non-representative, no signature scan needed.
    if UNKNOWN_RANK in per_rank_tails:
        matched, sig = scan_highlight(per_rank_tails[UNKNOWN_RANK], pattern)
        decisions[UNKNOWN_RANK] = {
            "representative": False,
            "because": "unparsed lines (no rank tag)",
            "matched_highlight": matched,
            "highlight_signature": sig,
        }

    return decisions


# ---------------------------------------------------------------------------
# Build per-rank response entries
# ---------------------------------------------------------------------------
def build_rank_entry(
    rank: int,
    tail: list[str],
    decision: dict,
    source_format: str,
    ctx: dict,
) -> dict:
    if rank == UNKNOWN_RANK:
        rank_label: int | str = "unknown"
        log_path = ctx.get("unified_path")
    else:
        rank_label = rank
        if source_format == "per_rank_file":
            log_path = ctx["rank_files"].get(rank)
        else:
            log_path = ctx.get("unified_path")
    entry = {
        "rank": rank_label,
        "representative": decision["representative"],
        "because": decision["because"],
        "log_path": log_path,
        "tail": tail,
        "matched_highlight": decision["matched_highlight"],
    }
    if decision.get("highlight_signature"):
        entry["highlight_signature"] = decision["highlight_signature"]
    return entry


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
    if not work_dir or not os.path.isdir(work_dir):
        fail("job work_dir missing or not a directory",
             registry_id=job.get("id"), work_dir=work_dir)

    n_lines = int(args.get("lines", 200))
    highlight_name = args.get("highlight", "errors")
    if highlight_name not in HIGHLIGHT_PATTERNS:
        fail(f"unknown highlight: {highlight_name}")
    pattern = HIGHLIGHT_PATTERNS[highlight_name]

    # Detect format + read per-rank tails.
    source_format, ctx = detect_source_format(work_dir)
    if source_format == "per_rank_file":
        per_rank_tails = read_per_rank_file(ctx["rank_files"], n_lines)
    elif source_format == "labeled":
        per_rank_tails = read_labeled(ctx["unified_path"], n_lines)
    else:
        per_rank_tails = read_unlabeled(ctx.get("unified_path"), n_lines)

    real_ranks_detected = sorted(r for r in per_rank_tails.keys() if r >= 0)
    total_ranks_detected = len(real_ranks_detected)

    # Decide which ranks to return.
    requested = args.get("ranks")
    decisions = pick_representatives(per_rank_tails, highlight_name, pattern)

    if requested is None:
        # Default: representative heuristic.
        ranks_to_return = sorted(r for r, d in decisions.items()
                                 if d["representative"] and r != UNKNOWN_RANK)
    elif requested == [-1]:
        # All detected ranks (real only — unknown bucket excluded unless caller
        # explicitly asks via... well, they can't via int rank ids; that's fine).
        ranks_to_return = real_ranks_detected
    else:
        # Explicit list. Filter to those actually detected; silently drop missing.
        ranks_to_return = [r for r in requested if r in per_rank_tails]

    rank_entries = []
    for r in ranks_to_return:
        tail = per_rank_tails.get(r, [])
        decision = decisions.get(r, {
            "representative": False,
            "because": "explicitly requested",
            "matched_highlight": False,
            "highlight_signature": None,
        })
        # If user explicitly requested this rank, mark it so the LLM understands
        # why it's in the response even though heuristic didn't pick it.
        if requested is not None and requested != [-1] and not decision["representative"]:
            decision = {**decision, "because": "explicitly requested"}
        rank_entries.append(build_rank_entry(r, tail, decision, source_format, ctx))

    # §25.3.3 inspection audit with 5-min session_seen dedup guard.
    tool_qn = "job_logs_mpi@1.0.0"
    target_id = str(job["id"])
    if not audit.session_seen(caller, tool_qn, target_id, within_sec=300):
        audit.record_event(
            actor=caller,
            tool=tool_qn,
            action="inspect",
            summary=f"inspected MPI logs for job {target_id} ({total_ranks_detected} ranks, format={source_format})",
            target_kind="job",
            target_id=target_id,
            detail={
                "source_format": source_format,
                "total_ranks_detected": total_ranks_detected,
                "highlight": highlight_name,
            },
        )

    response = {
        "ok": True,
        "tool": "job_logs_mpi",
        "registry_id": job["id"],
        "owner": owner,
        "work_dir": work_dir,
        "source_format": source_format,
        "total_ranks_detected": total_ranks_detected,
        "lines": n_lines,
        "highlight": highlight_name,
        "ranks": rank_entries,
    }
    print(json.dumps(response, ensure_ascii=False))


try:
    main()
except SystemExit:
    raise
except Exception as e:
    fail(f"unhandled exception: {type(e).__name__}: {e}")
PY
