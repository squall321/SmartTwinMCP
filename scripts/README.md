# Smoke scripts

Manual end-to-end checks that need an external setup (seeded webhook DB,
isolated `STMC_JOBS_DB`). NOT pytest-collected — run them by hand when you
want to validate the whole catalog against real-ish state.

## Setup (do this once per session)

```bash
export STMC_JOBS_DB=/tmp/stmc_e2e/jobs.db
export STMC_WEBHOOK_DB=/tmp/stmc_e2e/inbound_webhooks.db
mkdir -p "$(dirname "$STMC_WEBHOOK_DB")"

# Seed a few fake webhook rows so the §17 tools have something to work with.
.venv/bin/python - <<'PY'
import sqlite3, json, os, time
db = os.environ["STMC_WEBHOOK_DB"]
con = sqlite3.connect(db)
con.executescript("""
CREATE TABLE IF NOT EXISTS inbound_webhooks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    received_at INTEGER NOT NULL,
    source TEXT NOT NULL,
    event_type TEXT,
    headers TEXT,
    payload TEXT NOT NULL,
    signature_verified INTEGER,
    ack_status TEXT DEFAULT 'pending',
    ack_at INTEGER,
    ack_note TEXT
);
""")
now = int(time.time())
for src, et, body in [
    ("github", "push", {"ref": "refs/heads/main"}),
    ("slurm-callback", "job.completed", {"job_id": "12345"}),
]:
    con.execute(
        "INSERT INTO inbound_webhooks (received_at, source, event_type, headers, payload, signature_verified) VALUES (?, ?, ?, ?, ?, 1)",
        (now, src, et, "{}", json.dumps(body)),
    )
con.commit()
PY
```

## Smoke scripts

```bash
# Round-trip every tool with minimal args. Verifies the JSON-envelope contract
# holds for all 20+ tools, even when underlying solver binaries are missing.
.venv/bin/python scripts/smoke_all_tools.py

# Simulate a low-capability LLM: natural-language intent → catalog_search
# → catalog_describe → catalog_run. Confirms the discovery flow works.
.venv/bin/python scripts/smoke_weak_llm_flow.py
```
