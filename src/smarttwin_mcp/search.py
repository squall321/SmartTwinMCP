"""Tiny lexical search over tool name/summary/tags/description.

No external deps. For hundreds of tools this is plenty fast and gives the LLM
a way to find what it needs without listing everything.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

from .spec import ToolEntry


_TOK = re.compile(r"[a-z0-9_]+")


def _tokens(s: str) -> list[str]:
    return _TOK.findall(s.lower())


@dataclass
class SearchHit:
    name: str
    version: str
    summary: str
    score: float
    tags: list[str]

    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "version": self.version,
            "summary": self.summary,
            "score": round(self.score, 3),
            "tags": self.tags,
        }


def _score(entry: ToolEntry, q_tokens: list[str]) -> float:
    if not q_tokens:
        return 0.0
    haystacks = {
        "name": (entry.name, 5.0),
        "tags": (" ".join(entry.meta.tags), 3.0),
        "summary": (entry.meta.summary, 2.0),
        "description": (entry.meta.description, 1.0),
    }
    score = 0.0
    for field_text, weight in haystacks.values():
        toks = set(_tokens(field_text))
        score += weight * sum(1 for t in q_tokens if t in toks)
    if entry.meta.deprecated:
        score *= 0.3
    return score


def search(entries: list[ToolEntry], query: str, limit: int = 20) -> list[SearchHit]:
    q_tokens = _tokens(query)
    if not q_tokens:
        # Empty query → return latest of each tool, ranked alphabetically.
        return [
            SearchHit(
                name=e.name, version=e.version, summary=e.meta.summary,
                score=0.0, tags=e.meta.tags,
            )
            for e in sorted(entries, key=lambda e: e.name)
            if e.is_latest
        ][:limit]

    scored = [(e, _score(e, q_tokens)) for e in entries if e.is_latest]
    scored = [(e, s) for e, s in scored if s > 0]
    scored.sort(key=lambda x: (-x[1], x[0].name))
    return [
        SearchHit(
            name=e.name, version=e.version, summary=e.meta.summary,
            score=s, tags=e.meta.tags,
        )
        for e, s in scored[:limit]
    ]
