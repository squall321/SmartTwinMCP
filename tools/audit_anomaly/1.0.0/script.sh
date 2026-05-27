#!/usr/bin/env bash
# audit_anomaly — §29.5 closed-set heuristics over the §25 audit log.
# mode: read-all (§18.2 / §29.1). Observability only — never writes audit rows.
set -euo pipefail
export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import json
import os
import sys
import time


def fail(reason, **extra):
    print(json.dumps(
        {"ok": False, "tool": "audit_anomaly", "reason": reason, **extra},
        ensure_ascii=False,
    ))
    sys.exit(1)


def heuristic_cancel_churn(rows):
    """§29.5.1 — same target_id cancelled >= 2 times within any 10-min window."""
    findings = []
    # Bucket cancel events by target_id.
    by_target: dict[str, list] = {}
    for r in rows:
        if r.get("action") != "cancel":
            continue
        tid = r.get("target_id")
        if not tid:
            continue
        by_target.setdefault(tid, []).append(r)

    for tid, cancels in by_target.items():
        if len(cancels) < 2:
            continue
        # Sort by occurred_at ascending.
        cancels.sort(key=lambda r: int(r.get("occurred_at", 0) or 0))
        # Sliding 10-min window: find the largest cluster, report once per target.
        window_sec = 10 * 60
        best_cluster = []
        n = len(cancels)
        i = 0
        for j in range(n):
            while int(cancels[j]["occurred_at"]) - int(cancels[i]["occurred_at"]) > window_sec:
                i += 1
            if (j - i + 1) > len(best_cluster):
                best_cluster = cancels[i:j + 1]

        if len(best_cluster) >= 2:
            span = int(best_cluster[-1]["occurred_at"]) - int(best_cluster[0]["occurred_at"])
            actors = sorted({c.get("actor") for c in best_cluster if c.get("actor")})
            # §29.5 multi-actor semantics: single actor → actor=str, actors omitted.
            # Multiple actors → actor=null, actors=[...list...].
            finding = {
                "heuristic": "cancel_churn",
                "severity": "medium",
                "target_id": tid,
                "summary": f"target {tid} cancelled {len(best_cluster)} times in {span // 60} min {span % 60} sec",
                "supporting_events": [int(c["id"]) for c in best_cluster],
            }
            if len(actors) == 1:
                finding["actor"] = actors[0]
            else:
                finding["actor"] = None
                finding["actors"] = actors
            findings.append(finding)

    return findings


def heuristic_submit_flood(rows, threshold=50):
    """§29.5.2 — one actor with > threshold submit events within any 60-min window.

    Severity is `low` when >= 80% of those events have `detail.dry_run == true`
    (informational — no compute landed). Otherwise `medium`.
    """
    findings = []
    window_sec = 60 * 60

    by_actor: dict[str, list] = {}
    for r in rows:
        if r.get("action") != "submit":
            continue
        actor = r.get("actor")
        if not actor:
            continue
        by_actor.setdefault(actor, []).append(r)

    for actor, submits in by_actor.items():
        if len(submits) <= threshold:   # noqa: B023 — threshold is loop-constant
            continue
        submits.sort(key=lambda r: int(r.get("occurred_at", 0) or 0))
        # Sliding 60-min window: find the largest run.
        best_run = []
        n = len(submits)
        i = 0
        for j in range(n):
            while int(submits[j]["occurred_at"]) - int(submits[i]["occurred_at"]) > window_sec:
                i += 1
            if (j - i + 1) > len(best_run):
                best_run = submits[i:j + 1]

        if len(best_run) <= threshold:
            continue

        # §29.5 severity: low when >= 80% are dry_run, else medium.
        dry_count = 0
        for s in best_run:
            det = s.get("detail")
            if isinstance(det, dict) and det.get("dry_run") is True:
                dry_count += 1
        dry_ratio = dry_count / len(best_run) if best_run else 0.0
        severity = "low" if dry_ratio >= 0.8 else "medium"

        span = int(best_run[-1]["occurred_at"]) - int(best_run[0]["occurred_at"])
        findings.append({
            "heuristic": "submit_flood",
            "severity": severity,
            "actor": actor,
            "target_id": None,
            "summary": (
                f"actor {actor} submitted {len(best_run)} jobs in {span // 60} min "
                f"(dry_run ratio: {round(dry_ratio, 2)})"
            ),
            "supporting_events": [int(s["id"]) for s in best_run],
        })

    return findings


