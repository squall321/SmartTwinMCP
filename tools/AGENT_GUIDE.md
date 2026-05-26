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

**Shortcut for steps 1-5:** `smarttwin-mcp lint tools/`. This runs the
automated subset of the checklist below (catalog load, name/version match,
schema validity, examples, exec bits, latest symlink, expose distribution,
mode tags, hard-coded secrets). CI gates PRs on it. **Step 6 (end-to-end
run) still requires you to actually execute the tool** — the lint can't
exercise transport-specific paths or domain logic.

Manual checklist (what `smarttwin-mcp lint` automates + what it doesn't):

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
#     If your tool calls registry.record_submission(), ALWAYS set STMC_JOBS_DB
#     to a tmpfile (§9.2) so verification rows don't leak into production.
#     Replace the JSON below with your tool's actual minimal valid args.
#     (Zero-arg tools: pass '{}'.)
STMC_JOBS_DB=/tmp/test_jobs.db \
STMC_ARGS_JSON='{"message": "smoke test", "count": 1}' \
bash tools/my_tool/1.0.0/script.sh | python3 -m json.tool
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
>
> **`bash script.sh` skips JSON Schema validation.** Running the script directly
> via `STMC_ARGS_JSON='...' bash script.sh` invokes your tool but does NOT
> validate the args against `args.schema.json` — only the MCP server path
> (`catalog_run` → `_validate_args`) does. If you need to verify that a bad-args
> call is rejected (e.g. testing `anyOf` enforcement, the `maxItems` cap on a
> list arg), use one of:
>
> - the in-memory `fastmcp.Client(server)` path from `tests/test_e2e_mcp_session.py`, or
> - call `jsonschema.validate(args, entry.args_schema)` directly in your verifier.
>
> Don't conclude "the schema works" from a `bash script.sh` test alone.

---

## 8. Naming, aliases, and uniqueness

- Tool names live in a flat global namespace. `tools/job_status/` is `job_status`, period.
- `aliases` in `meta.yaml` are alternative resolution keys for the **latest** version
  of a tool. They share the same global namespace as tool names. The loader
  records a `CatalogIssue` and DROPS the alias in either of these collision
  cases:
  - **alias vs alias** — two different tools claim the same alias.
  - **alias vs name** — an alias matches the primary name of another tool.
    The actual tool wins on `resolve()`; the alias is ignored. (Added 2026-05
    after a subagent test created `tools/my_jobs/` while
    `list_recent_jobs.aliases` already had `my_jobs` — both ended up live and
    the LLM had no signal they meant different things.)
- A version-qualified name like `job_status@1.0.0` is always resolvable, regardless of
  aliases or which version is `latest`.
- A `self-alias` (alias equal to the tool's own name) is a no-op, not an error.
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

**Test override:** if the `STMC_JOBS_DB` env var is set **at the moment `registry`
is first imported**, `registry.py` uses that path instead. Set the env var
BEFORE the `import registry` line in your verification script — if you set it
after, you'll silently hit production. **Use this in §7 step 6 verification**
to keep test runs out of the production registry:

```bash
STMC_JOBS_DB=/tmp/test_jobs.db STMC_ARGS_JSON='{...}' bash tools/my_tool/1.0.0/script.sh
```

Production callers must NOT set this. Don't reference `STMC_JOBS_DB` in any tool's
`meta.yaml` `description` or `args.schema.json` — it's a test seam, not a feature.

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

**Reconciling §14.2 and §16.2 when both apply** (multi-node + multi-GPU tools):

- §14.2's "8 cpus per GPU" rule is *per-task* in the multi-node world. With
  `ntasks_per_node = gpus_per_node` (the standard distributed-training topology
  of one rank per GPU), set `--cpus-per-task = 8` flat. Total CPUs allocated
  per node = `8 * gpus_per_node`, matching §14.2 in aggregate.
- §14.2's "32G per GPU" memory rule becomes `--mem-per-cpu = 4G` (since
  `32G / 8 cpus = 4G/cpu`). Don't use `--mem` on multi-node — §16.2 / §16.7.
- If your tool uses a non-standard topology (e.g. 4 ranks per GPU for data
  loaders), state the cpu/mem formula explicitly in `description` so the LLM
  doesn't have to guess.

### 14.3 Environment variables inside the sbatch script

Inside the apptainer/singularity exec (or bare process) for GPU workloads:

```bash
--env NVIDIA_VISIBLE_DEVICES=all      # apptainer-side; Slurm sets CUDA_VISIBLE_DEVICES per allocation
--env CUDA_DEVICE_ORDER=PCI_BUS_ID
--nv                                   # apptainer flag — exposes nvidia-smi + libs into the container
```

For multi-GPU training **on a single node**, set:

```bash
--env NCCL_DEBUG=WARN
--env NCCL_SOCKET_IFNAME=^docker0,lo   # avoid loopback/docker bridges
```

For multi-node multi-GPU training, **§16.4 supersedes this snippet** — it adds
`bond0` to the NIC exclusion list and turns on IB and async error handling. Use
§16.4's full set when `nodes >= 2`.

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

---

## 16. Multi-node MPI jobs (Slurm conventions)

Conventions for tools that submit MPI jobs spanning **more than one compute node**.
Single-node MPI (the `submit_lsdyna_job` case) uses `--ntasks=1 --cpus-per-task=N`
and doesn't need these — Slurm and the in-container MPI runtime handle everything.

Once you cross node boundaries, you're picking the topology, and Slurm needs you
to be explicit. The conventions below are *additive* on top of §14 (GPU); combining
multi-node and multi-GPU is the common case for distributed training.

### 16.1 Required args for multi-node tools

```json
{
  "nodes": {
    "type": "integer",
    "minimum": 1,
    "maximum": 64,
    "default": 1,
    "description": "Number of compute nodes. 1 = single-node (no MPI fabric setup). >= 2 enables the multi-node path."
  },
  "ntasks_per_node": {
    "type": "integer",
    "minimum": 1,
    "maximum": 128,
    "default": 1,
    "description": "MPI ranks per node. For pure MPI: cpus per node / cpus-per-task. For 1-rank-per-GPU training: equal to gpus per node."
  },
  "mpi_fabric": {
    "type": "string",
    "enum": ["auto", "ofi", "ucx", "tcp"],
    "default": "auto",
    "description": "MPI transport fabric. 'auto' = let the runtime pick (works for most jobs). Force tcp only as a fallback when the high-performance fabric misbehaves."
  }
}
```

Tools that are also GPU-aware (§14) add the three §14.1 args on top of these.
Tools that aren't GPU-aware (pure CPU MPI like LS-DYNA MPP across nodes) just
add the three above.

### 16.2 sbatch directives — the canonical multi-node snippet

```bash
#SBATCH --partition={partition}
#SBATCH --nodes={nodes}
#SBATCH --ntasks-per-node={ntasks_per_node}
#SBATCH --cpus-per-task={cpus_per_task}
#SBATCH --mem-per-cpu={mem_per_cpu}              # NOT --mem; on multi-node, use --mem-per-cpu
#SBATCH --time={time_limit}
#SBATCH --exclusive                              # Recommended: prevents other jobs sharing nodes
{gres_line}                                      # §14.2 --gres=gpu:... — only if GPU-aware
```

**`--mem` vs `--mem-per-cpu`:** on single-node jobs `--mem=32G` is fine. On
multi-node, `--mem=32G` means 32G *total across all nodes*, which is almost
never what you want. Use `--mem-per-cpu=4G` (or similar) so each rank gets a
sane allocation regardless of node count.

**`--exclusive`:** without it, Slurm can co-schedule other jobs onto your nodes
and starve MPI collectives. Multi-node MPI without `--exclusive` is a footgun.

**Total ranks** = `nodes * ntasks_per_node`. Always print this in your tool's JSON
response so users can sanity-check.

### 16.3 Launching the MPI program

Inside the sbatch script, use **`srun`**, not `mpirun`, when on Slurm. `srun`
inherits the allocation correctly; `mpirun` requires you to construct a hostfile
and pass `--map-by`/`--bind-to` flags that vary by MPI implementation.

```bash
srun --mpi=pmix \
  apptainer exec --bind /data:/data{gpu_nv_flag} \
    {sif_path} \
    /path/to/binary {args...}
```

- `--mpi=pmix` is the right default for modern OpenMPI / Intel MPI builds, and
  the only value §16 tools should hard-code. **Do not expose `--mpi=` as a tool
  arg** — the `mpi_fabric` arg (§16.1) covers the fabric, not the PMIx/PMI
  binding. If your cluster's Slurm is too old for pmix and you need
  `--mpi=openmpi` instead, file that as a separate tool variant
  (`submit_distributed_train_legacy_pmi`) rather than expanding `mpi_fabric`'s
  enum — keeping the standard tool predictable matters more than covering one
  legacy cluster.
- Don't write your own hostfile. Don't pass `-n {total_ranks}` to `mpirun` from
  inside an sbatch script — `srun` already knows.
- For GPU jobs, add the `--nv` flag (§14.3) and the env vars from §16.4.

### 16.4 MPI fabric environment vars

The exact env depends on `mpi_fabric`:

```bash
case "{mpi_fabric}" in
  ofi|auto)
    --env FI_PROVIDER=verbs,tcp
    --env I_MPI_FABRICS=ofi
    ;;
  ucx)
    --env UCX_TLS=rc,tcp
    --env I_MPI_FABRICS=ucx
    ;;
  tcp)
    --env FI_PROVIDER=tcp
    --env I_MPI_FABRICS=tcp
    --env OMPI_MCA_btl=tcp,self
    ;;
esac
```

For NCCL on multi-node GPU jobs (§14.3 has the single-node basics):

```bash
--env NCCL_SOCKET_IFNAME=^docker0,lo,bond0      # exclude bridges/bond
--env NCCL_IB_DISABLE=0                          # let NCCL use IB if available
--env NCCL_DEBUG=WARN                            # quiet unless something's wrong
--env NCCL_ASYNC_ERROR_HANDLING=1
```

Hard rule: **don't set `OMPI_MCA_orte_base_help_aggregate=0`** unless debugging.
It makes MPI dump per-rank errors and floods the log.

### 16.5 Registry fields for MPI jobs

Use `registry.extra` (no new columns). **The four keys below are mandatory** for
any §16 tool — downstream tools (`job_status`, `job_logs`, ...) inspect them to
render a proper multi-node view. This is stricter than §14.4 where GPU fields
are opt-in; here they're required because nothing else captures the topology.

```python
extra={
    "nodes": nodes,
    "ntasks_per_node": ntasks_per_node,
    "total_ranks": nodes * ntasks_per_node,
    "mpi_fabric": mpi_fabric,
    # ...plus §14.4 gpu fields if also GPU-aware (also required when GPU-aware)
}
```

### 16.6 Single-node fast path

When `nodes == 1`, **skip** `--exclusive`, `--mem-per-cpu`, the `srun --mpi=pmix`
launcher, and the fabric env vars. Use the single-node pattern from §14.2 / the
existing `submit_lsdyna_job`. Mixing multi-node directives onto a single-node
allocation works on most clusters but wastes scheduling priority — and tells the
scheduler your job is much bigger than it is.

Branch in `script.sh`:

```python
nodes = int(args.get("nodes", 1))
if nodes == 1:
    # Use the §14 single-node sbatch template.
    sbatch_text = SINGLE_NODE_TEMPLATE.format(...)
else:
    # Use the §16.2 multi-node template + §16.4 fabric env.
    sbatch_text = MULTINODE_TEMPLATE.format(...)
```

### 16.7 MPI anti-patterns

| Don't                                                       | Why                                                             |
|-------------------------------------------------------------|-----------------------------------------------------------------|
| Use `--mem=...` on multi-node                               | That's the TOTAL across all nodes. Use `--mem-per-cpu` instead. |
| Skip `--exclusive` on multi-node                            | Co-scheduled jobs starve MPI collectives. Always set it.        |
| `mpirun -n {ranks}` from inside sbatch                      | Use `srun`. It already knows the allocation.                    |
| Write your own hostfile                                     | Slurm + srun does this. Custom hostfiles drift on node changes. |
| Force `mpi_fabric: tcp` as default                          | Loses 10-100x performance vs verbs/UCX. Use 'auto' default.     |
| Set NCCL/MPI env on the single-node path                    | Pointless overhead and confusing logs. Branch on `nodes`.       |
| Hard-code `--ntasks-per-node=N` to match GPU count silently | Make the relationship explicit: state it in the description.    |

---

## 17. Inbound webhooks (sidecar pattern)

> **Architecture constraint, read this before designing.** This MCP server is
> **outbound only** — `transport: http` (§15) makes calls *out* to remote APIs.
> Receiving HTTP requests *into* the catalog (webhooks, callbacks, push events)
> requires infrastructure outside this repo. **The webhook-receiving tools in
> this catalog do not listen on a port.** They poll a queue that a separate
> sidecar service writes to.

### 17.1 The sidecar contract (what lives outside this repo)

A separate service — a small Flask/FastAPI app, an Nginx + Lua hook, an SQS
consumer, whatever fits — is configured to accept POSTs at e.g.
`https://stmc-hooks.internal/inbound/<source>` and write each received payload
as a row in a SQLite table. This is the "sidecar". **This repo does not contain
the sidecar.** Deployment is out of scope here.

Schema the sidecar MUST write (so the MCP-side tools can read it without
coordination):

```sql
CREATE TABLE inbound_webhooks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    received_at INTEGER NOT NULL,        -- unix epoch seconds
    source TEXT NOT NULL,                -- e.g. "github", "slurm-callback", "vendor-x"
    event_type TEXT,                     -- e.g. "job.completed", "push" — source-specific
    headers TEXT,                        -- JSON blob of relevant request headers
    payload TEXT NOT NULL,               -- raw request body (usually JSON)
    signature_verified INTEGER,          -- 1 if HMAC checked OK, 0 if not, NULL if N/A
    ack_status TEXT DEFAULT 'pending',   -- pending | acked | error
    ack_at INTEGER,                      -- when an MCP tool consumed it
    ack_note TEXT
);
CREATE INDEX IF NOT EXISTS idx_inbound_received ON inbound_webhooks(received_at DESC);
CREATE INDEX IF NOT EXISTS idx_inbound_source ON inbound_webhooks(source, ack_status);
```

Path convention: `/data/SmartTwinMCP/inbound_webhooks.db` (parallel to the job
registry's `jobs.db`). Same WAL settings.

**Test override (mirroring §9.2's `STMC_JOBS_DB`):** every §17 tool MUST honor
`STMC_WEBHOOK_DB` at import time and prefer it over the production path when
set. Use it in §7 step 6 to verify the tool against a tmpfile DB. Like
`STMC_JOBS_DB`, this is a test seam — don't expose it in `meta.yaml` or args.

```python
DB_PATH = os.environ.get("STMC_WEBHOOK_DB") or "/data/SmartTwinMCP/inbound_webhooks.db"
```

The sidecar's responsibilities (NOT this repo's):

- TLS termination
- HMAC signature verification (writes the result into `signature_verified`)
- Idempotency / dedup on `(source, headers[Idempotency-Key])`
- Rate limiting
- Persisting the row

**MCP tools in this repo only consume the table.** If you find yourself wanting
to receive HTTP in a `script.sh`, stop — you're rebuilding the sidecar in the
wrong layer.

### 17.2 The MCP tools you can author against this table

Standard set (write each as a separate tool; `expose: catalog`):

- `list_inbound_webhooks` — page through the queue, filter by `source`, `event_type`,
  `ack_status`, `since`. Returns row dicts with the payload **already JSON-parsed**.
- `get_inbound_webhook` — fetch one row by `id`.
- `ack_inbound_webhook` — mark a row `acked` (or `error`, with a note). Used after
  the LLM has acted on the event. Idempotent.
- `peek_inbound_webhook` — peek at the next pending row without acking. **FIFO:
  smallest `id` first** (the queue is a queue, not a stack). Optional filters
  may narrow `source` / `event_type`. If nothing matches, return
  `{ok: true, webhook: null, reason: "no pending webhooks"}` — an empty queue
  is not a failure.

Don't go beyond this set unless you have a concrete need. The queue is dumb on
purpose.

### 17.3 Args / behavior conventions

For `list_inbound_webhooks`:

```json
{
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "source": { "type": "string", "description": "Filter by source (e.g. 'github')." },
    "event_type": { "type": "string", "description": "Filter by event_type." },
    "ack_status": { "type": "string", "enum": ["pending", "acked", "error"], "default": "pending" },
    "since": { "type": "integer", "minimum": 0, "description": "Unix epoch. Filter received_at >= since." },
    "limit": { "type": "integer", "minimum": 1, "maximum": 500, "default": 50 }
  }
}
```

For `ack_inbound_webhook`:

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["webhook_id", "outcome"],
  "properties": {
    "webhook_id": { "type": "integer", "minimum": 1 },
    "outcome": { "type": "string", "enum": ["acked", "error"] },
    "note": { "type": "string", "description": "Optional human-readable explanation." }
  }
}
```

All webhook tools follow the standard envelope from §4.3 — always include `ok`
and `tool` at the top level of the response. See §17.5 for the per-tool shape.

### 17.4 Authoring `script.sh` for webhook tools

These tools are pure local SQLite reads/writes. **Don't import `_shared/registry.py`**
— it points at `jobs.db`, different schema, different lifecycle. Open the
webhook DB directly. `job_helpers.fail` IS fine to import (it's just a JSON
envelope helper, DB-agnostic); equivalently you can define a local `fail` to
keep webhook tools fully independent of `_shared/`. Pick one style per tool;
don't mix.

```python
import json, os, sqlite3, sys

DB_PATH = os.environ.get("STMC_WEBHOOK_DB") or "/data/SmartTwinMCP/inbound_webhooks.db"

def fail(reason, **extra):
    print(json.dumps({"ok": False, "reason": reason, **extra}, ensure_ascii=False))
    sys.exit(1)

if not os.path.exists(DB_PATH):
    fail("inbound webhook DB missing — sidecar not deployed or wrong host",
         expected_at=DB_PATH)

con = sqlite3.connect(DB_PATH)
con.row_factory = sqlite3.Row
# ... query / mutate ...
```

JSON-decode the `payload` and `headers` columns before returning rows:

```python
def row_to_dict(r):
    d = dict(r)
    for k in ("payload", "headers"):
        if d.get(k):
            try: d[k] = json.loads(d[k])
            except json.JSONDecodeError: pass
    return d
```

### 17.5 Response shape

Always include `webhook_id` (the row id) in any response that references a row.
Downstream tools will use it to `ack_inbound_webhook`.

`list_inbound_webhooks` returns:

```json
{
  "ok": true,
  "tool": "list_inbound_webhooks",
  "count": 3,
  "webhooks": [
    {
      "webhook_id": 17,
      "received_at": 1716_500_000,
      "source": "github",
      "event_type": "push",
      "signature_verified": 1,
      "ack_status": "pending",
      "payload": { "...parsed JSON..." }
    },
    ...
  ]
}
```

`ack_inbound_webhook` returns:

```json
{
  "ok": true,
  "tool": "ack_inbound_webhook",
  "webhook_id": 17,
  "previous_ack_status": "pending",
  "ack_status": "acked",
  "idempotent": false
}
```

**Idempotency rules for `ack_inbound_webhook`:**

- Calling with the SAME `outcome` and NO new `note` on an already-acked row →
  `idempotent: true`, no DB write, `previous_ack_status == ack_status` (both
  equal the current stored value).
- Calling with the SAME `outcome` and a NEW `note` → writes the note (only),
  returns `idempotent: false`, `previous_ack_status == ack_status`.
- Calling with a DIFFERENT `outcome` on an already-acked row → writes both,
  returns `idempotent: false`, `previous_ack_status` reflects the prior value.
- Calling on a nonexistent `webhook_id` → hard `fail()`, not idempotent.

### 17.6 Webhook anti-patterns

| Don't                                                  | Why                                                              |
|--------------------------------------------------------|------------------------------------------------------------------|
| Try to receive HTTP in a `script.sh`                   | This server is outbound only. Build a sidecar (§17.1).           |
| Verify HMAC signatures inside the MCP tool             | The sidecar already did it. Read `signature_verified`.           |
| Auto-ack on list/peek                                  | Caller must explicitly `ack_inbound_webhook` after acting.       |
| Reuse `_shared/registry.py` for webhook rows           | Different DB and schema. Open `inbound_webhooks.db` directly.    |
| Return raw `payload` as a string                       | JSON-decode it. The LLM shouldn't re-parse stdout JSON-in-JSON.  |
| Block on a long `since` window with no limit           | Use the `limit` arg. The queue can grow unbounded.               |

---

## 18. Multi-tenant isolation

The job registry has a `user` column (`registry.record_submission` auto-fills it
with `$USER`/`$LOGNAME`). Most existing query tools ignore it. **Any new query,
status, or mutation tool that the LLM might dispatch on a shared host MUST honor
the calling user's identity** — otherwise user A's prompt can read or cancel
user B's jobs.

### 18.1 The contract

Caller's identity is **always** `$USER` in the script's process environment.
Do not accept `user` as a JSON arg — that would let the LLM impersonate. Do not
read `$LOGNAME` as a fallback unless `$USER` is unset (very rare).

```python
caller = os.environ.get("USER") or os.environ.get("LOGNAME")
if not caller:
    job_helpers.fail("cannot determine caller identity (USER/LOGNAME unset)")
```

### 18.2 Three isolation modes — pick one in `meta.yaml.description`

Document which mode your tool uses, near the top of the description, so the LLM
and reviewers see it immediately. **In addition, declare the mode as a tag** so
catalog audits can grep for it without reading prose:

```yaml
tags: [job, query, mode-own]     # one of: mode-own, mode-own-shared, mode-read-all
description: |
  **Isolation mode: own.** Only returns rows where `user == $USER`.
  (rest of description...)
```

The `mode-*` tag is the machine-checkable signal. The description sentence
is what the LLM reads.

- **`mode: own`** — operate only on rows where `user == caller`. **Default for
  any tool that mutates** (`job_stop`, `job_rerun`, `ack_inbound_webhook`).
  Reject foreign rows with a hard `fail()` that says so explicitly.
- **`mode: own+shared`** — operate on rows where `user == caller` OR
  `extra` JSON has `"shared_with": [..., caller, ...]`. For tools that
  legitimately need a hand-off mechanism. Sharing is opt-in via the submitting
  tool, never automatic.
- **`mode: read-all`** — read everything across users. **Only for purely
  diagnostic / observability tools** (`list_recent_jobs` for an ops dashboard,
  `sinfo`-style cluster status). Must NOT mutate. Each row in the response
  MUST include the owner `user` so the LLM doesn't accidentally act on it.

### 18.3 Filter pattern (`mode: own`)

```python
rows = registry.list_recent(limit=args.get("limit", 50), user=caller)
# registry.list_recent's `user` filter is already there — use it, don't fetch
# all rows and post-filter in Python.
```

For a single-row lookup, check ownership after resolve:

```python
job = job_helpers.resolve_job(args)
if not job:
    job_helpers.fail("job not found", lookup=args)
if job.get("user") != caller and mode != "read-all":
    job_helpers.fail(
        "permission denied: job belongs to another user",
        job_owner=job.get("user"),
        caller=caller,
    )
```

### 18.4 Args convention

`mode: read-all` tools may accept an `owner` filter to narrow the view:

```json
{
  "owner": {
    "type": "string",
    "description": "Filter results to a specific OS user. Omit to see all users.",
    "pattern": "^[a-zA-Z_][a-zA-Z0-9_-]*$"
  }
}
```

`mode: own` and `mode: own+shared` tools **must not** expose any `owner`,
`user`, or `as_user` arg — identity is from the environment, period.

### 18.5 Response shape

Every row returned (in any mode) MUST include the `user` field. Specifically:

- `list_recent_jobs` and similar: `user` on each row.
- `job_status`, `job_logs`, `get_job_details`: `owner: <user>` at the top level.

This makes the multi-user view obvious to the LLM without it having to dig.

**Auto-satisfied by `_shared/registry.py`:** `registry.list_recent(...)` and
`registry.get_by_id(...)` already return the `user` column populated. If you
build response rows from those helpers and don't strip fields, the §18.5 rule
is met for free. The defensive `setdefault("user", None)` you sometimes see
is belt-and-suspenders, not required.

### 18.6 Anti-patterns

| Don't                                              | Why                                                                 |
|----------------------------------------------------|---------------------------------------------------------------------|
| Accept `user` as a JSON arg                        | LLM can impersonate. Identity is `$USER` only.                      |
| Use `mode: read-all` for any tool that writes      | A read-everything mutation tool is just a privilege-escalation bug. |
| Forget to surface `owner` on response rows         | LLM can't tell whose job is whose, will pick wrong one.             |
| Default to `read-all` instead of `own`             | "Show me my jobs" is the common case. Foreign-row access opt-in.    |
| Filter in Python after `list_recent(limit=500)`    | Use `registry.list_recent(user=caller)` — it filters in SQL.        |

---

## 19. Long-running job progress (deriving %)

`job_status` (the existing tool) returns `squeue` state per Slurm job and the
KooChainRun status blob. Neither directly answers **"how far along is this run?"**
A separate `job_progress` tool can derive a percentage from the on-disk output
the runner produces, without polluting `job_status`'s contract.

### 19.1 What the progress signal is

For LS-DYNA / KooChainRun runs (the common case in this catalog), progress comes
from one of three signals — pick the most reliable available:

1. **KooChainRun status JSON.** Run `KooChainRun status <runner_config>` and
   parse its `progress` field if present. This is the canonical source.
2. **Completed angle / case directories.** A multi-angle run writes one subdir
   per completed angle under `output_dir`. Count `output_dir/angle_*/d3plot`
   vs the registered `num_angles`. Ratio = progress.
3. **`d3hsp` / `mes0000` parsing.** If neither above works, parse the
   LS-DYNA `mes0000` file for `current_time` lines and compare against the
   scenario's `t_final_s`. Fragile — use only as last resort.

**`completed == 0` is NOT a valid `completed_angles` signal.** When the angle
counter is exactly zero, fall through to the queued/no-signal path instead of
reporting `progress_pct: 0.0` with `signal_used: "completed_angles"` — the
two cases are semantically different (queued vs running-but-no-output-yet) and
the LLM should see that distinction. Same for signal 1: if KooChainRun returns
a malformed or absent `progress` value, fall through; don't report 0.

**KooChainRun status JSON shape varies.** Walk the response recursively for a
numeric `progress` field. Normalize both 0..1 and 0..100 ranges to 0..100
(`val > 1 → val`, else `val * 100`). Don't assume a fixed envelope path —
KooChainRun versions differ.

### 19.2 Mandatory args

```json
{
  "type": "object",
  "additionalProperties": false,
  "oneOf": [{"required": ["registry_id"]}, {"required": ["work_dir"]}],
  "properties": {
    "registry_id": { "type": "integer", "minimum": 1 },
    "work_dir": { "type": "string", "pattern": "^/.+" }
  }
}
```

Same lookup pattern as §3.4. Multi-tenant: `mode: own` per §18.2.

### 19.3 Response shape

```json
{
  "ok": true,
  "tool": "job_progress",
  "registry_id": 42,
  "owner": "alice",
  "progress_pct": 67.3,
  "signal_used": "completed_angles",
  "detail": {
    "completed": 109,
    "total": 162,
    "latest_completed_at": 1716_400_000
  },
  "elapsed_sec": 4320,
  "eta_sec": 2100,
  "eta_confidence": "medium"
}
```

Rules:

- `progress_pct` is a float in `[0.0, 100.0]`, OR `null` (queued / no signal).
- `signal_used` is one of `"koochainrun_status"`, `"completed_angles"`,
  `"mes_time"`, or **`null`** when no signal was used (queued / unavailable).
  Lets the LLM judge how trustworthy the value is.
- `eta_sec` is **optional**. Only set when you can actually estimate it
  (e.g. completed/total + elapsed). Set `eta_confidence` to
  `low|medium|high|null` to reflect the variance. **Don't fabricate ETAs.**

  Recommended confidence tiers based on signal sample size:

  | completed angles | `eta_confidence` |
  |------------------|------------------|
  | >= 20            | `high`           |
  | 5..19            | `medium`         |
  | 1..4             | `low`            |
  | 0                | `null` (no ETA)  |

  Other signals (koochainrun_status, mes_time) get `low` by default unless the
  source explicitly reports a confidence.
- If you can't compute progress at all (no signal available), return
  `progress_pct: null` with a `reason` field rather than guessing zero.
  Same for the queued case: `progress_pct: 0` IS acceptable when you can
  positively detect "Slurm has accepted it but no output yet" — pair with
  `signal_used: null, reason: "queued"`.

### 19.4 Anti-patterns

| Don't                                                  | Why                                                              |
|--------------------------------------------------------|------------------------------------------------------------------|
| Return `progress_pct: 0` when no signal is available   | Misleads the LLM into thinking the job is stuck. Use `null`.     |
| Derive ETA from `current_time / t_final` alone         | LS-DYNA wall-clock per sim-second varies 100×. Use angle counts. |
| Re-run `KooChainRun status` after `job_status` did     | Two invocations per LLM turn. Cache the first.                   |
| Fail on missing `output_dir`                           | Job may be queued — return `progress_pct: 0` + reason "queued".  |

---

## 20. Batch cancel by filter

`job_stop` cancels one job. **`batch_cancel_jobs`** cancels many by filter — but
this is dangerous and needs guardrails. The default behavior MUST be `dry_run`.

### 20.1 Mandatory `dry_run` default

```json
{
  "dry_run": {
    "type": "boolean",
    "default": true,
    "description": "If true (default), list the jobs that WOULD be cancelled but cancel nothing."
  }
}
```

`dry_run: false` actually cancels. Any LLM that wants to cancel without
review must explicitly set this. Don't make it easy.

### 20.2 Required filter — at least one MUST be set

`additionalProperties: false` plus `anyOf` to force at least one filter:

```json
{
  "anyOf": [
    {"required": ["status"]},
    {"required": ["tool_name"]},
    {"required": ["project_like"]},
    {"required": ["submitted_before"]},
    {"required": ["registry_ids"]}
  ],
  "properties": {
    "status": { "type": "string", "enum": ["submitted", "running", "pending"] },
    "tool_name": { "type": "string" },
    "project_like": { "type": "string", "description": "SQL LIKE pattern, e.g. 'doe_%'" },
    "submitted_before": { "type": "integer", "description": "Unix epoch. Cancel jobs submitted before this time." },
    "registry_ids": { "type": "array", "items": {"type": "integer"}, "maxItems": 500 },
    "dry_run": { "type": "boolean", "default": true }
  }
}
```

**Calling with `{}` MUST be rejected by the schema** — `anyOf` does that. A
"cancel everything" call requires explicit `{status: "running"}` or similar.

**Why `dry_run` is NOT in the `anyOf`:** if it were, calling with just
`{dry_run: true}` would satisfy the "at least one filter" requirement without
actually picking any filter, defeating the guard. Keep `dry_run` in
`properties` only — it gates side effects but never counts as a filter.

### 20.3 Multi-tenant rule

Always `mode: own` (§18.2). **A batch cancel that touches another user's jobs
is a security issue, full stop.** Filter SQL by `user = caller` before applying
any other filter.

### 20.4 Result limit

Hard cap the number of jobs you'll act on in a single call:

```python
MAX_BATCH = 100

candidates = registry.list_recent(limit=MAX_BATCH + 1, user=caller, ...filters)
if len(candidates) > MAX_BATCH:
    job_helpers.fail(
        f"batch too large: {len(candidates)} > {MAX_BATCH}. "
        f"Narrow your filter (e.g. submitted_before) or chunk the request.",
        candidates=len(candidates),
    )
```

**Helper coverage caveat.** `registry.list_recent` supports SQL-side filters
for `status`, `tool_name`, `project_like`, `user`, and `since` (>= epoch),
but **not `submitted_before` (<= epoch)**. For that path, fetch a wider
candidate set with the OTHER filters applied and post-filter in Python:

```python
if "submitted_before" in args:
    raw = registry.list_recent(
        limit=MAX_BATCH * 5 + 1,       # wider net to make the cap meaningful
        user=caller, status=args.get("status"), tool=args.get("tool_name"),
        project_like=args.get("project_like"),
    )
    candidates = [r for r in raw if r["submitted_at"] < args["submitted_before"]]
    if len(candidates) > MAX_BATCH:
        job_helpers.fail("batch too large", candidates=len(candidates))
```

The `registry_ids` path uses `registry.get_by_id` per id (no `list_recent`),
so apply ownership check explicitly: `if row["user"] != caller: skip`.
That's NOT the §18.3 anti-pattern — that anti-pattern is about Python
post-filtering a `list_recent` dump for a query that has a SQL form. Per-id
lookups have no SQL form for ownership, so per-row check is required.

### 20.5 Response shape

```json
{
  "ok": true,
  "tool": "batch_cancel_jobs",
  "dry_run": true,
  "would_cancel": [
    {"registry_id": 17, "tool_name": "submit_lsdyna_job", "slurm_job_ids": ["12345"]},
    {"registry_id": 18, "tool_name": "submit_lsdyna_job", "slurm_job_ids": ["12346"]}
  ],
  "cancelled": [],
  "failures": [],
  "summary": {
    "matched": 2,
    "cancelled": 0,
    "failed": 0,
    "skipped_not_owner": 0
  }
}
```

When `dry_run: false`, populate `cancelled` and `failures`. `would_cancel` stays
empty. Always include `summary` for the LLM to render to the user.

**`skipped_not_owner` semantics:** this counter is only meaningful on the
`registry_ids` path, where the caller explicitly named rows and some may
belong to other users. On the SQL-filter paths (`status`, `tool_name`,
`project_like`, `submitted_before`) the `user = caller` clause already filters
foreign rows at the database layer, so `skipped_not_owner` is always 0 there.
Emit it as 0 anyway for response-shape consistency — don't omit the key.

### 20.6 Anti-patterns

| Don't                                                   | Why                                                              |
|---------------------------------------------------------|------------------------------------------------------------------|
| `dry_run: false` as the default                         | One misfired tool call cancels everyone's work.                  |
| Accept `{}` as "cancel everything"                      | Hostile to weak LLMs. Schema must reject. Use `anyOf`.           |
| Skip `mode: own`                                        | Other users' jobs get nuked. Multi-tenant violation per §18.     |
| No `MAX_BATCH` cap                                      | A bad filter hits 10k jobs and DOS's the scheduler.              |
| Hide partial failures inside `ok: true`                 | Surface them in `failures` so the LLM can react.                 |

---

## 21. Slurm topology / partition status

Read-only tools that wrap `sinfo`, `scontrol show node`, `scontrol show
partition`. Pre-flight check tools — the LLM calls them before `submit_*` to
make sure the chosen partition has live nodes with the requested resources.

### 21.1 Tools in this category

- `list_slurm_partitions` — `sinfo --format=...` summary per partition. Returns
  partition name, state, total/idle/down nodes, default time limit.
- `show_slurm_node` — `scontrol show node <name>` for one node. Returns
  state, allocated/free CPUs/GPUs, current jobs.
- `check_partition_capacity` — given `partition` + `gpus` + `nodes`, return
  whether the requested resources are currently available. Used by submit
  tools as a pre-flight.

**All three are `mode: read-all` per §18.2 — they're observability.** No
mutation, no user filtering.

### 21.2 The Slurm command wrapper pattern

Slurm output is **whitespace-delimited columnar text**, NOT JSON. The wrapper
must format it before returning:

```python
import subprocess, json, os, sys

def run_slurm(*args, timeout=15):
    try:
        r = subprocess.run(list(args), capture_output=True, text=True,
                           timeout=timeout, check=False)
    except FileNotFoundError:
        job_helpers.fail(f"{args[0]} not on PATH — Slurm client not installed?")
    except subprocess.TimeoutExpired:
        job_helpers.fail(f"{args[0]} timed out after {timeout}s")
    if r.returncode != 0:
        job_helpers.fail(f"{args[0]} failed", rc=r.returncode, stderr=r.stderr[-500:])
    return r.stdout
```

Use **`sinfo --format=...`** with explicit columns rather than the default — the
default format is meant for human eyes and varies between Slurm versions.

Two modes you'll need.

**Partition aggregate** (`list_slurm_partitions`): one row per partition+state.

```python
fmt = "%P|%a|%l|%D|%T|%C|%G"   # partition|avail|timelimit|nodes|state|cpus|gres
out = run_slurm("sinfo", "-h", f"--format={fmt}")
```

**Per-node detail** (`check_partition_capacity`): one row per node. Pass `-N`
and a per-node format string, optionally with `-p <partition>` to scope:

```python
fmt = "%n|%T|%C|%G"            # node|state|cpus(alloc/idle/other/total)|gres
out = run_slurm("sinfo", "-N", "-h", "-p", partition, f"--format={fmt}")
```

**`scontrol show node <name>`** returns key=value text — parse it with a tiny
regex or a `dict(token.split("=", 1) for token in tokens)` over `re.split(r"\s+", ...)`.
Don't trust whitespace inside values.

**`scontrol`'s `Reason=...` field wraps onto continuation lines** that don't
contain `=`. A robust parser must treat any whitespace-stripped line without `=`
as a continuation of the previous value:

```python
fields = {}
last_key = None
for line in out.splitlines():
    for token in re.split(r"\s+", line.strip()):
        if not token:
            continue
        if "=" in token:
            k, v = token.split("=", 1)
            fields[k] = v
            last_key = k
        elif last_key:
            fields[last_key] = (fields[last_key] + " " + token).strip()
```

### 21.3 Response shape (`list_slurm_partitions`)

```json
{
  "ok": true,
  "tool": "list_slurm_partitions",
  "partitions": [
    {
      "name": "cpu",
      "state": "up",
      "default_time_limit": "1-00:00:00",
      "nodes_total": 32,
      "nodes_idle": 12,
      "nodes_mixed": 18,
      "nodes_allocated": 2,
      "nodes_down": 0,
      "gres_summary": null
    },
    {
      "name": "gpu-a100",
      "state": "up",
      "default_time_limit": "8:00:00",
      "nodes_total": 8,
      "nodes_idle": 1,
      "nodes_mixed": 5,
      "nodes_allocated": 2,
      "nodes_down": 0,
      "gres_summary": "gpu:a100:8"
    }
  ]
}
```

**Slurm state → bucket mapping** (use this exact table; don't invent your own):

| Slurm state                              | Bucket            |
|------------------------------------------|-------------------|
| `idle`                                   | `nodes_idle`      |
| `mixed`                                  | `nodes_mixed`     |
| `allocated`, `completing`                | `nodes_allocated` |
| everything else (see list below)         | `nodes_down`      |

"Everything else" covers: `down`, `drain`, `draining`, `drained`, `fail`,
`failing`, `maint`, `reserved`, `planned`, `power_down`, `unknown`, `future`,
and any state not in the rows above. Rationale: from the LLM's perspective
the only useful question is "can this node accept new work now" — anything
that isn't idle/mixed/allocated/completing answers no.

Strip trailing modifier characters (`*`, `~`, `#`, `%`, `$`, `@`) from the
state column before bucketing — Slurm appends them to indicate special
conditions (reboot pending, etc.) and they're orthogonal to the base state.

**Partition name's trailing `*`** in the `%P` column marks Slurm's default
partition. Strip it before reporting the name (`cpu*` → `cpu`); optionally
add a `is_default: true` field if you want to surface it.

**Multi-row `gres_summary`** — `sinfo` may produce several rows for one
partition (one per state group), each potentially with different GRES. In
practice they're identical; if they differ, take the first non-null/non-`"(null)"`
value seen for that partition and stop. If you want to surface heterogeneity,
add `gres_summary_others: [...]` rather than overloading the singular field.

For `check_partition_capacity`, include a clear verdict:

```json
{
  "ok": true,
  "tool": "check_partition_capacity",
  "request": {"partition": "gpu-a100", "gpus": 4, "nodes": 1},
  "available_now": true,
  "candidates": [{"node": "gpu03", "free_gpus": 4, "free_cpus": 32}],
  "queue_depth": 3,
  "hint": "1 node has the requested 4 GPUs free now. Expected start: immediate."
}
```

**Free-GPU accounting on `mixed` nodes.** `sinfo %G` reports TOTAL GRES per
node, not free. On a `mixed` node some GPUs are already allocated and `sinfo`
alone can't tell which. **The conservative default is `free_gpus = 0` on
mixed nodes** — i.e. only `idle` nodes count toward `candidates`. This
under-reports capacity but never misleads the LLM into submitting a job that
will queue when it expected to run.

If precision matters more than simplicity, drill into `scontrol show node
<name>` for each mixed candidate and parse `AllocTRES=gres/gpu=N` vs
`CfgTRES=gres/gpu=M`. That's one extra `scontrol` invocation per candidate
node; only do it if `idle`-only counting returns insufficient capacity AND
mixed nodes exist. Document whichever choice you made in the tool's response
(`"free_gpu_method": "conservative" | "scontrol_drilldown"`).

### 21.4 Caching

Slurm queries are cheap (single-digit ms) but can pile up. **Do not cache
inside the tool.** Each invocation re-runs `sinfo`. Caching is the MCP
client's job, not ours — we'd be lying about timeliness.

**`include_down: false` edge case.** "Drop partitions where all nodes are
down" means `nodes_total > 0 AND nodes_total == nodes_down`. An empty
partition (`nodes_total == 0`, which `sinfo` can produce for a partition
defined in `slurm.conf` but with no nodes assigned) is NOT "all down" —
it's empty. Keep it in the response with explicit zero counts; let the LLM
decide what to do.

### 21.5 Anti-patterns

| Don't                                                   | Why                                                              |
|---------------------------------------------------------|------------------------------------------------------------------|
| Parse `sinfo`'s default human format                    | Format changes between Slurm versions. Use `--format=...`.       |
| Hard-fail when one partition is `down`                  | Report the down state; LLM and user need to know.                |
| Mix `sinfo` and `squeue` into one tool                  | One concern per tool. Use `job_status` for squeue.               |
| Add `mode: own` here                                    | This category is observability across the whole cluster.         |
| Cache inside the tool                                   | LLM gets stale state. Let the client cache if it wants.          |

---

## 22. SSH remote execution

§6.2 documented `transport: ssh` years ago but no tool in this catalog uses it.
This section is the convention layer for tools whose `script.sh` runs on a
cluster head node instead of locally.

### 22.1 When to choose `transport: ssh` vs `local`

- **`transport: ssh`**: the tool's correctness depends on commands that ONLY
  exist on the cluster head node (`sbatch`, `squeue`, `scontrol`, site-local
  scripts in `/opt/site/bin/...`). Most existing tools in this catalog use
  `local` because the dev host happens to have Slurm CLI too — that's a
  coincidence, not a contract.
- **`transport: local` with `ssh` inside the script**: don't. If you find
  yourself writing `ssh head subprocess.run(...)` inside a local script, your
  transport choice is wrong. Switch to `transport: ssh`.

### 22.2 Self-containment rule

The runner pipes `script.sh` over `ssh host bash -s` (see [runner.py](../src/smarttwin_mcp/runner.py)).
**The script body executes on the REMOTE host. `_shared/` is not shipped.**
Anything you import from `_shared/` will fail with `ModuleNotFoundError` on
the remote.

Practical implications:

- Inline whatever helpers you need. A 20-line SQLite write or KooChainRun call
  inside `script.sh` is fine.
- Registry writes still must hit the production `jobs.db`. That DB lives on
  the same shared filesystem the cluster mounts — the script can write to it
  directly. Confirm the path is mounted on the remote: `[ -f /data/SmartTwinMCP/jobs.db ]`
  in your script, fail clearly if not.
- `STMC_JOBS_DB` test override still works — ssh transport forwards the env via
  the `env:` field in `meta.yaml`. Set it there for `transport: ssh` test runs.

### 22.3 Required `meta.yaml` fields

```yaml
transport:
  kind: ssh
  host: ${STMC_CLUSTER_HEAD}              # env-interpolated like §15.3
  user: ${STMC_CLUSTER_USER:-svc-stmc}    # default user if env unset
  key_path: ${STMC_SSH_KEY:-~/.ssh/id_ed25519}
  port: 22
  remote_cwd: /scratch/stmc-jobs          # optional but recommended
  env:
    PATH: /usr/local/slurm/bin:/usr/bin:/bin
    STMC_JOBS_DB: /data/SmartTwinMCP/jobs.db
  timeout_sec: 300
```

**Always use env interpolation for `host`/`user`/`key_path`** — hard-coding a
hostname in a committed `meta.yaml` locks the catalog to one site. The runner
returns a clean error before connecting if any required env is missing
(matches §15.3 semantics for HTTP).

### 22.4 Required env vars for SSH tools

| Env var               | Purpose                                            | Default if unset             |
|-----------------------|----------------------------------------------------|------------------------------|
| `STMC_CLUSTER_HEAD`   | Hostname/IP of the cluster head node.              | (required, no default)       |
| `STMC_CLUSTER_USER`   | Username to log in as.                             | `svc-stmc`                   |
| `STMC_SSH_KEY`        | Path to the private key. Must be 0600.             | `~/.ssh/id_ed25519`          |

Document these at the top of the tool's `description` so the LLM can tell the
user what to set up.

### 22.5 Connection failure shape

When ssh can't connect, the runner returns:

```json
{
  "ok": false,
  "transport": "ssh",
  "stderr": "ssh: connect to host ... port 22: Connection timed out",
  "command": "ssh -p 22 -i ... user@host ..."
}
```

Tools should NOT retry on connection failure — let the LLM and user decide. A
`fail()` inside the script body is for problems detected after ssh succeeded.

### 22.6 Idempotency under partial failure

SSH calls can hang up mid-execution (network blip, head reboot). Your script
must be re-runnable without making things worse:

- **Submission tools**: check the registry BEFORE submitting. The dedup key is
  the **most specific identifier of the input** — for an LS-DYNA raw tool that's
  `extra.k_file`, for a KooChainRun drop tool it's `work_dir` (one config per
  dir). Pick the key that uniquely identifies "this same submission" for your
  tool, document it in the tool's `description`, and if a matching row has
  `slurm_job_ids` set within the last 60 seconds, return the existing IDs with
  a `note: "duplicate submission suppressed"` rather than submitting twice.
