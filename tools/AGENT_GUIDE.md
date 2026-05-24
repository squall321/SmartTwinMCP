# Tool Authoring Guide for AI Agents

> **Read this file before adding a new tool to this catalog.**
> This is the single source of truth for what a tool spec must look like.
> If a rule here conflicts with what you remember from a previous session, **this file wins**.

This catalog is loaded by the FastMCP server at [src/smarttwin_mcp/server.py](../src/smarttwin_mcp/server.py).
The server exposes 4 meta-tools (`catalog_search`, `catalog_describe`, `catalog_versions`, `catalog_run`)
plus any individual tool whose `meta.yaml` has `expose: direct`. Hundreds of tools can live here
without bloating the LLM tool list, **as long as you follow the rules below.**

---

## 0. The 60-second cheatsheet

To add a new tool named `my_tool`:

```bash
mkdir -p tools/my_tool/1.0.0
# create the 3 files described in §1 below
chmod +x tools/my_tool/1.0.0/script.sh
ln -sfn 1.0.0 tools/my_tool/latest
```

Then validate locally (§7) before considering the work done.

Three files, one symlink. That's it. No registration anywhere else. The server discovers
the tool on its next `catalog_reload` (or restart).

---

## 1. Required file layout

Every tool lives at:

```text
tools/<tool_name>/<version>/
  meta.yaml            # required — see §2
  args.schema.json     # required — see §3
  script.sh            # required — see §4 (must be chmod +x)
tools/<tool_name>/latest -> <version>    # symlink — see §5
```

Rules the catalog loader enforces (see [catalog.py](../src/smarttwin_mcp/catalog.py)):

- `<tool_name>` MUST be a valid Python identifier in spirit: `[a-z][a-z0-9_]*`.
  Do not use hyphens. Do not use uppercase. The folder name and `meta.name` MUST match exactly.
- `<version>` MUST follow semver (`MAJOR.MINOR.PATCH`, optionally `-prerelease+meta`).
  The folder name and `meta.version` MUST match exactly.
- A version folder name starting with `_` or `.` is ignored by the loader.
- A top-level tool folder starting with `_` or `.` is ignored entirely. This is how
  [_shared/](_shared/) (helper modules) hides from the catalog. **Use the same trick**
  if you need to drop helpers next to tools.

If folder name ≠ `meta.name` or `meta.version`, the loader records a `CatalogIssue` and
skips your tool. Always match.

---

## 2. `meta.yaml` — the contract with the LLM

This file is parsed by the pydantic models in [spec.py](../src/smarttwin_mcp/spec.py).
`extra: forbid` is on — **unknown keys cause load failure**. If you need a field that
doesn't exist, update `spec.py` first, don't invent ad-hoc keys.

### 2.1 Minimal valid `meta.yaml`

```yaml
name: my_tool                    # MUST equal folder name
version: 1.0.0                   # MUST equal version-folder name
summary: One-line description shown in catalog_search results.
description: |
  Multi-paragraph usage doc. Shown to the LLM via catalog_describe.
  This is where you tell the LLM how to call the tool. Be verbose. See §2.4.
tags: [job, slurm, lsdyna]       # used by catalog_search ranking
transport:
  kind: local                    # local | ssh | http  — see §6
  shell: /bin/bash
  timeout_sec: 60
expose: catalog                  # catalog (default) | direct | both — see §2.3
```

### 2.2 All available fields

| Field              | Type                              | Default    | Notes                                                                                                                |
|--------------------|-----------------------------------|------------|----------------------------------------------------------------------------------------------------------------------|
| `name`             | string                            | (required) | Must match folder name. Snake_case.                                                                                  |
| `version`          | string                            | (required) | Must match folder name. Semver.                                                                                      |
| `summary`          | string                            | (required) | ONE LINE. Shown in search hits. Keep under ~100 chars.                                                               |
| `description`      | string (multi-line)               | `""`       | LLM-facing usage doc. See §2.4.                                                                                      |
| `tags`             | list of strings                   | `[]`       | Search weights this 3× (vs 1× for description). Pick discriminating tags.                                            |
| `aliases`          | list of strings                   | `[]`       | Alternative names that resolve to this tool (latest version only). Must be globally unique across the whole catalog. |
| `transport`        | object                            | (required) | See §6.                                                                                                              |
| `expose`           | `catalog` / `direct` / `both`     | `catalog`  | See §2.3.                                                                                                            |
| `examples`         | list of `{title, args, note?}`    | `[]`       | At least one example is **strongly recommended**. The LLM uses these.                                                |
| `deprecated`       | bool                              | `false`    | Search score is multiplied by 0.3 for deprecated tools.                                                              |
| `deprecation_note` | string                            | `null`     | Tell the LLM what to use instead.                                                                                    |

### 2.3 `expose` — the most important choice you make

**Default is `catalog`. Keep it that way unless you have a specific reason.**

- `catalog` (default): The tool is reachable via `catalog_run` only. It does NOT
  appear as its own MCP tool in the LLM tool list. **This is what makes the catalog
  scale to hundreds of tools.**
- `direct`: The tool is ALSO registered as its own top-level MCP tool (named exactly
  `<name>`). Use this only for tools the LLM should see by name without searching.
  Examples of legitimate uses: a small set of "hub" tools (`submit_job`, `job_status`,
  `cancel_job`) that the LLM should always know exist.
- `both`: Same as `direct` (kept for clarity).

**Rule of thumb:** if you can't justify why this tool should be in the top-level list
over the existing direct-exposed tools, leave it as `catalog`.

> Only the **latest** version is ever directly exposed. Older versions stay catalog-only
> even if they have `expose: direct`. This is enforced in [server.py](../src/smarttwin_mcp/server.py).
>
> **Current state of this catalog:** as of writing, most existing tools are
> `expose: direct` because there are only ~14 of them and the LLM can handle the full
> list. This is fine for now. But **once the catalog grows past ~30–50 direct-exposed
> tools, weak LLMs will start losing track.** When that happens, flip the less-used
> tools back to `expose: catalog`. New tools you add now should default to `catalog`
> unless you have a specific reason — don't make the future cleanup harder.

