---
name: emacs-tools
description: Usage depth for the emacs MCP server's agent tools (diagnostics, find-references/definition, symbol-info, document-outline, modified-buffers, buffer-diff, present, sidebar, edit-buffer/edit-file, transform, add-comment/list-comments, and the enhanced context/buffer-text). Read when reaching for these tools beyond their one-line triggers — especially BEFORE using the edit verbs or transform, before presenting to the user, before commenting on shared text, or when an LSP-backed tool errors or seems stale.
---

# Emacs agent tools

These tools answer questions only the user's live Emacs session can
answer: warm LSP servers (eglot with correct per-project config and
envrc environments), unsaved buffer state, where the user's attention
is, and the editing engine. Anything grep / ranged reads / native edits
do well stays native — these are not mirrors of those.

Design and rationale: `projects/ch-emacs-config/docs/development/emacs-mcp-agent-tools.md`.
Safety rules: the `live-emacs-safety` skill (read-only tools are fine
unasked; `present` and buffer auto-open are consented by design).
Two server-side filters are structural, not etiquette: writes
(edit-file, transform, edit-buffer on file-backed buffers) are
confined to your session's territory — the project you were launched
in — and eval-elisp/transform accept only elisp the server can prove
safe (below). A filter refusal is a boundary, not a bug: don't route
around it; ask the user, who owns the widening knobs.

## Conventions

- Positions **in**: absolute `file`, 1-based `line`, 1-based `col` —
  exactly what `grep -n --column` / rg prints.
- Locations **out**: `path:line:col: text` lines, capped with the true
  total appended when truncated (`limit` param where it matters).
- Everything is plain text; no elisp on any common path.

## Tool notes

- **diagnostics** — omit `file` to sweep every file-visiting buffer.
  Trust the status trailer: "check pending or running" means *not yet
  checked*, not clean — retry shortly. Stale unmodified buffers are
  auto-reverted first, so results reflect disk after your own edits.
- **find-references / find-definition / symbol-info** — need the file
  in a buffer with a backend: eglot for LSP modes, native xref for
  elisp. "No LSP (eglot) server manages …" usually means the file
  wasn't open and auto-open couldn't boot a server fast enough, or the
  mode has no server configured; a timeout error means the server hung
  — both are per-call failures, not session breakage.
- **modified-buffers → buffer-diff** — the don't-clobber-the-user
  sequence. Before editing files in the user's active project, run
  modified-buffers (cheap); on a hit for a file you want to touch, get
  buffer-diff and *incorporate* the user's in-flight changes rather
  than fighting them on disk.
- **document-outline** — orientation in big files without reading them;
  works in every mode via imenu.
- **buffer-text** — takes `start-line`/`end-line` for paging, and
  `numbered: yes` for native-Read-style line-numbered output (use when
  the answer will feed line-addressed tools).

## Auto-open policy

Tools that take a `file` resolve it to a buffer: existing buffer
(reverted if stale and unmodified), else `find-file-noselect` — which
boots LSP via the normal mode hooks. Auto-open covers files in your
session's own territory unconditionally (worktree checkouts included),
plus files under a project that already has buffers in the session
(`ch-emacs-config-mcp-auto-open-scope`, default `session-projects`;
`any-project` opens anything readable).

To deliberately open a file — including booting a project's eglot
server by touching its first file — invoke any file-taking tool on it
(`document-outline` is the cheap one); opening happens windowless as a
side effect, within the same scope. Prefer files actually relevant to
the task so the session doesn't accumulate noise.

## present: before asking, show

Before asking the user a non-trivial question, write the full context
(options, tradeoffs, evidence) into a `present` buffer, then ask with
terse labels referencing it. Also for "here's what I found, organized".

- `mode: markdown` (default) for prose — `markdown-ts-mode` with
  `visual-line-mode`, so write paragraphs as long lines and let the
  window soft-wrap them; `diff` for proposed changes;
  `locations` for evidence lists — `path:line:col: text` lines become
  clickable jumps; `mermaid` for diagrams — content is mermaid source,
  rendered to an SVG image in the buffer. Use it wherever you'd have
  drafted a mermaid block into plan text: architecture, sequences,
  DAGs. Render errors return mmdc's own message — fix the source and
  re-present under the same name.
- Buffers are named `*agent/<name>*`; reusing a name rewrites the
  buffer (fine for iterating on the same artifact).
- `display: no` writes without raising a window. Display never steals
  focus; the user's display-buffer-alist rules govern placement.

## sidebar: read-once material beside the reply