- **Cancel/mutation tools**: same; if the target row is already in the desired
  state, return `idempotent: true` (mirrors the §17.5 ack pattern).

### 22.7 Anti-patterns

| Don't                                                   | Why                                                              |
|---------------------------------------------------------|------------------------------------------------------------------|
| Hard-code `host: head01.cluster.internal` in meta.yaml  | Site-locked. Use `${STMC_CLUSTER_HEAD}`.                         |
| `import registry` inside an ssh-transport script        | `_shared/` isn't on the remote. Inline the SQL.                  |
| Retry ssh connections inside the tool                   | Bad network is a user-visible problem. Let it surface.           |
| Mix `transport: local` + `ssh` subprocess inside script | Use `transport: ssh`. The runner handles it.                     |
| Forget to forward `STMC_JOBS_DB` via `env:`             | Test override won't reach the remote; you'll hit prod.           |
| Assume `/data/...` is mounted on the remote             | Probe it (`[ -d /data/SmartTwinMCP ]`) and fail cleanly if not.  |

---

## 23. Result collection / download

Tools that move job output back to the user's workstation (or to a known
shared location). Existing `job_collect` runs KooChainRun's collect step,
but there's no convention yet for "give me the d3plot for job 42 on my laptop".

### 23.1 The 3 destination modes

