"""Smoke tests — no MCP transport, just the catalog + runner.

Run with: python -m pytest tests/ -q
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from smarttwin_mcp.catalog import load_catalog
from smarttwin_mcp.runner import run as run_tool
from smarttwin_mcp.search import search as search_tools


TOOLS_ROOT = Path(__file__).resolve().parents[1] / "tools"


def test_catalog_loads_with_no_issues():
    cat = load_catalog(TOOLS_ROOT)
    assert cat.issues == [], cat.issues
    assert "echo" in cat.latest_by_name
    assert "submit_job" in cat.latest_by_name
    assert cat.latest_by_name["echo"].version == "1.0.0"


def test_qualified_name_resolves():
    cat = load_catalog(TOOLS_ROOT)
    assert cat.resolve("echo@1.0.0") is not None
    assert cat.resolve("echo") is cat.resolve("echo@1.0.0")
    assert cat.resolve("does_not_exist") is None


def test_alias_resolves_to_latest():
    cat = load_catalog(TOOLS_ROOT)
    # submit_job has aliases [run_job, launch]
    entry = cat.resolve("run_job")
    assert entry is not None
    assert entry.name == "submit_job"


def test_search_finds_by_tag():
    cat = load_catalog(TOOLS_ROOT)
    hits = search_tools(cat.all_entries(), "slurm")
    names = [h.name for h in hits]
    assert "submit_job" in names


def test_run_echo_local():
    cat = load_catalog(TOOLS_ROOT)
    entry = cat.resolve("echo")
    result = run_tool(entry, {"message": "hi", "count": 2})
    assert result.ok, (result.stderr, result.stdout)
    assert result.parsed is not None
    assert result.parsed["echoed"] == ["hi", "hi"]


def test_run_submit_job_local():
    cat = load_catalog(TOOLS_ROOT)
    entry = cat.resolve("submit_job")
    result = run_tool(entry, {"case_dir": "/data/x", "solver": "smarttwin-dyna"})
    assert result.ok, (result.stderr, result.stdout)
    assert result.parsed is not None
    assert result.parsed["job_id"].startswith("stc-")
    assert result.parsed["solver"] == "smarttwin-dyna"