`sidebar (name, content)` shows markdown in a right-hand side window
(20% of the frame) that the user dismisses with `q`, which also kills
the buffer. Use it for anticipated questions with answers, a glossary,
a checklist — things read once alongside the reply. Use `present` for
artifacts the user keeps. Write paragraphs as single long lines; the
window soft-wraps. Buffers are `*agent/sidebar/<name>*`; reusing a
name rewrites the sidebar.

## edit-buffer / edit-file: the single surgical change

Your native Edit contract, in the live editor: literal `old-string`
(never regex), must match **exactly once** or the call fails naming the
count (`replace-all: yes` opts out), `old-string` ≠ `new-string`. Two
verbs, split so restricted dispatch profiles can withhold disk writing
by tool name (workspace `consent-gate.md`): **edit-file** takes a
`file` (auto-open rules apply), edits its buffer, and always saves;
**edit-buffer** takes a `buffer` name (any live buffer, including
`*agent/…*` co-editing buffers) and never writes disk — a file-visiting
buffer is left modified as a staged edit for the user to review and
save. Both return a unified diff — read it; that is the verification
step.

- The uniqueness rule is also the concurrency story: when the user is
  editing the same buffer live, a stale anchor fails loudly instead of
  editing the wrong occurrence. On failure, re-read and re-anchor.
- edit-file refuses buffers with unsaved user modifications (use
  buffer-diff and incorporate, or stage via edit-buffer). edit-buffer
  accepts them: the change stays in the buffer under the user's eyes.
- Prefer the edit verbs over hand-rolled eval-elisp search/replace for
  any single replacement; prefer transform below for 3+ or structural.

## transform: the editing engine

Trigger: **3+ similar edits in one file, or a structural edit** (sexp
wrap/raise/splice, computed replacements, reindentation) — one short
form instead of N native edits. Not for one or two ordinary edits;
native edit tools stay the default.

- Runs your elisp with the buffer current, returns a **unified diff**
  of what changed — read it; that diff is the verification step.
- **Gated elisp**: only motion, search, and current-buffer editing
  functions are accepted (the server's agent-safe registries; the
  rejection names the offender). No `set-buffer`, no kill ring (use
  `delete-region`), no `replace-regexp`/`query-replace-regexp` (their
  replacement strings evaluate embedded elisp) — write the
  re-search-forward + replace-match loop instead. Computation in the
  replacement (string ops, `match-string`, arithmetic) is fine.
- Refuses buffers with unsaved user modifications (use buffer-diff).
- Errors restore the buffer untouched.
- Saves to disk by default (`save: no` to stage in-buffer only).
- Point starts wherever it was: begin with `(goto-char (point-min))`.
- **After a transform, re-read the file before further native edits** —
  the harness requires re-reading files changed outside its own tools.

Recipes:

```elisp
;; computed multiline replacement across matches
(goto-char (point-min))
(while (re-search-forward "RX" nil t)
  (replace-match (computed-string ...) t t))

;; sexp-aware: operate over balanced expressions, not lines
(goto-char (point-min))
(search-forward "(defun target-fn")
(beginning-of-defun)
(let ((beg (point))) (forward-sexp) (delete-region beg (point)))

;; mode-canonical reindentation after structural edits
(indent-region (point-min) (point-max))
```

`eval-elisp` remains the escape hatch for **reading** session state
the dedicated tools don't cover — variables, buffer facts, window
layout. It accepts only elisp the server can prove side-effect-free,
so it is structurally not an editing interface; mutation belongs to
the edit verbs and transform. If a legitimately innocuous function is
rejected, the user can add it to
`ch-emacs-config-mcp-agent-safe-functions`.

## add-comment / list-comments: the margin, not the page

Review-style comment threads anchored to buffer text, shared with the
user (design: `docs/development/emacs-collab-comments.md` in
ch-emacs-config). Use them to say something *about* a passage — a
question, a concern, a suggestion — without editing it; during
co-editing or review sessions this replaces describing locations in
chat prose.

- **add-comment** with `anchor` starts a thread: the anchor is a
  literal string matched under the edit contract (exactly once in the
  `file` or `buffer`, ambiguity errors with the count). With `thread`
  (an id) it appends a reply instead. Your author name is always
  `claude`. Comments never modify the text — they live in overlays the
  user sees highlighted with a count badge.
- **list-comments** (read-only) shows every thread with ids, positions,
  anchor excerpts, and bodies — buffer-filtered or global. Read it to
  find the user's comments and the thread ids to reply to; check it at
  the start of a review turn the way you'd check modified-buffers
  before editing.
- Threads are session-scoped (they die with the buffer) and the user
  can dismiss or hide them at will; don't treat a vanished thread as an
  error — re-anchor or start a new one.
