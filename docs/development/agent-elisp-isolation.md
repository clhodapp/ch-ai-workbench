# Agent Elisp Isolation

Design, 2026-09-07. Nothing below is implemented yet; the phases at the
end give the order. The subject is the elisp an agent runs against the
resident Emacs through the MCP server
(`modules/home-manager/emacs/inits/mcp-server.el`): how it is kept from
changing the session, and how it is kept from seeing what it was not
given.

## The problem

Today `eval-elisp` evaluates a form in the live Emacs after a syntactic
gate: `unsafep` over Emacs's own safety metadata, extended by an
allowlist of function symbols. The gate has two shortcomings, and they
are different in kind.

The first is vocabulary. `unsafep` does not macroexpand and admits a
symbol only if it carries a `side-effect-free`, `pure`, or
`safe-function` property or sits in the allowlist. So `bound-and-true-p`,
`with-current-buffer`, `seq-find`, `lookup-key`, and `advice-member-p`
are refused, none of which changes anything, and each refusal names only
the first unknown symbol. This is friction, and an allowlist can chip at
it forever.

The second is confidentiality, and no allowlist reaches it. `unsafep`
proves that a form changes nothing, because the mutating primitives are
a finite set with names. It cannot bound what a form observes. Inside
one Emacs the observable set is the whole heap: `symbol-value` and bare
variable references, `getenv` and `process-environment`, `recent-keys`
(which holds typed passwords), the minibuffer histories, `kill-ring`,
`auth-source` caches, and anything reachable from `obarray` with
`mapatoms`. Every one is a plain read, several already pass the gate
because byte-opt marks them side-effect-free, and the list is not
closed. A blocklist over an open set loses.

The buffer-name tools have the same gap from the other side:
`buffer-text` and `list-buffers` reach any live buffer with no scope,
including HTTP response buffers and terminals, by a documented decision
that reads were left unscoped.

## The principle

Integrity is a property of the form; confidentiality is a property of
the environment. A syntactic proof is the right instrument for the
first. For the second, the instrument is isolation: agent elisp runs in
a child Emacs that holds only an authorized set of data, stated
positively. Everything not in that set is unreachable rather than
forbidden, so a new reflection primitive in a future Emacs changes
nothing.

## Architecture

**The parent** is the resident Emacs. It runs the MCP server, owns the
live session, owns every policy decision below, and answers session
facts through named read-only tools.

**The child** is an Emacs spawned by `parenting-spawn` from the same
Nix-built configuration as the parent, in a mirror profile (no language
servers, no process-spawning modes), under a bwrap sandbox: a scrubbed
environment, and a filesystem view limited to the Nix store, the
configuration, the project directories, and the mirror directory. An
unsandboxed child would be weaker than today's gate, since `getenv`
would return real keys and `insert-file-contents` would read
`~/.authinfo`; the sandbox is part of the design, not a hardening step
after it. The child is spawned on first use, keyed to the parent's
configuration store path so that a switch replaces it, stopped after
idle, and kills itself when the connection closes, which `parenting`
already does.

**The mirror** is the data the child holds. The parent produces it per
request under the two contracts below.

**The agent's CLI** runs inside the same bwrap filesystem view as the
child, which makes a second editing mode possible: the CLI transform
(see "What runs where"). A buffer's inert text is materialized as a
file in the mirror directory, and the agent edits it with its ordinary
command-line tools (ripgrep, sed, its own ranged reads and writes) with
no Emacs round-trip; the edited text lands through the same back
channel as an elisp transform. The child Emacs reads the mirror as a
buffer; the agent reads and writes the same bytes as a file. Both come
from the one forward contract and pass the one set of filters, so the
file the agent sees is exactly the redacted, in-scope, unlatched text
the child sees, and no unfiltered path reaches the CLI.

## Forward contract: parent to child

