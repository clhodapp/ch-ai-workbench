# claude-code-sandbox

Nix-authored per-project configuration for [Claude Code]'s native
sandbox. The `claude-code-sandbox` Home Manager module declares named
sandbox **modules**, each saying what one kind of tooling (git, nix, a
language toolchain) needs inside the sandbox: its executables, domains,
sockets and writable paths. The `claude-code-sandbox` CLI binds each
checkout to the set of modules its work needs by explicit
**enrollment**, composing them into native sandbox rules, without
placing anything in shared repositories.

[Claude Code]: https://code.claude.com

Where things live in this repository:

| Piece | Path |
|---|---|
| Home Manager module (`ch-ai-workbench.claude-code-sandbox.*`) | `modules/homeManager/claude-code-sandbox/default.nix` |
| CLI (Python, stdlib only) | `pkg-overlays/default/packages/claude-code-sandbox/` |
| Skills-dir plugin (enrollment skill, session-start hook, agent tools MCP server) | `pkg-overlays/default/packages/claude-code-sandbox-plugin/` |
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

Each project needs its own combination of tooling, while what it means
to use a given tool (git needs `git`, `ssh` and GitHub's domains; nix
needs `nix`, the daemon socket and an unmasked store) is the same in
every project. A sandbox module states the second once; a checkout
picks the first by naming modules.

The home-manager module compiles every sandbox module into a *part*:
the module's own bin farm (a `buildEnv` of its toolset), the closure of
that farm, and the grants it declares. One *base* part holds what every
enrollment carries: the base farm (`runtime.basePackages` and the CLI),
the ssh wrapper, the pinned shells, the Claude Code package and the
sandbox runtime tools. Nix cannot know which combinations checkouts
will choose, so the CLI composes at enroll time. The composed settings
fragment for Claude Code's built-in sandbox carries:

- `denyRead ["/nix/store"]` plus exact per-path `allowRead` entries for
  the union of the chosen parts' closures. The mask is mount-level:
  store paths outside the closure are *nonexistent* inside sandboxed
  commands, so the chosen toolsets are the executable world, exact to
  the store hash. One chosen module with `allowNix` unmasks the store
  for the whole checkout.
