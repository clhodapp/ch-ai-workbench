# Claude Code CLI Integration Surfaces

What the `claude` CLI actually offers for driving and observing sessions
from tooling (primarily Emacs). Everything here was **verified live**
against CLI 2.1.195 (2026-07-16); none of the on-disk formats are
documented upstream, so treat record shapes as version-dependent and
parse defensively. Consumer today: the `claude-queue` Emacs package
(`lib-overlays/default/emacs-packages/claude-queue/`).

## Background agents (the fire-and-forget backend)

- `claude --bg --model <m> --name <n> [flags] <prompt>` works with no
  TTY, returns immediately, and prints a banner whose first line is
  `backgrounded · <id> · <name>`. The id is ANSI-colored — strip SGR
  sequences before parsing. `<id>` is the first 8 hex digits of the
  session UUID.
- `claude agents --json [--all] [--cwd <path>]` is the only JSON
  enumeration the CLI provides.
  Fields: `id`, `sessionId`, `name`, `cwd`, `pid`, `startedAt`,
  `state` (`working` / `blocked` / `done` / `stopped` / `failed` —
  `blocked` means a pending permission or question), `status`
  (`busy` / `idle`). `--all` is the full history, including sessions
  retired from the active list (sometimes prematurely); in it, exactly
  the agents the plain listing would return carry `pid` (live
  process), so one `--all` fetch serves both scopes.
  Coverage drift (clean-environment probes 2026-08-08/09 against
  2.1.220): on 2.1.195 the listing covered background agents only; now
  interactive chats appear too. Hosting differs by how the chat
  started: a fresh-started chat is hosted by a **daemon worker**
  process (the TUI is a viewer over it; the row's `pid` is the
  worker's), while a *resumed* chat runs **inside the TUI process
  itself** (`kind: "interactive"` in its session record; the process
  chdirs on `/cd`, so its /proc cwd is live truth). Rows in the
  listing still all say `kind: background`. Timing gap: a session —
  resumed ones especially — registers only when it takes its **first
  message**; between opening a conversation and messaging it, the
  session appears in neither the listing nor the session records, and
  its terminal reflects only the launch directory.
- `cwd` is **live**, not the launch directory (verified 2026-07-30 by
  entering and leaving a worktree mid-session): it moves with the
  session — worktree entry/exit, `/cd` — and the CLI implements the
  move as a real `chdir` of the session process, so
  `/proc/<pid>/cwd` reads the same truth without invoking the CLI.
  Caveat on whose `/proc` to read (2.1.220): read the *hosting*
  process. A fresh-started chat lives in a daemon worker — the
  worker's cwd is the truth, and the TUI's own cwd stops meaning
  anything once its terminal views another conversation. A resumed
  chat lives in the TUI process itself, whose cwd then IS the
  session's and follows its `/cd`s. Process shapes for tree-walking: an
  interactive session is `claude [flags] [prompt]` under the user's
  shell; `attach <id>` processes are viewer clients whose own cwd is
  meaningless (map the id through the listing); `--bg*` flags mark
  daemon plumbing (pty hosts, spare-pool workers), never sessions to
  follow. The nix wrapper leaves `.claude-wrapped` as argv[0]'s
  basename. Session processes can be **respawned mid-session**
  (observed 2026-07-31: a session's pid changed while it kept
  running), so a cached pid can go stale while the session lives on —
  fall back to the listing rather than assuming pid stability.
- Which conversation a terminal is *currently viewing* is not
  observable from the process tree: attach views are multiplexed over
  the daemon's `control.sock` (per-session `rv/<id>.sock` view sockets
  exist, but their peers are all the daemon), and no hook event fires
  on attach or agent-browser navigation (checked against the hooks
  reference 2026-07-31 — the docs are silent on attach; a `CwdChanged`
  hook *does* exist for the session-side directory signal; the emacs
  home-manager module ships `emacs-claude-cwd-hook` for it, which
  projects register in their `.claude/settings.json` to push
  directory moves into claude-queue without waiting on a poll).
  `CwdChanged` scope, probe-verified 2026-07-31 against 2.1.195: it
  fires on a persisted shell `cd` (payload `cwd` = the new
  directory) but **not** on worktree entry or exit — the worktree
  tools chdir the session without emitting it, despite the docs'
  "fires on every directory change" (upstream gap worth reporting —
  and precisely: the daemon's own bookkeeping *does* track the move,
  its live session record's `cwd` updating in lockstep with
  `/proc/<pid>/cwd` through both entry and exit, probe-verified
  2026-08-08 against 2.1.220; only the hook emission is missing).
  The observation tap for worktree moves is `PostToolUse` matched on
  `EnterWorktree|ExitWorktree` — probe-verified: both fire, and the
  payload's common `cwd` field is the *post-move* directory (the
  worktree after entry, the original root after exit), so the same
  hook command serves both registrations unchanged.
  `WorktreeCreate`/`WorktreeRemove` are no substitute: they are
  delegation hooks (a registered command must *implement* creation
  and print the path; failure fails the creation), not observation
  taps. Same probes: headless background sessions execute
  project-settings hooks without any interactive approval step.
  The observable channel for *what a terminal is viewing* is the
  **terminal title**: the TUI titles its terminal `<glyph> <name>`
  with the *viewed* conversation's agents-listing `name`, verbatim,
  and retitles on agent-browser switches (verified live 2026-07-31).
  An interactive session's own conversation never appears in the
  listing, so its title matches nothing — process-tree cwd is the
  fallback for exactly that case. The TUI's complete OSC vocabulary
  (grepped from the 2.1.195 bundle): `]0;` title, `]8;` hyperlinks,
  `]52;` clipboard, `]104;` color reset — notably **no OSC 7**
  working-directory reports, so terminals with native pwd tracking
  learn nothing from it.