A result-fetching tool MUST declare one of:

- **`destination: local`** — the tool's caller is on the same filesystem as
  the cluster output. Just verify the file exists; return its absolute path.
  No data movement.
- **`destination: rsync`** — pull files to a target path the user specifies.
  Uses `rsync -av --partial --progress` over ssh. Default mode for "download
  this job's d3plot".
- **`destination: presigned_url`** — for very large files. Upload to a
  configured S3-compatible bucket, return a time-limited URL. **Sidecar
  required** (§17.1 pattern): bucket creds live outside the catalog.

### 23.2 Required args

```json
{
  "type": "object",
  "additionalProperties": false,
  "allOf": [
    { "oneOf": [{"required": ["registry_id"]}, {"required": ["work_dir"]}] },
    { "required": ["destination"] }
  ],
  "properties": {
    "registry_id": { "type": "integer", "minimum": 1 },
    "work_dir": { "type": "string", "pattern": "^/.+" },
    "files": {
      "type": "array",
      "items": { "type": "string" },
      "description": "Filename globs relative to output_dir. e.g. ['d3plot*', 'mes0000']. Default: ['d3plot*']."
    },
    "destination": { "type": "string", "enum": ["local", "rsync", "presigned_url"] },
    "rsync_target": {
      "type": "string",
      "description": "Required when destination=rsync. Absolute path on the caller's host or rsync URL like 'user@host:/path'."
    },
    "max_total_bytes": {
      "type": "integer", "minimum": 1, "maximum": 1099511627776,
      "default": 53687091200,
      "description": "Hard cap on total bytes transferred. Default 50GB. Fails before transfer if exceeded."
    }
  }
}
```