### 2.4 Writing `description` for low-capability LLMs

This text is what a weak LLM sees when it calls `catalog_describe(my_tool)`. Treat it
as a self-contained instruction manual. Recommended structure:

````markdown
description: |
  One-paragraph overview of what this tool does.

  # When to call this
  - Concrete trigger phrases ("user asks to submit a .k file", "user wants raw LS-DYNA without KooChainRun")
  - When NOT to call this — name the alternative tool explicitly

  # Distinguish from similar tools
  - this_tool vs other_tool: ...

  # Pre-conditions
  - what must already exist on disk
  - what services must be reachable
  - what other tools must have been called first (e.g. submit_job → job_status)

  # Returns
  ```json
  { "ok": true, "registry_id": 42, ...exact-shape-of-response... }
  ```
````

Look at [submit_lsdyna_job/1.0.0/meta.yaml](submit_lsdyna_job/1.0.0/meta.yaml) for a
worked example.

**Don't**: write "see the code" or assume the LLM has access to anything outside
`meta.yaml` + `args.schema.json` + `examples`. It doesn't.

**Language policy:** LLM-facing fields (`summary`, `description`, JSON Schema
`description`s) may be in Korean, English, or mixed. Match the convention of neighboring
tools when in doubt — most existing `job_*` and drop-simulation tools use Korean
prose with English section headers (`# When to call this`), which is fine and
discoverable by both Korean and English prompts.

### 2.5 `examples` are not optional in practice

Even though the spec marks them as optional, **always include at least 2 examples**:
one minimal call and one with most options set. Examples cost nothing to write and
dramatically improve weak-LLM call accuracy. Examples must validate against
`args.schema.json` (CI/lint will check this — see §7).

**Exception for zero-arg tools.** If your tool's schema has no properties (or all
properties are optional and the LLM never needs to vary them — e.g. a health
check), one `args: {}` example is enough. Don't add a duplicate "second" example
that carries no information.

```yaml
examples:
  - title: minimal call
    args: { k_file: /data/x.k, lstc_license_ip: 192.168.122.1 }
  - title: large job, real submission
    args:
      k_file: /data/x.k
      lstc_license_ip: 192.168.122.1
      ncpu: 16
      memory: 32G
      time_limit: "12:00:00"
      dry_run: false
    note: dry_run=false actually submits to Slurm. Confirm with user first.
```

---

## 3. `args.schema.json` — JSON Schema for arguments

The server validates `args` against this schema BEFORE running your script.
Use **JSON Schema Draft 2020-12**.

### 3.1 Required structure

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "my_tool args",
  "type": "object",
  "additionalProperties": false,
  "required": ["essential_arg"],
  "properties": {
    "essential_arg": {
      "type": "string",
      "description": "..."
    }
  }
}
```

### 3.2 Hard rules

1. **`additionalProperties: false` is mandatory.** Catches LLM typos at validation time
   instead of silently dropping them in your script.
2. **Every property MUST have a `description`.** This is what the LLM reads to decide
   what value to pass. No description = LLM guesses.
3. **Constrain aggressively.** Use `enum`, `pattern`, `minimum`/`maximum`, `minLength`,
   `format`. The tighter the schema, the less the LLM hallucinates.
4. **Use `default` for any optional field with a sensible default.** The default is
   shown to the LLM via `catalog_describe`. Don't bury defaults inside the script.
5. **Absolute paths use `"pattern": "^/.+"` (or stricter).** Make it impossible for the
   LLM to pass a relative path.
6. **Booleans default to the safe choice.** `dry_run: true` by default, not false.

### 3.3 Common patterns to copy

```json
{
  "absolute_path":      { "type": "string", "pattern": "^/.+" },
  "k_file":             { "type": "string", "pattern": "^/.+\\.k$" },
  "ipv4":               { "type": "string", "pattern": "^([0-9]{1,3}\\.){3}[0-9]{1,3}$" },
  "slurm_time_limit":   { "type": "string", "pattern": "^[0-9]{1,3}:[0-5][0-9]:[0-5][0-9]$" },
  "slurm_memory":       { "type": "string", "pattern": "^[0-9]+[GM]$" },
  "ncpu":               { "type": "integer", "minimum": 1, "maximum": 64, "default": 1 },
  "solver":             { "type": "string", "enum": ["smarttwin-dyna", "openradioss"] }
}
```

### 3.4 The `job_*` lookup pattern (`registry_id` OR `work_dir`)

Any follow-up tool that operates on an already-submitted job (`job_status`, `job_logs`,
`job_stop`, ...) MUST accept lookup by **either** `registry_id` (preferred) **or**
`work_dir`. Both are passed to `job_helpers.resolve_job(args)` (§9.3). Encode the
mutual-exclusion in JSON Schema with `oneOf`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "job_logs args",
  "type": "object",
  "additionalProperties": false,
  "oneOf": [
    { "required": ["registry_id"] },
    { "required": ["work_dir"] }
  ],
  "properties": {
    "registry_id": {
      "type": "integer",
      "minimum": 1,
      "description": "DB primary key from the registry (preferred lookup)."
    },
    "work_dir": {
      "type": "string",
      "pattern": "^/.+",
      "description": "Absolute path to the job's work directory (fallback if registry_id unknown)."
    },
    "lines": {
      "type": "integer", "minimum": 1, "maximum": 5000, "default": 50,
      "description": "Lines to tail from each log file."
    }
  }
}
```

`oneOf` rejects both empty `{}` and ambiguous `{registry_id: 1, work_dir: "/x"}`,
which is exactly what we want.

---

## 4. `script.sh` — the executable body

The script is invoked by the runner in [runner.py](../src/smarttwin_mcp/runner.py).

### 4.1 The calling contract (memorize this)

| Channel              | Content                                                               |
|----------------------|-----------------------------------------------------------------------|
| `$STMC_ARGS_JSON`    | The args object, JSON-encoded. **Use this.**                          |
| stdin                | Same JSON. Available as a fallback if you prefer reading from stdin.  |
| stdout               | Your result. **Output a single JSON object** (see §4.3).              |
| stderr               | Diagnostics, logs, anything verbose. Returned to caller separately.   |
| exit code            | `0` = success. Non-zero = failure (caller sees `ok: false`).          |

