---
description: Enroll this checkout into Claude Code sandbox modules (nix-declared toolsets and grants per kind of tooling), change which modules it uses, or inspect its sandbox status. Use when asked to sandbox a repo, add or remove a tool from its sandbox, remove its sandbox, check sandbox status, or when sandbox rules in .claude/settings.local.json look stale or surprising.
---

# claude-code-sandbox ceremony

This machine declares Claude Code sandbox *modules* in home-manager.
Each module says what one kind of tooling needs inside the sandbox: its
executables, domains, unix sockets and writable paths. A checkout opts
into the set of modules its work needs by *enrollment*, which composes
them into native sandbox rules through two files in `.claude/`: the
co-owned `settings.local.json` (tool-owned `sandbox`/`env` keys merged
alongside Claude Code's own keys) and the sidecar
`claude-code-sandbox.json` (the chosen modules and the last-applied
blob).

Run the verbs with the Bash tool. Each acts on the checkout containing
the current directory, or the checkout containing DIR with `-C DIR`.

- `claude-code-sandbox list`: the declared modules, with what each
  means, what each requires, and which ones every enrollment gets.
  Read it before choosing modules.
- `claude-code-sandbox status`: the chosen modules, staleness, local
  additions. Exit 2 means something needs attention; read the line it
  printed.
- `claude-code-sandbox enroll MODULE...`: bind this checkout to exactly
  these modules (plus the ones every enrollment gets and everything
  they require). With no modules, only the base toolset.
- `claude-code-sandbox add MODULE...` and `drop MODULE...`: change the
  set of an enrolled checkout. `add --for day` or `add --for week`
  chooses the modules until that deadline; a systemd user timer drops
  them when it passes. `add` without `--for` makes a choice permanent.
- `claude-code-sandbox abandon`: remove the sandbox fragment while the
  checkout stays managed (deliberate opt-out that survives syncs; not
  a deletion).
- `claude-code-sandbox sync`: drop expired modules and re-apply the
  chosen ones after a module edit.
- `claude-code-sandbox scan DIR`: report every checkout under the given
  directory (the invoker supplies the scope; nothing is assumed).
- `claude-code-sandbox show MODULE...`: what each module allows and its
  status in this checkout.
- `claude-code-sandbox decline MODULE... [--reason TEXT]` and
  `undecline MODULE...`: record or withdraw the user's refusal of a
  module for this checkout. Agents asking for a declined module are told
  of the refusal instead of prompting.

An agent working inside the sandbox uses the plugin's MCP tools instead
of these verbs (`list-modules`, `enabled-modules`, `describe-module`,
`declined-modules`, `request-module`): from inside the sandbox the
verbs cannot read the module parts or change the checkout's settings.
`request-module` prompts the user and enables the module only on the
user's answer.

Facts that prevent wrong conclusions:

- Choose modules from what the project's work uses (its build tool,
  language toolchain, forge), not from what would be convenient. A
  module with `allowNix` unmasks the store for the whole checkout, which
  `list` marks.
- A session reads its sandbox rules at launch. A change to the
  checkout's modules, including a module expiring, reaches a running
  session only after the user stops it with `/stop` and starts it
  again.
- Hand-*additions* inside tool-owned arrays persist across syncs and are
  reported by `status`/`scan` as local additions. Hand-*removals* do not
  persist; narrower wants mean a different set of modules, not an edit.
- A checkout bound to a *profile* predates sandbox modules. `status`
  reports it and `sync` refuses; enrolling it with modules replaces the
  old rules cleanly.
- Never edit the sidecar by hand, and never delete
  `settings.local.json` to "reset"; use `abandon`.
- Modules are declared in home-manager
  (`ch-ai-workbench.claude-code-sandbox.modules`); changing what a
  module contains is a nix edit and a switch, not a CLI verb.
