"""Verify STMC_JOBS_DB override isolates tests from the production registry.

The registry module reads STMC_JOBS_DB at IMPORT time, so we set it before
importing and run all assertions in a single test process.
"""
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path


def test_jobs_db_env_override_isolates_writes():
    tmpdir = tempfile.mkdtemp(prefix="stmc_test_jobs_")
    tmp_db = os.path.join(tmpdir, "jobs.db")
    os.environ["STMC_JOBS_DB"] = tmp_db

    # Make _shared importable; force a fresh module so the env var is read.
    shared = Path(__file__).resolve().parents[1] / "tools" / "_shared"
    sys.path.insert(0, str(shared))
    sys.modules.pop("registry", None)
    import registry

    assert registry.DB_PATH == tmp_db, registry.DB_PATH
    assert not os.path.exists(tmp_db)

    jid = registry.record_submission(
        tool_name="test_isolation",
        work_dir="/tmp/x",
        output_dir="/tmp/x",
        status="dry_run",
    )
    assert jid >= 1
    assert os.path.exists(tmp_db), "registry should have created the override DB"

    # Production DB must NOT have been touched.
    prod_db = "/data/SmartTwinMCP/jobs.db"
    if os.path.exists(prod_db):
        import sqlite3
        con = sqlite3.connect(prod_db)
        row = con.execute(
            "SELECT count(*) FROM jobs WHERE tool_name = ?", ("test_isolation",)
        ).fetchone()
        con.close()
        assert row[0] == 0, "override DB leaked to production!"
