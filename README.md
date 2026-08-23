# claude-code-sandbox

Nix-authored per-project configuration for [Claude Code]'s native
sandbox. Declares named sandbox **profiles** — closed toolsets compiled
from Nix closures into native sandbox rules — and binds individual
checkouts to them by explicit **enrollment**, without placing anything
in shared repositories.

[Claude Code]: https://code.claude.com

## What it does

A profile is a Nix-declared set of packages. The home-manager module
compiles each profile into a settings fragment for Claude Code's
built-in sandbox:

- `denyRead ["/nix/store"]` plus exact per-path `allowRead` entries for
  the profile's closure. The mask is mount-level: store paths outside
  the closure are *nonexistent* inside sandboxed commands, so the
  profile's toolset is the executable world, cryptographically exact —
  no name patterns, no PATH-only hygiene.
- An `env.PATH` pointing at a stable per-profile bin farm, and
  `env.SHELL` pinned to the profile's bash.
- Fail-closed posture: `failIfUnavailable` so a sandbox that cannot
  initialize refuses commands instead of silently running them
  unsandboxed.

Enrolling a checkout (`claude-code-sandbox enroll`) merges the fragment
into the repo's own `.claude/settings.local.json` — a file co-owned
with Claude Code, which saves permission approvals there. The merge is
three-way with the last-applied blob as base and touches only the paths
it applied: Claude Code's keys, and anything added by hand outside the
applied set, pass through untouched. Hand-added entries inside managed
arrays persist across syncs and are reported as local additions.

## Verbs

| Verb | Effect |
|---|---|
| `enroll [--profile NAME]` | Bind this checkout to a profile |
| `retarget NAME` | Rebind to a different profile |
| `abandon` | Bind to the reserved empty profile `none` |
| `status` | This checkout's binding, staleness, local additions |
| `scan` | Same, for every checkout under the scan roots |
| `sync [--all]` | Re-apply the bound profile after a profile change |
| `materialize NAME` | Clone and enroll a registry-declared project |

Profiles regenerate at every home-manager switch, and the switch also
re-syncs enrolled checkouts under the scan roots, so converging the
system converges the sandboxes. Claude Code live-reloads settings
files, so synced rules generally reach running sessions.

## Module sketch

```nix
{
  claude-code-sandbox = {
    enable = true;
    claudePackage = pkgs.claude-code;
    profiles.default.toolset = [ pkgs.ripgrep pkgs.jq ];
    profiles.python-work = {
      toolset = [ pkgs.python3 pkgs.ruff pkgs.ripgrep ];
      allowedDomains = [ "pypi.org" ];
    };
    profiles.nix-full.allowNix = true;
  };
}
```

`default` exists even when empty and is augmentable: checkouts bound to
it track whatever it becomes. `none` is reserved and deliberately empty
forever. A skills-dir plugin ships alongside with an enrollment skill
and two advisory hooks (session-start staleness tripwire, config-change
co-ownership canary); the design is correct without them.

## Boundaries worth knowing

- Only Bash commands are OS-sandboxed by Claude Code; file tools and
  MCP servers are gated by its permission system. The module's baseline
  guards the settings files at both layers.
- On non-NixOS hosts the store mask governs the nix side only; system
  directories like `/usr/bin` remain. The closed-world property is a
  NixOS property.
- A profile containing `nix` (`allowNix`) necessarily leaves the store
  unmasked: an unmasked store makes every installed tool reachable.
- Fragment size is bounded (~128KB of rules rides the exec
  environment); the builder fails loudly past 100KB. Keep toolsets
  lean.

## Development

See `docs/development/` for testing and commands. `nix flake check`
builds the CLI (its unittest suite runs in the build) and the plugin;
`nix fmt` formats.