`destination` is required (the `allOf`/`required` pair above enforces this on
top of the lookup `oneOf`). `mode: own` per §18 (a fetch is a read, but it
exposes another user's data on disk — gate it).

### 23.3 The pre-transfer size check

**Source directory:** glob against `row["output_dir"]` if set, falling back to
`row["work_dir"]`. The two are equal for raw lsdyna runs but `output_dir` is
the right anchor for drop simulations (KooChainRun writes results into a
subdir).

Always size up the source before transferring. Either `subprocess + find` or
stdlib `glob` is fine — they produce equivalent file lists:

```python
import glob, os
src_root = row.get("output_dir") or row["work_dir"]
files = []
for pattern in args.get("files", ["d3plot*"]):
    files.extend(glob.glob(os.path.join(src_root, "**", pattern), recursive=True))
total = sum(os.path.getsize(f) for f in files)
if total > args["max_total_bytes"]:
    job_helpers.fail(
        f"transfer would exceed cap: {total} > {args['max_total_bytes']}. "
        f"Narrow `files` or raise max_total_bytes.",
        total=total, file_count=len(files),
    )
```

This catches `files: ["*"]` against a 500GB simulation directory BEFORE rsync
starts saturating the disk.

**`rsync_target` directory creation:** for local target paths (no `user@host:`
prefix), `mkdir -p` the target before invoking rsync. For remote targets,
leave creation to rsync's `--mkpath` flag or to the user (sshing in to create
the dir would be a transport mixup — keep this tool's transport `local` and
let rsync handle the network).

