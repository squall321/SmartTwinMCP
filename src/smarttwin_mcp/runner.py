"""Transport layer — actually executes a ToolEntry against a target.

Contract with every script:
  * Arguments arrive as JSON on stdin AND in the env var STMC_ARGS_JSON.
    Scripts may pick whichever is convenient (bash with `jq`, python with stdin, etc.).
  * Exit code 0 = success. Non-zero is surfaced to the caller.
  * stdout is the result payload (preferred: JSON; falls back to text).
  * stderr is captured separately and returned for diagnostics.

This keeps script.sh portable across local/ssh, and matches HTTP body templating
through the same JSON envelope (rendered via str.format_map for body_template).
"""
from __future__ import annotations

import json
import logging
import os
import shlex
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .spec import HttpTransport, LocalTransport, SshTransport, ToolEntry

logger = logging.getLogger(__name__)


@dataclass
class RunResult:
    ok: bool
    exit_code: int | None
    stdout: str
    stderr: str
    parsed: Any | None  # JSON-parsed stdout if it looked like JSON
    transport: str
    command: str        # what we actually invoked (sanitized, no secrets)

    def to_dict(self) -> dict:
        return {
            "ok": self.ok,
            "exit_code": self.exit_code,
            "stdout": self.stdout,
            "stderr": self.stderr,
            "result": self.parsed,
            "transport": self.transport,
            "command": self.command,
        }


def _try_parse_json(s: str) -> Any | None:
    s = s.strip()
    if not s or s[0] not in "{[":
        return None
    try:
        return json.loads(s)
    except json.JSONDecodeError:
        return None


def _run_local(entry: ToolEntry, args: dict, t: LocalTransport) -> RunResult:
    args_json = json.dumps(args, ensure_ascii=False)
    env = {**os.environ, **t.env, "STMC_ARGS_JSON": args_json}
    cmd = [t.shell, str(entry.script_path)]
    try:
        proc = subprocess.run(
            cmd,
            input=args_json,
            capture_output=True,
            text=True,
            timeout=t.timeout_sec,
            cwd=t.cwd,
            env=env,
            check=False,
        )
    except subprocess.TimeoutExpired as e:
        return RunResult(
            ok=False,
            exit_code=None,
            stdout=e.stdout or "",
            stderr=f"timeout after {t.timeout_sec}s",
            parsed=None,
            transport="local",
            command=shlex.join(cmd),
        )
    return RunResult(
        ok=proc.returncode == 0,
        exit_code=proc.returncode,
        stdout=proc.stdout,
        stderr=proc.stderr,
        parsed=_try_parse_json(proc.stdout),
        transport="local",
        command=shlex.join(cmd),
    )


def _run_ssh(entry: ToolEntry, args: dict, t: SshTransport) -> RunResult:
    """Pipe script.sh over ssh stdin; pass args via env exported on the remote.

    We don't upload the script to a persistent path — each invocation is hermetic.
    """
    args_json = json.dumps(args, ensure_ascii=False)
    target = f"{t.user}@{t.host}" if t.user else t.host
    env_exports = " ".join(
        f"{k}={shlex.quote(v)}" for k, v in t.env.items()
    )
    args_export = f"STMC_ARGS_JSON={shlex.quote(args_json)}"
    cd = f"cd {shlex.quote(t.remote_cwd)} && " if t.remote_cwd else ""
    # The remote shell reads the script body from stdin (bash -s).
    remote_cmd = f"{cd}{args_export} {env_exports} bash -s"
    ssh_cmd = ["ssh", "-p", str(t.port)]
    if t.key_path:
        ssh_cmd += ["-i", t.key_path]
    ssh_cmd += ["-o", "BatchMode=yes", target, remote_cmd]

    try:
        with entry.script_path.open("rb") as f:
            script_body = f.read()
        proc = subprocess.run(
            ssh_cmd,
            input=script_body,
            capture_output=True,
            timeout=t.timeout_sec,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return RunResult(
            ok=False, exit_code=None, stdout="",
            stderr=f"ssh timeout after {t.timeout_sec}s",
            parsed=None, transport="ssh", command=shlex.join(ssh_cmd),
        )
    stdout = proc.stdout.decode("utf-8", errors="replace")
    stderr = proc.stderr.decode("utf-8", errors="replace")
    return RunResult(
        ok=proc.returncode == 0,
        exit_code=proc.returncode,
        stdout=stdout,
        stderr=stderr,
        parsed=_try_parse_json(stdout),
        transport="ssh",
        command=shlex.join(ssh_cmd),
    )


def _run_http(entry: ToolEntry, args: dict, t: HttpTransport) -> RunResult:
    """Send args as the request body. body_template, if set, is formatted with args.

    We use urllib to avoid a hard runtime dep on httpx for the minimal case.
    """
    import urllib.request
    import urllib.error

    if t.body_template:
        try:
            body_str = t.body_template.format_map(_SafeArgs(args))
        except KeyError as e:
            return RunResult(
                ok=False, exit_code=None, stdout="",
                stderr=f"body_template references missing arg {e}",
                parsed=None, transport="http", command=f"{t.method} {t.url}",
            )
        body_bytes = body_str.encode("utf-8")
    else:
        body_bytes = json.dumps(args).encode("utf-8")

    headers = {"Content-Type": "application/json", **t.headers}
    req = urllib.request.Request(t.url, data=body_bytes, headers=headers, method=t.method)
    try:
        with urllib.request.urlopen(req, timeout=t.timeout_sec) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return RunResult(
                ok=200 <= resp.status < 300,
                exit_code=resp.status,
                stdout=raw,
                stderr="",
                parsed=_try_parse_json(raw),
                transport="http",
                command=f"{t.method} {t.url}",
            )
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace") if e.fp else ""
        return RunResult(
            ok=False, exit_code=e.code, stdout=body, stderr=str(e),
            parsed=_try_parse_json(body), transport="http",
            command=f"{t.method} {t.url}",
        )
    except (urllib.error.URLError, TimeoutError) as e:
        return RunResult(
            ok=False, exit_code=None, stdout="", stderr=str(e),
            parsed=None, transport="http", command=f"{t.method} {t.url}",
        )


class _SafeArgs(dict):
    """str.format_map helper — leaves unknown keys as-is in JSON-safe form."""
    def __missing__(self, key: str):
        raise KeyError(key)


def run(entry: ToolEntry, args: dict) -> RunResult:
    t = entry.meta.transport
    if isinstance(t, LocalTransport):
        return _run_local(entry, args, t)
    if isinstance(t, SshTransport):
        return _run_ssh(entry, args, t)
    if isinstance(t, HttpTransport):
        return _run_http(entry, args, t)
    raise RuntimeError(f"unknown transport: {t!r}")