- `state` is classifier-derived from the agent's message text, not
  observed from the process: done-detection keys on a final message
  carrying a `result:` line (the background-harness convention), and a
  task that ends its last turn without one can linger as
  `state=working` + `status=idle` indefinitely (observed live
  2026-07-17: a finished task sat "working" 9+ minutes while
  same-shaped siblings whose prose read clearly as complete did flip
  to `done` — the prose path works sometimes, the `result:` line is
  the reliable one). So `working`+`idle` usually means "finished but
  unconfirmed", NOT "waiting for input" — genuine questions and
  permission stalls surface as `blocked`. Dispatch prompts should
  instruct agents to end with a `result:` line (claude-queue's
  standing conduct block does).
- Even with stdout piped, the CLI can decorate output with terminal
  escapes: the `agents --json` spinner writes cursor controls
  (`\e[?25l` / `\e[?25h`) to stderr, so any consumer that merges
  stderr into stdout (e.g. Emacs `make-process` without `:stderr`)
  must strip CSI sequences and trim to the JSON body before parsing.
- `claude attach <id>` (TUI; run it in a terminal buffer) and
  `claude stop <id>` act on a session. `claude logs <id>` emits raw TUI
  escape sequences — rendering, not data; read the transcript file
  instead (below).

### Permissions for unattended dispatch

The CLI default permission mode is Manual, so a background agent's
first tool call parks it in `blocked` until approved from an agent
view. For unattended tasks pass a `--permission-mode` (choices on
2.1.241: `acceptEdits`, `auto`, `bypassPermissions`, `manual`,
`dontAsk`, `plan`; `acceptEdits` auto-approves file edits only,
`auto` lets the CLI's classifier approve routine actions more
broadly) — and note permission *modes* do not cover MCP tools: those
need explicit `--allowedTools` entries. claude-queue dispatches in
`auto` mode with the restricted correction profile (workspace
`consent-gate.md`, Dispatch capability profiles), declared entirely
on the command line:

- **Allowed** (`--allowedTools`): subagent spawning (`Agent`/`Task`,
  so a task can delegate to another model) and the emacs server's
  tools — the read-only tools, the comment system, `present`,
  `edit-buffer`, and also `edit-file`, `transform`, and `eval-elisp`.
  The last three rely on the server's own filters
  (`emacs-mcp-agent-tools.md` § Security filters): writes are confined
  to the client's territory, the project of the bridge's launch
  directory, and elisp runs only when `unsafep` proves it
  side-effect free. Those filters run in the Emacs process, which no
  sandbox reaches, so they hold in every checkout alike.
- **Absent** (`--settings '{"permissions":{"deny":[...]}}'`): `Bash`,
  `WebFetch`, `WebSearch`. Denied tools are unregistered from the
  session's toolset (verified below).
- **Absent for bare roots** (`claude-queue-bare-root-denied-tools`,
  default `Edit`, `Write`, `NotebookEdit`, `mcp__emacs__edit-file`,
  `mcp__emacs__transform`): when the dispatch root lies in no project
  (`project-current` on the root is nil, the same call the emacs
  server's write-scope filter makes on its launch directory), there
  is no project identity to grant as territory, and every disk-writing
  path would take the bare directory as its whole territory: the
  consent hook and the CLI's workdir rule for Edit/Write, the server's
  write-scope filter for its verbs. So a bare-root dispatch gets no
  unattended disk writes on either path; it keeps reads, comments,
  `present`, and `edit-buffer`, whose changes land in the buffer for
  the resident user to save. The sandbox lift also requires a project
  root: the sandbox tool only enrolls git roots, so a sidecar under a
  bare directory lifts nothing.
- **Lifted inside a sandboxed checkout** (`claude-queue-sandboxed-tools`,
  default `Bash`, `WebFetch`, `WebSearch`): when the dispatch root
  carries a claude-code-sandbox sidecar
  (`.claude/claude-code-sandbox.json`) binding a profile other than
  the reserved empty `none`, shell and network are dropped from the
  deny floor before rendering, so the session keeps them under the
  profile's OS-level confinement (closed toolset, filesystem,
  network). Detection is the sidecar alone — absent, unreadable, or
  malformed all read as unenrolled — and the root is the outermost git
  checkout (`claude-queue--root`), so a dispatch from a linked worktree
  under the primary checkout reads the primary's sidecar. Approval of
  the lifted calls is then the sandbox settings' business (the
  dispatch permission mode and the profile's `autoAllowBashIfSandboxed`
  if set), not the dispatcher's. `WebFetch` and `WebSearch` run inside
  the CLI process, outside the Bash sandbox's network namespace: the
  profile's domain rules do not reach them, and the permission mode
  alone gates their calls.

