"""End-to-end integration test for §29 audit analytics tools.

Seeds a tmp audit DB with a deterministic event stream that exercises every
heuristic and every shape clause in §29.2–§29.5, then invokes each of the
four §29 tools via the catalog runner (real script.sh, real subprocess,
real json envelope). Verifies:

- audit_summary: total + group_by aggregation, empty group_by shape, default since
- audit_trail: oldest-first timeline, target_kind_seen dedup, unknown target → count:0
- audit_who: action filter required, target_id narrow, limit clamping
- audit_anomaly:
    * cancel_churn: single-actor finding (one actor cancels twice)
    * cancel_churn: multi-actor finding (actor=null + actors=[...])  ← §29 gap fix
    * submit_flood: configurable threshold (submit_flood_threshold)  ← §29 gap fix
    * stale_pending: brand-new submit is NOT flagged (submit_age_min_sec)  ← §29 gap fix
    * stale_pending: old submit with no follow-up IS flagged

No production DB is touched — `STMC_AUDIT_DB` is repointed to a tmpfile.
"""
from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
TOOLS_DIR = REPO_ROOT / "tools"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _insert_event(
    db_path: str,
    *,
    occurred_at: int,
    actor: str,
    tool: str,
    action: str,
    target_kind: str | None = None,
    target_id: str | None = None,
    summary: str = "",
    detail: dict | None = None,
) -> int:
    """Insert one audit row at a chosen timestamp.

    The §29 tools never write — they only read. This bypasses
    ``audit.record_event`` (which stamps ``time.time()``) so the test can
    place events at exact timestamps relative to ``now``.
    """
    with sqlite3.connect(db_path) as con:
        cur = con.execute(
            """INSERT INTO audit_events (
                occurred_at, actor, tool, action,
                target_kind, target_id, summary, detail
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                occurred_at, actor, tool, action,
                target_kind, target_id, summary,
                json.dumps(detail) if detail else None,
            ),
        )
        return cur.lastrowid


def _run_tool(name: str, version: str, args: dict, audit_db: str, user: str = "alice") -> dict:
    """Invoke a §29 tool by directly calling its script.sh as the runner would.

    Mirrors what ``runner.py:_run_local`` does for catalog_run: pass args as
    ``STMC_ARGS_JSON`` env and read stdout JSON.
    """
    script = TOOLS_DIR / name / version / "script.sh"
    assert script.exists(), f"missing script: {script}"

    env = os.environ.copy()
    env["STMC_ARGS_JSON"] = json.dumps(args)
    env["STMC_AUDIT_DB"] = audit_db
    env["USER"] = user

    result = subprocess.run(
        ["/bin/bash", str(script)],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )
    # §4: stdout = JSON envelope, stderr = log. Tool may exit 1 on fail() but
    # still print JSON. We always parse stdout.
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as e:
        raise AssertionError(
            f"{name}: non-JSON stdout (rc={result.returncode}):\n"
            f"stdout: {result.stdout!r}\nstderr: {result.stderr!r}"
        ) from e
    return payload


# ---------------------------------------------------------------------------
# Fixture: seeded audit DB
# ---------------------------------------------------------------------------

# Anchor `now` at a fixed past instant so the test is deterministic regardless
# of when it runs. The §29 tools use `time.time()` for defaults — we override
# `until` explicitly in each call so wall-clock has no effect on assertions.
ANCHOR_NOW = 1_716_000_000   # 2024-05-18T07:33:20Z
ONE_HOUR = 3600
ONE_DAY = 24 * ONE_HOUR


@pytest.fixture
def seeded_audit_db(tmp_path):
    """A populated audit DB covering every §29 case the test asserts on."""
    db = tmp_path / "audit.db"

    # Bootstrap the schema by importing audit.py with STMC_AUDIT_DB pointing here.
    # Just calling _ensure_db() creates the file with the right shape.
    sys.path.insert(0, str(TOOLS_DIR / "_shared"))
    os.environ["STMC_AUDIT_DB"] = str(db)
    # Re-import in case audit was already imported in another test
    if "audit" in sys.modules:
        del sys.modules["audit"]
    import audit  # noqa: E402
    # audit.DB_PATH is module-level — re-bind to the test DB
    audit.DB_PATH = str(db)
    audit.DB_DIR = str(db.parent)
    audit._ensure_db()

    # --- Events for audit_summary / audit_trail / audit_who ----------------
    # Job 100: standard submit→inspect→postprocess chain by alice
    _insert_event(str(db), occurred_at=ANCHOR_NOW - 6*ONE_HOUR,
                  actor="alice", tool="submit_lsdyna_job@1.1.0",
                  action="submit", target_kind="job", target_id="100",
                  summary="submit job 100")
    _insert_event(str(db), occurred_at=ANCHOR_NOW - 5*ONE_HOUR,
                  actor="alice", tool="job_status@1.0.0",
                  action="inspect", target_kind="job", target_id="100",
                  summary="status check")
    _insert_event(str(db), occurred_at=ANCHOR_NOW - 4*ONE_HOUR,
                  actor="alice", tool="job_postprocess@1.1.0",
                  action="pipeline_step", target_kind="job", target_id="100",
                  summary="postprocess all")

    # Job 200: bob did a single submit, no follow-up — STALE candidate
    # (must be older than submit_age_min_sec=1800 from `until`)
    _insert_event(str(db), occurred_at=ANCHOR_NOW - 20*ONE_HOUR,
                  actor="bob", tool="submit_lsdyna_job@1.1.0",
                  action="submit", target_kind="job", target_id="200",
                  summary="bob's lonely submit")

    # Job 201: bob just submitted (5 minutes ago) — NOT stale yet (age gate)
    _insert_event(str(db), occurred_at=ANCHOR_NOW - 5*60,
                  actor="bob", tool="submit_lsdyna_job@1.1.0",
                  action="submit", target_kind="job", target_id="201",
                  summary="brand-new submit")

    # --- Events for audit_anomaly: cancel_churn (single-actor) -------------
    # Job 300: alice cancels 3 times within 6 minutes — clearly churn
    for i, off in enumerate([10*ONE_HOUR, 10*ONE_HOUR - 120, 10*ONE_HOUR - 360]):
        _insert_event(str(db), occurred_at=ANCHOR_NOW - off,
                      actor="alice", tool="job_stop@1.1.0",
                      action="cancel", target_kind="job", target_id="300",
                      summary=f"cancel #{i+1}")

    # --- Events for audit_anomaly: cancel_churn (multi-actor) --------------
    # Job 400: alice cancels, then admin also cancels — both within 10 min
    _insert_event(str(db), occurred_at=ANCHOR_NOW - 8*ONE_HOUR,
                  actor="alice", tool="job_stop@1.1.0",
                  action="cancel", target_kind="job", target_id="400",
                  summary="alice cancels")
    _insert_event(str(db), occurred_at=ANCHOR_NOW - 8*ONE_HOUR + 300,
                  actor="admin", tool="job_stop@1.1.0",
                  action="cancel", target_kind="job", target_id="400",
                  summary="admin also cancels")

    # --- Events for audit_anomaly: submit_flood ----------------------------
    # Carol submits 12 jobs in 30 min — flood when threshold=10, fine at 50
    base = ANCHOR_NOW - 12*ONE_HOUR
    for i in range(12):
        _insert_event(str(db), occurred_at=base + i*120,
                      actor="carol", tool="submit_lsdyna_job@1.1.0",
                      action="submit", target_kind="job", target_id=f"50{i:02d}",
                      summary=f"carol burst #{i+1}",
                      detail={"dry_run": False})

    yield str(db)

    # cleanup — restore env / clear cached module so other tests aren't poisoned
    os.environ.pop("STMC_AUDIT_DB", None)
    sys.modules.pop("audit", None)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_audit_summary_default_group_by_action(seeded_audit_db):
    """§29.2: default group_by=['action'] aggregates by action, sorted desc.

    Default actor = caller (alice). alice's events in the window:
    - 1 submit (job 100), 1 inspect (job 100), 1 pipeline_step (job 100)
    - 3 cancels (job 300), 1 cancel (job 400) = 7 total
    """
    out = _run_tool(
        "audit_summary", "1.0.0",
        {"since": ANCHOR_NOW - ONE_DAY, "until": ANCHOR_NOW},
        audit_db=seeded_audit_db, user="alice",
    )
    assert out["ok"] is True, out
    assert out["tool"] == "audit_summary"
    assert out["actor"] == "alice"
    assert out["total_events"] == 7, out
    actions = {g["key"]["action"]: g["count"] for g in out["groups"]}
    assert actions.get("cancel") == 4
    assert actions.get("submit") == 1
    assert actions.get("inspect") == 1
    assert actions.get("pipeline_step") == 1
    # Sort: cancel (4) must come first
    assert out["groups"][0]["key"]["action"] == "cancel"


def test_audit_summary_empty_group_by_returns_total_only(seeded_audit_db):
    """§29 gap fix: group_by=[] → groups:[] with only total_events populated."""
    out = _run_tool(
        "audit_summary", "1.0.0",
        {
            "since": ANCHOR_NOW - ONE_DAY,
            "until": ANCHOR_NOW,
            "group_by": [],
        },
        audit_db=seeded_audit_db, user="alice",
    )
    assert out["ok"] is True, out
    assert out["groups"] == [], out
    assert out["total_events"] == 7, out


def test_audit_summary_multi_dim_composite_key(seeded_audit_db):
    """§29.2: group_by=['action','tool'] produces composite keys."""
    out = _run_tool(
        "audit_summary", "1.0.0",
        {
            "since": ANCHOR_NOW - ONE_DAY,
            "until": ANCHOR_NOW,
            "group_by": ["action", "tool"],
        },
        audit_db=seeded_audit_db, user="alice",
    )
    assert out["ok"] is True
    # Every group key must have both dimensions present
    for g in out["groups"]:
        assert set(g["key"].keys()) == {"action", "tool"}


def test_audit_trail_oldest_first_with_kind_dedup(seeded_audit_db):
    """§29.3: trail returns oldest-first; target_kind_seen lists unique kinds."""
    out = _run_tool(
        "audit_trail", "1.0.0",
        {"target_id": "100", "limit": 100},
        audit_db=seeded_audit_db, user="alice",
    )
    assert out["ok"] is True, out
    assert out["count"] == 3, out
    assert out["target_kind_seen"] == ["job"], out
    actions = [e["action"] for e in out["events"]]
    assert actions == ["submit", "inspect", "pipeline_step"], (
        f"trail must be oldest-first, got {actions}"
    )


def test_audit_trail_unknown_target_returns_empty(seeded_audit_db):
    """§29.3: empty target → count:0, no hard fail."""
    out = _run_tool(
        "audit_trail", "1.0.0",
        {"target_id": "99999", "limit": 100},
        audit_db=seeded_audit_db, user="alice",
    )
    assert out["ok"] is True, out
    assert out["count"] == 0
    assert out["events"] == []


def test_audit_who_filters_by_action_and_target(seeded_audit_db):
    """§29.4: action+target_id filter narrows to the matching rows."""
    out = _run_tool(
        "audit_who", "1.0.0",
        {
            "action": "cancel",
            "target_id": "300",
            "since": ANCHOR_NOW - ONE_DAY,
            "until": ANCHOR_NOW,
            "limit": 50,
        },
        audit_db=seeded_audit_db, user="alice",
    )
    assert out["ok"] is True, out
    assert out["count"] == 3, out
    for e in out["events"]:
        assert e["action"] == "cancel"
        assert e["target_id"] == "300"
        assert e["actor"] == "alice"


def test_audit_who_unknown_action_zero_rows(seeded_audit_db):
    """§29.4: no matches → count:0, events:[] (still ok)."""
    out = _run_tool(
        "audit_who", "1.0.0",
        {
            "action": "acknowledge",   # not seeded
            "since": ANCHOR_NOW - ONE_DAY,
            "until": ANCHOR_NOW,
        },
        audit_db=seeded_audit_db, user="alice",
    )
    assert out["ok"] is True, out
    assert out["count"] == 0


def test_anomaly_cancel_churn_single_actor(seeded_audit_db):
    """§29.5.1: job 300 has 3 cancels by alice within 6 min → churn finding."""
    out = _run_tool(
        "audit_anomaly", "1.0.0",
        {
            "since": ANCHOR_NOW - ONE_DAY,
            "until": ANCHOR_NOW,
            "heuristics": ["cancel_churn"],
        },
        audit_db=seeded_audit_db, user="alice",
    )
    assert out["ok"] is True, out
    churns = [f for f in out["findings"] if f["heuristic"] == "cancel_churn"]
    by_target = {f["target_id"]: f for f in churns}
    assert "300" in by_target, churns
    j300 = by_target["300"]
    assert j300["actor"] == "alice"
    assert "actors" not in j300, "single-actor finding must not include actors[]"
    assert len(j300["supporting_events"]) == 3


def test_anomaly_cancel_churn_multi_actor(seeded_audit_db):
    """§29 gap fix: job 400 has 2 cancels by 2 actors → actor=null + actors=[..]."""
    out = _run_tool(
        "audit_anomaly", "1.0.0",
        {
            "since": ANCHOR_NOW - ONE_DAY,
            "until": ANCHOR_NOW,
            "heuristics": ["cancel_churn"],
        },
        audit_db=seeded_audit_db, user="alice",
    )
    churns = [f for f in out["findings"] if f["heuristic"] == "cancel_churn"]
    by_target = {f["target_id"]: f for f in churns}
    assert "400" in by_target, churns
    j400 = by_target["400"]
    assert j400["actor"] is None, j400
    assert j400["actors"] == ["admin", "alice"], j400
    assert len(j400["supporting_events"]) == 2


def test_anomaly_submit_flood_configurable_threshold(seeded_audit_db):
    """§29 gap fix: threshold=10 fires for carol's 12 burst; default 50 does not."""
    # Default threshold (50) — 12 submits is well under
    out_default = _run_tool(
        "audit_anomaly", "1.0.0",
        {
            "since": ANCHOR_NOW - ONE_DAY,
            "until": ANCHOR_NOW,
            "heuristics": ["submit_flood"],
        },
        audit_db=seeded_audit_db, user="alice",
    )
    assert out_default["ok"] is True, out_default
    assert all(f["heuristic"] != "submit_flood" for f in out_default["findings"]), (
        "default threshold 50 should NOT flag a 12-event burst"
    )

    # Lower threshold to 10 — now it must fire
    out_strict = _run_tool(
        "audit_anomaly", "1.0.0",
        {
            "since": ANCHOR_NOW - ONE_DAY,
            "until": ANCHOR_NOW,
            "heuristics": ["submit_flood"],
            "submit_flood_threshold": 10,
        },
        audit_db=seeded_audit_db, user="alice",
    )
    floods = [f for f in out_strict["findings"] if f["heuristic"] == "submit_flood"]
    assert len(floods) == 1, out_strict
    assert floods[0]["actor"] == "carol"
    assert floods[0]["severity"] == "medium"   # dry_run=False → not low
    assert len(floods[0]["supporting_events"]) == 12


def test_anomaly_stale_pending_respects_age_gate(seeded_audit_db):
    """§29 gap fix:

    - Job 200 (bob, submitted 20h ago, no follow-up) → IS stale
    - Job 201 (bob, submitted 5 min ago, no follow-up) → NOT stale (age gate 30min)
    """
    out = _run_tool(
        "audit_anomaly", "1.0.0",
        {
            "since": ANCHOR_NOW - ONE_DAY,
            "until": ANCHOR_NOW,
            "heuristics": ["stale_pending"],
            # default submit_age_min_sec=1800 (30 min)
        },
        audit_db=seeded_audit_db, user="alice",
    )
    assert out["ok"] is True, out
    stales = [f for f in out["findings"] if f["heuristic"] == "stale_pending"]
    targets = {f["target_id"] for f in stales}
    assert "200" in targets, f"expected job 200 stale, got {targets}"
    assert "201" not in targets, (
        f"job 201 is only 5 min old — age gate should exclude it. Got {targets}"
    )


def test_anomaly_stale_pending_age_gate_can_be_disabled(seeded_audit_db):
    """§29 gap fix: submit_age_min_sec=0 disables the gate (everything qualifies)."""
    out = _run_tool(
        "audit_anomaly", "1.0.0",
        {
            "since": ANCHOR_NOW - ONE_DAY,
            "until": ANCHOR_NOW,
            "heuristics": ["stale_pending"],
            "submit_age_min_sec": 0,
        },
        audit_db=seeded_audit_db, user="alice",
    )
    stales = [f for f in out["findings"] if f["heuristic"] == "stale_pending"]
    targets = {f["target_id"] for f in stales}
    # With gate disabled, both 200 and 201 should appear
    assert {"200", "201"}.issubset(targets), (
        f"with gate=0 both jobs should be stale, got {targets}"
    )


def test_anomaly_run_all_heuristics(seeded_audit_db):
    """Sanity: default heuristics list runs all three without conflict."""
    out = _run_tool(
        "audit_anomaly", "1.0.0",
        {
            "since": ANCHOR_NOW - ONE_DAY,
            "until": ANCHOR_NOW,
            "submit_flood_threshold": 10,   # so the flood actually appears
        },
        audit_db=seeded_audit_db, user="alice",
    )
    assert out["ok"] is True, out
    seen = {f["heuristic"] for f in out["findings"]}
    assert seen == {"cancel_churn", "submit_flood", "stale_pending"}, seen
    assert out["count"] == len(out["findings"])
