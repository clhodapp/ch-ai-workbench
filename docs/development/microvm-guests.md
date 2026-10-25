# microvm guests for Claude Code sessions

The home-manager module `microvm` lets Claude Code sessions use the
microvm guests of the machine their home is declared inside. A session
leases a guest, starts it, uses it, and stops it. The module knows
caisson-microvm guests and nothing of what runs in them. A tree that
runs a tool in a guest declares that tool, its guest configuration and
its MCP server entry itself.

## Slots

A caisson-microvm configuration declares its guests as NixOS
configurations. Its `slots.<kind>` option declares a pool of guests of
one kind, `<kind>-1` to `<kind>-<count>`. Each slot gets its own vsock
CID and its own share directories, and every slot of a kind serves on
the vsock port of the kind. The configuration records the slots as
`outputs.slots.<guest>`, each with `kind`, `index`, `cid`, `vsockPort`
and `shares`. caisson's `microvm-host` NixOS module runs the guests of
the machine as the units `microvm@<guest>.service`. Its option
`caisson.microvm-host.operators.<user>` lists the guests that user may
start, stop and restart, through a polkit rule.

## How the module reads the slots

The module reads the slots from the tree, so no option repeats them.
A home declared inside a NixOS configuration reads that machine as
`lib.caisson.evalManifest.nearest.nixos`. That manifest is the
childless view of the machine: the machine evaluated without the
configurations declared inside it. In that view
`caisson.caisson-microvm.configurations` refuses to be read, since its
values are the configurations declared inside the machine.

The module therefore finalizes each caisson-microvm configuration of
the machine a second time. It merges the definitions of that option
with the type of the option, as the machine does, and calls
`lib.caisson-core.finalizeChild` on each, with the childless machine
as its parent, as the machine does. The result is the same
caisson-microvm evaluation the machine holds. The module reads
`outputs.slots` from it and nothing else, so the guests themselves are
not evaluated.

Of those slots the module keeps the slots that
`caisson.microvm-host.operators` of the machine lists for the user of
the home. The polkit rule lets that user start and stop exactly those
units, so a slot outside the list is one the program could not start.

A home has no slots when caisson does not evaluate it, when no NixOS
configuration holds it, when its machine declares no slots, or when the
machine lists none for its user. The module then declares nothing.

## The program

`microvm` is a Python program with no dependencies outside the
standard library. The package `pkgs.ch-ai-workbench.microvm` is the
program alone. The module writes a configuration file with the slots,
the state directory, the systemctl of the machine and the socat to
relay with, and wraps the program with it. Two wrappers exist. The
command of the home accepts every verb. The program behind the trusted
executable accepts `up`, `status` and `down`.

The verbs:

- `microvm up <kind>` leases a free slot of the kind to the calling
  session, starts its unit, waits until its vsock port accepts a
  connection, and prints the slot, its CID and port, and its share
  directories. A slot the session already holds is used again. A newly
  leased slot is restarted, so a guest left running by a session that
  is gone does not carry its state into the next session.
- `microvm status [--all]` shows the slots the session holds, each
  with the state of its unit, whether it answers, and its uptime from
  the `ActiveEnterTimestamp` of the unit. With `--all` it shows every
  slot and its holder. It also shows the kinds and how many slots of
  each are free.
- `microvm down [<slot>]` stops the slots the session holds, or one
  slot. A slot that another live session holds is refused.
- `microvm reap` stops every leased slot whose holder process is gone,
  and removes its lease. The reap timer runs it.
- `microvm connect <kind>` brings up the slot of the kind as `up`
  does, then relays stdin and stdout to its vsock port with
  `socat STDIO VSOCK-CONNECT:<cid>:<port>`. It writes what `up` prints
  to stderr, since stdout carries the relayed stream.

The program accepts only these verbs and the kind and slot names of
the configuration. It refuses every other argument before it reads
any state.

## Leases

A lease is the file `$XDG_STATE_HOME/ch-ai-workbench/microvm/leases/<slot>.json`:

```json
{
  "slot": "rea-1",
  "kind": "rea",
  "session": "<CLAUDE_CODE_SESSION_ID>",
  "pid": 12345,
  "start": "<field 22 of /proc/12345/stat>",
  "claimed": 1793000000
}
```

The program writes a lease to a temporary file and renames it into
place. It changes leases only while it holds an exclusive lock on
`$XDG_STATE_HOME/ch-ai-workbench/microvm/lock`, so two concurrent `up`
calls never lease one slot twice.

The calling session comes from `CLAUDE_CODE_SESSION_ID` and
`CLAUDE_PID`, which Claude Code sets in every Bash command, inside the
sandbox too. The holder is that process, recorded with its start time,
since a process ID alone can be reused. A slot is free when it has no
lease or when its holder process is gone. A caller holds a lease when
the session IDs match, or when the caller names the holder process
with its start time. The session ID is the claim of the caller, so the
scoping keeps sessions from stopping or sharing the guests of each
other by accident. It is no boundary between sessions of one user.

