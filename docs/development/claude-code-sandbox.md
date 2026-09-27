# claude-code-sandbox

Nix-authored per-project configuration for [Claude Code]'s native
sandbox. The `claude-code-sandbox` Home Manager module declares named
sandbox **profiles** (closed toolsets compiled from Nix closures into
native sandbox rules), and the `claude-code-sandbox` CLI binds
individual checkouts to them by explicit **enrollment**, without
placing anything in shared repositories.

[Claude Code]: https://code.claude.com

Where things live in this repository:

| Piece | Path |
|---|---|
| Home Manager module (`ch-ai-workbench.claude-code-sandbox.*`) | `modules/homeManager/claude-code-sandbox/default.nix` |
| CLI (Python, stdlib only) | `pkg-overlays/default/packages/claude-code-sandbox/` |
| Skills-dir plugin (enrollment skill, session-start hook) | `pkg-overlays/default/packages/claude-code-sandbox-plugin/` |
| Landlock shim (unix-socket narrowing) | `pkg-overlays/default/packages/landlock-shim/` |

## Principles

- **Enforcement belongs to Claude Code's sandbox**; Nix authors its
  configuration.
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

## What it does

A profile is a Nix-declared set of packages. The module compiles each
profile into a settings fragment for Claude Code's built-in sandbox:

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
into the repo's own `.claude/settings.local.json`, a file co-owned
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

The CLI is on every profile's PATH, so a sandboxed agent can run
`claude-code-sandbox status` to verify its own enrollment. Inside a
masked profile the registry and fragments (store symlinks) are
unreadable, so status there reports the profile and settings integrity
with freshness marked unknown rather than guessing.

Profiles regenerate at every home-manager switch; enrolled checkouts
converge at point of use: the session-start hook heals staleness in
the session it fires in, and an unhealed checkout keeps running its
previous closure consistently. No enumeration of enrollments exists
anywhere, so nothing breaks when folders move. Claude Code
live-reloads settings files, so synced rules generally reach running
sessions.

## Module sketch

```nix
{
  ch-ai-workbench.claude-code-sandbox = {
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
forever. The skills-dir plugin ships an enrollment skill and an
advisory session-start hook (staleness/integrity tripwire with
auto-sync); the design is correct without it.

## Boundaries worth knowing

- Only Bash commands are OS-sandboxed by Claude Code; file tools and
  MCP servers are gated by its permission system. The module's baseline
  guards the settings files at both layers.
- Background-job scratch: Claude Code tells background jobs to write
  under `$CLAUDE_JOB_DIR/tmp`, which sits under `~/.claude`, kept
  write-protected inside the sandbox regardless of grants, and no
  static `allowWrite` can name a per-job path. The plugin's
  session-start hook therefore replaces the job's `tmp` with a symlink
  into the checkout's working tree, at
  `.claude/claude-code-sandbox/jobs/<id>/tmp`: writable inside the
  sandbox, per worktree by construction, alive as long as the checkout,
  and kept out of `git status` through the clone's `.git/info/exclude`.
  Nothing is granted, and the isolation unit stays the checkout, the
  sandbox's own (every session in a checkout can already write its
  working tree). Scratch of vanished jobs is pruned.
- Unix-socket narrowing: upstream's Linux seccomp filter is
  all-or-nothing, so a profile's `allowUnixSockets` list is made real by
  opening that filter (`allowAllUnixSockets`) and pinning the profile's
  SHELL to a Landlock wrapper (`landlock-shim`) that narrows `connect()`
  back to the declared sockets; abstract-namespace sockets from outside
  the sandbox are denied wholesale. This is a real reach barrier: it
  bounds which host services sandboxed code can talk to, and a copied
  file cannot defeat it. `allowAllUnixSockets = true` skips the
  narrowing; `allowNix` grants the nix daemon socket this way
  automatically. It is ABI-gated: the abstract-socket scope needs
  Landlock ABI 6 (6.12+), the socket allowlist ABI 9 (7.1+). On a kernel
  without ABI 9 (Ubuntu 24.04 HWE, for instance) a socket-allowlist
  profile warns once per command and leaves sockets as upstream left
  them; `runtime.landlock.socketFallback = "closed"` makes it refuse
  instead.

  Execve confinement was considered and deliberately not shipped: it
  could not be a real boundary while the checkout and scratch dirs are
  both writable and executable (an agent copies a readable file in and
  runs it), and `no_new_privs` already neutralizes setuid. The barriers
  that hold, the ones a copy cannot defeat, are network isolation, the
  read mask, and the write scope.
- On non-NixOS hosts the store mask governs the nix side only; system
  directories like `/usr/bin` remain. The closed-world property is a
  NixOS property.
- A profile containing `nix` (`allowNix`) necessarily leaves the store
  unmasked: an unmasked store makes every installed tool reachable.
- Fragment size is bounded (~128KB of rules rides the exec
  environment); the builder fails loudly past 100KB. Keep toolsets
  lean.

## Implementation notes

- **CLI**: Python, stdlib only (`json`, `argparse`, `pathlib`,
  `unittest`). The three-way merge wants real data handling and unit
  tests; no dependency tail is the point. Packaged with
  `buildPythonApplication` (pyproject/setuptools).
- **Module**: profile fragments are built at generation time
  (`writeClosure` to JSON via an inline python builder) and placed
  behind stable `$XDG_CONFIG_HOME` paths; per-profile bin farms are
  `buildEnv`s referenced by exact store path inside fragments, so each
  enrolled checkout runs one consistent closure generation
  (stable-path indirection would tear live sessions at switch).
- **Plugin**: a Claude Code skills-dir plugin (skill + hooks.json) as a
  `runCommand` derivation with the CLI store path substituted in.
- Behavior against the real Claude Code sandbox (mask semantics, size
  ceiling, env delivery, permission-save co-ownership) was established
  empirically on 2026-08-22 and is documented in the module's header
  comment; re-verify against the live binary when Claude Code's
  sandboxing or settings machinery changes visibly.

## Testing and commands

The CLI's `unittest` suite under
`pkg-overlays/default/packages/claude-code-sandbox/tests/` runs in the package's
`checkPhase`, so building the package is the test run;
`checks.<system>.claude-code-sandbox` exposes it to `nix flake check`,
beside the plugin and shim builds. The merge engine is the correctness
core: any change to `merge.py` needs a test for the affected rule
(domain invariant, ad-hoc persistence, removal asymmetry, scalar
authority, pruning, idempotence).

From this repository's root:

```zsh
nix build '.#claude-code-sandbox'
nix build '.#claude-code-sandbox-plugin'
nix build '.#landlock-shim'
```

Fast Python loop, from `pkg-overlays/default/packages/claude-code-sandbox/`:

```zsh
PYTHONPATH=src python3 -m unittest discover -s tests -v
```

Run the CLI against a scratch registry by pointing
`CLAUDE_CODE_SANDBOX_CONFIG` at a directory containing a
`registry.json` (see `tests/test_cli.py` for the shape).
