"""FastMCP server entrypoint.

Design for low-end LLMs: only 4 catalog meta-tools are *always* exposed.

  1. catalog_search(query, limit=20)         -> ranked tool hits
  2. catalog_describe(name)                  -> usage doc + schema + examples
  3. catalog_versions(name)                  -> all versions of a tool
  4. catalog_run(name, args, version=None)   -> validated execution

Tools whose meta.yaml sets `expose: direct` (or `both`) are ALSO registered as
their own MCP tool. This is the escape hatch for "favorite" tools that should
appear by name in the LLM tool list. Default is `catalog` so hundreds of tools
don't drown the model.

Versions: by default only the resolved `latest` of each tool is reachable by
short name. Explicit `name@version` is always honored via catalog_run or the
`version` argument. Old direct-exposed versions can still be reached through
catalog_run.
"""
from __future__ import annotations

import argparse
import logging
import os
from pathlib import Path
from typing import Any

import jsonschema
from fastmcp import FastMCP

from .catalog import Catalog, load_catalog
from .runner import run as run_tool
from .search import search as search_tools

logger = logging.getLogger("smarttwin_mcp")


def _identifier_for(name: str, version: str | None, catalog: Catalog) -> str:
    if version:
        return f"{name}@{version}"
    return name


def _format_describe(entry, catalog: Catalog) -> dict[str, Any]:
    all_versions = catalog.versions_by_name.get(entry.name, [entry.version])
    return {
        "name": entry.name,
        "version": entry.version,
        "is_latest": entry.is_latest,
        "summary": entry.meta.summary,
        "description": entry.meta.description,
        "tags": entry.meta.tags,
        "transport": entry.meta.transport.kind,
        "deprecated": entry.meta.deprecated,
        "deprecation_note": entry.meta.deprecation_note,
        "aliases": entry.meta.aliases,
        "all_versions": all_versions,
        "args_schema": entry.args_schema,
        "examples": [e.model_dump() for e in entry.meta.examples],
        "how_to_call": {
            "via_catalog_run": {
                "name": entry.name,
                "version": None,
                "args": "<object matching args_schema>",
            },
            "pinned_version_example": f"catalog_run(name='{entry.name}', version='{entry.version}', args={{...}})",
        },
    }


def _validate_args(schema: dict, args: dict) -> str | None:
    try:
        jsonschema.validate(args, schema)
    except jsonschema.ValidationError as e:
        return f"args validation failed at {'/'.join(map(str, e.absolute_path)) or '<root>'}: {e.message}"
    return None


def build_server(tools_root: Path) -> FastMCP:
    mcp = FastMCP(
        name="SmartTwinMCP",
        instructions=(
            "Catalog server for SmartTwinCluster commands. "
            "Hundreds of tools may exist; they are NOT all listed individually. "
            "Use `catalog_search` to find a tool by keyword, "
            "then `catalog_describe` to see its arguments and examples, "
            "then `catalog_run` to execute it. "
            "Use `name@version` or the `version` argument to pin a specific version."
        ),
    )

    # Mutable holder so re-loads don't need to rebuild the FastMCP instance.
    state = {"catalog": load_catalog(tools_root)}

    def _catalog() -> Catalog:
        return state["catalog"]

    @mcp.tool(
        description=(
            "Find SmartTwinCluster tools by free-text query. "
            "Returns ranked hits (name, version=latest, summary, tags). "
            "Pass an empty string to list all tools."
        )
    )
    def catalog_search(query: str = "", limit: int = 20) -> dict:
        hits = search_tools(_catalog().all_entries(), query, limit=limit)
        return {
            "query": query,
            "total_tools": len(_catalog().latest_by_name),
            "hits": [h.to_dict() for h in hits],
        }

    @mcp.tool(
        description=(
            "Show full usage info for a tool: summary, description, args JSON Schema, "
            "examples, available versions. Accepts 'name' or 'name@version'."
        )
    )
    def catalog_describe(name: str) -> dict:
        entry = _catalog().resolve(name)
        if entry is None:
            return {"error": f"tool not found: {name}", "did_you_mean": _suggest(name, _catalog())}
        return _format_describe(entry, _catalog())

    @mcp.tool(
        description="List all versions of a tool, marking the latest."
    )
    def catalog_versions(name: str) -> dict:
        base = name.split("@", 1)[0]
        versions = _catalog().versions_by_name.get(base)
        if not versions:
            return {"error": f"tool not found: {base}"}
        latest = _catalog().latest_by_name.get(base)
        return {
            "name": base,
            "latest": latest.version if latest else None,
            "versions": versions,
        }

    @mcp.tool(
        description=(
            "Execute a SmartTwinCluster tool. Required: name, args (object). "
            "Optional: version (pin a specific version; default = latest). "
            "Args are validated against the tool's JSON Schema before execution."
        )
    )
    def catalog_run(name: str, args: dict | None = None, version: str | None = None) -> dict:
        args = args or {}
        identifier = _identifier_for(name, version, _catalog())
        entry = _catalog().resolve(identifier)
        if entry is None:
            return {
                "ok": False,
                "error": f"tool not found: {identifier}",
                "did_you_mean": _suggest(name, _catalog()),
            }
        err = _validate_args(entry.args_schema, args)
        if err:
            return {"ok": False, "error": err, "tool": entry.qualified_name}
        result = run_tool(entry, args)
        return {"tool": entry.qualified_name, **result.to_dict()}

    @mcp.tool(
        description=(
            "Re-scan the tools/ directory and rebuild the catalog without restarting. "
            "Returns counts and any issues found."
        )
    )
    def catalog_reload() -> dict:
        state["catalog"] = load_catalog(tools_root)
        c = state["catalog"]
        return {
            "tools": len(c.latest_by_name),
            "versions": len(c.by_qualified),
            "issues": [{"path": str(i.path), "message": i.message} for i in c.issues],
        }

    # Direct-exposed tools.
    for entry in _catalog().all_entries():
        if not entry.is_latest:
            continue  # only latest is auto-direct; older versions stay catalog-only
        if entry.meta.expose not in ("direct", "both"):
            continue
        _register_direct(mcp, entry, state)

    return mcp