### 23.4 Response shape

```json
{
  "ok": true,
  "tool": "fetch_job_output",
  "registry_id": 42,
  "destination": "rsync",
  "rsync_target": "/home/alice/local_runs/case42",
  "files_transferred": 18,
  "bytes_transferred": 4823423109,
  "duration_sec": 38.2,
  "rsync_log_tail": "<last 20 lines of rsync output>"
}
```

For `destination: local`, return `paths: [...]` (absolute paths). Also include
`files_transferred` (= len(paths)) and `bytes_transferred` (= total size) so
the LLM doesn't have to re-stat; `rsync_log_tail` is omitted and
`duration_sec` is `0`. For `destination: presigned_url`, return
`urls: [{file, url, expires_at}, ...]`.

### 23.5 Anti-patterns

| Don't                                                  | Why                                                              |
|--------------------------------------------------------|------------------------------------------------------------------|
| Default `files: ["*"]`                                 | First `fetch_job_output` call copies the whole 500GB run.        |
| Skip the pre-transfer size check                       | rsync starts, fills the disk, fails halfway, leaves partial.     |
| Use scp instead of rsync                               | No `--partial`, no resume, no progress. rsync is the standard.   |
| Stream the rsync stdout into the JSON response         | Multi-MB string in stdout kills the MCP client. Return tail only.|
| Default `max_total_bytes` to "no cap"                  | Same as no size check. 50GB default is generous; raise on ask.   |
| Run `destination: rsync` synchronously from MCP        | Long calls block the LLM. For >5GB, prefer presigned_url.        |

