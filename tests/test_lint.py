"""Lint module tests.

Two layers:
1. Regression: current catalog must lint clean (zero errors). Warnings are OK
   but errors block CI.
2. Unit: a deliberately broken fixture must trigger each rule exactly once.
"""
from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from smarttwin_mcp.lint import lint, ALL_RULES


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_current_catalog_lints_with_zero_errors():
    """Production catalog must have 0 lint errors. Warnings allowed."""
    report = lint(REPO_ROOT / "tools")
    if report.errors:
        msg = "\n".join(f.format() for f in report.errors)
        raise AssertionError(f"lint errors in current catalog:\n{msg}")
    assert report.tools_checked > 0


def _write_minimal_tool(tools_root: Path, name: str, *,
                       meta_yaml: str | None = None,
                       schema: dict | None = None,
                       script_exec: bool = True,
                       latest_symlink: bool = True) -> Path:
    """Create a tool with sensible defaults; tests override one piece at a time."""
    d = tools_root / name / "1.0.0"
    d.mkdir(parents=True)
    (d / "args.schema.json").write_text(json.dumps(schema if schema is not None else {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "additionalProperties": False,
        "properties": {},
    }))
    if meta_yaml is None:
        meta_yaml = "\n".join([
            f"name: {name}",
            "version: 1.0.0",
            "summary: smoke",
            "tags: []",
            "transport: {kind: local, shell: /bin/bash, timeout_sec: 5}",
            "expose: catalog",
            "examples:",
            "  - title: zero-arg",
            "    args: {}",
        ])
    (d / "meta.yaml").write_text(meta_yaml + "\n")
    sh = d / "script.sh"
    sh.write_text('#!/bin/bash\necho \'{"ok": true}\'\n')
    if script_exec:
        sh.chmod(0o755)
    else:
        sh.chmod(0o644)
    if latest_symlink:
        (tools_root / name / "latest").symlink_to("1.0.0")
    return d


def test_L011_missing_latest_symlink():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _write_minimal_tool(root, "no_latest", latest_symlink=False)
        report = lint(root)
        assert any(f.rule_id == "L011" for f in report.findings)


def test_L012_missing_exec_bit():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _write_minimal_tool(root, "no_exec", script_exec=False)
        report = lint(root)
        errs = [f for f in report.errors if f.rule_id == "L012"]
        assert len(errs) == 1, [f.format() for f in report.findings]


def test_L021_missing_additional_properties_false():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _write_minimal_tool(root, "open_schema", schema={
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "properties": {},
            # additionalProperties omitted -> defaults to true
        })
        report = lint(root)
        errs = [f for f in report.errors if f.rule_id == "L021"]
        assert len(errs) == 1


def test_L022_missing_property_description():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _write_minimal_tool(root, "no_desc", schema={
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "additionalProperties": False,
            "properties": {"foo": {"type": "string"}},  # no description
        })
        report = lint(root)
        warns = [f for f in report.findings if f.rule_id == "L022"]
        assert len(warns) == 1


def test_L030_no_examples_required_args():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _write_minimal_tool(
            root, "no_examples",
            schema={
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "type": "object",
                "additionalProperties": False,
                "required": ["x"],
                "properties": {"x": {"type": "string", "description": "x"}},
            },
            meta_yaml="\n".join([
                "name: no_examples",
                "version: 1.0.0",
                "summary: smoke",
                "tags: []",
                "transport: {kind: local, shell: /bin/bash, timeout_sec: 5}",
                "expose: catalog",
                # examples deliberately omitted
            ]),
        )
        report = lint(root)
        errs = [f for f in report.errors if f.rule_id == "L030"]
        assert len(errs) == 1


