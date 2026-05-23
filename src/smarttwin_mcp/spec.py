"""Tool spec models — single source of truth for what a catalog entry looks like.

A tool lives at: tools/<name>/<version>/
  - script.sh            : the executable body (or template for ssh/http)
  - args.schema.json     : JSON Schema for the input arguments
  - meta.yaml            : everything else (transport, usage, examples, options)

`latest` is a symlink (or `default_version` in a sibling _index.yaml) pointing
to the canonical version. Aliased tools `<name>@<version>` are derived, not stored.
"""
from __future__ import annotations

from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, Field, ConfigDict


Transport = Literal["local", "ssh", "http"]


class LocalTransport(BaseModel):
    model_config = ConfigDict(extra="forbid")
    kind: Literal["local"] = "local"
    shell: str = "/bin/bash"
    cwd: str | None = None
    env: dict[str, str] = Field(default_factory=dict)
    timeout_sec: int = 600


class SshTransport(BaseModel):
    model_config = ConfigDict(extra="forbid")
    kind: Literal["ssh"] = "ssh"
    host: str
    user: str | None = None
    key_path: str | None = None
    port: int = 22
    remote_cwd: str | None = None
    env: dict[str, str] = Field(default_factory=dict)
    timeout_sec: int = 600


class HttpTransport(BaseModel):
    model_config = ConfigDict(extra="forbid")
    kind: Literal["http"] = "http"
    method: Literal["GET", "POST", "PUT", "DELETE", "PATCH"] = "POST"
    url: str
    headers: dict[str, str] = Field(default_factory=dict)
    body_template: str | None = None
    timeout_sec: int = 120


TransportSpec = LocalTransport | SshTransport | HttpTransport


class Example(BaseModel):
    model_config = ConfigDict(extra="forbid")
    title: str
    args: dict[str, Any]
    note: str | None = None


class ToolMeta(BaseModel):
    """Contents of meta.yaml."""
    model_config = ConfigDict(extra="forbid")

    name: str
    version: str
    summary: str = Field(description="One-line description for tool listings.")
    description: str = Field(
        default="",
        description="Multi-paragraph usage doc shown to LLMs via catalog_describe.",
    )
    tags: list[str] = Field(default_factory=list)
    transport: TransportSpec = Field(discriminator="kind")
    expose: Literal["catalog", "direct", "both"] = Field(
        default="catalog",
        description=(
            "catalog: only reachable via catalog_run (default, recommended for 100s of tools). "
            "direct: also registered as its own MCP tool. "
            "both: same as direct."
        ),
    )
    examples: list[Example] = Field(default_factory=list)
    deprecated: bool = False
    deprecation_note: str | None = None
    aliases: list[str] = Field(
        default_factory=list,
        description="Extra names this tool is reachable as (e.g. legacy names).",
    )


class ToolEntry(BaseModel):
    """Materialized tool, loaded from disk and ready to invoke."""
    model_config = ConfigDict(arbitrary_types_allowed=True, extra="forbid")

    meta: ToolMeta
    args_schema: dict[str, Any]
    script_path: Path
    spec_dir: Path
    is_latest: bool = False

    @property
    def name(self) -> str:
        return self.meta.name

    @property
    def version(self) -> str:
        return self.meta.version

    @property
    def qualified_name(self) -> str:
        """e.g. submit_job@1.0.0"""
        return f"{self.meta.name}@{self.meta.version}"
