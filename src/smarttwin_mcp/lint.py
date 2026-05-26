"""Catalog linter — automates AGENT_GUIDE.md §7 steps 1-5 + per-§ rule checks.

Run via the CLI: `smarttwin-mcp lint tools/`. Used by CI to gate PRs.

Findings have a stable `rule_id` so users can grep / filter / suppress per
team policy. Errors fail the lint; warnings are reported but don't.

Rules cover what a subagent typically gets wrong without reading the guide:
naming, exec bits, JSON Schema validity, example coverage, hard-coded URLs,
missing mode tags, etc.
"""
from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable, Literal

import jsonschema

from .catalog import Catalog, load_catalog
from .spec import HttpTransport, SshTransport, ToolEntry


Severity = Literal["error", "warning"]


@dataclass(frozen=True)
class Finding:
    severity: Severity
    rule_id: str
    tool: str | None     # qualified name, or None for catalog-wide findings
    message: str
    path: Path | None = None

    def format(self) -> str:
        loc = self.tool or "<catalog>"
        where = f" ({self.path})" if self.path else ""
        return f"{self.severity.upper():7s} [{self.rule_id}] {loc}: {self.message}{where}"


@dataclass
class LintReport:
    findings: list[Finding] = field(default_factory=list)
    tools_checked: int = 0

    @property
    def errors(self) -> list[Finding]:
        return [f for f in self.findings if f.severity == "error"]

    @property
    def warnings(self) -> list[Finding]:
        return [f for f in self.findings if f.severity == "warning"]

    def passed(self) -> bool:
        return not self.errors

    def render(self) -> str:
        lines: list[str] = []
        for f in self.findings:
            lines.append(f.format())
        lines.append("")
        lines.append(f"checked {self.tools_checked} tools — "
                     f"{len(self.errors)} error(s), {len(self.warnings)} warning(s)")
        if self.passed():
            lines.append("OK")
        else:
            lines.append("FAILED")
        return "\n".join(lines)


# ---- Rule helpers ----

_MODE_TAG_RE = re.compile(r"^mode-(own|own-shared|read-all)$")
_ENV_TOKEN_RE = re.compile(r"\$\{[A-Z_][A-Z0-9_]*(?::-[^}]*)?\}")
_PRIVATE_IP_RE = re.compile(r"^(192\.168|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.)")


_MUTATION_NAME_PREFIXES = (
    "submit_", "cancel_", "batch_cancel", "ack_", "job_stop", "job_rerun",
    "delete_", "update_", "create_", "enable_", "disable_",
)


def _is_mutation_tool(entry: ToolEntry) -> bool:
    """Heuristic: does this tool have side effects worth auditing (§25.3)?

    `mode-own` alone is NOT enough — own-scoped READS (list_audit_events,
    summarize_costs) also use mode-own and should not be flagged. The signal
    we want is "side-effect", approximated by either:
      - the tool name matches a known mutation prefix, OR
      - the schema has a `dry_run` arg (the guide reserves this for mutators).

    `mode-read-all` is authoritative — observability never mutates.
    """
    if "mode-read-all" in entry.meta.tags:
        return False
    if "dry_run" in (entry.args_schema.get("properties") or {}):
        return True
    return any(entry.name.startswith(p) for p in _MUTATION_NAME_PREFIXES)


def _has_mode_tag(entry: ToolEntry) -> bool:
    return any(_MODE_TAG_RE.match(t) for t in entry.meta.tags)


# ---- Rules ----
# Each rule is `Callable[[Catalog, list[ToolEntry]], Iterable[Finding]]`.


def rule_L001_catalog_issues(catalog: Catalog, _entries) -> Iterable[Finding]:
    """L001 — catalog must load with zero CatalogIssues."""
    for issue in catalog.issues:
        yield Finding(
            severity="error", rule_id="L001", tool=None,
            message=f"catalog issue: {issue.message}",
            path=issue.path,
        )


def rule_L010_name_version_match(_catalog, entries) -> Iterable[Finding]:
    """L010 — meta.name/version must match the folder names.
    catalog.py rejects mismatches outright (becomes L001), but we surface a
    separate finding so the author sees the specific file."""
    for entry in entries:
        version_dir = entry.spec_dir
        tool_dir = version_dir.parent
        if entry.meta.name != tool_dir.name:
            yield Finding(
                "error", "L010", entry.qualified_name,
                f"meta.name '{entry.meta.name}' != folder '{tool_dir.name}'",
                version_dir / "meta.yaml",
            )
        if entry.meta.version != version_dir.name:
            yield Finding(
                "error", "L010", entry.qualified_name,
                f"meta.version '{entry.meta.version}' != folder '{version_dir.name}'",
                version_dir / "meta.yaml",
            )


