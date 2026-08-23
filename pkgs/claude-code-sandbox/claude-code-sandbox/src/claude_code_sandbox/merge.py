# SPDX-License-Identifier: LGPL-3.0-or-later
"""Three-way merge for co-owned Claude Code settings files.

The tool co-owns ``.claude/settings.local.json`` with Claude Code itself:
Claude's interactive flows write keys like ``permissions`` and parts of the
``sandbox`` subtree, humans may hand-add entries anywhere, and this tool
applies profile fragments. The merge therefore operates over a strictly
bounded domain and copies everything else through untouched.

Domain invariant: only paths present in ``paths(base) | paths(new)`` are
ever modified. ``base`` is the blob this tool last applied (from the
sidecar); ``new`` is the profile fragment being applied now. Keys owned by
Claude Code or added by hand outside that domain are never visited, so the
merge stays correct as Claude Code grows new keys — including new keys
*inside* subtrees this tool also writes to (co-ownership is interleaved at
path level, not partitioned at top level).

Per-node rules:

- Lists: set semantics. ``next = new + (current - base - new)`` — entries
  the fragment carries come first in fragment order, then ad-hoc entries
  someone added by hand (present in current but never applied by us),
  preserved in their current order. Entries that were in ``base`` but are
  not in ``new`` are removed: the fragment is authoritative for its own
  membership, so hand-*removals* of fragment entries do not persist while
  hand-*additions* do.
- Scalars: the fragment is authoritative. When the fragment drops a
  scalar, a locally drifted value (``current != base``) is preserved like
  an ad-hoc addition and reported; an undrifted one is removed. When the
  fragment sets it, a drifted current value is overridden and reported.
- Dicts: recurse; keys that end up empty and are not asserted by ``new``
  are pruned.
"""

from __future__ import annotations

from typing import Any

_MISSING = object()


class Report:
    """Collects human-relevant merge observations."""

    def __init__(self) -> None:
        self.overridden_scalars: list[tuple[str, Any, Any]] = []
        self.preserved_drift: list[tuple[str, Any]] = []
        self.adhoc_entries: list[tuple[str, list[Any]]] = []

    def has_findings(self) -> bool:
        return bool(self.overridden_scalars or self.preserved_drift or self.adhoc_entries)


def _is_dict(*values: Any) -> bool:
    return any(isinstance(v, dict) for v in values if v is not _MISSING)


def _is_list(*values: Any) -> bool:
    return any(isinstance(v, list) for v in values if v is not _MISSING)


def _merge_list(
    current: Any, base: Any, new: Any, path: str, report: Report
) -> list[Any]:
    cur = current if isinstance(current, list) else []
    bas = base if isinstance(base, list) else []
    nxt = new if isinstance(new, list) else []
    adhoc = [x for x in cur if x not in bas and x not in nxt]
    if adhoc:
        report.adhoc_entries.append((path, adhoc))
    return list(nxt) + adhoc


def _merge_node(
    current: Any, base: Any, new: Any, path: str, report: Report
) -> dict[str, Any]:
    """Merge one dict level. ``current`` is the whole current subtree
    (co-owned); ``base``/``new`` are the tool blobs bounding the domain."""
    cur: dict[str, Any] = current if isinstance(current, dict) else {}
    bas: dict[str, Any] = base if isinstance(base, dict) else {}
    nxt: dict[str, Any] = new if isinstance(new, dict) else {}
    result = dict(cur)  # foreign keys pass through untouched
    for key in sorted(bas.keys() | nxt.keys()):
        b = bas.get(key, _MISSING)
        n = nxt.get(key, _MISSING)
        c = cur.get(key, _MISSING)
        child_path = f"{path}.{key}" if path else key
        if _is_dict(b, n):
            sub = _merge_node(
                c if isinstance(c, dict) else {},
                b if isinstance(b, dict) else {},
                n if isinstance(n, dict) else {},
                child_path,
                report,
            )
            if sub or isinstance(n, dict):
                if sub:
                    result[key] = sub
                else:
                    result.pop(key, None)
            else:
                result.pop(key, None)
        elif _is_list(b, n):
            merged = _merge_list(c, b, n, child_path, report)
            if merged:
                result[key] = merged
            else:
                result.pop(key, None)
        else:
            # Scalar (or null) in the tool domain.
            if n is _MISSING:
                # Fragment dropped this key.
                if c is _MISSING or c == b:
                    result.pop(key, None)
                else:
                    # Local drift: preserve like an ad-hoc addition.
                    report.preserved_drift.append((child_path, c))
            else:
                if c is not _MISSING and c != n and c != b:
                    report.overridden_scalars.append((child_path, c, n))
                result[key] = n
    return result


def merge(
    current: dict[str, Any],
    base: dict[str, Any],
    new: dict[str, Any],
) -> tuple[dict[str, Any], Report]:
    """Merge the profile fragment ``new`` into the co-owned settings dict
    ``current``, subtracting the previously applied blob ``base``.

    Returns the next settings dict and a report of observations. The input
    dicts are not mutated.
    """
    report = Report()
    return _merge_node(current, base, new, "", report), report


def adhoc_additions(
    current: dict[str, Any], applied: dict[str, Any]
) -> list[tuple[str, list[Any]]]:
    """List-entry additions present in ``current`` but not in the applied
    blob, within the applied blob's domain. Used by ``status``/``scan``."""
    findings: list[tuple[str, list[Any]]] = []

    def walk(cur: Any, app: Any, path: str) -> None:
        if isinstance(app, dict):
            cur_d = cur if isinstance(cur, dict) else {}
            for key, app_v in app.items():
                walk(cur_d.get(key), app_v, f"{path}.{key}" if path else key)
        elif isinstance(app, list):
            cur_l = cur if isinstance(cur, list) else []
            extras = [x for x in cur_l if x not in app]
            if extras:
                findings.append((path, extras))

    walk(current, applied, "")
    return findings