`--allowedTools` is variadic — comma-join its value and keep a
non-variadic flag between it and the trailing positional prompt, or it
swallows the prompt. `--disallowedTools` has the same variadic hazard
(probed 2.1.220, 2026-08-09: it swallowed a trailing prompt), which is
why the deny floor goes in `--settings` — non-variadic, accepts inline
JSON — even though both were verified to unregister tools
identically.

`--add-dir` at dispatch **extends `acceptEdits` and the workdir
sandbox to the added trees in headless sessions** (probe-verified in
scrubbed environments 2026-08-09 against 2.1.220, for Write and Edit
both): a `-p` session under `acceptEdits` wrote and edited files in
an added sibling directory with zero `permission_denials`, while the
control run without the flag had exactly the out-of-workdir write
denied. This is what makes territory sandbox-shaped at dispatch in
the consent-gate design (workspace `docs/development/consent-gate.md`
settles its first open question on this probe). Two gotchas from the
same probes: `--add-dir` is variadic like `--allowedTools` (same
prompt-swallowing failure, same fix), and the `~/.claude/` sensitive
guard denies writes even when the session's *own workdir* lies under
it — a session launched from a directory inside `~/.claude/` (a
background job's tmp dir, say) cannot write beside itself.

## Session store (the real enumeration API)

No CLI command enumerates every session (`agents --json` misses any
session before its first message; see its coverage note above). The
state files under `~/.claude/` are all plain JSON(L):

- `~/.claude/history.jsonl` — global append-only prompt log: one record
  per user prompt with `display`, `project`, `sessionId`, `timestamp`.
  Grouping by `sessionId` yields the full session catalog per project,
  interactive and background alike, titled by first prompt (which is
  roughly what the `/resume` picker shows).
- `~/.claude/projects/<munged-cwd>/<sessionId>.jsonl` — the per-session
  transcript: typed JSONL records (`user`, `assistant`, config records,
  attachments) carrying message content, `timestamp`, `cwd`,
  `gitBranch`, and CLI `version`. The directory name mungs the session's
  *starting* cwd: every character outside `[A-Za-z0-9-]` becomes `-`.
  A session that moves (worktree, `/cd`) keeps appending to the same
  transcript file; the move only creates a session-state *subdirectory*
  under the new cwd's munged project dir (verified 2026-07-30). So a
  transcript lookup keyed on a *live* cwd misses exactly while the
  session is away from home — locate by session id when the derived
  directory misses.
- `~/.claude/sessions/<pid>.json` — one record per **live hosting
  process** (probed 2026-08-08/09, 2.1.220): `pid`, `sessionId`,
  `cwd`, `name`, `kind`, `jobId`, `status` (`busy`/`idle`),
  `startedAt`, `procStart`, `updatedAt`, `version`. The record's pid
  is whatever hosts the session — a daemon worker for background
  agents and fresh-started chats (the TUI viewing one has no record
  of its own), the TUI process itself for resumed chats
  (`kind: "interactive"`). Created at first message, not at session
  open. Facts that shape consumption:
  - `cwd` is live and trustworthy: it tracked `EnterWorktree` and
    `ExitWorktree` in lockstep with `/proc/<pid>/cwd` under repeated
    2s polling, never diverging — no CwdChanged-style blind spot.
  - `name` joins to the terminal title only for **worker-hosted**
    sessions. A resumed session's record carries a generated
    placeholder (observed: `tmp-94`, from the directory basename)
    while its terminal titles the conversation's real name — the
    name join structurally fails there; join TUI-hosted sessions by
    pid through the process tree instead. Worker-hosted names start
    as a session-id fragment and become the summary name once the
    summarizer runs.
  - Records **linger after death** — observed surviving plain
    SIGTERM, so crash vs. clean exit makes no difference. A record is
    a claim, not a fact: countersign it against the kernel before
    use — `/proc/<pid>` must exist *and* its start time
    (`/proc/<pid>/stat` field 22) must equal `procStart`, which also
    defeats pid recycling. Stale records then fail toward a no-op,
    never toward a wrong answer.

  Consumer policy (claude-queue follow-mode implements it): one cwd
  source per session, chosen by hosting — a countersigned record for
  worker-hosted sessions, `/proc/<pid>/cwd` via the process walk for
  TUI-hosted ones (same process the record names, so these never
  compete), and the `agents --json` listing only for sessions with
  no live process at all (transcript views of finished agents) plus
  history and task `state`. Never let a cached listing row shadow a
  live source: rows go stale between fetches, records and /proc
  cannot.

  **Probe hygiene:** a `claude` launched from inside another claude
  session inherits `CLAUDE_CODE_CHILD_SESSION` (plus `CLAUDECODE`,
  `CLAUDE_CODE_SESSION_ID`, …) and behaves differently — transcript
  saving off, no registration, no session record. Conclusions drawn
  from such probes are wrong. Scrub the environment (`env -i` with
  `HOME`/`PATH`/`XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS` — the
  wrapper needs the user bus) before probing session lifecycle
  behavior.

Any session can be reopened by id: `claude --resume <sessionId>`
(interactive), `claude -p --resume <sessionId> <prompt>` (headless
follow-up), `--fork-session` to branch instead of continuing. Two
resume behaviors verified in clean environments 2026-08-08/09
(2.1.220): resuming continues the **same sessionId**, appending to
the same transcript file. And lookup is **scoped to the
conversation's current directory** — not its birth directory: after
a session `/cd`s away, `--resume <id>` finds it only from the new
directory and answers "No conversation found with session ID"
everywhere else, including the directory whose project store holds
its transcript. A `claude` launched outside the right directory
cannot reopen the chat (its startup picker is blind to it too; only
the cross-project agent browser reaches registered sessions).

## Streaming JSON (what an embedded session builds on)

`--output-format stream-json` (print mode; **requires `--verbose`**)
emits JSONL on stdout as the session runs:

- `system`/`init` — `session_id`, model, `permissionMode`, tools, MCP
  servers, skills.
- `assistant` / `user` message records as turns progress (API-shaped;
  tool calls and results visible mid-flight). A one-shot plain-text
  answer may skip straight to `result`.
- `result` per completed turn — final text, `total_cost_usd`, usage,
  `num_turns`, `stop_reason`, `permission_denials`.
- Opt-ins: `--include-partial-messages` (token-level deltas),
  `--include-hook-events`; ambient events like `rate_limit_event` also
  appear.

`--input-format stream-json` turns one process into a persistent
multi-turn conversation: write user messages as JSONL lines to stdin
(`{"type":"user","message":{"role":"user","content":"..."}}`); context
is retained across turns and the session persists to the normal
transcript store. `--replay-user-messages` echoes each accepted user
message back on stdout for sequencing.

Print mode never prompts for permissions: an unapproved tool call is
silently denied and surfaces only in `result.permission_denials`, so
the permission posture must be preconfigured (see above) — with one
programmable exception: PreToolUse hooks run and gate in print mode
(next section), which is what makes an external permission UI
possible at all.

**Choosing a backend:** `--bg` gives fire-and-forget, agent-view
integration, and the background-job harness for free; stream-json gives
a foreground, owned session with turn-level fidelity (live rendering,
per-turn cost) at the price of owning UI, lifecycle, and permissions —
what a native embedded-session frontend would build on, should we
build one.

## Hooks as the headless permission surface

Probed live against 2.1.220 (2026-08-08/09); the facts the consent-gate
design depends on were re-verified in scrubbed environments per the
probe-hygiene note above. The consent-gate design builds on this
(workspace `docs/development/consent-gate.md`), whose core now ships
from the
emacs module: `emacs-claude-consent-hook` (the PreToolUse territory
classifier, registered user-level global by an activation merge into
`~/.claude/settings.json`) escalates a dispatched session's
out-of-territory Edit/Write through the
`$XDG_RUNTIME_DIR/claude-consent` spool, and `claude-consent.el`
(claude-queue's package directory) is the filenotify-driven
viewer/answerer over it. Since 2026-09-09 the hook asks through
`claude-consent ask` (the prompt API over the spool,
`pkg-overlays/default/packages/claude-consent`): Emacs answers while `claude-consent-mode` is
on, a terminal running `claude-consent watch` answers the same way,
and with no answerer attached the hook emits `permissionDecision:
ask` (design: workspace `consent-gate.md` § Prompt API).

- **PreToolUse hooks fire and gate inside `-p` stream-json sessions.**
  The stdin payload carries `tool_name`, the full `tool_input`,
  `tool_use_id`, `session_id`, `transcript_path`, `cwd`, and
  `permission_mode` — enough to render a real consent prompt
  elsewhere. A `permissionDecision: deny` prevents execution; the
  reason string comes back to the model verbatim as the tool result
  and the call is listed in `result.permission_denials`.
  `--include-hook-events` streams `hook_started`/`hook_response`
  records in-band.
- **Layering.** A hook that exits 0 with no output *abstains*: the
  file-based engine (modes, rules, workdir sandbox) decides as if the
  hook weren't registered. An explicit decision preempts that flow —
  a hook `allow` runs a call that headless defaults would deny, with
  no allowlist entry anywhere. Multiple entries on one matcher all
  fire and the most restrictive decision wins (deny beat allow), but
  a *lone unopposed* `allow` bypasses the rules engine — hooks must
  abstain unless they have something to say.
- **`permissions.deny` unregisters the tool.** A denied tool is
  absent from the session's toolset: no hook fires, and the model's
  tool search finds nothing to call. This is the hard floor — nothing
  a buggy hook-allow can reopen. Note it is tool-granular: denying
  `Bash` also removes the sandboxed read-only commands the default
  posture would have auto-run.
- **The deny floor is reachable per-dispatch, MCP names included**
  (probed 2.1.220, 2026-08-09, via the stream-json `init` event's
  `tools` array — structural evidence, not model self-report):
  `--settings '{"permissions":{"deny":["Bash","WebFetch","WebSearch",
  "mcp__emacs__edit"]}}'` removed exactly those four from the toolset
  while undenied siblings on the same MCP server stayed registered, so
  `mcp__<server>__<tool>` naming works in deny rules and inline JSON
  works for `--settings`. `--disallowedTools` produced the identical
  removal but is variadic (prompt-swallow hazard, noted with
  `--allowedTools` above); prefer `--settings` in constructed argv.
  The native disk writers unregister the same way (probed 2.1.241,
  2026-08-25, same `init`-event method): `--settings
  '{"permissions":{"deny":["Edit","Write","MultiEdit","NotebookEdit"]}}'`
  left `Bash` and `Read` registered and removed `Edit`, `Write`, and
  `NotebookEdit`; the control run without the deny registered all
  three. `MultiEdit` is not a registered tool on 2.1.241 either way.
- **Sensitive-path guards outrank hook-allow and allowlists both**:
  writes under `~/.claude/` are denied as "sensitive", and a Write to
  project-local `.claude/settings.json` is denied even under
  `acceptEdits` (Bash indirection unprobed).
- **Timeouts.** The per-hook `timeout` field (default 60s) works and
  raises cleanly — a hook that slept 70s under `timeout: 120` still
  had its decision honored, so long human-in-the-loop waits are fine.
  A hook that outlives its timeout is `cancelled` (visible in the
  `hook_response` event) and contributes **no decision** — fallthrough,
  which is *fail-open* wherever native rules allow the call. Policy
  deadlines therefore live inside the hook (self-answer with an
  actionable deny before dying); the declared timeout is only a
  liveness backstop against a hung hook.
- **`PermissionRequest` is a documented event** (hooks reference,
  read 2026-09-09; not probed here): it fires after PreToolUse when a
  call needs a permission decision, matches on tool name, and takes
  `permissionDecision` allow/deny through JSON only (exit 2 is not
  honored for it). It is the natural tap for routing the CLI's own
  permission prompts (a command outside the sandbox, say) into the
  consent spool; whether it fires in headless sessions is unverified.
- **Consumer note:** a session blocked in a synchronous PreToolUse
  hook reports `state=working` / `status=busy`, never `blocked` — the
  CLI cannot see that the hook is waiting on a human. Any external
  consent UI must track its own pending requests and join them to
  sessions by `session_id`.
- **A deny is a retry prompt.** Because the deny reason returns to
  the model as the tool result, a PreToolUse hook can act as a
  double-check on the text a call writes: the claude-code module's
  `claude-tic-check-edit-hook` (matcher `Edit|Write|NotebookEdit|
  mcp__emacs__edit-file|mcp__emacs__edit-buffer`) denies a call whose
  `new_string` / `content` / `new_source` / `new-string` matches the
  tic table, once. It keys a marker on `session_id` plus a hash of
  `{tool_name, tool_input}` under `$XDG_RUNTIME_DIR/claude-tic-check/
  seen/`, so the identical re-issue abstains (legitimate use costs one
  retry) while a rewritten re-issue is a new hash and is checked on
  its own.
- **A PostToolUse hook replaces what the model sees.** Its
  `hookSpecificOutput.updatedToolOutput` stands in for the tool result
  before it reaches the model, for built-in and MCP tools alike; the
  value must keep the tool's output shape (Read's is `{type, file:
  {content, filePath, numLines, startLine, totalLines}}`, Bash's
  carries `stdout` and `stderr`). Probe-verified 2.1.259 (2026-09-20):
  a hook that rewrote Read's `file.content` to a sentinel produced a
  model reply carrying only the sentinel, and the original text
  appeared nowhere in the stream-json transcript. `additionalContext`
  adds a string to the model's context beside the result; `decision:
  "block"` only adds its reason beside the original, which the model
  still sees. The claude-code module's `redact` hook
  (`claude-redact-hook`, PostToolUse on every tool) stands on this: the
  result's string leaves pass through betterleaks and a finding is
  replaced in place with a note.
- **A PreToolUse hook rewrites a call's input without deciding it.**
  `hookSpecificOutput.updatedInput` with no `permissionDecision`
  replaces the arguments the tool runs with, and the native permission
  flow still decides the call. Probe-verified 2.1.259 (2026-09-28): a
  hook that rewrote a Bash `command` from `echo SENTINEL-ORIGINAL` to
  `echo SENTINEL-REWRITTEN` produced a tool result and a model reply
  carrying only the rewritten sentinel, while the model's own
  `tool_use` record in the transcript kept the original command. The
  reveal hook stands on both halves: it adds an `approval` token to an
  approved MCP read, and the model never sees the token.
- **A deny is also a checklist gate.** The same module's
  `claude-push-pr-check-hook` (matcher `Bash`) denies a command that
  appears to run `git push` (the word `git`, any global options such
  as `-C dir`, then `push` as a word, anywhere on a line) once, with
  a reason headed `push-pr-check: verify` that asks the model to
  confirm the branch's pull request is not already merged (`gh pr
  list --head <branch> --state all`) before re-issuing, since GitHub
  keeps accepting pushes to a merged PR's head branch. The match is
  textual, so a command that only mentions a push (`echo git push >>
  script.sh`) is denied too; the reason says to re-issue such a
  command unchanged. Same marker
  scheme, under `$XDG_RUNTIME_DIR/claude-push-pr-check/seen/`, with
  one difference: the identical re-issue consumes the marker instead
  of leaving it, so the same push later in the session is checked
  again (the PR may have been merged in between).

### Stop hooks (the finished-message check)

Probed 2.1.241 (2026-08-29) in a scrubbed environment with
`--include-hook-events`: a `Stop` hook registered through `--settings`
whose script logged its stdin and answered
`{"decision":"block","reason":…}` on the first stop and nothing on the
second. The claude-code module's `hooks` option seeds one of these
(`claude-tic-check-hook`, the pattern table in `ticChecks`;
registration via the same activation-merge mechanism as the consent
hook).

- **Payload.** Keys observed: `hook_event_name` (`"Stop"`),
  `stop_hook_active`, `last_assistant_message`, `session_id`,
  `transcript_path`, `cwd`, `permission_mode`, `prompt_id`,
  `background_tasks`, `session_crons`. `last_assistant_message` is the
  text of the message the model just finished (`"PROBE-FIRST"` for a
  prompt asking for exactly that word), so a content check needs no
  transcript parsing. The field is optional in the CLI's schema; a
  hook should abstain when it is absent.
- **Blocking.** stdout `{"decision":"block","reason":"…"}` with exit 0
  prevents the turn from ending; the reason string becomes the
  model's next instruction and the model produces another message
  (the probe's reason asked for `PROBE-CONTINUED`, and that was the
  second assistant text and the session `result`; `num_turns` was 2).
  The original message is not withdrawn or edited: a hook has no
  channel back except the reason, so a "correction" is always a
  second message.
- **Loop guard.** The stop after a block arrives with
  `stop_hook_active: true`; a hook that wants one reminder per
  message abstains on it. The CLI additionally caps consecutive
  blocks at 8 (`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` raises it; strings in
  the 2.1.241 bundle, not probed) and overrides the hook past the cap.
- **Abstention** is the same as for PreToolUse: exit 0 with no output
  and the turn ends normally.
- **Token convention.** The continuation after a block is a whole
  message on screen, so every step of the tic-check cycle is headed
  by a fixed line. The checker's block reason starts with
  `tic-check: check` (emitted whenever it fires, however confident it
  is: a regex entry or a judge dimension, below) and asks the model for a
  verdict only, `tic-check: clean` (the message stands) or
  `tic-check: tic`; the MessageDisplay hook below renders those two
  as status lines. On `tic` the hook (seeing `stop_hook_active` plus
  the token) blocks once more with a reason headed `tic-check: rewrite`
  asking for the message again without the phrasing. The verdict is
  the full-power model's, so the check is a trigger and `clean` is the
  overrule. Anything else at a second stop ends the turn. Two blocks
  per cycle, no state.
  Note the block `reason` also surfaces as a `user`-role
  `Stop hook feedback:` event in the stream, so a consumer that
  renders user events shows it; MessageDisplay cannot touch that,
  which is why those reasons carry the `tic-check: check` /
  `tic-check: rewrite` headers for the consumer to match on.

### The judge (decision-model verdicts)

The regex table catches only phrasings a pattern can find, and it
cannot tell a real possessive from a dangling one when the noun sits in
backticks or on the next line. The judge adds a System One decision
model to the same cycle. A decision model reads a text (the `state`)
and named yes/no questions and returns, for each question, the
probability that the answer is yes, without generating text. The
claude-code module's `judge.dimensions` are those questions, one per
output-style rule that needs judgment (seeded from
`modules/homeManager/claude-code/lib/judge-dimensions.nix`).

- **Client.** `claude-response-judge`
  (`pkg-overlays/default/packages/claude-response-judge`) posts the
  text, with code blocks replaced by a marker, to `<url>/v1/systemone`
  of each `judge.endpoints` entry in ascending `order` and prints the
  first answer as `{endpoint, model, answers}`. The seeded `local`
  entry is ch-local-llms' `decision-server` (elephant-1, 9B) at
  `http://127.0.0.1:8000`. While no server runs there, the connection
  is refused at once and costs no wait. The seeded `baseten` entry is
  `https://inference.baseten.co` with
  `decision-models/baseten-mammoth-27b-latest` (mammoth-1, 27B). Its key
  is read at each request from `apiKeyFile` (default
  `$XDG_CONFIG_HOME/baseten/api-key`) and sent as `Authorization:
  Api-Key <key>`. While that file is missing, the entry is skipped. When
  no endpoint answers, every hook behaves as it did with the regex
  table alone.
- **Push-back.** On the first stop the Stop hook asks the judge, then
  builds its findings from both checkers. A dimension with `pushBack`
  set at or above `judge.pushBackAbove` (0.9) is a finding. A regex hit
  whose entry names a `dimension` is dropped when the judge put that
  dimension below `judge.dismissBelow` (0.2), and otherwise carries the
  judge's probability. Literal-character entries (em-dash, the arrow)
  name no dimension and always fire. The findings go out under
  `tic-check: check`, and the verdict and rewrite steps are unchanged:
  the model writing the message still has the last word.
- **Context.** When the Stop hook lets a message stand, it writes the
  verdict to `$XDG_RUNTIME_DIR/claude-tic-check/verdicts/<session>.json`.
  The `tic-check-context` hook (UserPromptSubmit) reads and deletes it
  with the next prompt. It returns the dimensions at or above
  `judge.reportAbove` (0.5) as `hookSpecificOutput.additionalContext`,
  headed `tic-check: verdicts`, which the CLI adds to the model's
  context beside the prompt. The user does not see it. This path has
  been exercised by the flake check against the hook's output shape
  only. It has not been probed live in a CLI session the way the Stop
  facts above were.
- **Edits.** The edit hook asks the judge about every write. The
  target (`file_path`, `notebook_path`, or the emacs verbs' `file` and
  `buffer`) decides the kind: prose when its extension is in
  `judge.proseExtensions`, code otherwise. Each dimension's `targets`
  lists the kinds it is asked of, and most target replies and prose
  only. `arguing-with-ghosts` targets prose and code. It asks whether a
  comment, doc, or test is written as a correction to the author's own
  earlier version, arguing a difference from what was removed or
  rejected, instead of for a new reader. For that question the request
  carries the edit's replaced text (`old_string`) and the user's last
  three typed messages, read from the tail of `transcript_path`
  (entries of type `user` that are neither `isMeta`, which marks hook
  feedback and skill bodies, nor `isSidechain`, nor tool results).
- **Latency.** On an R9700, decision-server answers a request of two or
  three questions over a few hundred tokens in 0.15 to 0.26 s, and ten
  questions over 5k tokens in 1.2 s (ch-local-llms README). The judge
  asks ten. The hooks that run it are registered with a timeout of 10
  s plus the sum of the enabled endpoints' timeouts (30 s each by
  default), because a hung endpoint costs its whole timeout before the
  next is tried.