### 4.2 Mandatory shebang & flags

```bash
#!/usr/bin/env bash
set -euo pipefail
```

Always. `set -e` (fail fast), `set -u` (no unset vars), `set -o pipefail` (catch
failures in pipes). Without these your script silently swallows errors and the catalog
reports `ok: true` for a broken run.

### 4.3 Stdout MUST be a single JSON object

This is non-negotiable. The runner tries to JSON-parse stdout and populates the `result`
field. If parsing fails, the caller gets raw text and probably misinterprets it.

**Required top-level keys** (project convention from existing tools):

```json
{
  "ok": true,
  "tool": "my_tool",
  "...":  "..."
}
```

On failure, exit non-zero AND print a JSON envelope to stdout:

```bash
python3 -c 'import json,sys; print(json.dumps({"ok": False, "reason": "license server unreachable"}))'
exit 1
```

**Do not print anything else to stdout.** Send progress logs to stderr (`>&2`).

### 4.4 Skeleton (copy this)

```bash
#!/usr/bin/env bash
# <tool_name> — <one-line purpose>
set -euo pipefail

# Make the shared helper modules importable if you need them.
export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import json, os, sys

# Optional shared helpers (SQLite registry, scenario builder, etc.)
sys.path.insert(0, os.environ["SHARED_DIR"])
# import registry  # uncomment if you need /data/SmartTwinMCP/jobs.db

def fail(reason, **extra):
    print(json.dumps({"ok": False, "reason": reason, **extra}, ensure_ascii=False))
    sys.exit(1)

args = json.loads(os.environ["STMC_ARGS_JSON"])

# --- your logic here ---
# Validate domain-specific preconditions the JSON Schema can't express.
# Call subprocesses. Read files. Whatever.
# On any error: fail("human-readable reason", path=..., detail=...)

print(json.dumps({
    "ok": True,
    "tool": "my_tool",
    # ...domain payload...
}, ensure_ascii=False))
PY
```

### 4.5 Permissions

```bash
chmod +x tools/my_tool/1.0.0/script.sh
```

Without the exec bit the runner can still invoke it via `/bin/bash`, but **other agents
expect it executable** for direct testing. Always set it.

### 4.6 What NOT to do

- ❌ Print human-readable text to stdout. Only JSON.
- ❌ Use `echo "ok"` for success. The catalog parses stdout as JSON.
- ❌ Trust `args` without re-validating domain preconditions (file exists, etc).
  JSON Schema can't check "this path exists on disk".
- ❌ Source other `script.sh` files. Each tool is independent.
- ❌ Write logs to stdout. Use stderr (`>&2`) or a real log file.

---

## 5. `latest` symlink — the canonical version pointer

Every tool MUST have a `latest` symlink pointing at the version that the catalog
exposes by default.

```bash
ln -sfn 1.0.0 tools/my_tool/latest
```

Resolution priority in [catalog.py](../src/smarttwin_mcp/catalog.py):

