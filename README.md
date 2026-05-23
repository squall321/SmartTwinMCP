# SmartTwinMCP

A FastMCP server that exposes **SmartTwinCluster commands as versioned, catalog-indexed tools**.
Drop a `script.sh + args.schema.json + meta.yaml` triplet into `tools/<name>/<version>/`,
reload, and the tool is callable from any MCP client — even by low-capability LLMs.

The trick that makes this scale to hundreds of tools without overwhelming the model:
**only four catalog meta-tools are always exposed.** The LLM searches the catalog,
reads the tool's usage doc + JSON schema, and invokes it through `catalog_run`.
Frequently used tools can opt-in to direct exposure via `expose: direct`.

## Layout

```text
SmartTwinMCP/
  pyproject.toml
  src/smarttwin_mcp/
    server.py          # FastMCP entrypoint + 4 meta-tools
    catalog.py         # disk scanner + version resolver
    spec.py            # pydantic models for meta.yaml
    runner.py          # local / ssh / http transports
    search.py          # lexical search over name/summary/tags
  tools/
    <tool_name>/
      <version>/                # e.g. 1.0.0
        meta.yaml               # transport + summary + usage doc + examples
        args.schema.json        # JSON Schema for arguments
        script.sh               # executed by the chosen transport
      latest -> <version>       # symlink — pick the canonical version
  tests/
```

## The meta-tool surface (what the LLM sees)

| Tool                | Purpose                                                                  |
|---------------------|--------------------------------------------------------------------------|
| `catalog_search`    | Find tools by free text (returns name, version, summary, tags, score).   |
| `catalog_describe`  | Full usage doc + JSON schema + examples for one tool.                    |
| `catalog_versions`  | List all versions of a tool, marking the latest.                         |
| `catalog_run`       | Execute a tool by name (optionally pinned to a version), with args.      |
| `catalog_reload`    | Re-scan `tools/` without restarting the server.                          |

Tools whose `meta.yaml` has `expose: direct` are **also** registered as their own MCP tool.
This gives "favorite" tools first-class visibility while everything else stays catalog-only.

## Versioning

- Each version lives in its own folder: `tools/submit_job/1.0.0/`, `tools/submit_job/1.1.0/`, ...
- The canonical version is selected by, in order:
  1. The `latest` symlink (preferred — `ln -sfn 1.1.0 tools/submit_job/latest`)
  2. `_index.yaml` with `default_version: 1.1.0` (use when symlinks are inconvenient)
  3. Highest semver as a last resort
- `catalog_run("submit_job", {...})` → latest. `catalog_run("submit_job", {...}, version="1.0.0")` → pinned.
- Older versions are reachable but never appear as direct MCP tools, so the tool list stays uncluttered.

## meta.yaml fields

```yaml
name: submit_job              # must match folder name
version: 1.0.0                # must match folder name
summary: Submit a job to SmartTwinCluster.       # one line
description: |                                   # markdown, shown via catalog_describe
  When to call this... what to pass... what comes back...
tags: [job, submit, slurm]
aliases: [run_job]            # other names that resolve to this tool
deprecated: false
deprecation_note: null
expose: catalog               # catalog (default) | direct | both
transport:
  kind: local                 # local | ssh | http
  shell: /bin/bash
  timeout_sec: 600
  env: { LOG_LEVEL: info }
examples:
  - title: minimal
    args: { case_dir: /data/a, solver: smarttwin-dyna }
```

### Transports

| kind  | Where script.sh runs                        | Extra fields                                                           |
|-------|---------------------------------------------|------------------------------------------------------------------------|
| local | this host, via `subprocess.run`             | `shell`, `cwd`, `env`, `timeout_sec`                                   |
| ssh   | piped over `ssh host bash -s`               | `host`, `user`, `key_path`, `port`, `remote_cwd`, `env`, `timeout_sec` |
| http  | not a script — POST JSON to a REST endpoint | `method`, `url`, `headers`, `body_template`, `timeout_sec`             |

For `http`, `body_template` is a Python `str.format_map` template over the args
(e.g. `'{"case": "{case_dir}"}'`). Omit it to send args as-is.

## Calling contract for `script.sh`

Every script receives args **as a JSON object on stdin AND in `$STMC_ARGS_JSON`**.
Pick whichever is easier:

```bash
# stdin
ARGS=$(cat)

# env
ARGS="$STMC_ARGS_JSON"
```

Stdout is the result. If it's valid JSON, the server parses it into `result`.
Otherwise it's returned verbatim in `stdout`. Stderr is captured separately.
Exit code 0 = success.

## Quickstart

```bash
python3 -m venv .venv
.venv/bin/pip install -e .
.venv/bin/smarttwin-mcp --tools-root ./tools                 # stdio MCP transport (default)
.venv/bin/smarttwin-mcp --tools-root ./tools --transport sse # for HTTP-style clients
```

Tests:

```bash
.venv/bin/pip install pytest
.venv/bin/pytest tests/ -q
```

Wire it into Claude Code (or any MCP client) by pointing at the `smarttwin-mcp` command.

## Adding a new tool (the only doc most people need)

1. `mkdir -p tools/my_tool/1.0.0`
2. Write `meta.yaml`, `args.schema.json`, `script.sh`. Make the script executable.
3. `ln -sfn 1.0.0 tools/my_tool/latest`
4. From the MCP client: call `catalog_reload`. New tool is live.

## Adding a new version of an existing tool

1. `cp -r tools/my_tool/1.0.0 tools/my_tool/1.1.0` and edit
2. `ln -sfn 1.1.0 tools/my_tool/latest`
3. `catalog_reload`. `my_tool` now points to 1.1.0; `my_tool@1.0.0` still works.
