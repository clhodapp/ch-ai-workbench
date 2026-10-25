# microvm guests for Claude Code sessions

The home-manager module `microvm` lets Claude Code sessions use the
microvm guests of the machine their home runs on. A session leases a
guest, starts it, uses it, and stops it. When the guest serves MCP, the
session uses its tools as tools of the MCP server `microvm`. The module
knows caisson-microvm guests and nothing of what runs in them. A tree
that runs a tool in a guest declares that tool and its guest
configuration itself.

## Kinds and slots

A kind is a pool of guests that run one NixOS configuration. Each guest
of a kind is a slot, with its own vsock CID and its own share
directories. Every slot of a kind serves on the vsock port of the kind.
caisson's `microvm-host` NixOS module runs the guests of a machine as
the units `microvm@<slot>.service`. Its option
`caisson.microvm-host.operators.<user>` lists the guests that user may
start, stop and restart, through a polkit rule.

The option `ch-ai-workbench.microvm.kinds.<kind>` declares a kind:

- `slots`: the guests of the kind, each as
  `{ name; cid; vsockSocket; }`, in the order a session claims them.
  Slot names and CIDs are unique across the kinds, and an assertion
  refuses a home that repeats one. `vsockSocket` is null by default.
  For a guest that runs under cloud-hypervisor, it is the path of the
  hybrid vsock socket of the guest, which the section on reaching a
  guest describes.
- `vsockPort`: the vsock port the guests serve on, or null. `up` waits
  until a started guest accepts a connection on it.
- `shareRoot`: the directory of the share directories, or null. The
  guest `<slot>` shares `<shareRoot>/<slot>/in`, read-only in the
  guest, and `<shareRoot>/<slot>/out`, writable in the guest. This is
  the layout of `shareRoot` of a caisson-microvm configuration, which
  mounts the two at `/work/in` and `/work/out`.
- `agents`: whether agents may use the kind. The default is false. The
  MCP server `microvm` offers only the kinds that set it. The `microvm`
  command controls every kind.
- `mcp`: null, or `{ description; }` when the guests serve MCP on
  `vsockPort`. The description goes into the description of the tool
  `microvm_up`. An assertion refuses a kind that sets `mcp` and no
  `vsockPort`.

The module reads nothing about the guests from the tree. A machine
that declares its slots in a caisson-microvm configuration gives the
same names, CIDs, port and share root to this option. For a guest
under cloud-hypervisor, it also gives the path that caisson records as
`outputs.slots.<slot>.vsockSocket`.

## Reaching a guest

The program reaches the vsock port of a guest in two places: the wait
of `up` for the guest to answer, and the connection of the MCP server
to a guest that serves MCP. Both go through one function,
`transport.connect`, which takes the slot, its CID, the port of its
kind and its `vsockSocket`.

A slot without `vsockSocket` is reached through an `AF_VSOCK` socket
connected to `<cid>:<port>`.

A slot with `vsockSocket` is reached through the hybrid vsock of
cloud-hypervisor. The VMM of the guest listens on that Unix socket on
the host. The program connects to it and sends `CONNECT <port>` and a
newline. The VMM answers `OK <host-port>` and a newline when the guest
accepts the connection. Any other answer, or the end of the stream,
means the guest refused it. After the answer, the stream is the
connection to the port of the guest. The program reads the answer one
byte at a time, so nothing the guest sends after it is lost.

Connecting and the exchange each wait at most one second in the wait
of `up`, and five seconds for the MCP connection. A failure names the
slot and the cause:

- the socket does not exist, or nothing listens on it, when the VMM of
  the guest does not run;
- permission is denied on the socket, when the user is not an operator
  of the guest in `caisson.microvm-host.operators`;
- the VMM refuses `CONNECT`, with the answer it gave.

The wait of `up` tries again every half second until `upTimeout`, and
the message at the timeout carries the last failure. A permission
error ends the wait at once, since waiting does not change it.
`status` shows a permission error after `not answering`, and every
other failure as `not answering` alone.

## The program

`microvm` is a Python program with no dependencies outside the
standard library. The package `pkgs.ch-ai-workbench.microvm` is the
program alone. The module writes a configuration file with the kinds,
the state directory and the systemctl of `pkgs.systemd`, and wraps the
program with it as the command of the home.

The verbs:

- `microvm up <kind>` leases a free slot of the kind to the calling
  process, starts its unit, waits until its vsock port accepts a
  connection, and prints the slot, its CID and port, and its share
  directories. A slot the caller already holds is used again. A newly
  leased slot is stopped and then started, so a guest left running by
  a holder that is gone does not carry its state into the next
  session. A restart is not used because, with the pinned microvm.nix,
  a restart of a cloud-hypervisor guest that has a vsock CID does not
  complete.
- `microvm status [--all]` shows the slots the caller holds, each with
  the state of its unit, whether it answers, and its uptime from the
  `ActiveEnterTimestamp` of the unit. With `--all` it shows every slot
  and its holder. It also shows the kinds and how many slots of each
  are free.
- `microvm down [<slot>]` stops the slots the caller holds, or one
  slot. A slot that another live holder holds is refused.
