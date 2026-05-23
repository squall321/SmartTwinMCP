#!/usr/bin/env bash
# list_recent_jobs — SQLite-backed registry query
set -euo pipefail

export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import json, os, sys, time, datetime

sys.path.insert(0, os.environ["SHARED_DIR"])
import registry


def main():
    args = json.loads(os.environ["STMC_ARGS_JSON"])

    limit = int(args.get("limit", 20))
    status = args.get("status")
    tool = args.get("tool")
    project_like = args.get("project_like")
    only_mine = bool(args.get("only_mine", True))

    since = None
    hrs = args.get("since_hours_ago")
    if hrs is not None:
        since = int(time.time() - float(hrs) * 3600)

    user = os.environ.get("USER") if only_mine else None

    rows = registry.list_recent(
        limit=limit, status=status, tool=tool,
        since=since, project_like=project_like, user=user,
    )

    # Add human-readable timestamps
    for r in rows:
        ts = r.get("submitted_at")
        if ts:
            r["submitted_at_human"] = datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")
        # Truncate notes for brevity
        if r.get("notes") and len(r["notes"]) > 200:
            r["notes"] = r["notes"][:200] + "..."

    print(json.dumps({
        "ok": True,
        "total_returned": len(rows),
        "filters_applied": {
            "limit": limit, "status": status, "tool": tool,
            "since_hours_ago": hrs, "project_like": project_like,
            "only_mine": only_mine,
        },
        "jobs": rows,
    }, ensure_ascii=False, default=str))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(json.dumps({"ok": False, "reason": f"{type(e).__name__}: {e}"}))
        sys.exit(1)
PY
