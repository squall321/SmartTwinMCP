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
    """Cheap suggestion: tools whose name shares any token with the query."""
    from .search import _tokens
    q = set(_tokens(query))
    if not q:
        return sorted(catalog.latest_by_name)[:k]
    scored = []
    for name in catalog.latest_by_name:
        n = set(_tokens(name))
        overlap = len(q & n)
        if overlap:
            scored.append((overlap, name))
    scored.sort(reverse=True)
    return [n for _, n in scored[:k]]


def main() -> None:
    parser = argparse.ArgumentParser(prog="smarttwin-mcp")
    parser.add_argument(
        "--tools-root",
        default=os.environ.get("STMC_TOOLS_ROOT", "./tools"),
        help="Path to the tools/ directory (default: ./tools or $STMC_TOOLS_ROOT).",
    )
    parser.add_argument(
        "--transport",
        choices=["stdio", "sse"],
        default=os.environ.get("STMC_MCP_TRANSPORT", "stdio"),
        help="MCP transport to expose the server on.",
    )
    parser.add_argument("--log-level", default=os.environ.get("STMC_LOG_LEVEL", "INFO"))
    args = parser.parse_args()

    logging.basicConfig(
        level=args.log_level.upper(),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    tools_root = Path(args.tools_root).resolve()
    server = build_server(tools_root)
    server.run(transport=args.transport)


if __name__ == "__main__":
    main()
