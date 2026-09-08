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
source; what arrives is its text.

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

1. **The buffer predicate.** A file-visiting buffer is readable exactly
   when its file would pass the auto-open scope
   (`ch-emacs-config-mcp-auto-open-scope`), which ties read scope to
   open scope through one rule. A buffer without a file is readable
   unless its name starts with a space, Emacs's convention for internal
   buffers and where the HTTP response buffers live, or matches a
   declared list of hidden names (seed: `*gptel-log*`). The same
   predicate is applied at every place the parent resolves a buffer by
   name, and `list-buffers` omits what it hides rather than listing it.
   Terminals stay visible.

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
- Session facts that are not text (Evil state, a terminal's input mode,
  hook lists, which features are loaded, what a key resolves to in the
  live session) are answered by small named read-only tools in the
  parent. There is no open evaluator in the parent.

The mirror also cannot answer questions about the parent's own runtime
state, which is why those tools exist rather than an escape hatch.

## The scan covers every file view, and is not a boundary

The gitleaks scan runs on every path by which file content reaches the
agent, not only the mirror. A buffer's text reaches the agent through
the mirror (buffer-read tools, the file in the mirror directory) and is
scanned there. A file's content also reaches the agent through the
ordinary file-reading tools and through the CLI's own reads inside the
sandbox; those pass through the scan too, or they are the bypass that
makes redacting the mirror pointless (reading `~/.env` directly defeats
a redacted mirror of it). Concretely: the file-reading tools scan and
redact before returning, and the CLI sees only files inside the bwrap
view, which holds the mirror and the bound project directories, so what
it can open is the scanned set.

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
  unavailable.
- **The editor layer** gains a mirror-profile option: no language-server
  autostart, no process-spawning modes.
- **gitleaks** on the profile PATH from the pinned nixpkgs.

## Phases

1. Parent side only: the buffer predicate at every resolver with
   `list-buffers` filtering, and the debug-knob latch. Stands alone and
   narrows the tools that stay in the parent regardless.
2. The child with configuration only, sandboxed, as the target for
   `eval-elisp`. This already answers every static question (keymaps,
   functions, defaults, features); the gated live path remains for
   session facts until the named tools exist.
3. The mirror (forward contract, incremental sync, secret scan) and the
   back channel; both transform modes move to the child, the elisp one
   and the CLI one; the gated live evaluation is deleted; named tools
   replace it for session facts.

The `parenting` `:sandbox` work can precede phase 2 or land alongside
it.
