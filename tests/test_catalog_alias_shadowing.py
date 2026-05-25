"""Regression: catalog must flag aliases that shadow real tool names.

Before the fix, `list_recent_jobs.aliases = [..., my_jobs, ...]` happily
coexisted with a real `my_jobs/` tool — both ended up in catalog state under
different keys (`aliases['my_jobs']` -> list_recent_jobs, `latest_by_name['my_jobs']`
-> my_jobs), and the LLM had no signal that they meant different things.
"""
from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from smarttwin_mcp.catalog import load_catalog


def _make_tool(tools_root: Path, name: str, aliases: list[str] | None = None) -> None:
    d = tools_root / name / "1.0.0"
    d.mkdir(parents=True)
    (d / "args.schema.json").write_text(json.dumps({
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "additionalProperties": False,
        "properties": {},
    }))
    meta = [
        f"name: {name}",
        "version: 1.0.0",
        f"summary: smoke {name}",
        "tags: []",
        "transport: {kind: local, shell: /bin/bash, timeout_sec: 5}",
        "expose: catalog",
    ]
    if aliases:
        meta.append("aliases: " + json.dumps(aliases))
    (d / "meta.yaml").write_text("\n".join(meta) + "\n")
    (d / "script.sh").write_text('#!/bin/bash\necho \'{"ok": true}\'\n')
    (d / "script.sh").chmod(0o755)
    (tools_root / name / "latest").symlink_to("1.0.0")


def test_alias_shadowing_real_tool_is_flagged():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _make_tool(root, "real_tool")
        _make_tool(root, "owner_tool", aliases=["real_tool"])

        c = load_catalog(root)

        # The real tool wins on resolve.
        assert c.resolve("real_tool").name == "real_tool"
        # The shadowing alias must NOT be silently registered.
        assert "real_tool" not in c.aliases
        # An issue must be recorded so reviewers see it.
        msgs = " ".join(i.message for i in c.issues)
        assert "shadows existing tool" in msgs


def test_alias_collision_with_other_alias_is_flagged():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _make_tool(root, "tool_a", aliases=["shared_alias"])
        _make_tool(root, "tool_b", aliases=["shared_alias"])

        c = load_catalog(root)

        # First-registered alias survives (loader iterates sorted).
        assert "shared_alias" in c.aliases
        msgs = " ".join(i.message for i in c.issues)
        assert "collides with alias" in msgs


def test_self_alias_is_a_noop():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _make_tool(root, "narcissist", aliases=["narcissist"])

        c = load_catalog(root)

        # No issue, no duplicate entry.
        assert c.issues == [], c.issues
        # resolve still works through the canonical name.
        assert c.resolve("narcissist").name == "narcissist"