- **Calibration.** The thresholds are starting values, chosen before
  any run against the real models. The flake check
  `claude-tic-check-judge` drives the hooks against a stub server with
  fixed answers, so it tests the plumbing, not the questions.

### MessageDisplay hooks (display-only rewriting)

Schema read from the 2.1.241 bundle and the hook exercised in a `-p`
stream-json session (2026-08-29): the event fires with each batch of
newly completed lines while an assistant message streams, and is
display-only: the stored message and what the model sees are untouched.

- **Payload.** `hook_event_name` (`"MessageDisplay"`), `turn_id`,
  `message_id` (stable across every flush of one message; not the
  API message id), `index` (zero-based flush counter), `final` (true
  on exactly one flush per message), `delta` (the newly completed
  lines, whole lines except that the final flush may end mid-line and
  is empty when the message ends on a newline).
- **Output.** `{"hookSpecificOutput":{"hookEventName":"MessageDisplay",
  "displayContent":"…"}}` replaces the delta on screen; omit the
  field (or abstain) to display the original. The module's
  `claude-tic-check-display-hook` returns a one-line status for a
  delta that is exactly one of the tic-check verdict tokens.
- **One call per completed message headlessly.** A twelve-line `-p`
  reply produced exactly one call, `index: 0`, `final: true`, whole
  text in `delta` (probed 2.1.241, 2026-08-29); the per-flush
  behavior is the interactive TUI's. So a hook that needs the whole
  message before deciding can act on `index == 0 && final` with no
  buffering, and that condition holds for every headless message.