- `microvm reap` stops every leased slot whose holder process is gone,
  and removes its lease. The reap timer runs it.
- `microvm mcp` serves the MCP server `microvm` on stdio.

The program accepts only these verbs and the kind and slot names of
the configuration. It refuses every other argument before it reads
any state.

## Leases

A lease is the file `$XDG_STATE_HOME/ch-ai-workbench/microvm/leases/<slot>.json`:

```json
{
  "slot": "rea-1",
  "kind": "rea",
  "session": "<CLAUDE_CODE_SESSION_ID, or null>",
  "pid": 12345,
  "start": "<field 22 of /proc/12345/stat>",
  "claimed": 1793000000
}
```

The program writes a lease to a temporary file and renames it into
place. It changes leases only while it holds an exclusive lock on
`$XDG_STATE_HOME/ch-ai-workbench/microvm/lock`, so two concurrent `up`
calls never lease one slot twice.

The holder of a lease is a process, recorded with its start time,
since a process ID alone can be reused. A slot is free when it has no
lease or when its holder process is gone. A caller holds a lease when
it names the holder process with its start time. The session ID is
recorded when the caller knows it, for `status --all` to show, and
decides nothing. The scoping keeps sessions from stopping or sharing
the guests of each other by accident. It is no boundary between the
processes of one user.

`microvm mcp` names its parent process as the holder: the Claude Code
process that started the server. The other verbs name the process that
`CLAUDE_PID` names when that variable is set, and their parent process
otherwise, which is the shell a user types the command in.

## The MCP server

The module installs the skills-directory plugin `microvm` as
`ch-ai-workbench.claude-code.skills.microvm`, when at least one kind
sets `agents`. Its `.claude-plugin/plugin.json` declares one MCP
server, `microvm`, which runs `microvm mcp`. This is how the other
plugins of this layer declare their MCP servers. Claude Code starts the
server with the session, outside the sandbox of Bash, so the server
reaches the system bus and the vsock of the guests, or their hybrid
vsock sockets, itself. No sandbox
module and no trusted executable is involved.

The server speaks MCP over stdio, one JSON-RPC message per line, with
the protocol version `2025-06-18`, as the agent tools of
claude-code-sandbox do. Its tools are:

- `microvm_up` with `kind`: brings up a slot of the kind for the
  session, as `microvm up` does. The schema lists the kinds that set
  `agents`, and the server refuses any other kind.
- `microvm_down` with an optional `slot`: stops one slot of the
  session, or all of them, as `microvm down` does.
- `microvm_status` with an optional `all`: shows the slots, as
  `microvm status` does, for the kinds that set `agents`.

The results are the text the verbs print. A tool of the server runs in
a thread of its own, so a guest that boots does not hold up the calls
to other guests. The server starts a guest only when `microvm_up` asks
for it.

### Share directories from Bash

Claude Code's sandbox of Bash lets a command write only the checkout
and the temporary directory of the session. The share directories of a
guest lie outside both. For each kind that sets `agents` and
`shareRoot`, the module therefore declares the claude-code-sandbox
module `microvm-<kind>`. It lists `<shareRoot>/<slot>` for every slot
of the kind in both `extraAllowRead` and `allowWrite`. A checkout that
chooses it, with `claude-code-sandbox add microvm-<kind>`, can copy a
target into `<shareRoot>/<slot>/in` from Bash and read what the guest
writes to `<shareRoot>/<slot>/out`. The grant names the directories of
the slots and not `shareRoot` itself, so the commands reach nothing
else that lies under the share root.

There is one sandbox module per kind, so a checkout that works with
one kind reaches the share directories of that kind and of no other.
The module declares the sandbox modules only when the home also
selects the claude-code-sandbox module of this layer, since the option
they go in comes from that module. The result of `microvm_up` for a
kind with a share root lists the host paths of the shares and says
that Bash commands reach them only in a checkout that has chosen
`microvm-<kind>`.

### Guests that serve MCP

When `microvm_up` brings up a slot of a kind that sets `mcp` and its
vsock port answers, the server connects to the port as the section on
reaching a guest describes. It sends `initialize` and `notifications/initialized` to the
MCP server of the guest, then fetches its `tools/list`. It adds those
tools to its own `tools/list` under their own names and sends Claude
Code `notifications/tools/list_changed`. The result of `microvm_up`
names the tools.

A guest tool whose name a tool of the server or of a guest connected
earlier already has gets the prefix `<kind>_`, and its description
says that it was renamed. A call of a guest tool goes to its guest
under the name the guest gave it, with a request ID of the server. The
reply comes back with the ID of Claude Code. The server forwards the
`notifications/progress` and `notifications/message` of the guest, and
a cancellation of a forwarded call. A `notifications/tools/list_changed`
of the guest makes the server fetch the tools again and send its own
`list_changed`.

When `microvm_down` stops the slot, the guest stops, or the connection
drops, the server fails the calls in flight with a JSON-RPC error,
removes the tools of the guest, and sends `list_changed`. A slot that
stays leased after a drop is connected again by the next `microvm_up`
of its kind.

