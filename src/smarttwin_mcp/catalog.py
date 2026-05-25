"""Catalog — discovers tools on disk and resolves versions.

Layout:
    tools/
      <name>/
        <version>/
          script.sh
          args.schema.json
          meta.yaml
        latest -> <version>            # symlink (preferred), OR
        _index.yaml                    # { default_version: <version> }

Version ordering: PEP 440-ish via `packaging.version`, falling back to string compare.
"""
from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

import yaml
from pydantic import ValidationError

from .spec import ToolEntry, ToolMeta

logger = logging.getLogger(__name__)

_SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$")


def _version_key(v: str) -> tuple:
    m = _SEMVER_RE.match(v)
    if m:
        return (1, int(m.group(1)), int(m.group(2)), int(m.group(3)), v)
    return (0, v)


@dataclass
class CatalogIssue:
    path: Path
    message: str


@dataclass
class Catalog:
    """In-memory index of all tools, keyed by qualified and short names."""
    root: Path
    by_qualified: dict[str, ToolEntry] = field(default_factory=dict)   # "name@version"
    latest_by_name: dict[str, ToolEntry] = field(default_factory=dict) # "name" -> latest
    versions_by_name: dict[str, list[str]] = field(default_factory=dict)
    aliases: dict[str, ToolEntry] = field(default_factory=dict)        # alias -> entry
    issues: list[CatalogIssue] = field(default_factory=list)

    def all_entries(self) -> list[ToolEntry]:
        return list(self.by_qualified.values())

    def resolve(self, identifier: str) -> ToolEntry | None:
        """Resolve any of: 'name', 'name@version', alias name."""
        if "@" in identifier:
            return self.by_qualified.get(identifier)
        if identifier in self.latest_by_name:
            return self.latest_by_name[identifier]
        return self.aliases.get(identifier)


def _load_yaml(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a YAML mapping at the top level")
    return data


def _load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a JSON object at the top level")
    return data


def _load_one_version(name: str, version_dir: Path, issues: list[CatalogIssue]) -> ToolEntry | None:
    meta_path = version_dir / "meta.yaml"
    schema_path = version_dir / "args.schema.json"
    script_path = version_dir / "script.sh"

    for p in (meta_path, schema_path, script_path):
        if not p.exists():
            issues.append(CatalogIssue(version_dir, f"missing required file: {p.name}"))
            return None

    try:
        meta_raw = _load_yaml(meta_path)
        meta_raw.setdefault("name", name)
        meta_raw.setdefault("version", version_dir.name)
        meta = ToolMeta.model_validate(meta_raw)
    except (ValidationError, ValueError) as e:
        issues.append(CatalogIssue(meta_path, f"invalid meta.yaml: {e}"))
        return None

    if meta.name != name:
        issues.append(
            CatalogIssue(meta_path, f"meta.name '{meta.name}' != folder '{name}'")
        )
        return None
    if meta.version != version_dir.name:
        issues.append(
            CatalogIssue(meta_path, f"meta.version '{meta.version}' != folder '{version_dir.name}'")
        )
        return None

    try:
        schema = _load_json(schema_path)
    except (json.JSONDecodeError, ValueError) as e:
        issues.append(CatalogIssue(schema_path, f"invalid args.schema.json: {e}"))
        return None

    return ToolEntry(
        meta=meta,
        args_schema=schema,
        script_path=script_path,
        spec_dir=version_dir,
    )


def _resolve_latest(name: str, tool_dir: Path, versions: list[str], issues: list[CatalogIssue]) -> str | None:
    """Pick the canonical version. Priority: `latest` symlink, `_index.yaml`, highest semver."""
    if not versions:
        return None

    latest_link = tool_dir / "latest"
    if latest_link.is_symlink():
        target = latest_link.resolve().name
        if target in versions:
            return target
        issues.append(CatalogIssue(latest_link, f"`latest` points to missing version '{target}'"))

    index_path = tool_dir / "_index.yaml"
    if index_path.exists():
        try:
            idx = _load_yaml(index_path)
            dv = idx.get("default_version")
            if dv in versions:
                return dv
            if dv:
                issues.append(CatalogIssue(index_path, f"default_version '{dv}' not found"))
        except ValueError as e:
            issues.append(CatalogIssue(index_path, str(e)))

    return sorted(versions, key=_version_key)[-1]


def _iter_tool_dirs(tools_root: Path) -> Iterable[Path]:
    if not tools_root.exists():
        return []
    for p in sorted(tools_root.iterdir()):
        if p.is_dir() and not p.name.startswith((".", "_")):
            yield p


def load_catalog(tools_root: Path) -> Catalog:
    """Scan tools_root and build the catalog index."""
    tools_root = tools_root.resolve()
    catalog = Catalog(root=tools_root)

    for tool_dir in _iter_tool_dirs(tools_root):
        name = tool_dir.name
        version_entries: dict[str, ToolEntry] = {}

        for vdir in tool_dir.iterdir():
            if not vdir.is_dir() or vdir.name.startswith(("_", ".")):
                continue
            if vdir.is_symlink():
                continue
            entry = _load_one_version(name, vdir, catalog.issues)
            if entry is not None:
                version_entries[entry.version] = entry

        if not version_entries:
            continue

        latest_v = _resolve_latest(name, tool_dir, list(version_entries.keys()), catalog.issues)

        for v, entry in version_entries.items():
            if v == latest_v:
                entry.is_latest = True
                catalog.latest_by_name[name] = entry
            catalog.by_qualified[entry.qualified_name] = entry

        catalog.versions_by_name[name] = sorted(version_entries.keys(), key=_version_key)

    # Second pass: register aliases AFTER all tool names are known, so we can
    # detect alias-vs-name shadowing and alias-vs-alias collisions in one place.
    for entry in catalog.latest_by_name.values():
        for alias in entry.meta.aliases:
            if alias == entry.name:
                continue  # self-alias is a no-op
            if alias in catalog.latest_by_name:
                catalog.issues.append(
                    CatalogIssue(
                        entry.spec_dir,
                        f"alias '{alias}' shadows existing tool '{alias}' — "
                        f"the tool wins on resolve(), the alias entry is ignored",
                    )
                )
                continue
            if alias in catalog.aliases:
                catalog.issues.append(
                    CatalogIssue(
                        entry.spec_dir,
                        f"alias '{alias}' collides with alias from "
                        f"'{catalog.aliases[alias].name}'",
                    )
                )
                continue
            catalog.aliases[alias] = entry

    logger.info(
        "loaded %d tools (%d versions, %d issues) from %s",
        len(catalog.latest_by_name),
        len(catalog.by_qualified),
        len(catalog.issues),
        tools_root,
    )
    return catalog