- **"Display" includes headless output.** In a `-p` stream-json
  session whose only assistant text was the token, a hook returning
  an empty `displayContent` left the stream with no `assistant` text
  event at all and an empty `result`, while the session's transcript file kept
  the `"tic-check: clean"` message (probed 2.1.241, 2026-08-29). So
  the stored message and the model's context are untouched, as the
  schema says, but "display" means every rendering the CLI emits,
  the stream-json feed included; an embedded consumer (claude-queue)
  sees the rewrite too. `--include-hook-events` shows the hook firing
  and its output either way.
- **Streaming-only; resume does not re-fire.** A `-p` session created
  with `--session-id` and resumed with `--resume` fired the hook once
  per run, for the newly streamed message only; the replayed earlier
  message produced no call (probed 2.1.241, 2026-08-30). So a rewrite
  (the mermaid link lines, a hidden token) exists only in the rendering
  of the run that streamed it; a resumed transcript is redrawn from the
  stored messages, bare. Anything that must be recoverable later needs
  a durable artifact keyed by the message content, not the rewrite:
  the mermaid display hook renders into render-dwim's content-addressed
  cache under `XDG_CACHE_HOME` so the `render-dwim` command can
  re-produce the identical file from the fence text on screen.
- **`displayContent` composes freely.** Appending lines to the delta
  (the mermaid hook's link lines) is the same mechanism as replacing
  it; the field's value is simply what the terminal shows for that
  flush.
- **Hook processes have no controlling tty.** Writing to `/dev/tty`
  from a hook (or a Bash-tool child) fails with "device not
  configured" (upstream anthropics/claude-code#54546); a hook that
  wants a side effect in the user's editor goes through emacsclient
  (the cwd hook) or a spool, never the terminal device.

## Output styles (the voice knob)

An output style is a markdown file whose body the CLI appends to the
system prompt while the style is selected. Probed 2026-08-23 against
2.1.241 with a throwaway project-scope style and `claude -p --settings
'{"outputStyle": …}'`:

- Discovery is by directory: `~/.claude/output-styles/*.md` (personal)
  and `.claude/output-styles/*.md` (project, nearest wins), read on
  session start. A store symlink in place of the file is followed —
  the home-manager module installs styles that way
  (`ch-ai-workbench.claude-code.outputStyles`).
- **The selection key is the frontmatter `name` when present,
  otherwise the file name without `.md`.** With `name: Probe Display`
  in `probe-file.md`, `outputStyle: "probe-file"` left the style
  inactive and `outputStyle: "Probe Display"` activated it; with no
  `name` field, `"probe-file"` activated it. **The `/config` picker
  lists every file under `output-styles/`, one row per file**, so
  installing two files for one style (tried 2026-08-24, reverted)
  produces two picker rows, not an alias — there is no way to give a
  style two selectable keys without two visible rows.
  `ch-ai-workbench.claude-code.outputStyles.<attr>.displayName` sets
  the frontmatter `name` field on the style's one file: it becomes
  both the picker label and the required `outputStyle` value,
  replacing the attribute name as the selectable key.
- Frontmatter fields present in the 2.1.241 binary:
  `description` (picker text), `keep-coding-instructions` (boolean,
  default false: the CLI's own engineering instructions are *dropped*
  and only the style text remains; `true` keeps them and appends the
  style), and `force-for-plugin` (plugin-shipped styles only). The
  frontmatter is parsed as YAML, not line-split: a double-quoted
  `description` containing colons and escaped inner quotes loaded and
  the style activated, so a generator can emit descriptions as JSON
  strings without escaping rules of its own.
- What `keep-coding-instructions` gates (read out of the 2.1.241
  binary's prompt assembly): exactly one section, `# Doing tasks` —
  the software-engineering framing (interpret vague asks as code
  tasks, 2–3 sentence answers to exploratory questions, prefer editing
  to creating files, OWASP hygiene, no scope creep or speculative
  abstractions, no defensive code for impossible cases, comments only
  for a non-obvious why, browser-test UI changes, no compatibility
  hacks, the /help pointer). Identity, tool rules, the risky-actions
  section, task tools, environment, and CLAUDE.md are unaffected
  either way. A voice style keeps it; only a style that redefines the
  job should drop it.
- Selection is runtime state: `outputStyle` in a settings file
  (`~/.claude/settings.json`, project `.claude/settings.local.json`, or
  `--settings` JSON) or the `/output-style` command, which writes the
  project-local settings file. The built-in names (`default`,
  `explanatory`, `learning`, and the newer `concise`, `proactive`) are
  not files, so a custom file cannot shadow one by accident — nor be
  found under those names.
- A `--settings` inline JSON on the command line is enough to pin a
  style for a single `-p` run; nothing is written.