1. `latest` symlink (preferred — explicit, fast, git-trackable)
2. `_index.yaml` with `default_version: <v>` (use when filesystems don't support symlinks)
3. Highest semver (fallback — works, but implicit and surprising on prerelease versions)

**Always use option 1 unless you have a concrete reason not to.**

### Adding a new version of an existing tool

```bash
cp -r tools/my_tool/1.0.0 tools/my_tool/1.1.0
# edit meta.yaml: bump `version: 1.1.0`, update description if behavior changed
ln -sfn 1.1.0 tools/my_tool/latest    # promotes 1.1.0 to canonical
```

Old version stays reachable as `my_tool@1.0.0` via `catalog_run`. **Don't delete old
versions unless you mean it.**

---

## 6. Transports — local / ssh / http

The `transport` field in `meta.yaml` picks how `script.sh` (or the equivalent payload)
runs. Schemas are defined in [spec.py](../src/smarttwin_mcp/spec.py).

### 6.1 `local` (most common)

```yaml
transport:
  kind: local
  shell: /bin/bash           # optional, default /bin/bash
  cwd: /some/working/dir     # optional
  env:                       # optional, merged on top of os.environ
    LOG_LEVEL: info
  timeout_sec: 600           # optional, default 600
```

Runs `script.sh` as a subprocess on this host. Used by every existing tool in this
catalog.

### 6.2 `ssh`

```yaml
transport:
  kind: ssh
  host: head-node.cluster.local
  user: opscluster           # optional
  key_path: /home/svc/.ssh/cluster_id_ed25519   # optional
  port: 22                   # optional, default 22
  remote_cwd: /scratch/jobs  # optional
  env: { ... }               # optional
  timeout_sec: 600
```

The runner pipes `script.sh` over `ssh host bash -s` with `STMC_ARGS_JSON` exported on
the remote side. **The script must be self-contained** — `_shared/` modules are NOT
shipped to the remote host. If you need shared code over ssh, inline it.

### 6.3 `http`

```yaml
transport:
  kind: http
  method: POST                                 # GET | POST | PUT | DELETE | PATCH
  url: https://cluster-api.internal/v1/jobs
  headers: { Authorization: "Bearer ${TOKEN}" }
  body_template: '{"case": "{case_dir}"}'      # optional — Python str.format_map over args
  timeout_sec: 120
```

No `script.sh` execution. The runner POSTs args (or a `body_template` rendered with
args) to `url`. Response stdout is the body. Useful when SmartTwinCluster exposes a
REST endpoint and you don't want a shell shim. The `script.sh` file still needs to
exist (catalog requires it) — make it a no-op:

```bash
#!/usr/bin/env bash
echo '{"ok": false, "reason": "this tool uses http transport, not script execution"}'
exit 1
```

---

## 7. Validation checklist (do this before saying "done")

Run from the repo root:

```bash
# 1. Catalog loads with zero issues
.venv/bin/python -c "
from pathlib import Path
from smarttwin_mcp.catalog import load_catalog
c = load_catalog(Path('./tools').resolve())
assert c.issues == [], c.issues
assert 'my_tool' in c.latest_by_name, 'tool not discovered'
e = c.latest_by_name['my_tool']
print('OK:', e.qualified_name, '| exposed as', e.meta.expose)
"

# 2. JSON Schema is valid
.venv/bin/python -c "
import json, jsonschema
s = json.load(open('tools/my_tool/1.0.0/args.schema.json'))
jsonschema.Draft202012Validator.check_schema(s)
print('schema OK')
"

# 3. Every example validates against the schema
.venv/bin/python -c "
import json, yaml, jsonschema
schema = json.load(open('tools/my_tool/1.0.0/args.schema.json'))
meta = yaml.safe_load(open('tools/my_tool/1.0.0/meta.yaml'))
for ex in meta.get('examples', []):
    jsonschema.validate(ex['args'], schema)
print('examples OK:', len(meta.get('examples', [])))
"

# 4. Script is executable
test -x tools/my_tool/1.0.0/script.sh && echo 'exec bit OK'

# 5. latest symlink exists and points somewhere real
test -L tools/my_tool/latest && readlink tools/my_tool/latest

# 6. End-to-end run — TRANSPORT-DEPENDENT
#
# 6a. transport: local
STMC_ARGS_JSON='{"...minimal valid args..."}' bash tools/my_tool/1.0.0/script.sh | python3 -m json.tool
#
# 6b. transport: ssh
# Same env trick, but run through the runner instead of `bash` directly:
.venv/bin/python -c "
from pathlib import Path
from smarttwin_mcp.catalog import load_catalog
from smarttwin_mcp.runner import run
e = load_catalog(Path('./tools').resolve()).resolve('my_tool')
print(run(e, { '...minimal valid args...': '' }).to_dict())
"
#
# 6c. transport: http
# script.sh is a no-op (§15.7); test the actual HTTP path through the runner.
# Prove env interpolation works by trying BOTH (env unset → ok=false, missing env;
# env set to a fake host → ok=false, urlopen error proves URL was rendered).
unset STMC_CLUSTER_URL STMC_CLUSTER_TOKEN
.venv/bin/python -c "
from pathlib import Path
from smarttwin_mcp.catalog import load_catalog
from smarttwin_mcp.runner import run
e = load_catalog(Path('./tools').resolve()).resolve('my_tool')
r = run(e, {})
assert r.ok is False and 'missing env' in r.stderr, r
print('unset env OK')
"
STMC_CLUSTER_URL=http://127.0.0.1:1 STMC_CLUSTER_TOKEN=xxx .venv/bin/python -c "
from pathlib import Path
from smarttwin_mcp.catalog import load_catalog
from smarttwin_mcp.runner import run
e = load_catalog(Path('./tools').resolve()).resolve('my_tool')
r = run(e, {})
assert r.ok is False and ('Connection refused' in r.stderr or 'URLError' in r.stderr), r
print('fake env OK')
"

# 7. Existing tests still pass
.venv/bin/pytest tests/ -q
```

If any of these fail, **do not commit**. Fix first.

> **Prerequisite for steps 1, 2, 3, 6:** the venv must have `smarttwin-mcp`
> installed editable (`.venv/bin/pip install -e .` from repo root). The snippets
> import from `smarttwin_mcp.catalog` and `smarttwin_mcp.runner` which only
> resolve once the package is on the venv path.

---

## 8. Naming, aliases, and uniqueness

- Tool names live in a flat global namespace. `tools/job_status/` is `job_status`, period.
- `aliases` in `meta.yaml` are alternative resolution keys for the **latest** version
  of a tool. They share the same global namespace as tool names. The loader records
  a `CatalogIssue` if two tools claim the same alias.
- A version-qualified name like `job_status@1.0.0` is always resolvable, regardless of
  aliases or which version is `latest`.
- Don't pick aliases that look like another tool's primary name. Future-you will get
  confused. Bad: alias `submit` (too generic). Good: alias `sbatch_lsdyna`.

**Check existing names + aliases before picking yours.** Run this from the repo
root before committing a new tool:

```bash
.venv/bin/python -c "
from pathlib import Path
from smarttwin_mcp.catalog import load_catalog
c = load_catalog(Path('./tools').resolve())
taken = set(c.latest_by_name) | set(c.aliases)
for n in sorted(taken): print(n)
"
```

The collision check is also enforced at load time — duplicate aliases get
silently dropped and logged as a `CatalogIssue`, which §7 step 1 catches. But
catching it locally before you commit is friendlier than discovering it after.

---

## 9. Shared helpers in `_shared/`

Existing helpers (do not duplicate):

Three modules. **Read this section before writing anything that touches jobs, KooChainRun,
Slurm, or LS-DYNA scenarios** — these helpers already exist and re-implementing them in
your script is an anti-pattern.

### 9.1 How to import (the boilerplate)

```bash
export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"
python3 - <<'PY'
import sys, os
sys.path.insert(0, os.environ["SHARED_DIR"])

import registry           # SQLite job registry
import job_helpers        # resolve_job, run_koochainrun, slurm_queue_for, fail
import scenario_builder   # build_single_angle_scenario, build_fullangle_scenario, deep_merge
PY
```

The `SHARED_DIR` env var is the standard way to locate `_shared/`. **Do not** hard-code
absolute paths — different deployments mount the tree elsewhere.

### 9.2 `registry.py` — SQLite job registry

**DB path:** `/data/SmartTwinMCP/jobs.db` (auto-created on first call, WAL mode enabled).

**Schema columns (read-only — don't ALTER the table from a tool):**

| Column               | Type    | Notes                                                                          |
|----------------------|---------|--------------------------------------------------------------------------------|
| `id`                 | INTEGER | Primary key. **This is the `registry_id` other tools accept.**                 |
| `submitted_at`       | INTEGER | Unix epoch seconds (set by `record_submission`).                               |
| `tool_name`          | TEXT    | The tool that recorded this row, e.g. `"submit_lsdyna_job"`.                   |
| `project_name`       | TEXT    | Free-form project label (often a subdir of `work_dir`).                        |
| `work_dir`           | TEXT    | Absolute path where the job lives.                                             |
| `output_dir`         | TEXT    | Absolute path where results land. Equal to `work_dir` for raw `.k`.            |
| `runner_config_path` | TEXT    | Path to KooChainRun scenario JSON, if any.                                     |
| `slurm_job_ids`      | TEXT    | JSON-encoded list of Slurm IDs (e.g. `'["12345", "12346"]'`).                  |
| `sphere_job_id`      | TEXT    | Sphere postprocess Slurm ID, if any.                                           |
| `num_angles`         | INTEGER | For multi-angle drop runs.                                                     |
| `status`             | TEXT    | One of: `submitted`, `running`, `completed`, `failed`, `cancelled`, `dry_run`. |
| `last_checked_at`    | INTEGER | Set by `update_status`.                                                        |
| `notes`              | TEXT    | Free-form.                                                                     |
| `user`               | TEXT    | Auto-set to `$USER` / `$LOGNAME`.                                              |
| `extra`              | TEXT    | JSON blob for tool-specific data.                                              |

`slurm_job_ids` and `extra` are stored as JSON strings but `registry.py` decodes them
back to Python objects when reading. You write Python objects in, you read Python
objects out.

**Public functions:**

```python
def record_submission(
    tool_name: str,
    work_dir: str,
    output_dir: str,
    project_name: str | None = None,
    runner_config_path: str | None = None,
    slurm_job_ids: list[str] | None = None,
    sphere_job_id: str | None = None,
    num_angles: int | None = None,
    status: str = "submitted",
    notes: str | None = None,
    extra: dict | None = None,
) -> int:
    """Insert a row. Returns the DB primary key (NOT a Slurm job ID).
    Always include this `id` in your tool's JSON response as `registry_id`."""

def list_recent(
    limit: int = 20,
    status: str | None = None,
    tool: str | None = None,
    since: int | None = None,       # filter by submitted_at >= since (epoch)
    project_like: str | None = None, # SQL LIKE pattern, e.g. "drop%"
    user: str | None = None,
) -> list[dict]:
    """Newest-first list with AND filters. Returns row dicts (JSON fields decoded)."""

def get_by_id(job_id: int) -> dict | None:
    """Fetch one row by primary key. Returns None if missing."""

def update_status(job_id: int, status: str, notes: str | None = None) -> bool:
    """Update status (and optionally notes). Sets last_checked_at to now.
    Returns True if a row was updated."""

def search(query: str, limit: int = 20) -> list[dict]:
    """Case-insensitive LIKE search across project_name, work_dir, notes."""
```

**Conventions every tool that uses registry must follow:**

- After submission, **always** return `{"registry_id": <id>, ...}` in your JSON
  response. Downstream tools (`job_status`, `job_stop`, `job_logs`, ...) accept
  `registry_id` as their primary lookup key.
- On `dry_run`, still call `record_submission(..., status="dry_run")` so the user
  can see what would have been submitted. Some tools skip this — they shouldn't.
- Don't mutate rows from another tool's `tool_name` unless you're a status/lifecycle
  tool. Use `extra` for your own scratch data.

### 9.3 `job_helpers.py` — KooChainRun + Slurm wrappers

Used by every `job_*` follow-up tool (`job_status`, `job_stop`, `job_rerun`,
`job_collect`, `job_diagnose`, `job_postprocess`, `get_job_details`).

```python
KOOCHAINRUN = "/data/SmartTwinPreprocessor/bin/KooChainRun"

def resolve_job(args: dict) -> dict | None:
    """Look up a job by `registry_id` (preferred) or `work_dir` (fallback).
    Returns the registry row dict, or None if not found.
    YOUR tool's args.schema.json should accept BOTH keys (oneOf required)."""

def fail(reason: str, **extra) -> NoReturn:
    """Print {"ok": false, "reason": ..., **extra} to stdout and exit(1).
    Use this everywhere instead of raising bare exceptions —
    it keeps the JSON-stdout contract from §4.3.

    NOTE: If you're already importing `job_helpers` (which most job_* tools do),
    use `job_helpers.fail(...)` instead of defining a local `fail()` in your
    script. The skeleton in §4.4 defines a local `fail` only for tools that
    don't need any shared helpers; once you `import job_helpers`, drop the
    local copy."""

def run_koochainrun(
    subcommand: str,
    *extra_args: str,
    timeout: int = 300,
) -> tuple[int, str, str]:
    """Run `KooChainRun <subcommand> <args...>`. Returns (returncode, stdout, stderr).
    Calls fail() if the KooChainRun binary is missing or times out.
    Subcommands seen in existing tools: status, stop, rerun, collect, diagnose, postprocess."""

def slurm_queue_for(slurm_job_ids: list[str]) -> dict:
    """Run `squeue -j <ids>` and return {job_id: {state, name, reason}}.
    Returns {} on any error (don't fail — caller decides what missing data means)."""
```

**Pattern** (look at any `job_*/script.sh` for the full version):

```python
args = json.loads(os.environ["STMC_ARGS_JSON"])
job = job_helpers.resolve_job(args)
if not job:
    job_helpers.fail("job not found", lookup=args)

rc, out, err = job_helpers.run_koochainrun("status", job["runner_config_path"])
if rc != 0:
    job_helpers.fail("KooChainRun failed", rc=rc, stderr=err)

print(json.dumps({"ok": True, "tool": "...", "registry_id": job["id"], ...}))
```

**Key-name flip to remember:** the DB column is named `id`, so the dict returned by
`resolve_job()` has `job["id"]`. The downstream-facing JSON response field is named
`registry_id`. The flip happens at exactly one place — when you build the response
dict, write `"registry_id": job["id"]`. Don't carry the bare `id` through; callers
expect `registry_id`.

### 9.4 `scenario_builder.py` — drop-test scenario JSON

Used by `single_drop_simulation` and `fullangle_drop_simulation`. Builds the JSON
config that KooChainRun consumes. If you're writing a new tool that produces a
drop-test scenario, **always use these builders** — don't hand-roll the JSON.

```python
def build_single_angle_scenario(
    project_name: str,
    base_dir: str,
    model_file: str,        # absolute path to .k template
    lstc_ip: str,
    roll_deg: float = 0.0,
    pitch_deg: float = 0.0,
    yaw_deg: float = 0.0,
    height_mm: float = 1500,
    t_final_s: float = 0.005,
    ncpu: int = 1,
    memory: str = "2G",
    time_limit: str = "01:00:00",
    drop_surface_type: str = "Plane",
    extra_overrides: dict | None = None,   # Tier 2 — deep-merged on top
) -> dict: ...

def build_fullangle_scenario(
    project_name: str,
    base_dir: str,
    model_file: str,
    lstc_ip: str,
    num_directions: int = 162,             # Fibonacci lattice density
    height_mm: float = 1500,
    t_final_s: float = 0.005,
    ncpu: int = 2,
    memory: str = "4G",
    time_limit: str = "12:00:00",
    drop_surface_type: str = "Plane",
    enable_postprocess: bool = True,
    auto_deep: bool = True,
    auto_sphere: bool = True,
    auto_deep_mode: str = "inline",        # "inline" | "separate_job"
    yield_stress_mpa: float = 350,
    sif_path_postprocessor: str | None = None,
    extra_overrides: dict | None = None,
) -> dict: ...

def deep_merge(base: dict, overrides: dict | None) -> dict:
    """Recursively merge `overrides` into `base`. Lists REPLACE; dicts merge.
    Used internally by the builders, and exposed for tools that need to apply
    user-supplied scenario overrides."""

def write_scenario(scenario: dict, path: str) -> None:
    """json.dump with indent=2. Makes parent dirs."""
```

### 9.5 Rules for adding a new helper to `_shared/`

1. **Use threshold = 2.** Don't add to `_shared/` for a single tool; just inline.
2. **stdlib only** — no `requests`, `httpx`, `numpy`. Helpers must stay portable
   so they can eventually be inlined for ssh-transport tools (which don't have
   access to `_shared/` on the remote host — see §6.2).
3. **Module-level docstring** documenting every public function, with type hints.
   This guide section §9 mirrors what's in the docstrings; if you change one,
   change the other.
4. **Update this guide's §9** to list the new module + its public API.
5. **No state.** `_shared/` modules must not hold module-level mutable state
   (caches, sessions, connection pools). Each tool invocation is hermetic.

---

## 10. Deprecating a tool

Don't delete tools other agents may have learned. Deprecate:

```yaml
deprecated: true
deprecation_note: |
  Replaced by `submit_lsdyna_job` (v1.1.0+). Old tool used positional args;
  new tool uses keyword args via JSON Schema.
```

Search score is multiplied by 0.3 for deprecated tools, so they fall to the bottom
without disappearing. After ≥ 1 release cycle with no callers, you can delete the
folder.

---

## 11. Anti-patterns observed in past commits

Things that broke or almost broke the catalog. Don't repeat them.

| Anti-pattern                                              | What goes wrong                                            |
|-----------------------------------------------------------|------------------------------------------------------------|
| Adding a key to `meta.yaml` that isn't in `spec.py`       | Pydantic `extra=forbid` rejects → tool not loaded.         |
| `additionalProperties` missing or `true`                  | LLM typos silently dropped, hard to debug.                 |
| No `latest` symlink                                       | Works by fallback, but version promotion is implicit/risky.|
| `script.sh` prints "Job submitted!" then JSON             | stdout parsing fails. Use stderr for human text.           |
| `expose: direct` on every new tool                        | LLM tool list explodes; weak models lose track.            |
| Same alias on two tools                                   | `CatalogIssue` logged, one alias dropped silently.         |
| Hyphenated tool name (`submit-lsdyna-job`)                | Hard to call as a direct MCP tool from some clients.       |
| Sourcing `_shared/registry.py` from a `ssh` transport     | Remote host doesn't have the file. Inline what you need.   |
| Examples that don't validate against the schema           | LLM sees broken examples → broken calls.                   |
| Reading args from positional `$1 $2 $3` in `script.sh`    | Contract is JSON in `$STMC_ARGS_JSON` / stdin. Use it.     |
| Re-implementing SQLite logic (vs `_shared/registry.py`)   | Schema drifts; follow-up tools lose your jobs. See §9.2.   |
| Raising exceptions instead of `job_helpers.fail(...)`     | Breaks JSON-stdout contract (§4.3). Use the helper.        |
| Hand-rolling drop-test scenario JSON                      | `scenario_builder.build_*` already encodes the schema.     |

---

## 12. Quick reference: file templates

### `meta.yaml` template

````yaml
name: <tool_name>
version: 1.0.0
summary: <one line>
description: |
  <paragraph overview>

  # When to call this
  - <triggers>

  # Pre-conditions
  - <preconditions>

  # Returns
  ```json
  {"ok": true, ...}
  ```
tags: [<tag1>, <tag2>]
aliases: []
transport:
  kind: local
  shell: /bin/bash
  timeout_sec: 60
expose: catalog
examples:
  - title: minimal
    args: { <required_arg>: <value> }
  - title: full options
    args: { <required_arg>: <value>, <opt>: <value>, dry_run: false }
    note: <important behavior to flag>
````

### `args.schema.json` template

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "<tool_name> args",
  "type": "object",
  "additionalProperties": false,
  "required": ["<required_arg>"],
  "properties": {
    "<required_arg>": {
      "type": "string",
      "description": "<what this is>"
    },
    "dry_run": {
      "type": "boolean",
      "default": true,
      "description": "If true, validate and print plan without executing."
    }
  }
}
```

### `script.sh` template

```bash
#!/usr/bin/env bash
set -euo pipefail
export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"

python3 - <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["SHARED_DIR"])

