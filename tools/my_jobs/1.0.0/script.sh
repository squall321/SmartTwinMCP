#!/usr/bin/env bash
# my_jobs — §18 mode: own reference. Lists jobs where user == $USER.
set -euo pipefail
export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import json, os, sys

sys.path.insert(0, os.environ["SHARED_DIR"])
import registry


def fail(reason, **extra):
    print(json.dumps({"ok": False, "reason": reason, **extra}, ensure_ascii=False))
    sys.exit(1)


def main():
    # §18.1: caller identity comes from the environment, never from args.
    caller = os.environ.get("USER") or os.environ.get("LOGNAME")
    if not caller:
        fail("cannot determine caller identity (USER/LOGNAME unset)")

    args = json.loads(os.environ["STMC_ARGS_JSON"])

    limit = int(args.get("limit", 20))
    status = args.get("status")
    tool_name = args.get("tool_name")
    since = args.get("since")
    if since is not None:
        since = int(since)

    # §18.3: filter in SQL via list_recent's `user` param, not in Python.
    rows = registry.list_recent(
        limit=limit,
        status=status,
        tool=tool_name,
        since=since,
        user=caller,
    )

    # §18.5: every row must carry `user` so the LLM can confirm ownership.
    # registry.list_recent already returns the column, but defend against
    # legacy rows where it was never written.
    for r in rows:
        r.setdefault("user", None)

    print(json.dumps({
        "ok": True,
        "tool": "my_jobs",
        "caller": caller,
        "count": len(rows),
        "jobs": rows,
    }, ensure_ascii=False, default=str))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        fail(f"{type(e).__name__}: {e}")
PY
