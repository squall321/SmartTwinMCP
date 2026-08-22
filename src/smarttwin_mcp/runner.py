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
import re
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
    # env 값의 ${VAR}/${VAR:-default} 를 프로세스 env 로 확장한다 — ssh 트랜스포트와 동일.
    # 이걸 안 하면 meta 의 ${STMC_SLURM_SSH:-} 가 리터럴 그대로 들어가 스크립트 분기가 깨진다.
    rendered = {}
    for k, v in t.env.items():
        rendered[k], _ = _interpolate_env(v, os.environ)
    env = {**os.environ, **rendered, "STMC_ARGS_JSON": args_json}
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

    Supports ${VAR} and ${VAR:-default} interpolation in host, user, key_path,
    remote_cwd, and env values, sourced from the process environment. Missing
    required env vars cause a clean failure before any network attempt
    (matches _run_http semantics — see §15.3 / §22.3 of AGENT_GUIDE.md).

    We don't upload the script to a persistent path — each invocation is hermetic.
    """
    proc_env = os.environ

    rendered_host, miss_host = _interpolate_env(t.host, proc_env)
    # ⚠ 배포 이식성의 링치핀. host 가 비면(예: ${STMC_SLURM_SSH:-} 미설정) slurm 이 이 머신에
    # 로컬로 있다는 뜻이므로 로컬 실행으로 위임한다. dev(같은 컴에 slurm)와 cae00(ssh stc 로
    # 헤드노드)을 **같은 도구·같은 스크립트**로 돌리는 방법 — 도구 meta 는 ssh 로 두고
    # STMC_SLURM_SSH 하나로 전환한다(빈값=로컬, "stc"=원격). ssh config 별칭이 user/key/port 를
    # 채우므로 도구에 그것들을 하드코딩하지 않는다.
    if not rendered_host.strip():
        local = LocalTransport(env=dict(t.env), timeout_sec=t.timeout_sec,
                               cwd=t.remote_cwd or None)
        return _run_local(entry, args, local)
    rendered_user, miss_user = _interpolate_env(t.user, proc_env) if t.user else ("", [])
    rendered_key, miss_key = _interpolate_env(t.key_path, proc_env) if t.key_path else ("", [])
    rendered_cwd, miss_cwd = _interpolate_env(t.remote_cwd, proc_env) if t.remote_cwd else ("", [])
    rendered_env: dict[str, str] = {}
    miss_envv: list[str] = []
    for k, v in t.env.items():
        rv, m = _interpolate_env(v, proc_env)
        rendered_env[k] = rv
        miss_envv.extend(m)

    missing = sorted(set(miss_host + miss_user + miss_key + miss_cwd + miss_envv))
    sanitized_target = f"{rendered_user}@{rendered_host}" if rendered_user else rendered_host
    sanitized_cmd = f"ssh -p {t.port} {sanitized_target}"

    if missing:
        return RunResult(
            ok=False, exit_code=None, stdout="",
            stderr=f"missing env vars: {', '.join(missing)}",
            parsed=None, transport="ssh", command=sanitized_cmd,
        )

    args_json = json.dumps(args, ensure_ascii=False)
    target = sanitized_target
    env_exports = " ".join(
        f"{k}={shlex.quote(v)}" for k, v in rendered_env.items()
    )
    args_export = f"STMC_ARGS_JSON={shlex.quote(args_json)}"
    cd = f"cd {shlex.quote(rendered_cwd)} && " if rendered_cwd else ""
    # The remote shell reads the script body from stdin (bash -s).
    remote_cmd = f"{cd}{args_export} {env_exports} bash -s"
    ssh_cmd = ["ssh", "-p", str(t.port)]
    if rendered_key:
        ssh_cmd += ["-i", rendered_key]
    ssh_cmd += [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",       # fail fast on unreachable hosts
        "-o", "StrictHostKeyChecking=accept-new",
        target, remote_cmd,
    ]

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


_ENV_TOKEN = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)(?::-([^}]*))?\}")


def _interpolate_env(s: str, env: dict[str, str]) -> tuple[str, list[str]]:
    """Replace ${VAR} and ${VAR:-default}. Returns (rendered, missing_vars).

    Missing vars (no default given) are left in the string so the caller can
    decide what to do — we don't silently emit empty strings into a URL.
    """
    missing: list[str] = []

    def sub(m: re.Match) -> str:
        name = m.group(1)
        default = m.group(2)
        if name in env:
            return env[name]
        if default is not None:
            return default
        missing.append(name)
        return m.group(0)  # leave the literal ${VAR} so the caller sees it

    return _ENV_TOKEN.sub(sub, s), missing


def _run_http(entry: ToolEntry, args: dict, t: HttpTransport) -> RunResult:
    """Send args as the request body. body_template, if set, is formatted with args.

    Supports ${VAR} and ${VAR:-default} interpolation in url, headers, and
    body_template, sourced from the process environment. Missing required env
    vars cause a clean failure before any network request fires.

    We use urllib to avoid a hard runtime dep on httpx for the minimal case.
    """
    import urllib.request
    import urllib.error

    env = os.environ

    url, miss_url = _interpolate_env(t.url, env)
    rendered_headers: dict[str, str] = {}
    miss_hdr: list[str] = []
    for k, v in t.headers.items():
        rv, m = _interpolate_env(v, env)
        rendered_headers[k] = rv
        miss_hdr.extend(m)

    missing = sorted(set(miss_url + miss_hdr))
    sanitized_cmd = f"{t.method} {url}"

    if missing:
        return RunResult(
            ok=False, exit_code=None, stdout="",
            stderr=f"missing env vars: {', '.join(missing)}",
            parsed=None, transport="http", command=sanitized_cmd,
        )

    body_bytes: bytes | None
    if t.body_template:
        rendered_template, miss_body = _interpolate_env(t.body_template, env)
        if miss_body:
            return RunResult(
                ok=False, exit_code=None, stdout="",
                stderr=f"missing env vars in body_template: {', '.join(sorted(set(miss_body)))}",
                parsed=None, transport="http", command=sanitized_cmd,
            )
        try:
            body_str = rendered_template.format_map(_SafeArgs(args))
        except KeyError as e:
            return RunResult(
                ok=False, exit_code=None, stdout="",
                stderr=f"body_template references missing arg {e}",
                parsed=None, transport="http", command=sanitized_cmd,
            )
        body_bytes = body_str.encode("utf-8")
    elif t.method in ("POST", "PUT", "PATCH"):
        body_bytes = json.dumps(args).encode("utf-8")
    else:
        body_bytes = None  # GET/DELETE: don't send a body, urllib gets upset

    headers = {"Accept": "application/json", **rendered_headers}
    if body_bytes is not None and "Content-Type" not in headers:
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=body_bytes, headers=headers, method=t.method)
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
                command=sanitized_cmd,
            )
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace") if e.fp else ""
        return RunResult(
            ok=False, exit_code=e.code, stdout=body, stderr=str(e),
            parsed=_try_parse_json(body), transport="http",
            command=sanitized_cmd,
        )
    except (urllib.error.URLError, TimeoutError) as e:
        return RunResult(
            ok=False, exit_code=None, stdout="", stderr=str(e),
            parsed=None, transport="http", command=sanitized_cmd,
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
