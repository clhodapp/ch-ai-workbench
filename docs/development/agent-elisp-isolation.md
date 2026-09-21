# Agent Elisp Isolation

Design, 2026-09-07, built in the order the section at the end gives. The subject is the elisp an agent runs against the
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
Nix-built configuration as the parent, with the configuration's
spawners unhooked after it loads (no language servers, no
process-spawning modes; see the dependencies), under a bwrap sandbox: a scrubbed
environment, and a filesystem view limited to the Nix store, the
configuration, and the project directories. An
unsandboxed child would be weaker than today's gate, since `getenv`
would return real keys and `insert-file-contents` would read
`~/.authinfo`; the sandbox is part of the design, not a hardening step
after it. The child is spawned on first use, keyed to the parent's
configuration store path so that a switch replaces it, stopped after
idle, and kills itself when the connection closes, which `parenting`
already does. The child never performs a trusted step: every filter and
check runs in the parent, and what the child returns is data (see
"Settled").

**The copied text** is the data the child holds. The parent produces it
per request under the two contracts below.

**The agent's CLI** gets a second editing mode, the CLI transform (see
"What runs where"), without sharing the child's filesystem view: a
buffer's inert text is written as a file into the calling client's
territory, under the directory the CLI's own sandbox uses as
per-checkout scratch (`.claude/claude-code-sandbox/`, which sandboxed
commands can write and the clone's exclude file keeps out of `git
status`), and the agent edits it with its ordinary command-line tools
(ripgrep, sed, its own ranged reads and writes) with no Emacs
round-trip; the edited text lands through the same back contract as an
elisp transform. The file passes the same filters as every copy, so
what the agent sees is exactly the redacted, in-scope, unlatched text
the child would see, and no unfiltered path reaches the CLI. The child
never sees these files.

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
which buffers changed since the last copy, and only those are re-sent.
The copies are refreshed before each evaluation in the child, and a
buffer that dies or stops passing the filters is removed from the
child on the next refresh.

The same text is also written to a file in the copy directory, a
parent-internal temporary directory created and deleted with the
child, named for the buffer with every character outside letters,
digits, dot, dash, and underscore replaced by `%`; gitleaks runs over
that directory (below). The CLI transform's file is a separate write
of the same filtered text (see "What runs where"): a tool asks for it
by buffer name, the parent runs the buffer through the same filters,
writes the result under the client's territory, and returns the path.
A buffer the filters refuse yields no file and an error naming the
reason, so this surface never exposes what the buffer-read tools would
refuse.

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

3. **gitleaks.** It runs once over the copy directory before the
   changed copies are sent to the child:

   ```
   gitleaks dir --no-banner --log-level error \
     --report-format json --report-path - --exit-code 0 <copy-dir>
   ```

   The report carries the matched secret in clear so the parent can
   find it in the text; it is read by the parent and goes nowhere
   else. The stock rules are used as they are: they flag GitHub tokens,
   JWTs, provider keys, and PEM blocks, and they leave Nix store paths,
   `narHash` values, and git SHAs alone, so no entropy heuristics are
   enabled and no allowlist is needed. A hit replaces the matched span
   in the copy with a numbered placeholder naming the rule,
   `[REDACTED:github-pat:1]`, and the parent keeps the original beside
   the copy's record. When text from that copy lands, the parent puts
   each original back in place of its placeholder before anything
   touches the buffer (see the back contract), so the buffer never
   receives a placeholder and the agent never sees the secret; a
   placeholder the record cannot map, altered or invented, refuses the
   landing. The span is replaced by matching the reported secret on its
   reported lines rather than by column, since the columns are byte
   offsets; a match the parent cannot find on those lines (a multi-line
   one) has its whole line range collapsed to one placeholder line, and
   the original kept is those lines' text. A gitleaks that cannot run
   is a tool error, and no copy is sent before gitleaks has passed over
   it. gitleaks comes from the pinned nixpkgs.

The latch and gitleaks are not alternatives. gitleaks sees what has a
recognizable shape; the latch covers text written under conditions
known to leak, whatever its shape.

## Marking a buffer sensitive

gitleaks matches shapes, so a secret it has no rule for, a bare
token, a passphrase, an SSH key body, passes it. The user needs a way
to withhold a buffer by declaration rather than by pattern, decided
before the secret is in it. One buffer-local state does this,
`ch-mcp-server-buffer-sensitivity`, with three values: unset (nil),
`sensitive`, or `exposed`. Unset means the buffer's kind decides the
default; either explicit value overrides it in that direction. The
buffer predicate reads the effective state and refuses a sensitive
buffer before any other test, so no buffer-read tool returns it, no
copy is written for it, it is omitted from listings, and neither
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

This flag governs the buffer surfaces (the read tools and the copies).
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
still equals the value recorded when the copy was taken. The text is
applied through the existing edit path, which returns a diff.

The parent pulls: it evaluates the form in the child and takes the
copy's text as the value, then runs those checks in one landing
function (`ch-mcp-server--land-text`) before the text touches the
buffer. No function is registered for the child to call, so it has no
way to reach the parent at all; the read-only flag in the child is a
courtesy that stops honest mistakes, and the parent's refusal is the
enforcement.

Variables never cross in either direction. Printable data cannot carry a
closure, but it can carry a symbol naming a function into a hook
variable, so a synced variable is an effect.

## What runs where

- `eval-elisp` runs in the child, ungated, as a `parenting` evaluation
  with a timeout. The syntactic gate leaves this path. The value is
  printed in the child, so a buffer or marker arrives as its printed
  text; an error in the child is a tool error carrying its message. A
  form still running at the deadline cannot be interrupted in the
  child, so the child is stopped and the next call starts a fresh one;
  the call returns a tool error saying so.
- A buffer transform comes in two modes, siblings that differ only in
  what does the editing. Both run in the child against the copied
  buffer and both land the result through the one back channel. The
  **elisp transform** evaluates a form in the child Emacs (the existing
  `transform`, now ungated because the child is the sandbox; the editing
  registry retired with the gate). The **CLI transform**
  (`buffer-file` and `land-buffer-file`) writes the buffer as a
  file under the client's territory and hands the agent that path; the
  agent edits the file with its own command-line tools, and the file's
  text is what lands. A read is the CLI transform with no landing: ask
  for the file, read it. The file is a copy, so leaving it changed lands
  nothing on its own; only the landed text crosses the back contract,
  which is the single write path with all its checks, and the file is
  removed once landed or refused.
- Session facts that are not text are answered by four named read-only
  tools in the parent: `feature-loaded` (featurep, fboundp,
  boundp of a name, never a value), `hooks` (the functions on a hook,
  global and buffer-local, lambdas shown as `<lambda>`), `buffer-state`
  (mode, minor modes, flags, size, point, Evil state, a terminal's input
  mode, sensitivity, agent visibility), and `key-binding` (what a key
  resolves to in a buffer, through Evil's state maps). A named buffer
  passes the same read scope as `buffer-text`. There is no open
  evaluator in the parent.

The child holds copies only, so it cannot answer questions about the
parent's own runtime state either, which is why those tools exist
rather than an escape hatch.

## Redaction covers every file view, and is not a boundary

gitleaks runs on every path by which content reaches the agent's
context, not only the copies, and including the CLI's own built-in
tools (`Read` and `Bash` alike), not only the MCP tools. Any tool
result that would put bytes in the agent's context passes through it
first; on a finding the content is returned redacted, the agent is told,
and for `Read` it may resubmit to ask the user for the real bytes
(`Bash` differs on both counts, see "Redact and tell; resubmit to
approve"). A buffer's text reaches the agent as a copy (through the
buffer-read tools, or as the file in the copy directory) and gitleaks
runs there. A file's content reaches the agent through the MCP
file-reading tools, the CLI's `Read`, and the output of a shell command
run through `Bash`; all pass through gitleaks, or they are the bypass
that makes redacting the copy pointless (reading `~/.env` directly, or
`cat`-ing it, would defeat a redacted copy of it).

There are two enforcement points, in two repos. The MCP server runs
gitleaks over its own reads before returning them and redacts the
matched spans in place (workbench). The CLI's built-in tools are
handled by a hook in the `claude-code` module, and this covers `Bash`
as well as `Read`: a shell command's output is a tool result before it
reaches context, so the hook receives its stdout and stderr and runs
gitleaks over them the same way. So a `cat` of a bound file is covered
after all: it is a `Bash` result, and gitleaks runs over it. The
distinction that matters is not tool-read versus shell-read; it is
whether the bytes pass through the harness at all.

What genuinely escapes is only what never becomes a tool result: a
subprocess the agent's own code spawns whose output the harness does
not capture, or a byte stream routed around the tool channel entirely.
That is a narrow residue, and the sandbox bind list covers it, not
gitleaks: a secret in a directory never bound into the jail cannot be
reached by any means, tool or not.

### Redact and tell; resubmit to approve (Read); Bash cannot retry

A finding never fails a read. The matched spans come back redacted with
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
redacted in the result itself, and the note beside the result is what
makes the filtering evident rather than handing back bytes that
silently differ from what the command printed. Second, a `Bash` result carries no retry-for-raw
option: there is no resubmit-to-approve for it, because "the identical
read" has no clean meaning for a command whose output varies run to run
(a live tail, a timestamped listing). To see a shell command's raw
output the user runs it themselves, outside the agent's tool channel.

Either way the boundary is the same: the only way the agent sees a
secret without a per-read approval is a deliberate user action outside
the read path, exposing a buffer, binding a path, handing over the
value. gitleaks does not decide who may see a secret; the user does, by
what is exposed and by answering the resubmit prompt.

Redaction is accident-prevention, not access control, and edit is why
it cannot be more, in two ways. First, an edit verb that reports whether an
`old_string` matched is an oracle: an agent can recover a secret it
cannot read by proposing replacements and extending the confirmed
prefix one match-or-no-match at a time, never reading the value.
Second, and worse, a landed edit lets the agent move the secret past
gitleaks in one step: gitleaks matches known token shapes, so an edit
that breaks the shape (split the token across lines, insert a character
mid-token, base64 or reverse it) makes the next run find nothing, and
the mutated text comes back in full on the next read. This needs no
guessing; it is one edit and one read, and the mutation space is
unbounded, so no better matcher closes it. Redacting reads does nothing
against either, and the matching cannot be redacted without breaking
edit. So redaction stops a secret from landing in the agent's context
by being read or shown; it does not stop a determined agent from
extracting one it can already edit. Both attacks need the secret to be
in a file the agent can edit, which means already inside the sandbox's
view, so the confidentiality boundary is isolation, what is never
copied in and what the sandbox's filesystem view withholds, not
gitleaks.

## Residual accepted surface

Log text is only as clean as the latch and gitleaks: a bare secret with
no recognizable shape passes, and a knob outside the declared list is
invisible until someone adds it. A copy is a snapshot and can lag the
screen. A file that mixes a secret with settings the agent needs to
edit is editable through its redacted copy, since the parent puts the
original spans back when text lands; the agent can still delete or
duplicate a placeholder, and with it the secret, which the returned
diff shows (redacted) and the user sees in the buffer. The edit-oracle
extraction above is accepted, not closed. The MCP tools have no
resubmit-to-approve of their own: a redacted MCP read stays redacted,
since the prompt would have to come from inside a tool handler in the
live Emacs, and the CLI's `Read` with its prompt covers the file case.
Same-user boundaries stay soft. This is accident-surface hardening for
an agent expected to help debug, not an adversarial sandbox, and any
program can print a secret into a log.

## Settled

- No confidentiality blocklist is built inside the parent; the
  observable set is open.
- A per-symbol rules registry keyed by function or value position was
  designed and is superseded by isolation; only the buffer predicate and
  the secret policy survive, as the filters on what is copied.
- Variables are never synced.
- A redaction placeholder never round-trips into a buffer: placeholders
  are numbered, the parent keeps each original beside the copy's
  record, and a landing puts them back before the text touches the
  buffer; a placeholder the record cannot map refuses the landing.
- The child is only a sandbox with the OS sandbox in place.
- The child never performs a trusted step. The filters, the gitleaks
  run and the redaction, the redaction record, and the landing checks
  (read-only, tick) all run in the parent, before text is sent to the
  child or after text comes back; the read-only flag on a redacted copy
  in the child is a courtesy. Everything the child returns is data,
  read but never evaluated, and type-checked before use. This is a
  blanket rule from the first spawn, not a state that begins with the
  first agent form, so no step has to know whether agent code has run.
- A sensitive buffer is withheld by an explicit user mark, not by
  gitleaks; the mark is set before the secret arrives (on open, by
  command or by pattern), and gitleaks is not trusted to catch what the
  user already knows is sensitive.
- Sensitivity is one per-buffer state with a computed default:
  terminals and secret-named files start sensitive, everything else
  starts readable, and one generic toggle flips any buffer either way.
  Terminals and `.env` are special cases of the default, not of the
  toggle.
- Every tool result that reaches the agent's context passes through
  gitleaks and is redacted, `Read` and `Bash` alike (a shell command's output is a tool
  result, so `cat` is covered). `Read` and the MCP tools mark the spans
  in place and let the agent resubmit the identical read to raise a user
  prompt for the real bytes (single-use idempotency key over tool,
  target, range). `Bash` output is redacted in the result with the
  note beside it and has no retry: to see a command's raw output the
  user runs it themselves. Either way, the agent sees a
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
  as further backends. Those two differ from bwrap in one way this
  design must note: ungranted paths stay visible by name but unreadable,
  where bwrap leaves them absent.
- **The editor is not changed.** The editor sits below the workbench
  and knows nothing about agents; a knob in it with the workbench as
  its one consumer would invert that. The child loads the editor
  configuration as it is and the workbench neutralizes the spawners
  from its side, in the child's bootstrap after the `require`. In a
  child started with `-Q` and connected before the configuration
  loads, `after-init-hook` and `emacs-startup-hook` have already run,
  so envrc and jinx never start; no client frame ever exists, so
  ghostel's terminal never opens; the one live spawner is
  `eglot-ensure` on the mode hooks, which the bootstrap removes. The
  lifecycle piece's smoke test asserts that state in the child.
- **The `ghostel-terminals` skill** was an untracked, hand-placed file
  telling the agent terminals are always readable buffers. Terminals
  sensitive-by-default reverses that, so the skill is adopted into the
  workbench's skills beside `emacs-tools` with matching text: the agent
  sees a terminal only once the user has exposed it, and asks rather
  than assuming otherwise.
- **gitleaks** on the profile PATH from the pinned nixpkgs.
- **The `claude-code` module** gains the `redact` hook, PostToolUse on
  every tool: the result's string leaves pass through gitleaks and a
  finding replaces what the model sees (`updatedToolOutput`, keeping
  the result's shape), with a note naming the rules beside it
  (the replacement is probe-verified on 2.1.259, see
  `claude-cli.md`). The resubmit-to-approve prompt for `Read` is the
  `reveal` hook, PreToolUse on `Read`, keyed like the tic-check edit
  hook (a hash of the call, marked by the redact hook when the result
  was redacted), asking through the `claude-consent` spool; allow lets
  that one result through unredacted, and deny, a timeout, or no
  attached answerer leaves the redacted view standing with the reason
  told to the model. It lives with the CLI's other hooks,
  not in the MCP server, and is the second of the two enforcement
  points above.

## Landing order

The pieces landed in this order, each as its own pull request, so
that every step stood alone.

1. Parent side only: the buffer predicate at every resolver with
   `list-buffers` filtering, and the debug-knob latch. These narrow
   the tools that stay in the parent regardless of the child.
2. Buffer sensitivity: the buffer-local
   `ch-mcp-server-buffer-sensitivity` (unset, `sensitive`, `exposed`),
   the predicate refusing the effective state first, a computed default
   (terminal modes and `ch-mcp-server-sensitive-file-patterns` matches
   start sensitive), the generic `ch-mcp-server-toggle-buffer-sensitive`
   on `<leader> a t`, the `ch-mcp-server-visit-sensitive` command, and
   the `ghostel-terminals` skill adopted into the workbench with
   matching text. Parent-side and independent of the child; the
   copying later refuses through the same predicate.
3. `parenting`'s `:sandbox` keyword, then the child's lifecycle, then
   `eval-elisp` routed to the child, which already answers every
   static question (keymaps, functions, defaults, features) while the
   named session-fact tools answer the rest.
4. The copying of buffer text (forward contract, incremental
   refresh, gitleaks redaction), then `transform` in the child with the
   back contract, which deleted the gated live evaluation and the
   editing registry, then every MCP tool result through gitleaks in the
   parent, then the CLI transform through the territory's sandbox
   scratch.
5. The CLI-side hooks in the `claude-code` module: every tool result
   redacted in place through PostToolUse `updatedToolOutput` with a
   note beside it, `Bash` with no retry, and the resubmit-to-approve
   prompt for `Read` through the `claude-consent` spool. This completed
   "every tool result into context passes through gitleaks" for the
   CLI's own tools.