---

## 24. MPI debugging (rank-aware log inspection)

`job_logs` (§existing) returns a flat tail of stdout/stderr. For multi-node MPI
runs (§16), the user usually wants **"what did rank 0 say"** or **"which rank
hit OOM"** — single-stream tail loses that. A separate `job_logs_mpi` tool
parses per-rank output and surfaces the structure.

### 24.1 Where rank-tagged output comes from

Three common shapes — your tool must detect which is in use:

1. **Per-rank file** (cleanest). The user's training script writes
   `<work_dir>/rank.<N>.log` per rank. Look for that pattern first.
2. **Prefixed lines in the unified slurm.out**. `srun --label` prefixes each
   line with `<rank>:`. Detect by sampling **the first 1000 non-empty lines**:
   if ≥80% start with `^\d+:`, treat as labeled. Cap the sample so huge
   unified logs don't slow down format detection.
3. **Unlabeled unified stream**. Fall back to grep-based rank inference: lines
   matching `\b(rank|RANK|MPI_RANK)[=: ]\s*(\d+)\b` carry their own rank tag,
   everything else is "rank unknown".

Pick the first available signal; don't try to merge formats.

### 24.2 Args

```json
{
  "type": "object",
  "additionalProperties": false,
  "oneOf": [{"required": ["registry_id"]}, {"required": ["work_dir"]}],
  "properties": {
    "registry_id": { "type": "integer", "minimum": 1 },
    "work_dir": { "type": "string", "pattern": "^/.+" },
    "ranks": {
      "type": "array", "items": {"type": "integer", "minimum": -1},
      "description": "Which ranks to return. Default: [0] + any rank with ERROR/Traceback. Use [-1] to mean 'all detected ranks' — the sentinel; must be the sole element when used."
    },
    "lines": { "type": "integer", "minimum": 1, "maximum": 5000, "default": 200 },
    "highlight": {
      "type": "string", "enum": ["errors", "ncc", "oom", "none"],
      "default": "errors",
      "description": "Filter to lines matching a class of issue. 'errors' = ERROR/Traceback/CUDA_ERROR; 'ncc' = NCCL warnings; 'oom' = OOM/CUDA out of memory."
    }
  }
}
```

`mode: own` per §18.

### 24.3 The "representative rank" heuristic

When `ranks` is unset (default), surface the most informative ranks:

1. Always rank 0 (the orchestrator).
2. Any rank whose tail matches the `highlight` regex (default: ERROR class).
   Iterate ranks ascending; for each NEW error signature seen, add the rank
   that owns it. Stop at 3 distinct signatures total. ("Max 3" means three
   signatures, not three ranks — if rank 5 and rank 9 both hit the same OOM
   message, only rank 5 is added; rank 9 isn't a representative for the same
   information.)
3. If nothing matched #2 and the job is running, just rank 0.

**When the caller passes explicit `ranks`**, the heuristic is skipped — the
explicit list is authoritative. `highlight` still acts as a filter on the
returned tails (lines that match get flagged; non-matching ranks are still
returned but with `matched_highlight: false`).

Mark each returned rank with `representative: true` and a short `because:`
explanation. The LLM uses these to phrase its report. Ranks the caller
explicitly listed get `representative: false, because: "explicit"`.

### 24.4 Response shape

```json
{
  "ok": true,
  "tool": "job_logs_mpi",
  "registry_id": 42,
  "owner": "alice",
  "total_ranks_detected": 16,
  "source_format": "per_rank_file",
  "ranks": [
    {
      "rank": 0,
      "representative": true,
      "because": "orchestrator",
      "log_path": "/data/work/rank.0.log",
      "tail": [ "..." ],
      "matched_highlight": false
    },
    {
      "rank": 7,
      "representative": true,
      "because": "first rank with CUDA out of memory",
      "log_path": "/data/work/rank.7.log",
      "tail": [ "..." ],
      "matched_highlight": true,
      "highlight_signature": "CUDA out of memory"
    }
  ]
}
```

**Always include `source_format`** so the LLM knows whether to trust per-rank
splits or treat output as best-effort inferred.

**Unknown-rank sentinel.** In `unlabeled` mode, lines that don't carry their
own `rank=N` tag are bucketed under the JSON-string `"unknown"` (NOT an
integer like `-1`). The entry uses `"rank": "unknown"`. Only emit this bucket
when the caller asks for it explicitly with `ranks: [-1]`, since unknown-rank
lines are usually low-signal.

**`highlight_signature` is lowercase.** The regex match is case-insensitive,
but the signature you store/compare must be normalized to lowercase
(`"cuda out of memory"`, not `"CUDA out of memory"`). Grouping in §24.3
step 2 depends on signatures being string-equal — without normalization,
"CUDA error" and "cuda error" produce two distinct representative ranks for
the same problem.

### 24.5 Anti-patterns

| Don't                                                  | Why                                                              |
|--------------------------------------------------------|------------------------------------------------------------------|
| Return all 16 ranks' tails by default                  | 16 × 200 lines × 100 chars = 320KB in one tool result.           |
| Merge labeled and unlabeled detection in one pass      | Heuristics interfere. Detect format first, then parse.           |
| Treat `srun` `<rank>:` prefix as the only valid signal | PyTorch DDP and torchrun write per-rank files. Check both.       |
| Default `highlight: "none"`                            | LLM gets indiscriminate tail. Errors-first is the useful default.|
| Re-tail the whole file every call                      | For long runs, use `tail -n` not Python `readlines()`.           |
| Forget `representative` markers                        | LLM can't tell which rank IDs were "picked"; will report all.    |

---

## 25. Audit log (LLM-driven decision history)

A reasonable LLM session does many things: search the catalog, run a few
read-only tools, then submit something big. **When the user revisits the
session three days later and asks "wait, what gpus did you use for that
sweep?" the answer must be reconstructible.** `registry.notes` is too freeform
for that; per-row `extra` is per-tool. This is the cross-tool decision log.

### 25.1 The audit table (third table in `/data/SmartTwinMCP/`)

```sql
CREATE TABLE audit_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    occurred_at INTEGER NOT NULL,        -- unix epoch seconds
    actor TEXT NOT NULL,                 -- $USER on the host (never an arg)
    tool TEXT NOT NULL,                  -- qualified name: "submit_job@1.0.0"
    action TEXT NOT NULL,                -- enum below
    target_kind TEXT,                    -- "job" | "webhook" | "partition" | null
    target_id TEXT,                      -- domain-specific identifier (string for portability)
    summary TEXT NOT NULL,               -- one-line human-readable
    detail TEXT                          -- JSON blob: args, response highlights
);
CREATE INDEX IF NOT EXISTS idx_audit_occurred ON audit_events(occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_actor ON audit_events(actor, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_action ON audit_events(action);
```

Path: `/data/SmartTwinMCP/audit.db`. Test override: `STMC_AUDIT_DB`
(mirrors §9.2). WAL mode like the others.

### 25.2 What goes in `action`

Limited vocabulary — keep it grep-able:

- `submit` — created a new job (any submit_* tool)
- `cancel` — cancelled one or more jobs
- `inspect` — read a job's status/logs/progress for the first time in this session
- `acknowledge` — ack'd a webhook
- `template_apply` — applied a §26 preset
- `cost_estimate` — generated a §28 estimate
- `config_toggle` — flipped a config flag (e.g. §27 `enable_scheduled_job`).
  Use this when the mutation is metadata-only, no compute job involved.

**Don't** invent new actions ad-hoc. Adding one is a guide-level change.

### 25.3 Who writes audit rows

NOT every tool. Writing audit on every read-only call (`list_*`, `get_*`)
floods the table for no value. Rule:

- **Mutation tools (submit, cancel, ack, apply) MUST write one row** per
  successful invocation. Failures don't get recorded (the caller will see
  the failure response).
- **Observability tools MUST NOT write rows**. Their information value is in
  the response itself.
- **Inspection tools (job_status, job_logs, job_progress) MAY write one row
  per session-distinct target_id**. Heuristic: write iff the target_id +
  actor + tool tuple hasn't appeared in the last 5 minutes. Skip if it has.

Lint rule **L070** enforces this — any tool that `_is_mutation_tool` flags
(name prefix matches submit/cancel/etc., OR has a `dry_run` arg) must call
`record_event(...)` somewhere in its `script.sh`. False positives are
suppressible per-tool with `--disable L070`, but the bar should be high.

### 25.3.1 Wiring recipe — `transport: local` tools

For local-transport scripts (the common case), add one block on the success
path right after the registry write:

```python
import sys, os
sys.path.insert(0, os.environ.get("SHARED_DIR") or "")  # already set by the boilerplate
import audit

actor = os.environ.get("USER") or os.environ.get("LOGNAME") or "unknown"
audit.record_event(
    actor=actor,
    tool="submit_lsdyna_job@1.0.0",       # qualified name, hard-code per script
    action="submit",                       # one of §25.2's vocabulary
    summary=f"submitted {k_file} ({ncpu}cpu/{memory}/{time_limit}) -> slurm {slurm_ids}",
    target_kind="job",
    target_id=str(reg_id),                 # registry_id, slurm_job_id, webhook_id, …
    detail={                                # 3-5 fields, NOT the full response
        "k_file": k_file, "ncpu": ncpu, "memory": memory,
        "slurm_job_ids": slurm_ids, "dry_run": dry_run,
    },
)
```

