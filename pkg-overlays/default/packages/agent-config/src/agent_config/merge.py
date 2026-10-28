# SPDX-License-Identifier: MIT
"""Three-way merge of a declared fragment into a co-owned config document.

Each coding agent keeps its user configuration in a file the agent itself
rewrites at runtime: Claude Code saves permission answers and the model
into ``~/.claude/settings.json``, Codex records project trust and the
``/model`` choice in ``config.toml``, and OpenCode's ``mcp add`` writes
``opencode.json``. A store symlink would break all of that, so the
declared settings are merged into the live file instead.

The merge follows the rules of agent-sandbox's ``merge.py``:

- Only paths present in ``paths(base) | paths(new)`` are modified.
  ``base`` is the fragment this tool last applied (from the sidecar) and
  ``new`` is the fragment declared now. Everything else in the document
  passes through untouched, including keys the agent adds inside a table
  this tool also writes.
- Lists have set semantics: ``next = new + (current - base - new)``.
  Entries someone added by hand stay, after the declared ones; entries
  that were applied before and are no longer declared are removed.
- Scalars: the fragment is authoritative. A value the fragment drops is
  removed unless it was changed by hand since it was applied, in which
  case it stays and is reported.
- Tables recurse, and a table this tool leaves empty is removed.

Unlike ``merge.py``, the merge edits the document in place, so a TOML
document parsed by tomlkit keeps its comments and layout everywhere the
merge does not write, and a value that already equals the declared one
is not rewritten.
"""

from __future__ import annotations

from collections.abc import Mapping, MutableMapping
from typing import Any

_MISSING = object()


def plain(value: Any) -> Any:
    """The plain Python value of a parsed node: tomlkit items unwrap to
    dicts, lists and scalars, so they compare with the JSON fragments."""
    unwrap = getattr(value, "unwrap", None)
    return unwrap() if callable(unwrap) else value


class Report:
    """What a person should hear about after a merge."""

    def __init__(self) -> None:
        self.overridden: list[tuple[str, Any, Any]] = []
        self.preserved: list[tuple[str, Any]] = []
        self.adhoc: list[tuple[str, list[Any]]] = []

    def lines(self, name: str) -> list[str]:
        out = [
            f"{name}: replacing hand-edited {path} = {old!r} with the declared {new!r}"
            for path, old, new in self.overridden
        ]
        out += [
            f"{name}: keeping hand-edited {path} = {value!r}, which is no longer declared"
            for path, value in self.preserved
        ]
        out += [
            f"{name}: keeping entries added by hand to {path}: {entries!r}"
            for path, entries in self.adhoc
        ]
        return out


def _merge_table(
    current: MutableMapping[str, Any],
    base: Mapping[str, Any],
    new: Mapping[str, Any],
    path: str,
    report: Report,
) -> None:
    for key in sorted(base.keys() | new.keys()):
        b = base.get(key, _MISSING)
        n = new.get(key, _MISSING)
        c = current.get(key, _MISSING)
        child = f"{path}.{key}" if path else key
        if isinstance(b, dict) or isinstance(n, dict):
            if not isinstance(c, Mapping):
                current[key] = {}
            _merge_table(
                current[key],
                b if isinstance(b, dict) else {},
                n if isinstance(n, dict) else {},
                child,
                report,
            )
            if not plain(current[key]):
                del current[key]
        elif isinstance(b, list) or isinstance(n, list):
            cur = plain(c) if isinstance(plain(c), list) else []
            bas = b if isinstance(b, list) else []
            nxt = n if isinstance(n, list) else []
            adhoc = [x for x in cur if x not in bas and x not in nxt]
            if adhoc:
                report.adhoc.append((child, adhoc))
            merged = list(nxt) + adhoc
            if not merged:
                if c is not _MISSING:
                    del current[key]
            elif merged != cur or not isinstance(plain(c), list):
                current[key] = merged
        elif n is _MISSING:
            if c is _MISSING:
                continue
            if plain(c) == b:
                del current[key]
            else:
                report.preserved.append((child, plain(c)))
        else:
            if c is not _MISSING and plain(c) == n:
                continue
            if c is not _MISSING and plain(c) != b:
                report.overridden.append((child, plain(c), n))
            current[key] = n


def merge(
    current: MutableMapping[str, Any], base: Mapping[str, Any], new: Mapping[str, Any]
) -> Report:
    """Merge ``new`` into ``current`` in place, subtracting ``base``, the
    fragment applied last time."""
    report = Report()
    _merge_table(current, base, new, "", report)
    return report
