# microvm guests for Claude Code sessions

The home-manager module `microvm` lets Claude Code sessions run
microvm.nix guests of the user on demand. A session leases an instance
of a guest, starts it, uses it, and stops it. When the guest serves
MCP, the session uses its tools as tools of the MCP server `microvm`.

The instances come from ch-microvm (`github:clhodapp/ch-microvm`). Its
home-manager module declares the kinds of guests in
`ch-microvm.kinds.<kind>`, runs each instance as units of the user's
systemd manager in a directory of its own, and leases instances to
holder processes. Its documentation, `docs/development/instances.md`
in that repository, describes the kinds, the directories, the units,
the leases, the reap timer and the unprivileged virtiofsd. This layer
adds the agent parts: the MCP server, the plugin that installs it, and
the sandbox modules for the share directories.

## How this layer takes ch-microvm

- The flake lists ch-microvm in `projects`. The registry of this layer
  then holds its home-manager module as `ch-microvm/microvm`, and its
  package overlay as `ch-microvm/default`.
- The module `microvm` of this layer imports `ch-microvm/microvm` from
  that registry. A home that selects `microvm` therefore has the
  options `ch-microvm.*`.
- The package overlay of this layer imports `ch-microvm/default`. Every
  package set that applies this layer's overlay has
  `pkgs.ch-microvm.ch-microvm`, the command `ch-microvm` with its
  Python library `ch_microvm`.
- The package `pkgs.ch-ai-workbench.microvm-mcp` lists
  `pkgs.ch-microvm.ch-microvm` in its `dependencies`, so the program
  imports `ch_microvm` and its unit tests run against the fakes of
  `ch_microvm.testing`.

## The options

`ch-ai-workbench.microvm.kinds.<kind>` names a kind of
`ch-microvm.kinds` that sessions use:

- `agents`: whether agents may use the kind. The default is false. The
  MCP server `microvm` offers only the kinds that set it. The user
  controls every kind with `ch-microvm`.
- `mcp`: null, or `{ description; }` when the guest serves MCP on the
  `vsockPort` of its kind. The description goes into the description of
  the tool `microvm_up`.

An assertion refuses a kind that `ch-microvm.kinds` lacks, and a kind
that sets `mcp` while its `vsockPort` is null. The other options are
`programPackage`, the program before the module wraps it, and
`package` (read-only), the program with the kinds of the home baked in.

## The MCP server

The module installs the skills-directory plugin `microvm` as
`ch-ai-workbench.claude-code.skills.microvm`, when at least one kind
sets `agents`. Its `.claude-plugin/plugin.json` declares one MCP
server, `microvm`, which runs `microvm-mcp`. This is how the other
plugins of this layer declare their MCP servers. Claude Code starts the
server with the session, outside the sandbox of Bash, so the server
reaches the user's systemd manager and the vsock sockets of the
instances itself.

The module writes the configuration of the program: the path of
`ch-microvm.configFile`, and the kinds that set `agents` with the MCP
server of each guest. The program reads the configuration of
ch-microvm from that path and serves the instances of the kinds for
agents through the library `ch_microvm`. Its leases and units are the
ones `ch-microvm status` shows and `ch-microvm reap` stops.

The holder of every lease of the server is its parent process, the
Claude Code process, with that process's start time. The label of the
holder is `Claude Code session <CLAUDE_CODE_SESSION_ID>`, so
`ch-microvm status` shows which session holds an instance.

The server speaks MCP over stdio, one JSON-RPC message per line, with
the protocol version `2025-06-18`, as the agent tools of
claude-code-sandbox do. Its tools are:

- `microvm_up` with `kind` and an optional `directory`: leases an
  instance of the kind to the session, starts it and waits until it
  answers, as `ch-microvm up` does. The schema lists the kinds that set
  `agents`, and the server refuses any other kind. `directory` is an
  absolute path.
- `microvm_down` with an optional `instance`: stops one instance of the
  session, or all of them. An instance another live holder holds is
  refused.
- `microvm_status` with an optional `all`: shows the instances of the
  session, or with `all` every instance of the kinds for agents and
  its holder.

The results are the text the library prints. A tool of the server runs
in a thread of its own, so a guest that boots does not hold up the
calls to other guests. The server starts a guest only when
`microvm_up` asks for it.

### Share directories from Bash

Claude Code's sandbox of Bash lets a command write only the checkout
and the temporary directory of the session. The share directories of
an instance lie outside both. For each kind that sets `agents` and has
shares, the module therefore declares the claude-code-sandbox module
`microvm-<kind>`. It lists the share directories that
`ch-microvm.instances.<kind>` gives for every instance of the kind, in
both `extraAllowRead` and `allowWrite`. A checkout that chooses it,
with `claude-code-sandbox add microvm-<kind>`, can copy a target into
the `in` share of an instance from Bash and read what the guest writes
to its `out` share.