**Failure path stays silent.** Don't audit on `fail()` — the user already
sees the failure response. Auditing failures pollutes the table with noise.

**Adding audit to a tool that didn't import `_shared/` before.** Some
tools (especially zero-arg or webhook tools) historically had no
`SHARED_DIR` setup. Add both the bash boilerplate AND the python-side
`sys.path` insert at the top of the script:

```bash
#!/usr/bin/env bash
set -euo pipefail
export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"   # add this

python3 - <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["SHARED_DIR"])                       # add this
import audit                                                       # then this
# ... rest of the existing body ...
PY
```

### 25.3.2 SSH-transport tools: inline the SQL

Per §22.2, ssh-transport scripts execute on the REMOTE host and can't import
`_shared/audit.py`. Inline a minimal SQLite insert. Same DB path lives on the
shared filesystem the cluster mounts, so the audit row is visible to local
queries:

**Wrap the inline insert in a `def record_event(...)` helper** — otherwise
lint rule L070 (a static grep for `record_event(`) won't find the audit
call and will flag the tool as un-audited. The helper name is the contract
that links the gude-recommended pattern to the lint check:

```bash
# inside the remote-running script.sh body
python3 - <<'PY'
import json, os, sqlite3, time

def record_event(actor, tool, action, summary, *,
                 target_kind=None, target_id=None, detail=None):
    """Inline §25.3.2 audit writer for ssh-transport tools.
    Schema verbatim from §25.1 — do not drift."""
    db = os.environ.get("STMC_AUDIT_DB") or "/data/SmartTwinMCP/audit.db"
    con = sqlite3.connect(db)
    con.execute("""CREATE TABLE IF NOT EXISTS audit_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT, occurred_at INTEGER NOT NULL,
      actor TEXT NOT NULL, tool TEXT NOT NULL, action TEXT NOT NULL,
      target_kind TEXT, target_id TEXT, summary TEXT NOT NULL, detail TEXT)""")
    con.execute(
        "INSERT INTO audit_events (occurred_at, actor, tool, action, target_kind, target_id, summary, detail) VALUES (?,?,?,?,?,?,?,?)",
        (int(time.time()), actor, tool, action, target_kind, str(target_id) if target_id is not None else None,
         summary, json.dumps(detail) if detail else None),
    )
    con.commit()
    con.close()

# ... your normal script body that produces reg_id, summary_str, detail dict ...

record_event(
    actor=os.environ.get("USER", "unknown"),
    tool="submit_lsdyna_remote@1.1.0",
    action="submit",
    summary=summary_str,
    target_kind="job",
    target_id=reg_id,
    detail=detail,
)
PY
```

The schema must match §25.1 EXACTLY. The DDL above is the schema verbatim.
**Don't drift** — a remote-inlined schema that diverges silently breaks
local queries.

### 25.4 Required helper — `_shared/audit.py`

Add this module (it does not exist yet) so every audit-writing tool calls
the same path. Sketch:

```python
# tools/_shared/audit.py
import json, os, sqlite3, time
DB_PATH = os.environ.get("STMC_AUDIT_DB") or "/data/SmartTwinMCP/audit.db"

def record_event(
    actor: str, tool: str, action: str, summary: str,
    *, target_kind: str | None = None, target_id: str | None = None,
    detail: dict | None = None,
) -> int: ...

def list_events(
    limit: int = 50, since: int | None = None,
    actor: str | None = None, tool: str | None = None,
    action: str | None = None, target_id: str | None = None,
) -> list[dict]: ...

def session_seen(actor: str, tool: str, target_id: str, within_sec: int = 300) -> bool: ...
```

The first new audit-writing tool must add this file with stdlib-only deps.
Subsequent tools import it.

**Signature note:** `summary` is the 4th positional arg (after actor/tool/action).
Everything else is keyword-only (`target_kind`, `target_id`, `detail`). This
avoids the Python syntactic ambiguity of mixing default and non-default
positional args.

### 25.5 The MCP query tool

Add `list_audit_events` at the same time as the helper:

```json
{
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "limit": { "type": "integer", "minimum": 1, "maximum": 500, "default": 50 },
    "since": { "type": "integer", "description": "unix epoch; events where occurred_at >= since" },
    "actor": { "type": "string", "description": "Filter by OS user. Default: caller ($USER)." },
    "tool": { "type": "string", "description": "Filter by qualified tool name." },
    "action": { "type": "string", "enum": ["submit", "cancel", "inspect", "acknowledge", "template_apply", "cost_estimate", "config_toggle"] },
    "target_id": { "type": "string" }
  }
}
```

`mode: own` by default — actor filter overrideable but defaults to `$USER`.

**Reconciling with §18.4 (`mode: own` tools MUST NOT expose `owner`/`user`/`as_user`):**
audit query is the documented exception. Reading another user's audit trail is
benign (they can grep their own anyway). The §18.4 prohibition targets
**mutation** tools, where an `as_user` arg would enable impersonation. A query
filter is not impersonation. Lint rule L050 still expects `mode-own` tag here;
the override happens at the argument layer, not the catalog layer.

### 25.6 Response shape

```json
{
  "ok": true,
  "tool": "list_audit_events",
  "count": 3,
  "events": [
    {
      "id": 42,
      "occurred_at": 1716_600_000,
      "actor": "alice",
      "tool": "submit_lsdyna_job@1.0.0",
      "action": "submit",
      "target_kind": "job",
      "target_id": "stmc-7c3f81",
      "summary": "submitted /data/cases/A.k on partition cpu (8 cpu, 32G, 02:00:00)",
      "detail": { "k_file": "/data/cases/A.k", "ncpu": 8, "slurm_job_ids": ["12345"] }
    },
    ...
  ]
}
```

### 25.7 Anti-patterns

| Don't                                                  | Why                                                              |
|--------------------------------------------------------|------------------------------------------------------------------|
| Audit every read call                                  | Table fills with `inspect` noise. Use the 5-min dedup heuristic. |
| Skip audit on submit because "registry already has it" | Registry is what; audit is when+why+who. Different signal.       |
| Put the full response JSON in `detail`                 | Bloats the DB. Pick 3-5 fields the LLM will want to recall.      |
| Let the LLM set `actor`                                | Identity is `$USER`. Filter param is a query knob, not write.    |
| Reuse `registry.notes` for cross-tool history          | Tied to one row; lost when the job is purged.                    |

---

## 26. Templates / presets (named job configurations)

After a few rounds of LS-DYNA setup the user has half a dozen tier-1 / tier-2
parameter combos they reuse. Today those live in chat history or in the
user's head. **Templates make them first-class.** A preset is a named
dict-of-args that any submit_* tool can apply.

### 26.1 Storage

Templates live on disk, NOT in a database — they're meant to be diffable,
git-trackable, and shareable across users:

```text
/data/SmartTwinMCP/templates/
  <name>.yaml
```

Schema for each `.yaml`:

```yaml
name: tier1_gpu_pytorch_a100x4
description: Standard 4×A100 distributed PyTorch run (8h, NCCL on, conservative mem).
created_at: "2026-05-25T12:00:00Z"   # quoted — see "Serialization" below
created_by: alice
tags: [gpu, distributed, tier1]      # optional, free-form; used by list_templates filter
applies_to:                          # which tools accept this template
  - submit_distributed_train
  - train_pytorch_gpu
args:                                # raw arg map merged into the tool call
  gpus: 4
  gpu_type: a100
  gpu_partition: gpu-a100
  nodes: 1
  ntasks_per_node: 4
  time_limit: "08:00:00"
  mem_per_cpu: 4G
notes: |
  Validated against torchrun 2.3, NCCL 2.20.
```

Test override path: `STMC_TEMPLATES_DIR` (default
`/data/SmartTwinMCP/templates/`).

**Authoritative name:** the YAML `name:` field wins; the file stem is a
fallback for templates that omit `name:`. List/get tools should refuse
mismatches (warn or fail, your call — current impl: file stem fallback,
no warning).

**Serialization gotcha — quote ISO-8601 datetimes.** PyYAML `safe_load`
parses `2026-05-25T12:00:00Z` (unquoted) into a Python `datetime`, which
`json.dumps` then refuses with `TypeError`. **Always quote ISO timestamps**
in template YAML (`"2026-05-25T12:00:00Z"`). The tools must also call
`json.dumps(..., default=str)` as a defensive belt — same applies to §27
cron YAMLs and §28 cost_rates.yaml.

### 26.2 The three MCP tools

Standard set:

- `list_templates` — page through the templates dir. Filter by
  `applies_to` and tag. `mode: read-all`.
- `get_template` — fetch one by name. `mode: read-all`.
- `apply_template_args` — given `name` and `overrides: {}`, return the
  merged arg dict the caller can pass to a `submit_*` tool. **Does not
  invoke the target tool.** Composition is the LLM's job — apply_template
  produces args; the LLM then calls submit_* with them. Keeps responsibilities
  clean.

`list_templates` may omit a `limit` arg in v1 — template directories are
expected to be dozens of files, not thousands. Add `limit` (default 100) if a
deployment grows beyond that.

A separate fourth tool `save_template` is **out of scope** for the first
implementation: deciding whose .yaml gets written is a multi-user concern
that needs §18-style policy. Add later if needed.

### 26.3 Why apply_template_args is read-only

If `apply_template_args` directly invoked the target tool, the LLM would
have one tool call doing two things: pick the preset AND submit. That hides
the actual sbatch params from the audit log (§25). The two-step pattern
makes the substitution visible:

```text
1. apply_template_args(name="tier1_gpu_pytorch_a100x4", overrides={time_limit: "12:00:00"})
   -> {gpus: 4, gpu_type: a100, ..., time_limit: "12:00:00"}
2. submit_distributed_train(<those args>)
   -> audit row records the FINAL args, including the overridden time_limit
```

### 26.4 The `applies_to` whitelist

A template's `applies_to` list is enforced — if the caller hands the args to
a tool not in the list, the target tool's schema will probably reject them
anyway (different required keys), but `apply_template_args` should also
return a `compatible_tools: [...]` field so the LLM doesn't even try.

### 26.5 Response shape (`apply_template_args`)

