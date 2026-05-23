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

### 2.5 `examples` are not optional in practice

Even though the spec marks them as optional, **always include at least 2 examples**:
one minimal call and one with most options set. Examples cost nothing to write and
dramatically improve weak-LLM call accuracy. Examples must validate against
`args.schema.json` (CI/lint will check this — see §7).

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

# 6. End-to-end run with a dry-run / minimal input
STMC_ARGS_JSON='{"...minimal valid args..."}' bash tools/my_tool/1.0.0/script.sh | python3 -m json.tool

# 7. Existing tests still pass
.venv/bin/pytest tests/ -q
```

If any of these fail, **do not commit**. Fix first.

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

---

## 9. Shared helpers in `_shared/`

Existing helpers (do not duplicate):

- [`_shared/registry.py`](_shared/registry.py): SQLite job registry at `/data/SmartTwinMCP/jobs.db`.
  Persists submitted jobs across MCP sessions. Functions: `record_submission`,
  `list_recent`, `get_by_id`, `update_status`, `search`. **Use this for any tool that
  submits, queries, or modifies a long-running job.**
- [`_shared/scenario_builder.py`](_shared/scenario_builder.py): builds drop-test scenario
  configs.
- [`_shared/job_helpers.py`](_shared/job_helpers.py): shared logic for `job_*` tools.

How to use:

```bash
export SHARED_DIR="$(cd "$(dirname "$0")"/../../_shared && pwd)"
python3 - <<'PY'
import sys, os
sys.path.insert(0, os.environ["SHARED_DIR"])
import registry
# registry.record_submission(...)
PY
```

If you need a new shared helper:

1. Decide whether it really needs to be shared (used by ≥ 2 tools).
2. Add it to `_shared/` with a clear module-level docstring.
3. Update this guide's §9 list.
4. Avoid importing third-party packages — `_shared/` must work with stdlib only,
   so it stays portable to ssh transport later.

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
