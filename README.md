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
  profile's toolset is the executable world, exact to the store hash.
- An `env.PATH` pointing at the profile's bin farm by exact store
  path (each checkout sees one consistent world: new after sync,
  old-but-working when a sync hasn't reached it yet), and
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
| `scan DIR` | Same, for every checkout under the given directory |
| `sync` | Re-apply the bound profile after a profile change |
| `materialize NAME` | Clone and enroll a registry-declared project |

The CLI is on every profile's PATH, so a sandboxed agent can run
`claude-code-sandbox status` to verify its own enrollment. Inside a
masked profile the registry and fragments (store symlinks) are
unreadable, so status there reports the profile and settings integrity
with freshness marked unknown rather than guessing.

Profiles regenerate at every home-manager switch; enrolled checkouts
converge at point of use — the session-start hook heals staleness in
the session it fires in, and an unhealed checkout keeps running its
previous closure consistently. No enumeration of enrollments exists
anywhere, so nothing breaks when folders move. Claude Code
live-reloads settings files, so synced rules generally reach running
sessions.

## Module sketch

```nix
{
  claude-code-sandbox = {
    enable = true;
    runtime.claudePackage = pkgs.claude-code;
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
and an advisory session-start hook (staleness/integrity tripwire with
auto-sync); the design is correct without it.

## Boundaries worth knowing

- Only Bash commands are OS-sandboxed by Claude Code; file tools and
  MCP servers are gated by its permission system. The module's baseline
  guards the settings files at both layers.
- Background-job scratch: Claude Code tells background jobs to write
  under `$CLAUDE_JOB_DIR/tmp`, which sits under `~/.claude` — kept
  write-protected inside the sandbox regardless of grants — and no
  static `allowWrite` can name a per-job path. Every fragment therefore
  grants a durable scratch root, `$XDG_STATE_HOME/claude-code-sandbox/jobs`,
  and the plugin's session-start hook replaces the job's `tmp` with a
  symlink to a per-job directory beneath it (same lifetime as the job,
  on home storage; scratch of vanished jobs is pruned). Isolation
  matches the session temp dir's: a shared root, per-job subdirectories.
- Unix sockets: upstream's Linux seccomp filter is all-or-nothing, so a
  profile's `allowUnixSockets` list is made real by opening that filter
  and pinning the profile's SHELL to a Landlock wrapper
  (`landlock-unix-shim`) that narrows `connect()` back to the declared
  paths. Requires Landlock ABI 9 (kernel 7.1+); older kernels fail
  closed. `allowAllUnixSockets = true` skips the narrowing entirely.
  `allowNix` grants the nix daemon socket through this mechanism
  automatically.
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