def fail(reason, **extra):
    print(json.dumps({"ok": False, "reason": reason, **extra}, ensure_ascii=False))
    sys.exit(1)

args = json.loads(os.environ["STMC_ARGS_JSON"])

# TODO: implement
result = {"ok": True, "tool": "<tool_name>"}
print(json.dumps(result, ensure_ascii=False))
PY
```

---

## 13. When in doubt

- **Read a similar existing tool.** [submit_lsdyna_job](submit_lsdyna_job/1.0.0/) is a
  good full-featured reference (Slurm, sbatch, registry, dry_run pattern).
- **Don't invent new fields in `meta.yaml`.** If you really need one, update
  [spec.py](../src/smarttwin_mcp/spec.py) and this guide together in one PR.
- **Don't break the JSON stdout contract.** Everything downstream depends on it.
- **Keep `expose: catalog` unless you can defend a different choice in code review.**

---

## 14. GPU jobs (Slurm conventions)

LS-DYNA MPP in this catalog is CPU-only. GPU support here means **tools that submit
GPU jobs to Slurm** (PyTorch / JAX training, CUDA solvers, postprocessing on GPU
nodes, etc.). The conventions below are **for new tools** that target GPU
partitions. Do not retrofit existing CPU tools.

### 14.1 Required args for GPU-aware tools

If your tool can run on a GPU partition, accept these three args (others are
tool-specific):

```json
{
  "gpus": {
    "type": "integer",
    "minimum": 0,
    "maximum": 8,
    "default": 0,
    "description": "Number of GPUs to request. 0 = CPU-only (default). Must be >= 1 on a GPU partition."
  },
  "gpu_type": {
    "type": "string",
    "enum": ["a100", "h100", "rtx4090", "any"],
    "default": "any",
    "description": "GPU model selector. Maps to Slurm --gres=gpu:<type>:N. Use 'any' to skip the type filter."
  },
  "gpu_partition": {
    "type": "string",
    "enum": ["gpu-a100", "gpu-h100", "gpu-mixed"],
    "description": "Slurm partition. Required when gpus >= 1. Omit on CPU-only runs."
  }
}
```

Cross-validate in `script.sh`, not in JSON Schema (JSON Schema can't express
"`gpu_partition` required iff `gpus >= 1`"):

```python
gpus = int(args.get("gpus", 0))
if gpus >= 1 and not args.get("gpu_partition"):
    job_helpers.fail("gpu_partition is required when gpus >= 1", got=args)