def test_L031_example_fails_schema():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _write_minimal_tool(
            root, "bad_example",
            schema={
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "type": "object",
                "additionalProperties": False,
                "required": ["x"],
                "properties": {"x": {"type": "string", "description": "x"}},
            },
            meta_yaml="\n".join([
                "name: bad_example",
                "version: 1.0.0",
                "summary: smoke",
                "tags: []",
                "transport: {kind: local, shell: /bin/bash, timeout_sec: 5}",
                "expose: catalog",
                "examples:",
                "  - title: bad",
                "    args: {}",  # missing required 'x'
            ]),
        )
        report = lint(root)
        errs = [f for f in report.errors if f.rule_id == "L031"]
        assert len(errs) == 1


def test_L060_hardcoded_authorization_header():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _write_minimal_tool(
            root, "hardcoded_token",
            meta_yaml="\n".join([
                "name: hardcoded_token",
                "version: 1.0.0",
                "summary: bad http tool",
                "tags: []",
                "transport:",
                "  kind: http",
                "  method: GET",
                "  url: https://api.example.com/health",
                "  headers:",
                "    Authorization: 'Bearer sk-real-token-here'",
                "  timeout_sec: 10",
                "expose: catalog",
                "examples:",
                "  - title: x",
                "    args: {}",
            ]),
        )
        report = lint(root)
        errs = [f for f in report.errors if f.rule_id == "L060"]
        assert len(errs) == 1, [f.format() for f in report.findings]


def test_L070_mutation_tool_missing_audit_call():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        # A mutation-shaped tool that DOES NOT call audit.record_event.
        d = root / "submit_foo" / "1.0.0"
        d.mkdir(parents=True)
        (d / "args.schema.json").write_text(json.dumps({
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "additionalProperties": False,
            "properties": {"dry_run": {"type": "boolean", "default": True, "description": "dry"}},
        }))
        (d / "meta.yaml").write_text("\n".join([
            "name: submit_foo",
            "version: 1.0.0",
            "summary: smoke mutation",
            "tags: [mode-own]",
            "transport: {kind: local, shell: /bin/bash, timeout_sec: 5}",
            "expose: catalog",
            "examples:",
            "  - title: a",
            "    args: {dry_run: true}",
            "  - title: b",
            "    args: {dry_run: false}",
        ]) + "\n")
        sh = d / "script.sh"
        # Note: does NOT call record_event anywhere.
        sh.write_text('#!/bin/bash\necho \'{"ok": true}\'\n')
        sh.chmod(0o755)
        (root / "submit_foo" / "latest").symlink_to("1.0.0")

        report = lint(root)
        warns = [f for f in report.findings if f.rule_id == "L070"]
        assert len(warns) == 1, [f.format() for f in report.findings]


def test_L070_read_all_tool_not_flagged():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        # Read-all (observability) tool — mutation-shaped name but tagged read-all.
        d = root / "submit_summary" / "1.0.0"
        d.mkdir(parents=True)
        (d / "args.schema.json").write_text(json.dumps({
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "additionalProperties": False,
            "properties": {},
        }))
        (d / "meta.yaml").write_text("\n".join([
            "name: submit_summary",
            "version: 1.0.0",
            "summary: a misleadingly-named observability tool",
            "tags: [mode-read-all]",
            "transport: {kind: local, shell: /bin/bash, timeout_sec: 5}",
            "expose: catalog",
            "examples:",
            "  - title: a",
            "    args: {}",
        ]) + "\n")
        sh = d / "script.sh"
        sh.write_text('#!/bin/bash\necho \'{"ok": true}\'\n')
        sh.chmod(0o755)
        (root / "submit_summary" / "latest").symlink_to("1.0.0")

        report = lint(root)
        l070 = [f for f in report.findings if f.rule_id == "L070"]
        assert l070 == [], "mode-read-all must not trigger L070"


def test_rule_registry_is_complete():
    """Catch the case where someone adds a rule_Lxxx function but forgets to
    register it in ALL_RULES."""
    import smarttwin_mcp.lint as L
    registered = {rid for rid, _ in ALL_RULES}
    defined = {n.split("_")[1] for n in dir(L) if n.startswith("rule_L")}
    missing = defined - registered
    assert not missing, f"rule functions defined but not in ALL_RULES: {missing}"