Only inert text crosses. For each buffer the child receives the
contents as `buffer-substring-no-properties`, the buffer name, and the
file name if there is one. No text properties (they carry code:
`keymap`, `display` specs with functions, `help-echo` callbacks,
`yank-handler`), no overlays, no buffer-local values, no global
variables, no processes. The child recreates an ordinary in-memory
buffer and picks its major mode itself with `set-auto-mode` from the
file name, so sexp motion and indentation work for editing; a buffer
without a file stays in `fundamental-mode`. A terminal buffer may be a
source once the user has exposed it (terminals are sensitive by
default, below); what arrives is its text.

Syncing is incremental: `buffer-chars-modified-tick` tells the parent
which buffers changed since the last mirror, and only those are re-sent.

The same text is also written to a file in the mirror directory, named
for the buffer (the file name's basename when it has one, else a
sanitized buffer name). This is the file half of the CLI transform (see
"What runs where"): a tool asks for it by buffer name, the parent runs
the buffer through the same three filters, writes the result into the
mirror directory, and returns the in-jail path. A buffer the filters
refuse yields no file and an error naming the reason, so this surface
never exposes what the buffer-read tools would refuse.

Three filters apply, in this order.

1. **The buffer predicate.** A buffer carrying the sensitive mark (see
   "Marking a buffer sensitive") is never readable, before any other
   test. Otherwise a file-visiting buffer is readable exactly when its
   file would pass the auto-open scope
   (`ch-mcp-server-auto-open-scope`), which ties read scope to open
   scope through one rule. A buffer without a file is readable unless
   its name starts with a space, Emacs's convention for internal
   buffers and where the HTTP response buffers live, or matches a
   declared list of hidden names (seed: `*gptel-log*`). The same
   predicate is applied at every place the parent resolves a buffer by
   name, and `list-buffers` omits what it hides rather than listing it.
   A terminal (`ghostel-mode`) is sensitive by default (see "Marking a
   buffer sensitive"), so it is withheld until the user exposes it.

2. **The debug-knob latch**, for the log buffers `*Messages*`,
   `*Warnings*`, and `*Backtrace*`. A declared list names the variables
   that make libraries print secrets when set, with the value that
   counts as off: `url-debug` (nil), `auth-source-debug` (nil),
   `gptel-log-level` (nil), `debug-on-error` (nil),
   `smtpmail-debug-info` (nil), `tramp-verbose` (3 or lower). A
   variable watcher on each fires when it turns on, whether or not any
   sync is in progress, and drops a marker at `point-max` in each log
   buffer; when the knob turns off, a second marker. The region between
   them is the text written while the knob was on, and the buffer is
   refused, naming the knob, while that region is non-empty. Erasing
   the buffer, killing it, or the ordinary rolling of `message-log-max`
   all empty the region, so a tainted window clears itself once it has
   scrolled out.

3. **The secret scan.** gitleaks runs over the changed mirror files
   before the child reads them:

   ```
   gitleaks dir --no-banner --log-level error --redact \
     --report-format json --report-path - --exit-code 0 <mirror-dir>
   ```

   The stock rules are used as they are: they flag GitHub tokens,
   JWTs, provider keys, and PEM blocks, and they leave Nix store paths,
   `narHash` values, and git SHAs alone, so no entropy heuristics are
   enabled and no allowlist is needed. A hit redacts the matched span in
   the mirror copy with a placeholder naming the rule,
   `[REDACTED:github-pat]`, marks the child's buffer read-only, and
   marks the buffer refused on the back channel. The span is replaced
   by re-matching on the reported line rather than by column, since the
   columns are byte offsets. gitleaks comes from the pinned nixpkgs on
   the profile PATH.

The latch and the scan are not alternatives. The scan sees what has a
recognizable shape; the latch covers text written under conditions
known to leak, whatever its shape.

## Marking a buffer sensitive

The scan is a shape-matcher, so a secret it has no rule for, a bare
token, a passphrase, an SSH key body, passes it. The user needs a way
to withhold a buffer by declaration rather than by pattern, decided
before the secret is in it. One buffer-local state does this,
`ch-mcp-server-buffer-sensitivity`, with three values: unset (nil),
`sensitive`, or `exposed`. Unset means the buffer's kind decides the
default; either explicit value overrides it in that direction. The
buffer predicate reads the effective state and refuses a sensitive
buffer before any other test, so no buffer-read tool returns it, no
mirror file is written for it, it is omitted from listings, and neither
transform mode can reach it.

**The default is computed, not stamped.** A buffer is sensitive by
default when it is a terminal or visits a secret-named file. A terminal
(`ghostel-mode`, and the other terminal modes: `comint-mode` and what
derives from it, `term-mode`, `vterm-mode`, `eshell-mode`, a declared
list) shows whatever ran in it, an echoed password, a token in a
command line, the output of `env`. A secret-named file is one matching
`ch-mcp-server-sensitive-file-patterns` (seed: `~/.authinfo*`, `*.gpg`,
`*.age`, `.env` and `.env.*`, and a project's declared secrets file).
Every other buffer's default is readable. Because the default is a
computation over the buffer's mode and file name rather than a mark
stamped at open time, it needs no hook and holds however the buffer
came to visit the file; `.env` and a terminal are the same case,
withheld with the state still unset.

**One toggle, for any buffer.** `ch-mcp-server-toggle-buffer-sensitive`
(bound to `<leader> a t`) flips the effective state of the current
buffer: a withheld buffer becomes `exposed`, a readable one becomes
`sensitive`. Pressed in a terminal, which starts sensitive, the first
press exposes it; pressed in an ordinary buffer, it withholds it. It is
the quick per-buffer override of the defaults, and it is the same
command everywhere; terminals are not a special case of the toggle,
only of the default. The mode line shows the result for the displayed
buffer, `agent:hidden` or `agent:visible`, computed from the sensitivity
state and the debug-knob latch; the client-territory read scope is a
fact about the calling client, so the mode line leaves it out.

For a file the user knows is sensitive and no pattern anticipated,
`ch-mcp-server-visit-sensitive` reads a file name and visits it with the
state already `sensitive`, so the buffer never exists readable with the
secret in it. Toggling a buffer that already holds a secret still
withholds it going forward, but that is the fallback; the patterns and
the visit command exist so the common cases are withheld before the
content arrives. A file cannot set this variable through a file-local:
only nil is accepted, so a file can never expose itself.

This flag governs the buffer surfaces (the read tools and the mirror).
It does not reach a file the agent's own CLI opens inside the sandbox;
a file is kept from the CLI by not binding its directory into the jail
(see the back contract's territory and the sandbox bind list), which is
the isolation boundary, not this flag. The two together are the cover:
the flag for buffers, the bind list for files.

## Back contract: child to parent

Only text returns, and only to a buffer that visits a file or is an
in-memory buffer with no process attached. The parent accepts it when
all of the following hold: the file is inside the client territory (the
existing write scope); the buffer is not read-only in the parent; the
buffer was not redacted; and the parent's `buffer-chars-modified-tick`
still equals the value recorded when the mirror was taken. The text is
applied through the existing edit path, which returns a diff.

The mechanism is one parent function registered with
`parenting-allow-function`, whose argument predicate implements exactly
those checks, plus the connection's guard functions. Nothing else is
allowed, so the child has no other way to reach the parent; the
read-only flag in the child is a courtesy that stops honest mistakes,
and the parent's refusal is the enforcement.

Variables never cross in either direction. Printable data cannot carry a
closure, but it can carry a symbol naming a function into a hook
variable, so a synced variable is an effect.

## What runs where

- `eval-elisp` runs in the child, ungated, as a `parenting` task with a
  timeout and cancellation. The syntactic gate leaves this path.
- A buffer transform comes in two modes, siblings that differ only in
  what does the editing. Both run in the child against the mirrored
  buffer and both land the result through the one back channel. The
  **elisp transform** evaluates a form in the child Emacs (the existing
  `transform`, now ungated because the child is the sandbox; the editing
  registry retires with the gate). The **CLI transform** materializes
  the buffer as a file in the mirror directory and hands the agent that
  path; the agent edits the file with its own command-line tools, and
  the file's text is what returns. A read is the CLI transform with no
  edit: ask for the file, read it, return nothing. The file is a copy,
  so leaving it changed lands nothing on its own; only the returned text
  crosses the back channel, which is the single write path with all its
  checks.
- Session facts that are not text are answered by four named read-only
  tools in the parent (landed): `feature-loaded` (featurep, fboundp,
  boundp of a name, never a value), `hooks` (the functions on a hook,
  global and buffer-local, lambdas shown as `<lambda>`), `buffer-state`
  (mode, minor modes, flags, size, point, Evil state, a terminal's input
  mode, sensitivity, agent visibility), and `key-binding` (what a key
  resolves to in a buffer, through Evil's state maps). A named buffer
  passes the same read scope as `buffer-text`. There is no open
  evaluator in the parent.

The mirror also cannot answer questions about the parent's own runtime
state, which is why those tools exist rather than an escape hatch.

## The scan covers every file view, and is not a boundary

The gitleaks scan runs on every path by which content reaches the
agent's context, not only the mirror, and including the CLI's own
built-in tools (`Read` and `Bash` alike), not only the MCP tools. Any
tool result that would put bytes in the agent's context is scanned
first; on a hit the content is returned redacted, the agent is told,
and for `Read` it may resubmit to ask the user for the real bytes
(`Bash` differs on both counts, see "Redact and tell; resubmit to
approve"). A buffer's text reaches the agent
through the mirror
(buffer-read tools, the file in the mirror directory) and is scanned
there. A file's content reaches the agent through the MCP file-reading
tools, the CLI's `Read`, and the output of a shell command run through
`Bash`; all are scanned, or they are the bypass that makes redacting the
mirror pointless (reading `~/.env` directly, or `cat`-ing it, would
defeat a redacted mirror of it).

There are two enforcement points, in two repos. The MCP server scans
its own reads before returning them and redacts the matched spans in
place (workbench). The CLI's built-in tools are handled by a hook in
the `claude-code` module, and this covers `Bash` as well as `Read`: a
shell command's output is a tool result before it reaches context, so
the hook receives its stdout and stderr and scans them the same way. So
a `cat` of a bound file is covered after all: it is a `Bash` result,
and it is scanned. The distinction that matters is not tool-read versus
shell-read; it is whether the bytes pass through the harness at all.

What genuinely escapes is only what never becomes a tool result: a
subprocess the agent's own code spawns whose output the harness does
not capture, or a byte stream routed around the tool channel entirely.
That is a narrow residue, and it is the sandbox bind list's to cover,
not the scan's: a secret in a directory never bound into the jail
cannot be reached by any means, tool or not.

### Redact and tell; resubmit to approve (Read); Bash cannot retry

A scan hit never fails a read. The matched spans come back redacted with
a placeholder naming the rule (`[REDACTED:github-pat]`), and the agent
is told a redaction occurred. The agent proceeds on the redacted text,
which is the common case: it wanted the file, not the secret in it.

For `Read` and the MCP file tools, the agent may ask for the real bytes
by resubmitting the identical read. That second submission of the same
read raises a prompt to the user; the unredacted content crosses only on
approval, and a denial returns the redacted text again. The resubmit is
recognized as the same read by a single-use idempotency key over the
request (tool, target, range), so a later unrelated read of the same
path is a first submission and is redacted afresh, not silently approved
by a stale key. This is the design's consent posture: routine reads are
automatic, the one that crosses a sensitive boundary is the user's to
allow.

`Bash` output is the exception, in two ways. First, a shell stream has
no file the agent holds to see marked, so its stdout and stderr are
captured, run through a `gitleaks_redact` step (the scanner writing a
marked, redacted copy), and that distinct copy is what the agent
receives; the separate artifact is what makes the filtering evident
rather than handing back bytes that silently differ from what the
command printed. Second, a `Bash` result carries no retry-for-raw
option: there is no resubmit-to-approve for it, because "the identical
read" has no clean meaning for a command whose output varies run to run
(a live tail, a timestamped listing). To see a shell command's raw
output the user runs it themselves, outside the agent's tool channel.

Either way the boundary is the same: the only way the agent sees a
secret without a per-read approval is a deliberate user action outside
the read path, exposing a buffer, binding a path, handing over the
value. The scan does not decide who may see a secret; the user does, by
what is exposed and by answering the resubmit prompt.

The scan is accident-prevention, not access control, and edit is why it
cannot be more, in two ways. First, an edit verb that reports whether an
`old_string` matched is an oracle: an agent can recover a secret it
cannot read by proposing replacements and extending the confirmed
prefix one match-or-no-match at a time, never reading the value.
Second, and worse, a landed edit lets the agent move the secret past
the scan in one step: the scan matches known token shapes, so an edit
that breaks the shape (split the token across lines, insert a character
mid-token, base64 or reverse it) makes the next scan pass, and the
mutated text comes back in full on the next read. This needs no
guessing; it is one edit and one read, and the mutation space is
unbounded, so no better scan closes it. Redacting reads does nothing
against either, and the matching cannot be redacted without breaking
edit. So the scan stops a secret from landing in the agent's context by
being read or shown; it does not stop a determined agent from
extracting one it can already edit. Both attacks need the secret to be
in a file the agent can edit, which means already inside the sandbox's
view, so the confidentiality boundary is isolation, what is never
mirrored in and what the sandbox's filesystem view withholds, not the
scan.

## Residual accepted surface

Log text is only as clean as the latch and the scan: a bare secret with
no recognizable shape passes, and a knob outside the declared list is
invisible until someone adds it. The mirror is a snapshot and can lag
the screen. A file that mixes a secret with settings the agent needs to
edit has the secret redacted in the copy it sees, so an edit returned
from that copy would carry the placeholder back; splicing the original
spans back into returned text is deferred until that blocks real work,
since it adds a clever path the rest of the design avoids, and until
then such a buffer is effectively read-only through the mirror. The
edit-oracle extraction above is accepted, not closed. Same-user
boundaries stay soft. This is accident-surface hardening for an agent
expected to help debug, not an adversarial sandbox, and any program can
print a secret into a log.

## Settled

- No confidentiality blocklist is built inside the parent; the
  observable set is open.
- A per-symbol rules registry keyed by function or value position was
  designed and is superseded by isolation; only the buffer predicate and
  the secret policy survive, as mirror filters.
- Variables are never synced.
- A redaction placeholder never round-trips into a file: a redacted
  buffer is read-only.
- The child is only a sandbox with the OS sandbox in place.
- A sensitive buffer is withheld by an explicit user mark, not by the
  scan; the mark is set before the secret arrives (on open, by command
  or by pattern), and the scan is not trusted to catch what the user
  already knows is sensitive.
- Sensitivity is one per-buffer state with a computed default:
  terminals and secret-named files start sensitive, everything else
  starts readable, and one generic toggle flips any buffer either way.
  Terminals and `.env` are special cases of the default, not of the
  toggle.
- Every tool result that reaches the agent's context is scanned and
  redacted, `Read` and `Bash` alike (a shell command's output is a tool
  result, so `cat` is covered). `Read` and the MCP tools mark the spans
  in place and let the agent resubmit the identical read to raise a user
  prompt for the real bytes (single-use idempotency key over tool,
  target, range). `Bash` output goes through `gitleaks_redact` into a
  distinct redacted artifact and has no retry: to see a command's raw
  output the user runs it themselves. Either way, the agent sees a
  secret without a per-read approval only by a deliberate user action
  outside the read path (exposing a buffer, binding a path, handing over
  the value).

## Dependencies

- **parenting** gains a `:sandbox` keyword: a declarative spec
  (environment pass-through list, read-only and read-write binds,
  network on or off) that the package turns into a bwrap command line,
  always binding its own socket directory and library directory,
  passing `--die-with-parent`, and mounting the system directories the
  binary needs plus `/nix/store` read-only when present. These are facts
  the package already owns (`:child-socket-path`,
  `:child-library-directory`), which is why the builder belongs there;
  `:command-wrapper` remains the escape hatch and the composition point
  for remote spawns. Tests must skip where user namespaces are
  unavailable. Later: the spec (paths, environment, network) is
  backend-neutral, so the bwrap builder becomes one backend behind a
  `parenting-sandbox-backend` selector, with Landlock (Linux, no
  namespaces; the workspace already has a shim) and macOS `sandbox-exec`
  as further backends. Those two differ from bwrap in one way the
  mirror must note: ungranted paths stay visible by name but unreadable,
  where bwrap leaves them absent.
- **The editor layer's mirror profile** (landed): `ch/mirror-profile`, a
  variable the spawner sets on the child's command line before the
  configuration loads (`--eval (setq ch/mirror-profile t)`). The inits
  that start external programs or long-lived helpers consult it and stay
  off: eglot, envrc (direnv), jinx, and ghostel's terminal on a client
  frame. A runtime variable rather than a Nix option, so one built
  configuration serves the interactive session and its mirror children;
  the `emacs-mirror-profile` check loads the init with and without it and
  asserts hook membership both ways.
- **The `ghostel-terminals` skill** was an untracked, hand-placed file
  telling the agent terminals are always readable buffers. Terminals
  sensitive-by-default reverses that, so the skill is adopted into the
  workbench's skills beside `emacs-tools` with matching text: the agent
  sees a terminal only once the user has exposed it, and asks rather
  than assuming otherwise. Lands with phase 1b.
- **gitleaks** on the profile PATH from the pinned nixpkgs.
- **The `claude-code` module** gains the hook that scans the CLI's
  built-in tool results before they reach context: `Read` redacted in
  place with the resubmit-to-approve prompt, `Bash` output through
  `gitleaks_redact` into a distinct artifact with no retry. It lives
  with the CLI's other hooks, not in the MCP server, and is the second
  of the two enforcement points above.

## Phases

1. Parent side only: the buffer predicate at every resolver with
   `list-buffers` filtering, and the debug-knob latch. Stands alone and
   narrows the tools that stay in the parent regardless. (Landed.)
1b. Buffer sensitivity: the buffer-local
   `ch-mcp-server-buffer-sensitivity` (unset, `sensitive`, `exposed`),
   the predicate refusing the effective state first, a computed default
   (terminal modes and `ch-mcp-server-sensitive-file-patterns` matches
   start sensitive), the generic `ch-mcp-server-toggle-buffer-sensitive`
   on `<leader> a t`, the `ch-mcp-server-visit-sensitive` command, and
   the `ghostel-terminals` skill adopted into the workbench with
   matching text. Parent-side and independent of the child, so it lands
   next to phase 1; the mirror in phase 3 already refuses through the
   same predicate.
2. The child with configuration only, sandboxed, as the target for
   `eval-elisp`. This already answers every static question (keymaps,
   functions, defaults, features); the gated live path remains for
   session facts until the named tools exist.
3. The mirror (forward contract, incremental sync, secret scan) and the
   back channel; both transform modes move to the child, the elisp one
   and the CLI one; the gated live evaluation is deleted; named tools
   replace it for session facts. The MCP read tools scan and redact
   here.
4. The CLI-side hook in the `claude-code` module: `Read` redacted in
   place with the resubmit-to-approve prompt (single-use idempotency
   key), and `Bash` output through `gitleaks_redact` into a distinct
   artifact with no retry. Depends on the scan existing (phase 3) and on
   the sandbox bind list (phase 2), and completes "every tool result
   into context is scanned" for the CLI's own tools.

The `parenting` `:sandbox` work can precede phase 2 or land alongside
it.
