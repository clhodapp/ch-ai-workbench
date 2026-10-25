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
| `trusted-exec` (trusted-executable stub and service, Rust, std only) | `pkg-overlays/default/packages/trusted-exec/` |

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
| `add MODULE... [--for day\|week]` | Add modules to this checkout's set, for a day or a week, or until dropped |
| `drop MODULE...` | Remove modules from this checkout's set |
| `abandon` | Remove the sandbox fragment; the checkout stays managed |
| `status` | This checkout's modules, deadlines, staleness, local additions |
| `scan DIR` | Same, for every checkout under the given directory |
| `sync` | Drop this checkout's expired modules and re-apply the rest |
| `expire` | Drop expired modules in every checkout of the expiring index (the timer runs it) |
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
exists anywhere, so nothing breaks when folders move. A session reads
its sandbox rules when it launches: synced rules reach a running
session only after the user stops it with `/stop` and starts it again.

### Modules for a day or a week

`add --for day` or `add --for week` chooses a module until a deadline,
and the user picks the same durations when answering `request-module`.
The sidecar records the deadline under `expires`, keyed by module name.
Running `add` again for a module replaces its deadline, and `add`
without `--for` makes the choice last until someone drops the module.
`enroll` and `drop` clear the deadlines of the modules they bind or
remove.

A session reads its sandbox rules at launch, before its SessionStart
hook runs. If only the hook dropped expired modules, the first session
launched after a deadline would run with the expired module until it
restarted. The CLI therefore keeps a per-user index of the checkouts
that have a deadline, `$XDG_STATE_HOME/claude-code-sandbox/expiring.json`,
and a systemd user timer runs `claude-code-sandbox expire` every ten
minutes. The index lists checkouts only; the deadlines stay in each
checkout's sidecar. `expire` drops due modules, re-applies the rest,
and removes checkouts with no deadline left from the index, including
checkouts whose sidecar is gone. `sync`, `request-module` and the
SessionStart hook also drop due modules in their checkout. The baseline
write-guards the index like the sidecar, so an agent cannot remove its
checkout from the index to keep a module past its deadline.

A session that is already running when a deadline passes keeps the
module's rules until it is stopped and started again, as with any other
change to its rules.

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
   the prompt with five options: enable for a day, enable for a week,
   enable permanently, decline with an optional reason, and not now.
2. With no answerer attached, through an MCP elicitation: a dialog in
   the Claude Code terminal UI.
3. When the client cannot show a dialog, or the dialog is cancelled
   (a headless `claude -p` session cancels at once), the question is
   stored in the spool. The agent is told to relay `claude-consent
   answer ID`; the next `request-module` call for that module in the
   same session applies the answer.

On an enable answer the server runs the equivalent of `add`, with
`--for day` or `--for week` for the time-limited answers. A module
whose deadline has passed is dropped before the request is considered,
so the agent can ask for it again. The running
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

## Trusted executables

A trusted executable is a program that a sandboxed command runs outside
Claude Code's sandbox. The home-manager option
`trustedExecutables.<name>` declares the program, and a sandbox module
grants it by listing the name in its own `trustedExecutables`. A
checkout that chooses the module gets a stub named `<name>` on PATH.
Running the stub runs the program on the other side of a unix socket,
with stdin, stdout and stderr streamed over that socket.

The program runs as the user, under the systemd user manager. Its
access is locked down from the access of the user rather than built up
from nothing: by default it can do everything the user can, and so
everything Claude Code's sandbox allows and more. `serviceConfig` takes
access away with systemd `[Service]` settings.

```nix
{
  ch-ai-workbench.claude-code-sandbox = {
    trustedExecutables.notify-send = {
      description = "desktop notifications through the session bus";
      program = lib.getExe' pkgs.libnotify "notify-send";
      workingDirectory = "/";
      serviceConfig = {
        PrivateUsers = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateNetwork = true;
      };
    };
    modules.desktop.trustedExecutables = [ "notify-send" ];
  };
}
```

Here the sandbox keeps the session bus from Claude Code, and a checkout
that chooses `desktop` can still post notifications. The program can
reach the bus socket under `$XDG_RUNTIME_DIR`, but it cannot see home,
cannot write the system, and has no network.

Each declaration becomes two systemd user units. The socket unit
`ccs-trusted-<name>.socket` listens at
`$XDG_STATE_HOME/claude-code-sandbox/trusted/<name>.sock` (mode 0600)
with `Accept=yes`, so systemd starts one instance of the service
template `ccs-trusted-<name>@.service` per connection, with the
connection as stdin. The instance runs `trusted-exec serve`, which
starts the program with the settings in `serviceConfig` applied. The
socket lives under the state directory because composition writes
socket paths into the checkout's settings at enroll time, and
`$XDG_RUNTIME_DIR` contains the uid, which the home evaluation does not
know.

