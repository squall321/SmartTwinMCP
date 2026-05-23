#!/usr/bin/env bash
# Reads args from $STMC_ARGS_JSON (also available on stdin).
# Emits a JSON envelope on stdout.
set -euo pipefail

: "${STMC_ARGS_JSON:=$(cat)}"
export STMC_ARGS_JSON

python3 - <<'PY'
import json, os

args = json.loads(os.environ["STMC_ARGS_JSON"])
message = args["message"]
count = int(args.get("count", 1))
print(json.dumps({
    "echoed": [message] * count,
    "tool": "echo",
}, ensure_ascii=False))
PY