A kind without `mcp` gets no connection: `microvm_up` starts it and
returns the slot, its CID and port, and its shares.

## Stopping

Three mechanisms stop a guest, each covering what the one before
misses:

1. The server stops the slots of the session when its input ends or
   it receives SIGTERM or SIGHUP, which happens when the session ends.
   It queues each stop with `systemctl --no-block`, so that it exits
   before Claude Code kills it. No `SessionEnd` hook is needed, since
   the server sees the end of the session itself.
2. The user timer `ch-ai-workbench-microvm-reap.timer` runs
   `microvm reap` every minute, for a session that crashed.
3. Each slot unit has the `RuntimeMaxSec` of its caisson-microvm
   configuration, when that configuration sets `runtimeMaxSec`.

## The reap service

The reap service runs with this `serviceConfig`:

- `PrivateUsers`, `ProtectSystem = "strict"` and
  `ProtectHome = "read-only"`, with `ReadWritePaths` set to the state
  directory. The program writes leases there and nowhere else. A
  systemd user tmpfiles rule creates the directory, since a missing
  `ReadWritePaths` entry keeps the service from starting.
- `RestrictAddressFamilies = "AF_UNIX"`. The program needs unix
  sockets for the system bus and no other network.
- `PrivateTmp`, `PrivateDevices`, the `ProtectKernel*`,
  `ProtectControlGroups`, `ProtectClock` and `ProtectHostname`
  settings, `RestrictNamespaces`, `RestrictRealtime`,
  `RestrictSUIDSGID`, `LockPersonality`,
  `SystemCallArchitectures = "native"` and `UMask = "0077"`.
- `ProtectProc` is not set. The program reads `/proc/<pid>/stat` of the
  holders.

systemctl runs inside the user namespace that `PrivateUsers` creates.
The user's own UID is mapped to itself there, so the system bus and
polkit see the user, and the polkit rule of `microvm-host` applies.
The checks of this flake run no systemd, so they do not exercise a
call through polkit; the first `microvm_up` on a real host does.

## Options

- `ch-ai-workbench.microvm.kinds`: the kinds, described above.
- `ch-ai-workbench.microvm.upTimeout`: the number of seconds `up` waits
  for a guest to answer. The default is 120.
- `ch-ai-workbench.microvm.programPackage`: the program before the
  module wraps it. The default is `pkgs.ch-ai-workbench.microvm`.
- `ch-ai-workbench.microvm.package` (read-only): the command of the
  home with the kinds baked in. The home installs it when it has kinds.

## What a tree sets

A machine that runs guests for its sessions:

- selects caisson's `microvm-host` NixOS module and declares a
  caisson-microvm configuration with `slots.<kind>`, `vsockPort` set,
  `autostart = false` and a `runtimeMaxSec`;
- lists the slots for the user in
  `caisson.microvm-host.operators.<user>`;
- declares a home for that user that selects this module beside
  `claude-code`, with `claude-code` enabled, and sets
  `ch-ai-workbench.microvm.kinds.<kind>` from the same names, CIDs,
  port and share root, with `agents = true` and `mcp` for a kind whose
  guests serve MCP, and with the `vsockSocket` of each slot from
  `outputs.slots.<slot>.vsockSocket` for guests under cloud-hypervisor;
- selects `claude-code-sandbox` in that home as well when the Bash
  commands of agents should reach the share directories, and chooses
  `microvm-<kind>` in the checkouts that work with the kind.

## Checks

The package build runs the unittest suites of the program. The lease
suite runs against a fake systemctl, a fake `/proc` and a fake vsock
probe. It also waits for a guest through a fake VMM on a hybrid vsock
socket, and ends the wait at a permission error. The transport suite
runs the hybrid vsock exchange against a fake VMM on a Unix socket in
a temporary directory: an accepted connection, a refused `CONNECT`, an
answer that is not `OK `, a missing socket, a socket nothing listens
on, a socket the user may not open, and a VMM that never answers. The
MCP suite runs the server against the same fakes and fake guest MCP
servers: the tools before any guest, a kind agents may not use, a kind
without MCP, the tools of a guest after `microvm_up`, forwarding,
names that collide, stopping, a dropped connection, and the stops at
the end of input. It runs every test twice, once with the guests on
socket pairs in place of `AF_VSOCK` and once with the guests behind
fake VMMs on the hybrid vsock sockets of their slots. The check
`microvm-home-module` evaluates homes with kinds from the options. The
home with kinds for agents gets the command, the reap timer and the
plugin with the server `microvm`, whose tools over stdio list only the
kinds for agents and refuse the others. The configuration baked into
its command carries the `vsockSocket` of the slot that sets one, and
null for the others. That home also gets the
sandbox module `microvm-probe`, whose read and write paths are exactly
the directories of the two slots of `probe`, and no sandbox module for
`quiet`, which has no share root. A home whose only kind is not for
agents gets the command and the timer, no plugin and no sandbox
module. A home without kinds gets none of it, and a repeated CID or
slot name, or a kind with `mcp` and no port, fails an assertion.