The grant lists every path, since Claude Code ignores glob patterns in
`allowWrite` on Linux. It names the share directories and not the
directory of the instance, so a Bash command cannot replace a share
directory by a symbolic link before virtiofsd starts. It also keeps
Bash commands away from the sockets of the VMM in that directory.

No sandbox module grants a directory a caller passes to `microvm_up`.
Bash commands reach the shares there only where the sandbox of the
session already lets them write, such as a directory inside the
checkout. The result of `microvm_up` says which of the two applies.

There is one sandbox module per kind, so a checkout that works with
one kind reaches the share directories of that kind and of no other.
The module declares the sandbox modules only when the home also
selects the claude-code-sandbox module of this layer, since the option
they go in comes from that module.

### Guests that serve MCP

When `microvm_up` brings up an instance of a kind that sets `mcp` and
its vsock port answers, the server connects to the port through
`ch_microvm.transport.connect`, with the hybrid vsock socket in the
directory of the instance. It sends `initialize` and
`notifications/initialized` to the MCP server of the guest, then
fetches its `tools/list`. It adds those tools to its own `tools/list`
under their own names and sends Claude Code
`notifications/tools/list_changed`. The result of `microvm_up` names
the tools.

A guest tool whose name a tool of the server or of a guest connected
earlier already has gets the prefix `<kind>_`, and its description
says that it was renamed. A call of a guest tool goes to its guest
under the name the guest gave it, with a request ID of the server. The
reply comes back with the ID of Claude Code. The server forwards the
`notifications/progress` and `notifications/message` of the guest, and
a cancellation of a forwarded call. A `notifications/tools/list_changed`
of the guest makes the server fetch the tools again and send its own
`list_changed`.

When `microvm_down` stops the instance, the guest stops, or the
connection drops, the server fails the calls in flight with a JSON-RPC
error, removes the tools of the guest, and sends `list_changed`. An
instance that stays leased after a drop is connected again by the next
`microvm_up` of its kind.

A kind without `mcp` gets no connection: `microvm_up` starts it and
returns the instance, its directory, its vsock socket and its shares.

## Stopping

The server stops the instances of the session when its input ends or
it receives SIGTERM or SIGHUP, which happens when the session ends. It
queues each stop with `systemctl --user --no-block`, so that it exits
before Claude Code kills it. The reap timer of ch-microvm stops the
instances of a session that crashed, since their holder process is
gone. The `RuntimeMaxSec` of a kind stops an instance that runs too
long.

## What a tree sets

A machine whose user runs guests for its sessions sets what
ch-microvm needs, as its documentation describes, and then:

- declares a home for the user that selects this module beside
  `claude-code`, with `claude-code` enabled, sets
  `ch-microvm.kinds.<kind>` for each guest, and sets
  `ch-ai-workbench.microvm.kinds.<kind>` with `agents = true` and `mcp`
  for a kind whose guests serve MCP;
- selects `claude-code-sandbox` in that home as well when the Bash
  commands of agents should reach the share directories, and chooses
  `microvm-<kind>` in the checkouts that work with the kind.

## Checks

The package build of `microvm-mcp` runs its unittest suite against the
fakes of `ch_microvm.testing` and fake guest MCP servers behind fake
VMMs in the directories of their instances: the tools before any
guest, a kind agents may not use, a kind without MCP, the label of the
lease, the tools of a guest after `microvm_up`, a directory passed to
`microvm_up`, forwarding, names that collide, stopping, a dropped
connection, the stops at the end of input, and the label and arguments
of the program.

The check `microvm-home-module` evaluates homes with kinds of
ch-microvm and kinds for agents, with a fake runner. The home with
kinds for agents gets the plugin with the server `microvm`, whose tools
over stdio list only the kinds for agents and refuse the others. The
configuration baked into the program names the configuration file of
ch-microvm and carries the MCP server of each kind for agents. That
home also gets the sandbox module `microvm-probe`, whose read and
write paths are exactly the share directories that
`ch-microvm.instances` lists for the two instances of `probe`, and no
sandbox module for `quiet`, which has no shares. A home whose kinds are
not for agents gets the command of ch-microvm, no plugin and no
sandbox module. A home without kinds gets none of it. A kind outside
`ch-microvm.kinds`, and a kind with `mcp` and no port, fail an
assertion.

ch-microvm checks the instances themselves, with its unit tests, its
home-module check and its nested VM test, in which an ordinary user
starts a real guest.
