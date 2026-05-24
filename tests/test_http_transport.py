"""HTTP transport tests — env interpolation and error paths.

No actual network: we exercise the interpolation logic and the early-return
behavior for missing env vars / missing template args.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from smarttwin_mcp.runner import _interpolate_env, _run_http
from smarttwin_mcp.spec import HttpTransport, ToolEntry, ToolMeta


def test_interpolate_basic():
    rendered, missing = _interpolate_env("${A}/x/${B}", {"A": "1", "B": "2"})
    assert rendered == "1/x/2"
    assert missing == []


def test_interpolate_default_used_when_var_missing():
    rendered, missing = _interpolate_env("${A:-def}/x", {})
    assert rendered == "def/x"
    assert missing == []


def test_interpolate_default_skipped_when_var_present():
    rendered, missing = _interpolate_env("${A:-def}/x", {"A": "real"})
    assert rendered == "real/x"
    assert missing == []


def test_interpolate_reports_missing_with_no_default():
    rendered, missing = _interpolate_env("${A}/${B}", {"A": "ok"})
    assert "${B}" in rendered
    assert missing == ["B"]


def test_interpolate_ignores_unrelated_dollars():
    # Shell-style $VAR (without braces) is not touched.
    rendered, missing = _interpolate_env("price is $10 and ${A}", {"A": "x"})
    assert rendered == "price is $10 and x"
    assert missing == []


def _make_http_entry(method="GET", url="${MISSING_VAR}/v1/health", headers=None,
                    body_template=None):
    meta = ToolMeta(
        name="t", version="1.0.0", summary="t",
        transport=HttpTransport(
            kind="http", method=method, url=url,
            headers=headers or {}, body_template=body_template,
        ),
    )
    return ToolEntry(
        meta=meta,
        args_schema={"type": "object"},
        script_path=Path("/dev/null"),
        spec_dir=Path("/dev/null"),
    )


def test_http_fails_on_missing_env_before_network(monkeypatch):
    monkeypatch.delenv("MISSING_VAR", raising=False)
    entry = _make_http_entry()
    result = _run_http(entry, {}, entry.meta.transport)
    assert result.ok is False
    assert "missing env" in result.stderr
    assert "MISSING_VAR" in result.stderr
    # No network attempt — exit_code stays None.
    assert result.exit_code is None


def test_http_fails_on_missing_body_template_arg(monkeypatch):
    monkeypatch.setenv("URL_BASE", "http://example.com")
    entry = _make_http_entry(
        method="POST",
        url="${URL_BASE}/v1/jobs",
        body_template='{"case": "{case_dir}"}',
    )
    result = _run_http(entry, {}, entry.meta.transport)  # missing case_dir
    assert result.ok is False
    assert "missing arg" in result.stderr
