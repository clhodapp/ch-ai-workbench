---
description: Enroll, retarget, or inspect this checkout's Claude Code sandbox profile (nix-declared toolset restriction). Use when asked to sandbox a repo, change or remove its sandbox profile, check sandbox status, or when sandbox rules in .claude/settings.local.json look stale or surprising.
---

# claude-code-sandbox ceremony

This machine declares Claude Code sandbox *profiles* (named toolsets
compiled to native sandbox rules) in home-manager. A checkout opts in by
*enrollment*, which binds it to a profile via two files in `.claude/`:
the co-owned `settings.local.json` (tool-owned `sandbox`/`env` keys merged
alongside Claude Code's own keys) and the sidecar
`claude-code-sandbox.json` (the binding and the last-applied blob).

All verbs are cwd-local unless noted. Run them with the Bash tool.

- `claude-code-sandbox status` — binding, staleness, local additions.
  Exit 2 means something needs attention; read the line it printed.
- `claude-code-sandbox enroll [--profile NAME]` — bind this checkout
  (default profile if none named). Requires the repo root; run from
  inside the checkout.
- `claude-code-sandbox retarget NAME` — rebind to another profile.
- `claude-code-sandbox abandon` — bind to the reserved empty profile
  `none` (deliberate opt-out that survives syncs; not a deletion).
- `claude-code-sandbox sync [--all]` — re-apply the bound profile after
  a profile edit; `--all` walks the scan roots.
- `claude-code-sandbox scan` — report every checkout under the scan
  roots.
- `claude-code-sandbox materialize NAME` — clone + enroll a project
  declared in the registry (network; user-invoked).

Facts that prevent wrong conclusions:

- Settings live-reload: rule changes reach the running session on file
  save. Exception: *removing* an `env` var takes effect next launch, so
  a just-abandoned checkout keeps the profile PATH until relaunch.
- Hand-*additions* inside tool-owned arrays persist across syncs and are
  reported by `status`/`scan` as local additions. Hand-*removals* do not
  persist — narrower wants mean a different profile, not an edit.
- Never edit the sidecar by hand, and never delete
  `settings.local.json` to "reset" — use `abandon`.
- Profiles are declared in home-manager (`claude-code-sandbox.profiles`);
  changing what a profile contains is a nix edit + switch, not a CLI verb.