`connect` runs in an MCP server, which knows no `CLAUDE_PID`. Its
holder is its parent process, the Claude Code process that started the
server, and the lease records the session ID only when
`CLAUDE_CODE_SESSION_ID` is set. A later `microvm up` from a Bash
command of that session names the same process, finds the lease, and
records its session ID on it.

## Stopping

Four mechanisms stop a guest, each covering what the one before
misses:

1. The `SessionEnd` hook of the plugin runs `microvm down` for the
   ending session, with the session ID from the JSON on its stdin. It
   always exits 0.
2. The user timer `ch-ai-workbench-microvm-reap.timer` runs
   `microvm reap` every minute.
3. Each slot unit has the `RuntimeMaxSec` of its caisson-microvm
   configuration, when that configuration sets `runtimeMaxSec`.
4. Nothing survives a reboot of the host, when the configuration sets
   `autostart = false`.

## The trusted executable and the sandbox module

A sandboxed command cannot reach the system D-Bus, so it controls the
guests through the trusted executable `microvm` of
claude-code-sandbox (see `claude-code-sandbox.md`, "Trusted
executables"). The declaration passes `CLAUDE_CODE_SESSION_ID` and
`CLAUDE_PID` and runs the program in `/`. The sandbox module `microvm`
grants it. A checkout that chose that module gets the stub `microvm`
on PATH.

The service runs with this `serviceConfig`, which the reap service
shares:

- `PrivateUsers`, `ProtectSystem = "strict"` and
  `ProtectHome = "read-only"`, with `ReadWritePaths` set to the state
  directory. The program writes leases there and nowhere else. A
  systemd user tmpfiles rule creates the directory, since a missing
  `ReadWritePaths` entry keeps the service from starting.
- `RestrictAddressFamilies = "AF_UNIX AF_VSOCK"`. The program needs
  unix sockets for the system bus and vsock for the guests, and no IP
  network. `PrivateNetwork` is not set. Recent kernels can scope vsock
  to network namespaces, and the module does not rely on how a given
  kernel treats a connection from a private network namespace to a
  guest.
- `PrivateTmp`, `PrivateDevices`, the `ProtectKernel*`,
  `ProtectControlGroups`, `ProtectClock` and `ProtectHostname`
  settings, `RestrictNamespaces`, `RestrictRealtime`,
  `RestrictSUIDSGID`, `LockPersonality`,
  `SystemCallArchitectures = "native"` and `UMask = "0077"`.
- `ProtectProc` is not set. The program reads `/proc/<pid>/stat` of the
  calling session.

systemctl runs inside the user namespace that `PrivateUsers` creates.
The user's own UID is mapped to itself there, so the system bus and
polkit see the user, and the polkit rule of `microvm-host` applies.
Reading the state of a unit needs no rule. The checks of this flake
run no systemd, so they do not exercise a call through polkit; the
first `microvm up` on a real host does.

## The plugin

The module installs the skills-directory plugin `microvm` as
`ch-ai-workbench.claude-code.skills.microvm`. It holds
`.claude-plugin/plugin.json`, `hooks/hooks.json` with the
`SessionEnd` hook, and the skill `skills/microvm/SKILL.md`. The skill
lists the kinds of the machine with their slots, vsock ports and
shares. It says to bring a guest up before using a tool that runs in
it and down when the task is done, and that leases are per session.

## Options

- `ch-ai-workbench.microvm.upTimeout`: the number of seconds `up` waits
  for a guest to answer. The default is 120.
- `ch-ai-workbench.microvm.programPackage`: the program before the
  module wraps it. The default is `pkgs.ch-ai-workbench.microvm`.
- `ch-ai-workbench.microvm.slots` (read-only): the slots the home
  controls.
- `ch-ai-workbench.microvm.package` (read-only): the command of the
  home with the slots baked in. An MCP server entry runs
  `lib.getExe config.ch-ai-workbench.microvm.package` with the
  arguments `connect <kind>`.

## What a tree sets

A machine that runs guests for its sessions:

- selects caisson's `microvm-host` NixOS module and declares a
  caisson-microvm configuration with `slots.<kind>`, `vsockPort` set,
  `autostart = false` and a `runtimeMaxSec`;
- registers the NixOS configuration of each kind as
  `configs.nixos.<kind>`;
- lists the slots for the user in
  `caisson.microvm-host.operators.<user>`;
- declares a home for that user that selects this module beside
  `claude-code` and `claude-code-sandbox`, with both enabled.

An MCP server entry for a guest tool runs `microvm connect <kind>`
from `ch-ai-workbench.microvm.package`.

## Checks

The package build runs the unittest suite of the program against a
fake systemctl, a fake `/proc` and a fake vsock probe. The check
`microvm-home-module` builds a tree from `tests/microvm/configs` with
caisson's library and this flake as a project. On the machine `host`
the home gets the slots, the trusted executable, the sandbox module,
the reap timer and the plugin, and the program behind the trusted
executable refuses the verbs and names it does not accept. On the
machine `bare` the home gets none of it.