def rule_L011_latest_symlink(_catalog, entries) -> Iterable[Finding]:
    """L011 — latest symlink must exist and resolve. Loader falls back to
    semver ordering, but explicit `latest` is the convention (§5)."""
    seen: set[str] = set()
    for entry in entries:
        if entry.name in seen:
            continue
        seen.add(entry.name)
        latest = entry.spec_dir.parent / "latest"
        if not latest.exists():
            yield Finding(
                "warning", "L011", entry.name,
                "no `latest` symlink — semver fallback works but explicit is preferred (§5)",
                entry.spec_dir.parent,
            )
            continue
        if not latest.is_symlink():
            yield Finding(
                "error", "L011", entry.name,
                "`latest` is a regular file/dir, not a symlink",
                latest,
            )
            continue
        target = latest.resolve().name
        # The resolved target must be an existing version directory.
        if not (entry.spec_dir.parent / target).is_dir():
            yield Finding(
                "error", "L011", entry.name,
                f"`latest` points to '{target}' but no such version directory exists",
                latest,
            )


def rule_L012_script_exec_bit(_catalog, entries) -> Iterable[Finding]:
    """L012 — script.sh must have the user-exec bit set (§4.5)."""
    for entry in entries:
        if not os.access(entry.script_path, os.X_OK):
            yield Finding(
                "error", "L012", entry.qualified_name,
                "script.sh is not executable (run `chmod +x`)",
                entry.script_path,
            )


def rule_L020_schema_valid(_catalog, entries) -> Iterable[Finding]:
    """L020 — args.schema.json must be a valid Draft 2020-12 schema."""
    for entry in entries:
        try:
            jsonschema.Draft202012Validator.check_schema(entry.args_schema)
        except jsonschema.exceptions.SchemaError as e:
            yield Finding(
                "error", "L020", entry.qualified_name,
                f"args.schema.json is not a valid Draft 2020-12 schema: {e.message}",
                entry.spec_dir / "args.schema.json",
            )


def rule_L021_additional_properties(_catalog, entries) -> Iterable[Finding]:
    """L021 — `additionalProperties: false` is mandatory (§3.2)."""
    for entry in entries:
        if entry.args_schema.get("type") != "object":
            continue
        if entry.args_schema.get("additionalProperties") is not False:
            yield Finding(
                "error", "L021", entry.qualified_name,
                "args.schema.json must set `additionalProperties: false` (§3.2)",
                entry.spec_dir / "args.schema.json",
            )


def rule_L022_property_descriptions(_catalog, entries) -> Iterable[Finding]:
    """L022 — every schema property must have a `description` (§3.2)."""
    for entry in entries:
        for pname, pdef in (entry.args_schema.get("properties") or {}).items():
            if isinstance(pdef, dict) and not pdef.get("description"):
                yield Finding(
                    "warning", "L022", entry.qualified_name,
                    f"property `{pname}` has no description — LLM will guess values (§3.2)",
                    entry.spec_dir / "args.schema.json",
                )


def rule_L030_examples_present(_catalog, entries) -> Iterable[Finding]:
    """L030 — at least one example, unless the tool is genuinely zero-arg (§2.5)."""
    for entry in entries:
        props = entry.args_schema.get("properties") or {}
        required = entry.args_schema.get("required") or []
        is_zero_arg = not props or (not required and not props)
        n = len(entry.meta.examples)
        if n == 0:
            severity = "warning" if is_zero_arg else "error"
            yield Finding(
                severity, "L030", entry.qualified_name,
                f"meta.yaml has no `examples` (§2.5{' — zero-arg exception applies' if is_zero_arg else ''})",
                entry.spec_dir / "meta.yaml",
            )
        elif n < 2 and not is_zero_arg:
            yield Finding(
                "warning", "L030", entry.qualified_name,
                f"only {n} example(s); guide recommends >=2 unless zero-arg (§2.5)",
                entry.spec_dir / "meta.yaml",
            )


def rule_L031_examples_validate(_catalog, entries) -> Iterable[Finding]:
    """L031 — every example must validate against args.schema.json (§2.5)."""
    for entry in entries:
        for i, ex in enumerate(entry.meta.examples):
            try:
                jsonschema.validate(ex.args, entry.args_schema)
            except jsonschema.exceptions.ValidationError as e:
                yield Finding(
                    "error", "L031", entry.qualified_name,
                    f"example #{i} ({ex.title!r}) fails schema: {e.message}",
                    entry.spec_dir / "meta.yaml",
                )


def rule_L040_expose_value(_catalog, entries) -> Iterable[Finding]:
    """L040 — expose must be one of the allowed values; warn when many tools
    default to 'direct' (§2.3 — keeps the LLM tool list manageable)."""
    direct_count = 0
    for entry in entries:
        if entry.meta.expose in ("direct", "both"):
            direct_count += 1
    # >30 direct-exposed is the §2.3 "weak LLMs lose track" threshold.
    if direct_count > 30:
        yield Finding(
            "warning", "L040", None,
            f"{direct_count} tools have expose: direct (§2.3 says weak LLMs "
            f"lose track past ~30-50; consider flipping less-used tools to catalog)",
            None,
        )