```json
{
  "ok": true,
  "tool": "apply_template_args",
  "template_name": "tier1_gpu_pytorch_a100x4",
  "compatible_tools": ["submit_distributed_train", "train_pytorch_gpu"],
  "args": {
    "gpus": 4, "gpu_type": "a100", "gpu_partition": "gpu-a100",
    "nodes": 1, "ntasks_per_node": 4, "time_limit": "12:00:00",
    "mem_per_cpu": "4G"
  },
  "applied_overrides": { "time_limit": "12:00:00" },
  "hint": "Pass `args` directly to one of compatible_tools."
}
```

### 26.6 Anti-patterns

| Don't                                                  | Why                                                              |
|--------------------------------------------------------|------------------------------------------------------------------|
| Have `apply_template_args` actually submit             | Hides resolved args from audit (§25) and from the user.          |
| Store templates in SQLite                              | Not diffable. Templates are configs; configs belong in YAML.     |
| Skip `applies_to`                                      | A drop-test preset applied to a webhook tool wastes a turn.      |
| Allow template inheritance / `extends:`                | Templates are leaf configs. Composition = overrides at call site.|
| Let the LLM write templates via `save_template`        | First version is read-only. Write needs §18 policy.              |

---

## 27. Scheduled / recurring jobs (external cron)

MCP servers are stateless across sessions — they cannot themselves "wake up
at 2am and run a tool". Scheduled execution requires external infra (cron,
systemd timer, k8s CronJob). This section is for tools that **manage cron
specs**, not for tools that emulate scheduling inside MCP.

### 27.1 The sidecar pattern (mirrors §17.1)

The expected deployment:

```text
/data/SmartTwinMCP/cron/
  <name>.yaml       # one cron entry per file
```

A separate process (a host crond, k8s CronJob controller, ...) reads these
and runs the named tool at the named cadence. **This repo's tools only
manage the YAML files.** Don't try to install crontabs from MCP.

```yaml
# /data/SmartTwinMCP/cron/<name>.yaml
name: daily_drop_collect
description: Every weekday at 2am, pull yesterday's completed runs.
schedule: "0 2 * * 1-5"         # standard cron expression
tool: job_collect@1.0.0         # qualified tool name
args:                            # static args passed every invocation
  since: { _runtime: "now - 24h" }   # see §27.3
enabled: true
created_at: 2026-05-25T12:00:00Z
created_by: alice
last_run_at: null               # populated by the runner
last_run_status: null           # "ok" | "error" | "skipped"
```

Test override: `STMC_CRON_DIR` (default `/data/SmartTwinMCP/cron/`).

**When `STMC_CRON_DIR` doesn't exist** (sidecar not deployed yet):

- `list_scheduled_jobs` → `ok:true, count:0, scheduled:[]` (no installs is a
  valid empty state).
- `get_scheduled_job` / `enable_scheduled_job` → `ok:false` with
  `reason: "cron dir not initialized — sidecar not deployed?"` and `expected_at`
  pointing at the missing path. Target-by-name calls have nothing to read.

### 27.2 The MCP tools

- `list_scheduled_jobs` (`mode: read-all`) — page through the cron dir.
- `get_scheduled_job` — by name. `mode: read-all`.
- `enable_scheduled_job` / `disable_scheduled_job` — flip the `enabled`
  flag. `mode: own` (only the `created_by` user, or `mode-shared` if you
  later add shared specs).
- **No `create_scheduled_job` in the first impl.** Same reason as §26.5:
  writing requires multi-user policy. Hand-author the YAMLs for now.

### 27.3 Runtime args (`_runtime:` keys)

Static args don't always work — a daily collect needs "yesterday's date" not
"epoch 1716500000 forever". Reserve a `_runtime:` namespace for values the
sidecar resolves at execution time:

```yaml
args:
  since: { _runtime: "now - 24h" }      # epoch at run time minus 86400
  date_range: { _runtime: "yesterday_utc" }
```

The supported `_runtime` operators are part of the SIDECAR's contract, not
this catalog's. The MCP tools just read and write the YAML opaquely. Document
the operators you actually use in your sidecar.

### 27.4 Response shape (`list_scheduled_jobs`)

```json
{
  "ok": true,
  "tool": "list_scheduled_jobs",
  "count": 2,
  "scheduled": [
    {
      "name": "daily_drop_collect",
      "schedule": "0 2 * * 1-5",
      "tool": "job_collect@1.0.0",
      "enabled": true,
      "last_run_at": 1716_525_600,
      "last_run_status": "ok",
      "created_by": "alice"
    }, ...
  ]
}
```

**Sort order:** ascending by `name`. Deterministic across runs so the LLM
can refer to "the third entry" if needed.

**`get_scheduled_job` envelope:** `{ok, tool, scheduled: {...full yaml body...}}`.
The full body includes raw `_runtime:` keys per §27.3 — MCP does not resolve
them.

### 27.5 Anti-patterns

| Don't                                                  | Why                                                              |
|--------------------------------------------------------|------------------------------------------------------------------|
| Spawn a cron daemon inside an MCP tool                 | MCP is stateless. Use a real sidecar.                            |
| Resolve `_runtime: now - 24h` inside MCP               | Sidecar resolves at execution. MCP just reads/writes YAML.       |
| `enable_scheduled_job` for any user                    | `mode: own` — only the spec's `created_by` can flip its switch.  |
| Cron-schedule observability tools                      | Pointless — observability tools have no side effects to record.  |

---

## 28. Cost / resource accounting

Before submitting a 4×A100 × 48h job, the user should see "this will cost
≈ ₩X". After the job runs, they should be able to ask "what did I spend
this month?" Both need a cost-rate table outside the catalog plus tools
that read it.

### 28.1 The rate table

Rates change per cluster contract. Keep them in YAML outside the catalog:

```yaml
# /data/SmartTwinMCP/cost_rates.yaml
unit: KRW           # also accepts USD, JPY, etc.
last_updated: 2026-05-25
rates:
  cpu_partition: { cpu_hour: 100 }       # per cpu per hour
  cpu_large:     { cpu_hour: 150 }
  gpu_a100:      { cpu_hour: 200, gpu_hour: 5000 }
  gpu_h100:      { cpu_hour: 200, gpu_hour: 8000 }
```

Test override: `STMC_COST_RATES_FILE` (default
`/data/SmartTwinMCP/cost_rates.yaml`).

If the file is missing, cost tools fail with a clean
`reason: "cost_rates.yaml not deployed — ask ops to install it"`. Don't
guess defaults.

**YAML date serialization:** `last_updated: 2026-05-25` (unquoted) parses
into a Python `date`, which `json.dumps` refuses. Either quote the field
(`last_updated: "2026-05-25"`) OR have your tool coerce to string before
emitting. Same gotcha as §26.1 — apply `json.dumps(..., default=str)` as a
defensive belt.

**CPU-only partition rates** (e.g. `cpu: { cpu_hour: 100 }`) may omit
`gpu_hour`. Treat missing `gpu_hour` as 0 — `estimate_cost` called with
`gpus=N` on a CPU partition returns the CPU-only cost without raising.
The caller (LLM) shouldn't be requesting GPUs on a CPU partition anyway;
§14.1's cross-validation catches that earlier.

### 28.2 Two MCP tools

- `estimate_cost` (`mode: read-all`) — pre-flight. Given partition, gpus,
  cpus, time_limit → cost estimate. No side effects, no registry/audit
  writes (it's a calculator).
- `summarize_costs` (`mode: own`) — post-hoc. Aggregates over registry rows
  (caller's only) for a date range. Uses `extra.gpus`/`extra.cpus`
  (§14.4 / §16.5) + a `time_limit` field on `extra` to compute realized
  cost. **Not all existing submit_* tools record `time_limit` into `extra`
  yet** — rows missing it (or missing cost-relevant fields generally) get
  counted under `skipped: N` in the response rather than raising. Returns
  total + per-tool / per-partition breakdowns + the `skipped` count.

### 28.3 `estimate_cost` args

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["partition", "time_limit"],
  "properties": {
    "partition": { "type": "string", "description": "Slurm partition name." },
    "cpus": { "type": "integer", "minimum": 1, "default": 1 },
    "gpus": { "type": "integer", "minimum": 0, "default": 0 },
    "nodes": { "type": "integer", "minimum": 1, "default": 1, "description": "Multiplier across nodes (§16)." },
    "time_limit": { "type": "string", "pattern": "^[0-9]{1,3}:[0-5][0-9]:[0-5][0-9]$" }
  }
}
```

Formula: `hours = parse(time_limit); per_node = hours * (cpus * rate.cpu_hour + gpus * rate.gpu_hour); total = per_node * nodes`. The math is in the tool, not in the
sidecar — keeps audit trail self-contained.

### 28.4 Response (`estimate_cost`)

```json
{
  "ok": true,
  "tool": "estimate_cost",
  "request": {"partition": "gpu-a100", "cpus": 32, "gpus": 4, "nodes": 1, "time_limit": "08:00:00"},
  "unit": "KRW",
  "hours": 8.0,
  "breakdown": {
    "cpu_hours_cost": 51200,
    "gpu_hours_cost": 160000,
    "node_multiplier": 1
  },
  "estimated_total": 211200,
  "rate_source_updated": "2026-05-25",
  "caveat": "Wall-time estimate. Actual cost depends on job duration."
}
```

**`breakdown` values are PER-NODE; `estimated_total = (cpu_hours_cost +
gpu_hours_cost) × node_multiplier`.** This keeps the math visible — a request
with `nodes: 4` shows the per-node cost AND the multiplier separately, so the
LLM can explain "4 × 211200 = 844800" without inventing intermediate numbers.

`summarize_costs` returns `{period, total, by_tool: [...], by_partition: [...], jobs_counted: N}`.

### 28.5 Anti-patterns

| Don't                                                  | Why                                                              |
|--------------------------------------------------------|------------------------------------------------------------------|
| Bake rates into Python code                            | Rates change per contract; YAML lets ops edit without a release. |
| Charge `mixed` GPU nodes at full rate                  | Per §21.3 free-GPU rule — conservative or scontrol drilldown.    |
| Audit every `estimate_cost` call                       | It's a calculator. §25.3 says no audit on observability tools.   |
| `summarize_costs` over all users by default            | mode: own. Cross-user roll-ups need explicit `actor` filter.     |
| Skip `caveat` in the response                          | Estimate-vs-actual surprises users. Always include disclaimer.   |