The grant is the socket. A granting module adds the socket to its
`allowUnixSockets`, so the composer's Landlock narrowing admits it, and
adds the stub to its farm. The stub is a compiled wrapper around
`trusted-exec call`. Any program inside the sandbox that can connect to
the socket can speak the protocol, so a checkout that does not choose
the module has no way to reach the program.

The service treats the request as untrusted input. It takes from the
caller the arguments (after the declared `args`), stdin, the working
directory (only when `workingDirectory` is null), and the values of the
variables listed in `passEnv`. The program, the rest of its
environment, and its restrictions come from the declaration. The
service also refuses a peer whose uid differs from its own, a request
over 4 MiB, and a NUL byte in an argument, a variable or the directory.

A trusted program can still be steered by what the agent writes. With
`workingDirectory` null the program runs in the caller's directory,
which is usually a checkout the agent can write, and a program that
reads configuration from there (git reads `.git/config` and runs hooks)
then runs code the agent wrote, outside Claude Code's sandbox. We
recommend declaring trusted executables only for programs whose
behaviour the caller's arguments, stdin and directory cannot widen, and
fixing `workingDirectory` or narrowing the service with `serviceConfig`
otherwise. A program whose arguments can name commands to run
(subcommands that execute, aliases, extensions, `--exec`-style options)
gives the caller arbitrary code execution with whatever access
`serviceConfig` leaves. `gh` is one: `gh alias set --shell` followed by
the alias runs a shell, and `gh auth token` prints the token.

The protocol (`src/protocol.rs`) is a sequence of frames: one kind
byte, a four-byte big-endian length, and the payload. The caller sends
argument, directory and variable frames as raw bytes, then a run frame,
in one write. After that it sends stdin chunks and forwarded signals
(SIGHUP, SIGINT, SIGQUIT and SIGTERM, delivered to the program's
process group). The service sends stdout and stderr chunks, then an
exit frame with the exit code or the signal that ended the program, or
an error frame when the program did not start. Each side reads into a
buffer that keeps room for the header in front of the data, so every
chunk of up to 64 KiB leaves in a single write. Output gets
backpressure from blocking writes. Stdin is flow-controlled by credit,
as ssh does with channel windows: the caller may have at most 1 MiB of
stdin sent and not yet credited, and the service credits each chunk
once the program has taken it. The service therefore never stops
reading the connection, so signals and a closed connection reach it
even while the program does not read its stdin. In a local measurement, 1 GiB
passes through `cat` and back in about 0.3 s, against 0.13 s for a
plain pipe, and a call of `true` takes about 1.3 ms. The stub exits with
the program's exit code or 128 plus the signal. It exits 255 when it
cannot reach the service or loses the connection, as ssh does, and 126
or 127 when the service refuses the request or cannot start the
program. When the connection closes before the program exits, the
service sends SIGHUP to the program's process group, then SIGKILL after
five seconds.

The program sees pipes, never a terminal, so interactive prompts and
terminal colour detection behave as they do in a pipeline. A process
the program leaves running that keeps its stdout or stderr open holds
the call open, as with ssh, until the caller goes away or forwards a
signal. Either ends the call, and systemd then stops what is left in
the cgroup of the service instance.

In a user service, the systemd settings that need file-system
namespacing (`ProtectSystem`, `ProtectHome`, `ReadWritePaths`,
`PrivateTmp` and the like) only take effect together with
`PrivateUsers = true` (systemd.exec(5)). Inside that user namespace,
files owned by root, store-symlinked dotfiles among them, appear owned
by nobody, and tools that check the ownership of their configuration
(ssh, for one) reject them. Every instance also gets
`NoNewPrivileges = true` unless `serviceConfig` sets it.

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
  it refuse instead. Upstream leaves every socket reachable in that
  case, trusted-executable sockets included, so on such a kernel any
  checkout with a socket grant can call every trusted executable. On
  hosts with trusted executables and an older kernel, we recommend the
  closed fallback.

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
nix build '.#trusted-exec'
nix build '.#checks.x86_64-linux.claude-code-sandbox-compose'
```

Fast Python loop, from `pkg-overlays/default/packages/claude-code-sandbox/`:

```zsh
PYTHONPATH=src python3 -m unittest discover -s tests -v
```

Run the CLI against a scratch registry by pointing
`CLAUDE_CODE_SANDBOX_CONFIG` at a directory containing a
`registry.json` (`tests/fixtures.py` writes one, with its parts).