- An `env.PATH` of the ssh wrapper, the chosen modules' farms in name
  order, then the base farm and the sandbox runtime tools, all by exact
  store path (each checkout sees one consistent world: new after sync,
  old-but-working when a sync hasn't reached it yet), and `env.SHELL`
  pinned to the base bash.
- The union of the chosen modules' list grants: read and write paths,
  allowed and denied domains, excluded commands, unix sockets.
- Fail-closed posture: `failIfUnavailable` so a sandbox that cannot
  initialize refuses commands instead of silently running them
  unsandboxed.

The resolved set is the checkout's chosen modules plus `baseModules`,
closed over each module's `requires`. Two chosen modules that set the
same environment variable or passthrough setting to different values
make enrollment fail with both values named; two modules that put the
same command on PATH resolve to the module whose name sorts first.

Enrolling a checkout (`claude-code-sandbox enroll git nix`) merges the
fragment into the repo's own `.claude/settings.local.json`, a file
co-owned with Claude Code, which saves permission approvals there. The
merge is three-way with the last-applied blob as base and touches only
the paths it applied: Claude Code's keys, and anything added by hand
outside the applied set, pass through untouched. Hand-added entries
inside managed arrays persist across syncs and are reported as local
additions.

## Verbs

Every checkout-local verb acts on the checkout containing the current
directory, or the one containing `DIR` with `-C DIR`.

| Verb | Effect |
|---|---|
| `enroll [MODULE...]` | Bind this checkout to exactly these modules (none: the base alone) |
| `add MODULE...` | Add modules to this checkout's set |
| `drop MODULE...` | Remove modules from this checkout's set |
| `abandon` | Remove the sandbox fragment; the checkout stays managed |
| `status` | This checkout's modules, staleness, local additions |
| `scan DIR` | Same, for every checkout under the given directory |
| `sync` | Re-apply this checkout's modules after a module change |
| `list` | The declared modules, with descriptions and requirements |
| `show MODULE...` | What each module allows, and its status in this checkout |
| `decline MODULE... [--reason TEXT]` | Record that this checkout should not get these modules |
| `undecline MODULE...` | Withdraw a recorded refusal |
| `mcp` | Serve the agent tools over MCP on stdio (the plugin starts it) |

The CLI is on every enrollment's PATH, so a sandboxed agent can run
`claude-code-sandbox status` to verify its own enrollment. Inside a
masked enrollment the registry and parts (store symlinks) are
unreadable, so status there reports the modules and settings integrity
with freshness marked unknown rather than guessing.

An abandoned checkout keeps its sidecar, so the session-start hook
still redirects job scratch and provisions credentials there; only the
sandbox fragment is gone.

Parts regenerate at every home-manager switch; enrolled checkouts
converge at point of use: the session-start hook heals staleness in
the session it fires in, and an unhealed checkout keeps running its
previous closure consistently. The sidecar records the chosen names,
not their expansion, so a checkout tracks what its modules, their
`requires` and `baseModules` become. No enumeration of enrollments
exists anywhere, so nothing breaks when folders move. Claude Code
live-reloads settings files, so synced rules generally reach running
sessions.

A checkout enrolled before sandbox modules existed has a sidecar naming
a profile. A profile named `none` reads as abandoned. Any other profile
has no module equivalent, so `status` and the session-start hook report
it and `sync` refuses; the checkout keeps the fragment it last applied
until someone runs `enroll` with modules, which replaces that fragment
cleanly because the old applied blob is the merge base.

## Agent tools

An agent inside the sandbox cannot inspect or change its own sandbox
from Bash: in a masked enrollment the registry and parts are
unreadable, the settings and sidecar files are write-guarded, and the
consent spool (`$XDG_RUNTIME_DIR/claude-consent`) is outside the write
scope. The plugin therefore declares an MCP server, `claude-code-sandbox
mcp`, which Claude Code starts outside the Bash sandbox. Its tools act on
the checkout the session was launched in (`CLAUDE_PROJECT_DIR`), because
that checkout's `settings.local.json` governs the session's sandbox.

| Tool | Effect |
|---|---|
| `list-modules` | Every declared module, with its status here: enabled (chosen, base, or required by another), declined, or available |
| `enabled-modules` | The checkout's enrollment, chosen modules, every enabled module with the reason, and freshness |
| `describe-module` | What a module allows: commands and packages, domains, sockets, paths, excluded commands, env, store unmasking, and the modules its `requires` would also enable |
| `declined-modules` | The user's recorded refusals for this checkout, or whether one module is declined |
| `request-module` | Prompt the user to enable a module, with the agent's reason and the module's grants |

`request-module` changes nothing on its own. It reports an enabled
module as enabled and a declined module as declined without prompting,
and refuses in a checkout that is not enrolled with modules, because
enrolling is the user's act. Otherwise it prompts the user and waits:

1. Through `claude-consent ask`, the workbench's prompt API. An
   answerer attached to the spool (Emacs, `claude-consent watch`) shows
   the prompt with three options: enable, decline with an optional
   reason, and not now.
2. With no answerer attached, through an MCP elicitation: a dialog in
   the Claude Code terminal UI.
3. When the client cannot show a dialog, or the dialog is cancelled
   (a headless `claude -p` session cancels at once), the question is
   stored in the spool. The agent is told to relay `claude-consent
   answer ID`; the next `request-module` call for that module in the
   same session applies the answer.

On "enable" the server runs the equivalent of `add`. The running
session keeps its old sandbox rules until the user stops it with
`/stop` and starts it again, so the tool result tells the agent to
relay that restart to the user.
On "decline" the refusal goes into the sidecar under `declined`, with
the time and the reason; the sidecar is write-guarded, so an agent
cannot erase it. "Not now", a dismissed dialog, and a prompt left
unanswered for fifteen minutes record nothing. Choosing the module with
`enroll` or `add`, or running `undecline`, withdraws a refusal.

The tools go through Claude Code's usual permission check for MCP
tools, so the first call of each may itself ask for permission, unless
a permission rule allows `mcp__plugin_claude-code-sandbox_sandbox`.

## Module sketch

```nix
{
  ch-ai-workbench.claude-code-sandbox = {
    enable = true;
    runtime.claudePackage = pkgs.claude-code;
    modules = {
      git = {
        description = "git over https and ssh to GitHub";
        toolset = [ pkgs.git pkgs.openssh ];
        allowedDomains = [ "github.com" "*.github.com" ];
      };
      github = {
        requires = [ "git" ];
        toolset = [ pkgs.gh ];
        allowedDomains = [ "*.githubusercontent.com" ];
      };
      python = {
        toolset = [ pkgs.python3 pkgs.ruff ];
        allowedDomains = [ "pypi.org" "files.pythonhosted.org" ];
      };
      nix = {
        allowNix = true;
        toolset = [ pkgs.nix ];
        allowedDomains = [ "*.nixos.org" ];
      };
    };
  };
}
```

A Python project on GitHub then runs `claude-code-sandbox enroll github
python`, and a Nix flake on GitHub runs `claude-code-sandbox enroll
github nix`. The skills-dir plugin ships an enrollment skill and an
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
  all-or-nothing, so the union of the chosen modules' `allowUnixSockets`
  lists is made real by opening that filter (`allowAllUnixSockets`) and
  pinning SHELL to the socket shell, a wrapper around `landlock-shim`
  that narrows `connect()` back to those sockets; abstract-namespace
  sockets from outside the sandbox are denied wholesale. The socket
  shell is built once, so the composed list reaches it through the
  settings env (`CLAUDE_CODE_SANDBOX_UNIX_SOCKETS`, one path per line).
  The settings files are write-guarded, and a Landlock domain only
  narrows once applied, so a command cannot widen the list; an empty
  variable makes the socket shell refuse to run, because the shim reads
  an empty list as "no narrowing". This is a real reach barrier: it
  bounds which host services sandboxed code can talk to, and a copied
  file cannot defeat it. `allowAllUnixSockets = true` in any chosen
  module skips the narrowing; `allowNix` grants the nix daemon socket
  this way automatically. It is ABI-gated: the abstract-socket scope
  needs Landlock ABI 6 (6.12+), the socket allowlist ABI 9 (7.1+). On a
  kernel without ABI 9 (Ubuntu 24.04 HWE, for instance) an enrollment
  with a socket allowlist warns once per command and leaves sockets as
  upstream left them; `runtime.landlock.socketFallback = "closed"` makes
  it refuse instead.

  Execve confinement was considered and deliberately not shipped: it
  could not be a real boundary while the checkout and scratch dirs are
  both writable and executable (an agent copies a readable file in and
  runs it), and `no_new_privs` already neutralizes setuid. The barriers
  that hold, the ones a copy cannot defeat, are network isolation, the
  read mask, and the write scope.
- On non-NixOS hosts the store mask governs the nix side only; system
  directories like `/usr/bin` remain. The closed-world property is a
  NixOS property.
- A checkout that chooses a module with `allowNix` necessarily leaves
  the store unmasked for all its modules: an unmasked store makes every
  installed tool reachable.
- Fragment size is bounded: the rules are passed through the exec
  environment, which fails around 128KB. The CLI refuses a composition
  past 100KB, and a part's build fails if that part alone is past it.
  Keep toolsets lean.

## Implementation notes

- **CLI**: Python, stdlib only (`json`, `argparse`, `pathlib`,
  `unittest`). The three-way merge wants real data handling and unit
  tests; no dependency tail is the point. Packaged with
  `buildPythonApplication` (pyproject/setuptools).
- **Module**: the base part and one part per sandbox module are built
  at generation time (`writeClosure` to JSON via an inline python
  builder) and placed behind stable `$XDG_CONFIG_HOME` paths, named by
  `registry.json`; per-module bin farms are `buildEnv`s referenced by
  exact store path inside parts, so each enrolled checkout runs one
  consistent closure generation (stable-path indirection would tear
  live sessions at switch).
- **Composition** lives in the CLI (`compose.py`), because the set of
  modules is chosen per checkout after the parts are built. The
  composer is the only place the fail-closed keys are written.
- **Plugin**: a Claude Code skills-dir plugin (skill, hooks.json, and
  an `mcpServers` entry in `plugin.json`) as a `runCommand` derivation
  with the CLI and `claude-consent` store paths substituted in. Claude
  Code 2.1.283 registers a skills-dir plugin's MCP server as
  `plugin:claude-code-sandbox:sandbox`, and starts it with
  `CLAUDE_CODE_SESSION_ID` and `CLAUDE_PROJECT_DIR` set and form
  elicitation advertised (verified 2026-10-22).
- **MCP server** (`mcp.py`): JSON-RPC over stdio, stdlib only. A reader
  thread queues incoming messages, so a call waiting on a prompt still
  sees its own cancellation and the client's elicitation response;
  other requests that arrive meanwhile are served after it. Parts carry
  `packages` and `commands` (the farm's `bin` entries, wrapper
  internals excluded) for `describe-module` and the prompt.
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
beside the plugin and shim builds. The merge engine and the composer
are the correctness core: any change to `merge.py` needs a test for the
affected rule (domain invariant, ad-hoc persistence, removal asymmetry,
scalar authority, pruning, idempotence), and any change to `compose.py`
needs one in `tests/test_compose.py` (unions, masking, PATH order,
`requires` and `baseModules`, socket narrowing, conflicts, the size
limit). `checks.<system>.claude-code-sandbox-compose` runs the CLI
against the parts a home-manager configuration really builds.

From this repository's root:

```zsh
nix build '.#claude-code-sandbox'
nix build '.#claude-code-sandbox-plugin'
nix build '.#landlock-shim'
nix build '.#checks.x86_64-linux.claude-code-sandbox-compose'
```

Fast Python loop, from `pkg-overlays/default/packages/claude-code-sandbox/`:

```zsh
PYTHONPATH=src python3 -m unittest discover -s tests -v
```

Run the CLI against a scratch registry by pointing
`CLAUDE_CODE_SANDBOX_CONFIG` at a directory containing a
`registry.json` (`tests/fixtures.py` writes one, with its parts).
