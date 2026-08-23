# Product

claude-code-sandbox turns Claude Code's built-in sandbox into a
per-project, Nix-declared mechanism: named profiles (closed toolsets
compiled from closures into native sandbox rules) that individual
checkouts opt into by explicit enrollment.

Principles the design settled on:

- **Enforcement belongs to Claude Code's sandbox**; Nix authors its
  configuration. No external sandbox, no process wrapper, no launcher.
- **Enrollment is the user's act.** Nothing is ambient: unenrolled
  repos get only the monotone baseline, and no file ever lands in a
  shared repository.
- **The checkout is self-describing.** The sidecar carries the binding
  and the last-applied blob; there is no central inventory to rot when
  folders move.
- **Co-ownership, not ownership.** `.claude/settings.local.json` is
  Claude Code's own writable state (permission saves, MCP consent, the
  /sandbox panel). The three-way merge touches only the paths it
  applied; everything else passes through, including foreign keys
  inside subtrees this tool also writes.
- **Fail closed, degrade loud.** `failIfUnavailable` in every
  fragment; staleness and drift are reported, never silently absorbed;
  hooks are advisory and the design is correct without them.

Boundaries: OS-level enforcement covers Bash commands only (file tools
and MCP servers are permission-gated by Claude Code); the closed-world
property of the store mask is a NixOS property; `allowNix` profiles
necessarily leave the store unmasked.
