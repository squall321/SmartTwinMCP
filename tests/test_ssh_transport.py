"""SSH transport tests — env interpolation per §22.3.

Before the fix, _run_ssh passed `${VAR}` strings raw into ssh's argv, breaking
every §22 tool. Behavior must mirror _run_http (§15.3).
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from smarttwin_mcp.runner import _run_ssh
from smarttwin_mcp.spec import SshTransport, ToolEntry, ToolMeta


def _make_entry(host="${MISSING_HOST}", user=None, key_path=None, remote_cwd=None,
                env=None):
    meta = ToolMeta(
        name="t", version="1.0.0", summary="t",
        transport=SshTransport(
            kind="ssh", host=host, user=user, key_path=key_path,
            port=22, remote_cwd=remote_cwd, env=env or {},
        ),
    )
    return ToolEntry(
        meta=meta,
        args_schema={"type": "object"},
        script_path=Path("/dev/null"),
        spec_dir=Path("/dev/null"),
    )


def test_ssh_fails_on_missing_host_env_before_network(monkeypatch):
    monkeypatch.delenv("MISSING_HOST", raising=False)
    entry = _make_entry(host="${MISSING_HOST}")
    result = _run_ssh(entry, {}, entry.meta.transport)
    assert result.ok is False
    assert "missing env" in result.stderr
    assert "MISSING_HOST" in result.stderr
    assert result.exit_code is None
    # The unresolved ${VAR} CAN still appear in `command` — that's helpful
    # debugging context. The contract is that no NETWORK call fired
    # (exit_code is None, not 255 from ssh) and stderr names the missing var.


def test_ssh_fails_on_missing_env_anywhere(monkeypatch):
    monkeypatch.setenv("HOST_OK", "head.example.com")
    monkeypatch.delenv("MISSING_KEY", raising=False)
    monkeypatch.delenv("MISSING_USER", raising=False)
    entry = _make_entry(
        host="${HOST_OK}",
        user="${MISSING_USER}",
        key_path="${MISSING_KEY}",
    )
    result = _run_ssh(entry, {}, entry.meta.transport)
    assert result.ok is False
    # Both unresolved vars are reported, sorted.
    assert "MISSING_KEY" in result.stderr
    assert "MISSING_USER" in result.stderr


def test_ssh_interpolation_uses_default_form(monkeypatch):
    """Resolution + ${VAR:-default} fallback both work, no real network call."""
    import subprocess as sp

    monkeypatch.delenv("STMC_CLUSTER_USER", raising=False)
    monkeypatch.setenv("HOST_OK", "head.example.com")

    # Mock subprocess.run so the test doesn't actually try to ssh.
    captured = {}
    class FakeProc:
        returncode = 255
        stdout = b""
        stderr = b"ssh: connect mock"
    def fake_run(cmd, **kw):
        captured["cmd"] = cmd
        return FakeProc()
    monkeypatch.setattr("smarttwin_mcp.runner.subprocess.run", fake_run)

    entry = _make_entry(
        host="${HOST_OK}",
        user="${STMC_CLUSTER_USER:-svc-stmc}",
    )
    result = _run_ssh(entry, {}, entry.meta.transport)
    assert "missing env" not in result.stderr
    assert "svc-stmc@head.example.com" in result.command
    # Verify the actual argv passed to subprocess has the resolved target.
    assert "svc-stmc@head.example.com" in captured["cmd"]


def test_ssh_env_values_interpolated(monkeypatch):
    """env: {STMC_JOBS_DB: ${DB_PATH}} must substitute before forwarding."""
    import subprocess as sp

    monkeypatch.setenv("HOST_OK", "head.example.com")
    monkeypatch.setenv("DB_PATH", "/tmp/test_db.sqlite")

    captured = {}
    class FakeProc:
        returncode = 255
        stdout = b""
        stderr = b""
    def fake_run(cmd, **kw):
        captured["cmd"] = cmd
        return FakeProc()
    monkeypatch.setattr("smarttwin_mcp.runner.subprocess.run", fake_run)

    entry = _make_entry(
        host="${HOST_OK}",
        env={"STMC_JOBS_DB": "${DB_PATH}"},
    )
    result = _run_ssh(entry, {}, entry.meta.transport)
    assert "missing env" not in result.stderr
    # The argv passed to ssh contains the resolved value, not the literal token.
    argv_str = " ".join(captured["cmd"])
    assert "STMC_JOBS_DB=/tmp/test_db.sqlite" in argv_str
    assert "${DB_PATH}" not in argv_str