def heuristic_stale_pending(rows, until, submit_age_min_sec=1800):
    """§29.5.3 — target with `submit` but no inspect/pipeline_step/cancel
    since (now - 24h). i.e. no follow-up activity in the last 24h.

    `now` here is the `until` param (so the heuristic is reproducible against
    a historical window, not just wall-clock).

    submit_age_min_sec (default 1800): the submit must be at least this many
    seconds before `until` to be considered stale. Prevents brand-new submits
    from appearing as stale (§29.5 gap fix).
    """
    findings = []
    follow_up_actions = {"inspect", "pipeline_step", "cancel"}
    cutoff = int(until) - 24 * 3600
    # A submit must be older than this to be eligible.
    min_submit_ts = int(until) - int(submit_age_min_sec)

    # Group rows by target_id.
    by_target: dict[str, list] = {}
    for r in rows:
        tid = r.get("target_id")
        if not tid:
            continue
        by_target.setdefault(tid, []).append(r)

    for tid, evts in by_target.items():
        # Find the most recent submit for this target.
        submits = [e for e in evts if e.get("action") == "submit"]
        if not submits:
            continue
        submits.sort(key=lambda r: int(r.get("occurred_at", 0) or 0))
        last_submit = submits[-1]

        # Skip if the submit is too recent (brand-new — not actually stale yet).
        if int(last_submit.get("occurred_at", 0) or 0) > min_submit_ts:
            continue

        # Any follow-up since `cutoff`?
        has_follow_up = any(
            e.get("action") in follow_up_actions
            and int(e.get("occurred_at", 0) or 0) >= cutoff
            for e in evts
        )
        if has_follow_up:
            continue

        findings.append({
            "heuristic": "stale_pending",
            "severity": "medium",
            "actor": last_submit.get("actor"),
            "target_id": tid,
            "summary": (
                f"target {tid} submitted at {last_submit.get('occurred_at')} "
                f"with no inspect/pipeline_step/cancel in the last 24h"
            ),
            "supporting_events": [int(last_submit["id"])],
        })

    return findings


def main():
    # §18.1 — caller identity from environment.
    caller = os.environ.get("USER") or os.environ.get("LOGNAME")
    if not caller:
        fail("cannot determine caller identity (USER/LOGNAME unset)")

    args = json.loads(os.environ["STMC_ARGS_JSON"])

    sys.path.insert(0, os.environ["SHARED_DIR"])
    import audit  # noqa: E402

    db_existed_before = os.path.isfile(audit.DB_PATH)

    now = int(time.time())
    one_day = 24 * 3600
    since = int(args.get("since", now - one_day))
    until = int(args.get("until", now))
    if since > until:
        fail("`since` is later than `until`", since=since, until=until)

    heuristics = args.get("heuristics", ["cancel_churn", "submit_flood", "stale_pending"])
    # §29.5: default = all actors. Only narrow when the caller asked.
    actor_filter = args.get("actor")
    # §29.5 tunable thresholds (gap fix — see §29.5 arg spec).
    submit_flood_threshold = int(args.get("submit_flood_threshold", 50))
    submit_age_min_sec = int(args.get("submit_age_min_sec", 1800))

    # Fetch a wide window. `audit.list_events` accepts (limit, since, actor, ...).
    # Use a generous cap so we capture the full window.
    raw = audit.list_events(limit=100000, since=since, actor=actor_filter)
    rows = [r for r in raw if int(r.get("occurred_at", 0) or 0) <= until]

    findings = []
    if "cancel_churn" in heuristics:
        findings.extend(heuristic_cancel_churn(rows))
    if "submit_flood" in heuristics:
        findings.extend(heuristic_submit_flood(rows, threshold=submit_flood_threshold))
    if "stale_pending" in heuristics:
        findings.extend(heuristic_stale_pending(rows, until=until, submit_age_min_sec=submit_age_min_sec))

    # Stable ordering: severity (high > medium > low), then heuristic, then target.
    sev_rank = {"high": 0, "medium": 1, "low": 2}
    findings.sort(key=lambda f: (
        sev_rank.get(f.get("severity"), 99),
        f.get("heuristic", ""),
        str(f.get("target_id") or ""),
        str(f.get("actor") or ""),
    ))

    response = {
        "ok": True,
        "tool": "audit_anomaly",
        "period": {"since": since, "until": until},
        "heuristics_run": heuristics,
        "findings": findings,
        "count": len(findings),
    }
    if not db_existed_before:
        response["reason"] = "audit DB not initialized — no events recorded yet"

    print(json.dumps(response, ensure_ascii=False, default=str))


try:
    main()
except SystemExit:
    raise
except Exception as e:
    fail(f"{type(e).__name__}: {e}")
PY