def _register_direct(mcp: FastMCP, entry, state: dict) -> None:
    """Register an individual tool as a top-level MCP tool. Closure captures `entry`."""
    tool_name = entry.name
    desc = entry.meta.summary
    if entry.meta.description:
        desc = f"{desc}\n\n{entry.meta.description}"

    @mcp.tool(name=tool_name, description=desc)
    def _direct(args: dict | None = None) -> dict:
        args = args or {}
        # Always re-resolve from current catalog so reloads pick up new versions.
        current = state["catalog"].latest_by_name.get(tool_name, entry)
        err = _validate_args(current.args_schema, args)
        if err:
            return {"ok": False, "error": err, "tool": current.qualified_name}
        result = run_tool(current, args)
        return {"tool": current.qualified_name, **result.to_dict()}


def _suggest(query: str, catalog: Catalog, k: int = 5) -> list[str]:
    """Cheap suggestion: combine token overlap + substring + difflib fuzzy match.

    The token-only version missed typos like 'echoo' -> 'echo' because they
    tokenize to disjoint sets.
    """
    import difflib
    from .search import _tokens

    if not query:
        return sorted(catalog.latest_by_name)[:k]

    q_norm = query.lower()
    q_tokens = set(_tokens(query))
    names = list(catalog.latest_by_name)

    scored: dict[str, float] = {}
    for name in names:
        score = 0.0
        # token overlap (original behavior)
        if q_tokens:
            score += 2.0 * len(q_tokens & set(_tokens(name)))
        # substring either direction
        if q_norm in name or name in q_norm:
            score += 3.0
        # difflib ratio for typos
        ratio = difflib.SequenceMatcher(None, q_norm, name).ratio()
        if ratio >= 0.6:
            score += ratio
        if score > 0:
            scored[name] = score

    return [n for n, _ in sorted(scored.items(), key=lambda kv: (-kv[1], kv[0]))[:k]]


def _add_serve_args(p: argparse.ArgumentParser) -> None:
    p.add_argument(
        "--tools-root",
        default=os.environ.get("STMC_TOOLS_ROOT", "./tools"),
        help="Path to the tools/ directory (default: ./tools or $STMC_TOOLS_ROOT).",
    )
    p.add_argument(
        "--transport",
        choices=["stdio", "sse"],
        default=os.environ.get("STMC_MCP_TRANSPORT", "stdio"),
        help="MCP transport to expose the server on.",
    )


def _cmd_serve(args) -> int:
    tools_root = Path(args.tools_root).resolve()
    server = build_server(tools_root)
    server.run(transport=args.transport)
    return 0


def _cmd_lint(args) -> int:
    from .lint import lint
    tools_root = Path(args.tools_root).resolve()
    disable = set(args.disable.split(",")) if args.disable else set()
    report = lint(tools_root, disable=disable)
    print(report.render())
    return 0 if report.passed() else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="smarttwin-mcp")
    parser.add_argument("--log-level", default=os.environ.get("STMC_LOG_LEVEL", "INFO"))

    sub = parser.add_subparsers(dest="cmd")

    serve_p = sub.add_parser("serve", help="Run the MCP server (default).")
    _add_serve_args(serve_p)

    lint_p = sub.add_parser("lint", help="Check the catalog for guide-rule violations.")
    lint_p.add_argument(
        "tools_root",
        nargs="?",
        default=os.environ.get("STMC_TOOLS_ROOT", "./tools"),
        help="Path to the tools/ directory (default: ./tools).",
    )
    lint_p.add_argument(
        "--disable",
        default="",
        help="Comma-separated list of rule IDs to skip (e.g. L022,L040).",
    )

    # Backwards-compat: bare `smarttwin-mcp` (no subcommand) acts like `serve`.
    _add_serve_args(parser)

    args = parser.parse_args(argv)
    logging.basicConfig(
        level=args.log_level.upper(),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    if args.cmd == "lint":
        return _cmd_lint(args)
    return _cmd_serve(args)


if __name__ == "__main__":
    raise SystemExit(main())