def rule_L050_mode_tag(_catalog, entries) -> Iterable[Finding]:
    """L050 — mutation tools should declare a mode tag (§18.2)."""
    for entry in entries:
        if not _is_mutation_tool(entry):
            continue
        if not _has_mode_tag(entry):
            yield Finding(
                "warning", "L050", entry.qualified_name,
                "mutation tool has no `mode-*` tag (§18.2) — "
                "add `mode-own` to tags so the multi-tenant contract is machine-checkable",
                entry.spec_dir / "meta.yaml",
            )


def rule_L060_no_hardcoded_endpoint(_catalog, entries) -> Iterable[Finding]:
    """L060 — http/ssh transports must use ${VAR} interpolation, not raw
    hostnames/URLs/secrets (§15.3, §22.3)."""
    for entry in entries:
        t = entry.meta.transport
        if isinstance(t, HttpTransport):
            if not _ENV_TOKEN_RE.search(t.url) and not t.url.startswith("http://localhost"):
                yield Finding(
                    "warning", "L060", entry.qualified_name,
                    f"http transport URL has no ${{VAR}} interpolation: {t.url!r} "
                    f"(§15.3 — site-locked tools are hard to share)",
                    entry.spec_dir / "meta.yaml",
                )
            for hk, hv in t.headers.items():
                if hk.lower() == "authorization" and not _ENV_TOKEN_RE.search(hv):
                    yield Finding(
                        "error", "L060", entry.qualified_name,
                        f"Authorization header has no ${{VAR}} — looks like a hard-coded token "
                        f"(§15.3 anti-pattern: 'Hard-code tokens in meta.yaml')",
                        entry.spec_dir / "meta.yaml",
                    )
        elif isinstance(t, SshTransport):
            if not _ENV_TOKEN_RE.search(t.host) and not _PRIVATE_IP_RE.match(t.host):
                yield Finding(
                    "warning", "L060", entry.qualified_name,
                    f"ssh host has no ${{VAR}} interpolation: {t.host!r} (§22.3 anti-pattern)",
                    entry.spec_dir / "meta.yaml",
                )


_AUDIT_CALL_RE = re.compile(r"\b(audit\.)?record_event\s*\(")


def rule_L070_audit_wire(_catalog, entries) -> Iterable[Finding]:
    """L070 — mutation tools must call audit.record_event (§25.3).

    Heuristic: any tool flagged as a mutation by _is_mutation_tool() should
    have at least one occurrence of `record_event(...)` somewhere in its
    script.sh. False positives are possible when a tool legitimately uses
    a different audit pathway — wire those by tagging `mode-read-all` or
    by suppressing L070 explicitly via --disable.
    """
    for entry in entries:
        if not _is_mutation_tool(entry):
            continue
        try:
            body = entry.script_path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if not _AUDIT_CALL_RE.search(body):
            yield Finding(
                "warning", "L070", entry.qualified_name,
                "mutation tool does not call audit.record_event (§25.3) — "
                "every successful submit/cancel/ack must write one audit row",
                entry.script_path,
            )


# Registry — keep ordered so output is deterministic.
ALL_RULES: list[tuple[str, Callable]] = [
    ("L001", rule_L001_catalog_issues),
    ("L010", rule_L010_name_version_match),
    ("L011", rule_L011_latest_symlink),
    ("L012", rule_L012_script_exec_bit),
    ("L020", rule_L020_schema_valid),
    ("L021", rule_L021_additional_properties),
    ("L022", rule_L022_property_descriptions),
    ("L030", rule_L030_examples_present),
    ("L031", rule_L031_examples_validate),
    ("L040", rule_L040_expose_value),
    ("L050", rule_L050_mode_tag),
    ("L060", rule_L060_no_hardcoded_endpoint),
    ("L070", rule_L070_audit_wire),
]


def lint(tools_root: Path, disable: set[str] | None = None) -> LintReport:
    """Load the catalog and run every rule. Returns a LintReport.

    `disable` is a set of rule IDs to skip (e.g. for tools that legitimately
    need an exception — though §-rule violations should be argued in PR review,
    not muted by default).
    """
    disable = disable or set()
    catalog = load_catalog(tools_root)
    entries = [e for e in catalog.all_entries() if e.is_latest]
    report = LintReport(tools_checked=len(entries))
    for rule_id, rule_fn in ALL_RULES:
        if rule_id in disable:
            continue
        for finding in rule_fn(catalog, entries):
            report.findings.append(finding)
    # Stable ordering: by severity (error first), then rule_id, then tool name.
    severity_order = {"error": 0, "warning": 1}
    report.findings.sort(key=lambda f: (severity_order[f.severity], f.rule_id, f.tool or ""))
    return report