if gpus == 0 and args.get("gpu_partition", "").startswith("gpu-"):
    job_helpers.fail("gpu_partition set but gpus=0 — pass gpus >= 1 or drop the partition", got=args)
```

**Two flavors of GPU-aware tool:**

- **Purpose-built GPU tool** (the common case — PyTorch training, CUDA solver,
  GPU postprocessing): the tool literally cannot run without a GPU. **Reject
  `gpus=0` outright** at the top of `script.sh` with `job_helpers.fail("this tool
  requires gpus >= 1; see §14.1", ...)`. Don't try to provide a CPU fallback.
- **Multipurpose tool** (rare — a generic launcher that runs the same script on
  CPU or GPU): accept `gpus=0` and fall back to a CPU partition. Document this
  fork in the tool's `description` so the LLM knows the dual mode exists.

Pick one mode; don't be silent. If you choose purpose-built, you can leave
`default: 0` in the schema (so calling with no args doesn't accidentally request
GPUs) and rely on the script's `fail()` to teach the user.

### 14.2 sbatch directives — the canonical GPU snippet

This snippet assumes you've already passed the §14.1 cross-validation and `gpus >= 1`
with a valid `gpu_partition`. Do not render these lines on the `gpus=0` path.

```bash
#SBATCH --partition={gpu_partition}
#SBATCH --gres=gpu:{gres_spec}              # gres_spec = "<gpu_type>:<N>" or "<N>" if gpu_type=="any"
#SBATCH --ntasks=1
#SBATCH --cpus-per-task={cpus_per_gpu_x_gpus}   # default: 8 * gpus
#SBATCH --mem={memory}                       # default: 32G * gpus
#SBATCH --time={time_limit}
```

Build `gres_spec` from `gpu_type` + `gpus`:

```python
gres_spec = f"{gpus}" if gpu_type == "any" else f"{gpu_type}:{gpus}"
```

**Defaults rule of thumb (override only if the user asks):**

| Resource per GPU         | Default       |
|--------------------------|---------------|
| `--cpus-per-task`        | 8             |
| `--mem`                  | 32G           |
| `--time`                 | 04:00:00      |

Multiply by `gpus` when building the sbatch script — the defaults above scale
linearly. Since §14.1 guarantees `gpus >= 1` on this code path, the multiplication
is always safe (no zero-cpu allocations). Print the resolved values in your tool's
JSON response so users see what was actually requested.

### 14.3 Environment variables inside the sbatch script

Inside the apptainer/singularity exec (or bare process) for GPU workloads:

```bash
--env NVIDIA_VISIBLE_DEVICES=all      # apptainer-side; Slurm sets CUDA_VISIBLE_DEVICES per allocation
--env CUDA_DEVICE_ORDER=PCI_BUS_ID
--nv                                   # apptainer flag — exposes nvidia-smi + libs into the container
```

For multi-GPU training, set:

```bash
--env NCCL_DEBUG=WARN
--env NCCL_SOCKET_IFNAME=^docker0,lo   # avoid loopback/docker bridges
```

Do **not** export `CUDA_VISIBLE_DEVICES` yourself — Slurm sets it correctly based
on `--gres`. Overriding it breaks multi-GPU scheduling.

### 14.4 Registry fields for GPU jobs

`registry.record_submission` doesn't have GPU-specific columns. Put the GPU spec
in the `extra` JSON blob so downstream tools (`job_status`, `job_logs`) can show
it:

```python
registry.record_submission(
    ...,
    extra={
        "gpus": gpus,
        "gpu_type": gpu_type,
        "gpu_partition": gpu_partition,
        # ...plus any tool-specific keys (framework, model name, dataset path...)
    },
)
```

Add tool-specific keys (framework, model name, dataset path, ...) only if a
downstream tool will actually read them. Don't speculatively stuff fields.

### 14.5 Anti-patterns specific to GPU tools

| Don't                                                  | Why                                                                 |
|--------------------------------------------------------|---------------------------------------------------------------------|
| Default `gpus: 1`                                      | Forces every caller into the GPU queue. CPU-only is safer default.  |
| Hard-code a specific GPU node (`#SBATCH --nodelist=`)  | Schedules around the partition; defeats Slurm's load balancing.     |
| `export CUDA_VISIBLE_DEVICES=0,1,2,3` in your script   | Overrides Slurm's per-task masking, breaks multi-job GPU isolation. |
| Skip `--gres=gpu:N` and rely on partition default      | Some partitions allow CPU-only jobs and won't allocate any GPU.     |
| Ignore `apptainer --nv`                                | Container can't see GPUs; CUDA init fails inside the image.         |

---

## 15. REST API tools (`transport: http`)

For tools that call an external HTTP API instead of running a script — e.g.
cluster control-plane endpoints, monitoring dashboards, third-party services.
The runner ([runner.py](../src/smarttwin_mcp/runner.py)) handles HTTP transport;
your `meta.yaml` is the entire contract.

### 15.1 When to use `http` vs `local` with `curl`

- **`transport: http`**: the request is fully described by URL + headers + JSON
  body. No domain logic needed before/after. Examples: GET `/health`, POST
  `/jobs/<id>/cancel`, simple webhook fires. Use this — it's declarative,
  testable, and the runner gives you env-var interpolation and timeouts for free.
- **`transport: local` calling `curl`**: needed when the request requires
  pre-processing (e.g. constructing the URL from a registry lookup), looping
  over a paginated API, OR post-processing the response into a registry row.
  In other words: when there's domain logic. Don't shoehorn complex flows into
  `body_template`.

If you find yourself wanting conditionals in `body_template`, switch to `local`.

### 15.2 `meta.yaml` for an HTTP tool

```yaml
name: get_cluster_health
version: 1.0.0
summary: Hit the SmartTwinCluster /health endpoint and return raw JSON.
description: |
  Returns the cluster control-plane health snapshot. No registry interaction.

  # When to call this
  - User asks "is the cluster up?", "how busy is the cluster?", or similar
  - Pre-flight before submitting a large batch
tags: [http, cluster, health, monitoring]
expose: catalog
transport:
  kind: http
  method: GET
  url: ${STMC_CLUSTER_URL}/v1/health
  headers:
    Authorization: "Bearer ${STMC_CLUSTER_TOKEN}"
    Accept: application/json
  timeout_sec: 15
examples:
  - title: simple check
    args: {}
```

This is a legitimate zero-arg tool — the §2.5 exception applies, one example is fine.

### 15.3 URL / header environment interpolation

`${VAR}` (and `${VAR:-default}`) inside `url`, `headers` values, and
`body_template` is substituted with the process environment at call time. **This
is the only safe way to inject secrets** — do not hard-code tokens in
`meta.yaml`, and do not pass them as args (args end up in tool logs and search
indices).

Required env conventions for this catalog:

| Env var               | Purpose                                                |
|-----------------------|--------------------------------------------------------|
| `STMC_CLUSTER_URL`    | Base URL of the SmartTwinCluster control plane.        |
| `STMC_CLUSTER_TOKEN`  | Bearer token. Required by any tool that hits the API.  |

If a required env var is missing at call time, the runner returns a `RunResult`
with `ok: false` and a `stderr` field like `"missing env vars: STMC_CLUSTER_TOKEN,
STMC_CLUSTER_URL"` (sorted, comma-joined), and the `command` field still shows the
literal `${VAR}` so it's obvious what was unresolved. No network request is fired.
**Do not** put fallback tokens in `meta.yaml`.

### 15.4 Body templating (`POST`/`PUT`/`PATCH`)

`body_template` is a Python `str.format_map` template over the args. Unknown
placeholders cause a clean error before any HTTP request fires.

```yaml
transport:
  kind: http
  method: POST
  url: ${STMC_CLUSTER_URL}/v1/jobs
  headers:
    Authorization: "Bearer ${STMC_CLUSTER_TOKEN}"
  body_template: |
    {"case_dir": "{case_dir}", "solver": "{solver}", "gpus": {gpus}}
  timeout_sec: 60
```

`Content-Type: application/json` is **auto-injected** by the runner whenever a body
is sent and the header isn't already set, so you don't need to list it explicitly.
The runner also auto-adds `Accept: application/json`. Override either by listing it
in `headers` if your endpoint is unusual.

For complex/conditional bodies, use `local` transport with a Python script
that builds the JSON, then POSTs via `urllib`/`curl`. See §15.1.

### 15.5 Response handling — what the LLM sees

The runner returns:

```json
{
  "tool": "get_cluster_health@1.0.0",
  "ok": true,
  "exit_code": 200,
  "stdout": "<raw response body>",
  "result": { ...parsed JSON if the response was JSON... },
  "transport": "http",
  "command": "GET https://...truncated..."
}
```

- `ok: true` iff HTTP status is in `[200, 300)`.
- `result` is populated only when the response body parses as JSON. Plain-text
  responses live in `stdout`.
- 4xx / 5xx surface as `ok: false` with `exit_code = status` and the response
  body in `stdout`. Do not retry from the LLM side; if you need retry, see §15.6.

### 15.6 Retries and timeouts

The runner does **not** retry by default. If your endpoint is flaky and you
want retries, encode them in a `local` script (urllib + simple backoff loop).
Pure HTTP transport stays declarative.

`timeout_sec` is per-request. Default is 120 seconds. Set lower (10-15s) for
health checks; higher (300s+) only when the API itself takes that long.

### 15.7 The `script.sh` placeholder for HTTP tools

The catalog still requires `script.sh` to exist (loader checks for the file).
Make it a no-op that prints an error if someone runs it directly:

```bash
#!/usr/bin/env bash
echo '{"ok": false, "reason": "this tool uses http transport, not script execution"}'
exit 1
```

`chmod +x` it like any other script.

### 15.8 HTTP anti-patterns

| Don't                                                | Why                                                              |
|------------------------------------------------------|------------------------------------------------------------------|
| Hard-code tokens in `meta.yaml`                      | meta files are committed to git. Use `${STMC_CLUSTER_TOKEN}`.    |
| Pass tokens as tool args                             | Args appear in logs and search hits. Use env interpolation.      |
| Use `http` for paginated APIs                        | No loop construct. Use `local` + `curl`/`urllib` for pagination. |
| Use `http` then re-parse the body in another tool    | The runner already parses JSON into `result`. Reuse it.          |
| Set `timeout_sec: 600` for a health check            | Health endpoints fail fast. 15s is plenty.                       |
