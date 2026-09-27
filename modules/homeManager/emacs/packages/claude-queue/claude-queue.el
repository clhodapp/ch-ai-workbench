;;; claude-queue --- Rapid-fire background Claude Code tasks -*- lexical-binding: t -*-
;; SPDX-License-Identifier: MIT
;;; Commentary:
;; Queue tasks for Claude Code while browsing: `claude-queue-dispatch'
;; captures where you are (project root, file, line, and the selected
;; region if one is active), asks for a one-line instruction, and hands
;; the task to a Claude Code background agent (`claude --bg').  Fire as
;; many as you like without waiting; an Emacs-side FIFO releases them
;; to the CLI as running ones finish (`claude-queue-max-concurrent').
;;
;; `claude-queue-list' shows every task this package has dispatched --
;; queued, working, done -- joined live from `claude agents --json'.
;; From the list you can read a session's transcript (RET; the
;; conversation as a plain buffer, sender-labeled, where `a' attaches
;; to the agent), attach a terminal to a running agent (`a'), or stop
;; one.  The same sessions also appear in the regular `claude agents'
;; view.
;;
;; Tasks default to `claude-queue-default-model' (sonnet);
;; `claude-queue-dispatch-model' picks another model (opus, fable,
;; ...) first.
;;
;; `claude-queue-follow-mode' keeps session-viewing buffers rooted
;; where their session actually works: a ghostel where `claude' was
;; run by hand, an attach terminal, a transcript view -- each has its
;; `default-directory' follow the session's *live* working directory,
;; read from the daemon's session records (worker-hosted sessions)
;; and /proc (TUI-hosted ones; the CLI chdirs the hosting process
;; into worktrees and on /cd).  Directory-aware commands invoked
;; from those buffers -- find-file, project search, a new terminal --
;; therefore operate in the tree the session is working on, not where
;; it happened to start.  The terminal title tracks what a terminal
;; *currently shows*: paging into the TUI's agent browser and opening
;; a different conversation retitles the terminal with that session's
;; name, and the buffer follows the newly-viewed session.
;;
;; `claude-queue-find-agent' retrieves an agent by *description* --
;; "the one that was fixing the systemd socket race" -- by embedding
;; each agent's session transcript and ranking against the typed
;; description through semantic-finder's scoring (anchor-subtracted
;; cosines against the local embedding server; transcripts never
;; leave the machine).
;;
;; The CLI surfaces this package builds on (--bg, agents --json, the
;; session store, permission flags) are documented with verification
;; notes in docs/development/claude-cli.md.
;;; Code:

(require 'claude-consent)
(require 'seq)
(require 'semantic-finder)
(require 'subr-x)
(require 'tabulated-list)

(declare-function term-char-mode "term")
(declare-function make-term "term")
(declare-function ghostel-exec "ghostel")
(declare-function project-current "project")
(declare-function project-root "project")

(defgroup claude-queue nil
  "Queue background Claude Code tasks from Emacs."
  :group 'tools
  :prefix "claude-queue-")

(defcustom claude-queue-program "claude"
  "Claude Code CLI executable."
  :type 'string
  :group 'claude-queue)

(defcustom claude-queue-default-model "sonnet"
  "Model used by `claude-queue-dispatch'."
  :type 'string
  :group 'claude-queue)

(defcustom claude-queue-models '("sonnet" "opus" "fable")
  "Models offered by `claude-queue-dispatch-model'."
  :type '(repeat string)
  :group 'claude-queue)

(defcustom claude-queue-max-concurrent 1
  "How many queue-dispatched agents may run at once.

Tasks beyond the limit wait in an Emacs-side FIFO (state \"queued\"
in `claude-queue-list') and are released as running ones finish.
The serial default keeps related tasks coherent: a task that lands
its work is visible to the tasks queued behind it.  Only agents
dispatched by this Emacs session count against the limit; nil means
dispatch everything immediately."
  :type '(choice (const :tag "Unlimited" nil) natnum)
  :group 'claude-queue)

(defcustom claude-queue-permission-mode "auto"
  "Permission mode passed to dispatched agents, or nil to inherit.

With the CLI's default (manual) mode a background agent stalls in
\"blocked\" until its tool calls are approved, e.g. from the
`claude agents' view -- which defeats rapid-fire dispatch, so
dispatches default to the CLI's auto mode: its classifier approves
routine tool calls (file edits included) without attention.  Set to
nil to inherit the user settings instead."
  :type '(choice (const :tag "Inherit user settings" nil) string)
  :group 'claude-queue)

(defcustom claude-queue-consent-deadline 300
  "Seconds an out-of-territory edit may wait for a consent answer.

Written into each dispatch's territory record; the consent hook
self-denies past it with an actionable reason.  Bounded because a
forgotten consent would otherwise freeze the max-concurrent FIFO
behind the parked session; it must stay under the hook's declared
framework timeout (the hook clamps to 3500s), since a
framework-cancelled hook yields no decision at all."
  :type 'natnum
  :group 'claude-queue)

(defcustom claude-queue-allowed-tools
  '(;; Subagent spawning, so a task can delegate to another model
    ;; ("Task" is the tool's historical name; stale entries are inert).
    "Agent" "Task"
    ;; The emacs MCP server: read-only tools, the comment system,
    ;; presentation, and buffer-target editing, whose effects stay in
    ;; buffers the user sees.
    "mcp__emacs__buffer-diff"
    "mcp__emacs__buffer-text"
    "mcp__emacs__context"
    "mcp__emacs__diagnostics"
    "mcp__emacs__document-outline"
    "mcp__emacs__find-definition"
    "mcp__emacs__find-references"
    "mcp__emacs__list-buffers"
    "mcp__emacs__list-comments"
    "mcp__emacs__modified-buffers"
    "mcp__emacs__symbol-info"
    "mcp__emacs__add-comment"
    "mcp__emacs__edit-buffer"
    "mcp__emacs__present"
    ;; The server's disk-writing verbs and its elisp escape hatch,
    ;; confined by the server's own filters (emacs-mcp-agent-tools.md,
    ;; Security filters): writes stay under the calling client's
    ;; territory, the project of the bridge's launch directory, and
    ;; elisp runs only when `unsafep' proves it side-effect free.
    ;; Those filters run in the Emacs process, so they hold in every
    ;; checkout, sandbox-enrolled or not.  The disk-writing verbs are
    ;; floored again by `claude-queue-bare-root-denied-tools' where the
    ;; territory would degrade to a bare directory.
    "mcp__emacs__edit-file"
    "mcp__emacs__transform"
    "mcp__emacs__eval-elisp")
  "Tools pre-approved for dispatched agents (--allowedTools).

Permission modes do not cover MCP tools, so tasks touching the live
Emacs stall on approval even under \"acceptEdits\"; the default
pre-approves the emacs server's tools and subagent spawning so a task
can hand work to another model.  The server's write verbs and
elisp-taking tools are confined by its own filters (client-territory
write scope, the agent-safe elisp gate), which is the confinement
this list relies on: their widening knobs are the resident user's
alone, unreachable from gated elisp."
  :type '(repeat string)
  :group 'claude-queue)

(defcustom claude-queue-denied-tools
  '(;; Shell and network: absent, not refused.  Outside a
    ;; sandbox-enrolled checkout, dispatched corrections cannot build,
    ;; test, or land; verification and landing stay with the resident
    ;; side (consent-gate.md, Dispatch capability profiles).  Inside
    ;; one, `claude-queue-sandboxed-tools' lifts shell and network
    ;; from this floor: the OS sandbox is then the confinement.
    "Bash" "WebFetch" "WebSearch")
  "Tools removed from dispatched sessions entirely (permissions.deny).

Rendered as --settings {\"permissions\":{\"deny\":[...]}}, the verified
hard floor: a denied tool is absent from the session's toolset, so no
permission mode, hook decision, or allowlist entry can reopen it --
capability withheld by absence, never by behavioral instruction
\(claude-cli.md, Hooks as the headless permission surface).  Nil
disables the deny floor and dispatches with stock tool visibility.
Entries also in `claude-queue-sandboxed-tools' are lifted from the
floor when the dispatch root is a sandbox-enrolled checkout, and
`claude-queue-bare-root-denied-tools' joins the floor when the root
is no project."
  :type '(repeat string)
  :group 'claude-queue)

(defcustom claude-queue-sandboxed-tools '("Bash" "WebFetch" "WebSearch")
  "Tools lifted from `claude-queue-denied-tools' inside a sandboxed checkout.

A checkout enrolled in claude-code-sandbox (its sidecar
`claude-queue--sandbox-sidecar' binds a profile other than the
reserved empty profile \"none\") confines every Bash command at the
OS level: the profile's closed toolset, filesystem, and network
rules.  That is the confinement the deny floor otherwise stands in
for, so dispatches rooted in such a checkout keep the shell and the
network tools and can build, test, fetch, and land within the
sandbox's walls.  Note that WebFetch and WebSearch run inside the
CLI process, outside the Bash sandbox's network namespace: the
profile's domain rules do not reach them, and the dispatch
permission mode alone gates their calls.  The emacs server's tools
have nothing to do with this list: they run in the Emacs process,
which the sandbox never reaches.  An unreadable or absent sidecar
counts as unenrolled."
  :type '(repeat string)
  :group 'claude-queue)

(defcustom claude-queue-bare-root-denied-tools
  '(;; The CLI's own disk writers ("MultiEdit" is not a registered
    ;; tool on 2.1.241; the three below are, and permissions.deny
    ;; unregisters them -- probe-verified, claude-cli.md).
    "Edit" "Write" "NotebookEdit"
    ;; The emacs server's disk writers.
    "mcp__emacs__edit-file" "mcp__emacs__transform")
  "Tools added to the deny floor when the dispatch root is no project.

Territory is project identity (consent-gate.md): a dispatch from
inside a project grants edits to that project.  A dispatch rooted
outside any project -- `claude-queue--root' falls back to the
buffer's own directory when no git checkout or project encloses it
-- has no identity to grant, and every write path would otherwise
take that bare directory (the home directory, say) as its whole
territory: the consent hook and the CLI's workdir rule for
Edit/Write, and the emacs server's write-scope filter, which derives
its territory from the same directory, for edit-file and transform.
So a bare-root dispatch gets no unattended disk writes on either
path.  It keeps reading, commenting, presenting, and `edit-buffer',
whose changes land in the buffer for the resident user to save.  The
predicate is the server's own (`project-current' on the root), so
the guard fires exactly when the territory would degrade."
  :type '(repeat string)
  :group 'claude-queue)

(defcustom claude-queue-extra-args nil
  "Extra command-line arguments for every dispatch."
  :type '(repeat string)
  :group 'claude-queue)

(defcustom claude-queue-max-region-chars 8000
  "Longest selected-region excerpt embedded in a task prompt."
  :type 'natnum
  :group 'claude-queue)

(defcustom claude-queue-refresh-interval 5
  "Seconds between queue pumps and list refreshes."
  :type 'natnum
  :group 'claude-queue)

(defcustom claude-queue-registry-file
  (locate-user-emacs-file "claude-queue-registry.eld")
  "File persisting dispatched-agent bookkeeping across sessions."
  :type 'file
  :group 'claude-queue)

(defcustom claude-queue-registry-max 200
  "Most registry entries kept when saving."
  :type 'natnum
  :group 'claude-queue)

(defcustom claude-queue-projects-directory "~/.claude/projects/"
  "Directory holding Claude Code per-project session transcripts."
  :type 'directory
  :group 'claude-queue)

(defcustom claude-queue-sessions-directory "~/.claude/sessions/"
  "Directory of the Claude daemon's live-session records.
One small JSON file per hosting process; claude-cli.md documents the
format, its coverage, and the verification behind both."
  :type 'directory
  :group 'claude-queue)

(defcustom claude-queue-semantic-document-prefix
  "A Claude Code background agent named %s, with the conversation:\n"
  "Format string prefixing each embedded transcript; %s is the agent name.
The document side of the asymmetric query/document pair, mirroring
`semantic-finder-document-prefix': the model should judge \"is this
the agent being described\", not raw text similarity."
  :type 'string
  :group 'claude-queue)

(defcustom claude-queue-semantic-query-prefix
  "A Claude Code background agent matching the description: "
  "Prefix for the typed description before it is embedded.
The query-side counterpart of
`claude-queue-semantic-document-prefix'."
  :type 'string
  :group 'claude-queue)

;;; State

(defvar claude-queue--pending nil
  "FIFO of not-yet-dispatched items, oldest first.
Each item is a plist; :status is `queued', `dispatching', or `failed'.")

(defvar claude-queue--session-ids nil
  "Agent ids dispatched by this Emacs session (for slot accounting).")

(defvar claude-queue--agents-cache nil
  "Most recent parse of `claude agents --json --all'.")

(defvar claude-queue--registry 'unloaded
  "Persisted dispatch records, or `unloaded'.")

(defvar claude-queue--timer nil
  "Repeating timer driving the pump and the list refresh.")

(defconst claude-queue--list-buffer "*claude-queue*"
  "Name of the queue list buffer (queue-dispatched tasks only).")

(defconst claude-queue--agents-buffer "*claude-agents*"
  "Name of the all-agents list buffer (every background agent).")

(defvar-local claude-queue--list-scope 'queue
  "What this list buffer shows: `queue' tasks only, or `all' agents.")

(defvar-local claude-queue--list-retired nil
  "Whether this list buffer includes agents retired from the active list.")

;;; Capture

(defun claude-queue--root (&optional dir)
  "Root directory tasks near DIR are dispatched from.

The outermost enclosing git repository, so work in a submodule is
dispatched from the superproject checkout; falls back to the current
project root, then to DIR itself."
  (let* ((dir (expand-file-name (or dir default-directory)))
         (outermost nil)
         (probe (locate-dominating-file dir ".git")))
    (while probe
      (setq outermost probe)
      (setq probe (let ((parent (file-name-directory
                                 (directory-file-name probe))))
                    (and parent (not (equal parent probe))
                         (locate-dominating-file parent ".git")))))
    (or outermost
        (when-let* ((project (progn (require 'project)
                                    (project-current nil dir))))
          (project-root project))
        dir)))

(defun claude-queue--truncate (text limit)
  "Return TEXT clipped to LIMIT characters with a truncation marker."
  (if (> (length text) limit)
      (concat (substring text 0 limit) "\n[excerpt truncated]")
    text))

(defun claude-queue--capture ()
  "Snapshot the current location as a plist for prompt composition."
  (let ((region (when (use-region-p)
                  (list :text (claude-queue--truncate
                               (buffer-substring-no-properties
                                (region-beginning) (region-end))
                               claude-queue-max-region-chars)
                        :start-line (line-number-at-pos (region-beginning))
                        :end-line (line-number-at-pos (region-end))))))
    (list :root (claude-queue--root)
          :file (buffer-file-name)
          :buffer (buffer-name)
          :line (line-number-at-pos)
          :column (current-column)
          :line-text (unless region
                       (buffer-substring-no-properties
                        (line-beginning-position) (line-end-position)))
          :modified (buffer-modified-p)
          :region region)))

(defconst claude-queue--conduct
  (concat
   "Conduct for this queued background task: the user fired it from"
   " their editor and moved on; a clarifying question drags them into"
   " an interactive session.  When the request is ambiguous but the"
   " work is low-stakes and easy to redo, pick the most reasonable"
   " interpretation, note the assumption in your reply, and proceed;"
   " save questions for actions that are risky or hard to reverse."
   "  When the task is done, end your final message with a line"
   " starting with \"result:\" summarizing the outcome -- the CLI's"
   " done-detection keys on that line, and without it a finished task"
   " lingers as \"working\".")
  "Standing instructions appended to every dispatched task prompt.

Two field-observed failure modes motivate it: agents asking
clarifying questions on low-stakes tasks (stalling in \"blocked\"
until the user attaches), and agents finishing without a result:
line (leaving the session in \"working\" indefinitely).")

(defun claude-queue--compose-prompt (instruction capture)
  "Compose the task prompt from INSTRUCTION and a CAPTURE plist."
  (let* ((root (plist-get capture :root))
         (file (plist-get capture :file))
         (region (plist-get capture :region))
         (line-text (plist-get capture :line-text)))
    (concat
     instruction "\n\n---\n"
     "Location captured from Emacs when the user wrote the instruction"
     " above (that is where \"this\"/\"here\" point):\n"
     (if file
         (format "- File: %s (line %d, column %d)\n"
                 (file-relative-name file root)
                 (plist-get capture :line)
                 (plist-get capture :column))
       (format "- Emacs buffer %S (line %d; not visiting a file)\n"
               (plist-get capture :buffer)
               (plist-get capture :line)))
     (when (plist-get capture :modified)
       (concat "- The buffer has unsaved modifications; excerpts here"
               " reflect the buffer, the file on disk may differ.\n"))
     (cond
      (region
       (format "- Selected text (lines %d-%d):\n\n```\n%s\n```\n"
               (plist-get region :start-line)
               (plist-get region :end-line)
               (plist-get region :text)))
      ((and line-text (not (string-blank-p line-text)))
       (format "- Text of that line: %s\n" line-text)))
     "\n" claude-queue--conduct "\n")))

(defun claude-queue--derive-name (instruction capture)
  "Short display name for the task built from INSTRUCTION and CAPTURE."
  (let* ((file (plist-get capture :file))
         (name (concat (when file
                         (concat (file-name-nondirectory file) ": "))
                       instruction)))
    (if (> (length name) 64)
        (concat (substring name 0 63) "…")
      name)))

(defun claude-queue--location-description (capture)
  "One-glance description of CAPTURE for the minibuffer prompt."
  (let ((place (if (plist-get capture :file)
                   (file-name-nondirectory (plist-get capture :file))
                 (plist-get capture :buffer)))
        (region (plist-get capture :region)))
    (if region
        (format "%s:%d-%d" place
                (plist-get region :start-line)
                (plist-get region :end-line))
      (format "%s:%d" place (plist-get capture :line)))))

;;; Dispatch

(defconst claude-queue--sandbox-sidecar ".claude/claude-code-sandbox.json"
  "Checkout-relative path of the claude-code-sandbox enrollment sidecar.
Written only by the `claude-code-sandbox' CLI; a JSON object whose
\"profile\" names the bound sandbox profile (\"none\" = abandoned).")

(defun claude-queue--sandbox-profile (root)
  "Sandbox profile bound to the checkout at ROOT, or nil.

Nil when ROOT is nil, has no sidecar, or the sidecar is unreadable
or malformed -- every failure reads as unenrolled."
  (when root
    (let ((sidecar (expand-file-name claude-queue--sandbox-sidecar root)))
      (when (file-readable-p sidecar)
        (condition-case nil
            (with-temp-buffer
              (insert-file-contents sidecar)
              (let ((profile (gethash "profile" (json-parse-buffer))))
                (and (stringp profile) profile)))
          (error nil))))))

(defun claude-queue--sandboxed-p (root)
  "Non-nil when the checkout at ROOT is enrolled in a sandbox profile."
  (let ((profile (claude-queue--sandbox-profile root)))
    (and profile (not (equal profile "none")))))

(defun claude-queue--project-root-p (root)
  "Non-nil when ROOT lies in a project as the emacs MCP server sees it.
The same `project-current' call the server's write-scope filter
makes on the bridge's launch directory, so this predicts whether the
server's territory for a dispatch from ROOT is a project or a bare
directory."
  (and root
       (file-directory-p root)
       (progn (require 'project)
              (project-current nil root))
       t))

(defun claude-queue--denied-tools (root)
  "The deny floor for a dispatch rooted at ROOT.
`claude-queue-denied-tools' less `claude-queue-sandboxed-tools' when
ROOT is a project checkout enrolled in a sandbox profile, plus
`claude-queue-bare-root-denied-tools' when ROOT is no project.  The
sandbox lift needs the project: the sandbox tool only enrolls git
roots, so a sidecar found under a bare directory is not an
enrollment and lifts nothing."
  (let ((project (claude-queue--project-root-p root)))
    (append (if (and project (claude-queue--sandboxed-p root))
                (seq-remove (lambda (tool)
                              (member tool claude-queue-sandboxed-tools))
                            claude-queue-denied-tools)
              claude-queue-denied-tools)
            (unless project claude-queue-bare-root-denied-tools))))

(defun claude-queue--command (item)
  "Dispatch command line (a list of strings) for ITEM."
  (append (list claude-queue-program "--bg")
          ;; --allowedTools is variadic; comma-join to one value and keep
          ;; a non-variadic flag behind it so it can't swallow the prompt.
          (when claude-queue-allowed-tools
            (list "--allowedTools"
                  (string-join claude-queue-allowed-tools ",")))
          ;; The deny floor goes in --settings (accepts inline JSON), not
          ;; --disallowedTools: that flag is variadic like --allowedTools
          ;; and would be a second prompt-swallow hazard in the argv.
          (when-let* ((denied (claude-queue--denied-tools
                               (plist-get item :root))))
            (list "--settings"
                  (json-serialize
                   `(:permissions (:deny ,(vconcat denied))))))
          (list "--model" (plist-get item :model)
                "--name" (plist-get item :name))
          (when claude-queue-permission-mode
            (list "--permission-mode" claude-queue-permission-mode))
          claude-queue-extra-args
          (list (plist-get item :prompt))))

(defun claude-queue--strip-ansi (string)
  "Return STRING with ANSI CSI escape sequences removed.
Covers colors and also cursor/erase controls like \\e[?25h -- the
CLI's spinner leaks such sequences into piped output when stderr
shares the pipe."
  (replace-regexp-in-string "\e\\[[0-9;?]*[ -/]*[@-~]" "" string))

(defun claude-queue--parse-backgrounded (output)
  "Agent id from the `claude --bg' OUTPUT banner, or nil."
  (let ((clean (claude-queue--strip-ansi output)))
    (when (string-match "backgrounded · \\([0-9a-f]+\\)" clean)
      (match-string 1 clean))))

;;;###autoload
(defun claude-queue-dispatch (model)
  "Queue a task for Claude Code about the current location.

Captures the buffer's file, line, and the selected region (when one
is active), prompts for an instruction, and queues a background
agent working from the enclosing project root.  MODEL is
`claude-queue-default-model' when called interactively;
`claude-queue-dispatch-model' asks for one instead."
  (interactive (list claude-queue-default-model))
  (let* ((capture (claude-queue--capture))
         (instruction (read-string
                       (format "Claude [%s] (%s): " model
                               (claude-queue--location-description capture)))))
    (when (string-blank-p instruction)
      (user-error "Empty instruction"))
    (deactivate-mark)
    (let ((item (list :status 'queued
                      :instruction instruction
                      :prompt (claude-queue--compose-prompt
                               instruction capture)
                      :name (claude-queue--derive-name instruction capture)
                      :model model
                      :root (plist-get capture :root)
                      :time (float-time)
                      :error nil)))
      (setq claude-queue--pending
            (append claude-queue--pending (list item)))
      (claude-queue--ensure-timer)
      (claude-queue--pump)
      (message "claude-queue: queued %S (%d in queue)"
               (plist-get item :name)
               (length claude-queue--pending)))))

;;;###autoload
(defun claude-queue-dispatch-model ()
  "Like `claude-queue-dispatch', but pick the model first.

Offers `claude-queue-models', defaulting to
`claude-queue-default-model'; any other model name can be typed."
  (interactive)
  (claude-queue-dispatch
   (completing-read "Model: " claude-queue-models
                    nil nil nil nil claude-queue-default-model)))

(defun claude-queue--releasable (queued working dispatching maximum)
  "How many of QUEUED items may dispatch now.

WORKING and DISPATCHING already occupy slots out of MAXIMUM; a nil
MAXIMUM releases everything."
  (if (null maximum)
      queued
    (min queued (max 0 (- maximum working dispatching)))))

(defun claude-queue--queued-items ()
  "Pending items still waiting for a slot, oldest first."
  (seq-filter (lambda (item) (eq (plist-get item :status) 'queued))
              claude-queue--pending))

(defun claude-queue--session-working-count (agents)
  "Count of this session's dispatched AGENTS still working."
  (seq-count (lambda (agent)
               (and (member (alist-get 'id agent) claude-queue--session-ids)
                    (equal (alist-get 'state agent) "working")))
             agents))

(defun claude-queue--pump ()
  "Dispatch queued items into free slots, consulting live agent state."
  (when (claude-queue--queued-items)
    (if (null claude-queue-max-concurrent)
        (progn
          (mapc #'claude-queue--dispatch-now (claude-queue--queued-items))
          (claude-queue--redraw))
      (claude-queue--fetch-agents
       (lambda (agents)
         (let* ((queued (claude-queue--queued-items))
                (dispatching
                 (seq-count (lambda (item)
                              (eq (plist-get item :status) 'dispatching))
                            claude-queue--pending))
                (free (claude-queue--releasable
                       (length queued)
                       (claude-queue--session-working-count agents)
                       dispatching
                       claude-queue-max-concurrent)))
           (mapc #'claude-queue--dispatch-now (seq-take queued free))
           (claude-queue--redraw)))))))

(defun claude-queue--dispatch-now (item)
  "Launch a background agent for ITEM."
  (plist-put item :status 'dispatching)
  (let ((buffer (generate-new-buffer " *claude-queue dispatch*"))
        (default-directory (plist-get item :root)))
    (make-process
     :name "claude-queue-dispatch"
     :buffer buffer
     :command (claude-queue--command item)
     :sentinel (lambda (process _event)
                 (unless (process-live-p process)
                   (claude-queue--dispatch-finished item process))))))

(defun claude-queue--dispatch-finished (item process)
  "Record the dispatch result of PROCESS for ITEM."
  (let* ((buffer (process-buffer process))
         (output (if (buffer-live-p buffer)
                     (with-current-buffer buffer (buffer-string))
                   ""))
         (id (and (zerop (process-exit-status process))
                  (claude-queue--parse-backgrounded output))))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))
    (if (not id)
        (progn
          (plist-put item :status 'failed)
          (plist-put item :error output)
          (message "claude-queue: dispatch failed for %S (RET on the row for output)"
                   (plist-get item :name)))
      (setq claude-queue--pending (delq item claude-queue--pending))
      (push id claude-queue--session-ids)
      ;; Dispatch is the consent: record the structural grant (the
      ;; captured project root, which is also the session's workdir
      ;; sandbox) keyed by the agent id, so the consent hook gates this
      ;; session's out-of-territory edits instead of abstaining.  The
      ;; banner-to-record window is milliseconds against the seconds a
      ;; first tool call takes; losing it degrades to stock behavior
      ;; (abstention), never to a wrong decision.  A failed record is
      ;; reported but does not fail the dispatch: the session then
      ;; simply runs ungated, i.e. sandboxed to its workdir natively.
      (condition-case err
          (claude-consent-record-territory
           id (list (plist-get item :root))
           claude-queue-consent-deadline
           (plist-get item :name))
        (error
         (message "claude-queue: consent territory record failed for %s (%s)"
                  id (error-message-string err))))
      (claude-queue--registry-add
       (list :id id
             :name (plist-get item :name)
             :model (plist-get item :model)
             :root (plist-get item :root)
             :time (plist-get item :time)))
      (message "claude-queue: dispatched %S as %s"
               (plist-get item :name) id))
    (claude-queue--redraw)))

;;; Agent listing

(defun claude-queue--agents-from-json (json)
  "Parse JSON from `claude agents --json' into a list of alists.

The CLI decorates piped output with terminal escapes when its spinner
shares the pipe (observed: \\e[?25h after the closing bracket), so
the string is stripped of CSI sequences and trimmed to the outermost
bracketed body before parsing."
  (let* ((clean (claude-queue--strip-ansi json))
         (start (string-search "[" clean))
         (rpos (string-search "]" (reverse clean))))
    (json-parse-string
     (if (and start rpos)
         (substring clean start (- (length clean) rpos))
       clean)
     :object-type 'alist :array-type 'list)))

(defun claude-queue--agent-active-p (agent)
  "Whether the CLI still lists AGENT as active.
In the --all listing only agents with a live process carry `pid';
the CLI retires the rest (sometimes prematurely)."
  (and (alist-get 'pid agent) t))

(defun claude-queue--agent-by-id (id agents)
  "Row of AGENTS with short id ID, or nil."
  (seq-find (lambda (agent) (equal (alist-get 'id agent) id)) agents))

(defun claude-queue--fetch-agents (callback)
  "Fetch the background-agent list asynchronously, then run CALLBACK.

CALLBACK receives the parsed list; the result is also cached in
`claude-queue--agents-cache'.  On failure the stale cache is passed."
  (let ((buffer (generate-new-buffer " *claude-queue agents*")))
    (make-process
     :name "claude-queue-agents"
     :buffer buffer
     :command (list claude-queue-program "agents" "--json" "--all")
     :sentinel
     (lambda (process _event)
       (unless (process-live-p process)
         (when (buffer-live-p buffer)
           (when (zerop (process-exit-status process))
             (condition-case nil
                 (setq claude-queue--agents-cache
                       (claude-queue--agents-from-json
                        (with-current-buffer buffer (buffer-string))))
               (error nil)))
           (kill-buffer buffer))
         (funcall callback claude-queue--agents-cache))))))

;;; Registry

(defun claude-queue--registry-read (file)
  "Read persisted registry entries from FILE, tolerating absence."
  (when (file-readable-p file)
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents file)
          (read (current-buffer)))
      (error nil))))

(defun claude-queue--registry ()
  "Registry entries, newest first, loading the file on first use."
  (when (eq claude-queue--registry 'unloaded)
    (setq claude-queue--registry
          (claude-queue--registry-read claude-queue-registry-file)))
  claude-queue--registry)

(defun claude-queue--registry-write ()
  "Persist the registry, pruned to `claude-queue-registry-max'."
  (setq claude-queue--registry
        (seq-take (claude-queue--registry) claude-queue-registry-max))
  (with-temp-file claude-queue-registry-file
    (let ((print-length nil)
          (print-level nil))
      (prin1 claude-queue--registry (current-buffer)))))

(defun claude-queue--registry-add (entry)
  "Prepend ENTRY to the registry and persist."
  (setq claude-queue--registry (cons entry (claude-queue--registry)))
  (claude-queue--registry-write))

(defun claude-queue--registry-remove (entry)
  "Drop ENTRY from the registry and persist."
  (setq claude-queue--registry (delq entry (claude-queue--registry)))
  (claude-queue--registry-write))

;;; Session following

(defvar-local claude-queue--buffer-agent nil
  "Agent id whose session this buffer is a view of, or nil.
Set on attach terminals and transcript views; buffers found to view a
session some other way (a hand-run `claude' under a ghostel shell)
are recognized by process inspection instead and stay nil.")

(defvar claude-queue--follow-cache-miss nil
  "Cache-refill state for follow resolutions that missed an agent id.
Non-nil after a miss; the follow tick refills the agents cache once
and damps to `fetched' so an id the CLI no longer knows cannot spawn
a fetch per tick.  Selecting a followable buffer re-arms it.")

(defun claude-queue--process-argv (pid)
  "Command line of process PID as a list of strings, nil when gone."
  (ignore-errors
    (with-temp-buffer
      (insert-file-contents (format "/proc/%d/cmdline" pid))
      (split-string (buffer-string) "\0" t))))

(defun claude-queue--process-cwd (pid)
  "Current working directory of process PID, nil when unreadable.
The /proc cwd link tracks chdir as it happens, so for a claude
session process this is the session's live working directory.  For
TUI-hosted sessions -- a resumed conversation runs inside the TUI
process itself, which chdirs on /cd -- this is the only cwd source:
their session records carry a placeholder name no title can match,
and before their first message they have no record at all."
  (ignore-errors (file-symlink-p (format "/proc/%d/cwd" pid))))

(defun claude-queue--proc-start-time (pid)
  "Start time of process PID in boot clock ticks (a string), nil when gone.
Field 22 of /proc/PID/stat, taken from after the last close paren --
the executable-name field before it may itself contain spaces or
parens."
  (when-let* ((stat (ignore-errors
                      (with-temp-buffer
                        (insert-file-contents (format "/proc/%d/stat" pid))
                        (buffer-string))))
              ((string-match "\\`.*)" stat)))
    (nth 19 (split-string (substring stat (match-end 0))))))

(defun claude-queue--process-children (pid)
  "Direct child pids of process PID, via /proc (all threads)."
  (let ((task-directory (format "/proc/%d/task" pid))
        (children nil))
    (dolist (task (ignore-errors
                    (directory-files task-directory nil "\\`[0-9]+\\'")))
      (when-let* ((text (ignore-errors
                          (with-temp-buffer
                            (insert-file-contents
                             (expand-file-name
                              "children"
                              (expand-file-name task task-directory)))
                            (buffer-string)))))
        (setq children
              (nconc children
                     (mapcar #'string-to-number (split-string text))))))
    children))

(defun claude-queue--process-descendants (pid)
  "Descendant pids of process PID, breadth-first."
  (let ((frontier (claude-queue--process-children pid))
        (descendants nil))
    (while frontier
      (let ((next (pop frontier)))
        (push next descendants)
        (setq frontier
              (nconc frontier (claude-queue--process-children next)))))
    (nreverse descendants)))

(defun claude-queue--argv-session (argv)
  "How the process running ARGV relates to a claude session.

`self' when the process IS an interactive session, so its own /proc
cwd is the session's; (attach . ID) for an attach client viewing
background session ID; nil for anything else -- other programs, and
the CLI's non-session invocations: the daemon, pty hosts and
spare-pool workers (--bg* flags), and utility subcommands.  The
wrapped name is the argv[0] a nix wrapProgram leaves behind."
  (let ((basename (and argv (file-name-nondirectory (car argv)))))
    (when (member basename (list claude-queue-program
                                 (format ".%s-wrapped" claude-queue-program)))
      (let* ((rest (cdr argv))
             (subcommand (seq-find (lambda (argument)
                                     (not (string-prefix-p "-" argument)))
                                   rest)))
        (cond
         ((seq-some (lambda (argument) (string-prefix-p "--bg" argument))
                    rest)
          nil)
         ((equal subcommand "attach")
          (when-let* ((id (cadr (member "attach" rest))))
            (cons 'attach id)))
         ((member subcommand '("daemon" "agents" "logs" "stop"
                               "mcp" "config" "doctor" "update"))
          nil)
         (t 'self))))))

;; The daemon's per-process session records (sessions/<pid>.json) are
;; the freshest name+cwd surface for daemon-worker-hosted sessions --
;; background agents and fresh-started interactive chats -- and the
;; only one that cannot go stale in a cache: they are re-read from
;; disk at every resolution.  They are claims, not facts: the daemon
;; leaves them behind on crash and even clean termination, and pids
;; recycle (especially across the reboots that motivate all of this),
;; so every record is countersigned against the kernel before use.
;; TUI-hosted sessions (resumed conversations) also write records, but
;; under a generated placeholder name and only after their first
;; message -- for those the process walk above is the truth, joined by
;; pid, not name.  claude-cli.md carries the probes behind each claim.

(defun claude-queue--record-live-p (record)
  "Whether session RECORD still describes the running process it names.
The pid must be live and its start time must equal the record's
procStart -- a recycled pid cannot echo its predecessor's birth
tick, so lingering records of dead sessions fail here and resolution
falls through to other sources instead of a wrong answer."
  (when-let* ((pid (alist-get 'pid record))
              (start (alist-get 'procStart record))
              (actual (claude-queue--proc-start-time pid)))
    (equal (format "%s" start) actual)))

(defun claude-queue--session-records ()
  "Countersigned live-session records, one per hosting process.
Read fresh from `claude-queue-sessions-directory' on every call --
the directory holds a handful of small files, and staleness is the
failure mode this source exists to remove.  Unparseable files and
records whose process is gone or recycled drop out."
  (let (records)
    (dolist (file (ignore-errors
                    (directory-files
                     (expand-file-name claude-queue-sessions-directory)
                     t "\\.json\\'")))
      (when-let* ((record (ignore-errors
                            (with-temp-buffer
                              (insert-file-contents file)
                              (json-parse-buffer :object-type 'alist
                                                 :array-type 'list))))
                  ((claude-queue--record-live-p record)))
        (push record records)))
    (nreverse records)))

(defun claude-queue--record-for-id (id records)
  "Record of RECORDS for the session with agent id ID, or nil.
Agent ids are leading fragments of the session UUID; background
jobs carry the same fragment as their jobId."
  (when (and id (not (string-empty-p id)))
    (seq-find (lambda (record)
                (or (when-let* ((session (alist-get 'sessionId record)))
                      (string-prefix-p id session))
                    (equal id (alist-get 'jobId record))))
              records)))

(defun claude-queue--record-cwd (record)
  "Directory session RECORD works in, or nil.
A countersigned record is the single cwd source for the session it
names -- /proc is its validity check, never a competing answer.  A
directory that no longer exists (a removed worktree) is not
returned."
  (when-let* ((cwd (alist-get 'cwd record)))
    (when (file-directory-p cwd)
      (file-name-as-directory cwd))))

(defun claude-queue--agent-cwd (id)
  "Working directory of the session with agent id ID, or nil.

One source per session, chosen by liveness: a live session resolves
through its countersigned daemon record, and a session with no
record is not running, so the agents listing's last recorded cwd is
all there is (transcript views and attach terminals of finished
agents).  A directory that no longer exists (a removed worktree) is
not returned.  An id absent from records and cache alike arms the
follow tick's one-shot cache refill."
  (or (when-let* ((record (claude-queue--record-for-id
                           id (claude-queue--session-records))))
        (claude-queue--record-cwd record))
      (let ((agent (claude-queue--agent-by-id id claude-queue--agents-cache)))
        (unless (or agent (eq claude-queue--follow-cache-miss 'fetched))
          (setq claude-queue--follow-cache-miss t))
        (when-let* ((cwd (alist-get 'cwd agent)))
          (when (file-directory-p cwd)
            (file-name-as-directory cwd))))))

(declare-function ghostel--get-title "ghostel-module")

(defun claude-queue--terminal-title (buffer)
  "Current terminal title (OSC 2) of ghostel BUFFER, or nil.
Read from the terminal object, so manual buffer renames and custom
`ghostel-buffer-name-function's don't obscure it."
  (with-current-buffer buffer
    (when-let* ((term (bound-and-true-p ghostel--term))
                ((fboundp 'ghostel--get-title)))
      (ignore-errors (ghostel--get-title term)))))

(defun claude-queue--title-agent (title agents)
  "Row of AGENTS whose session the terminal TITLE shows, or nil.

The claude TUI titles its terminal with the *viewed* conversation's
name behind a status glyph (\"✳ <name>\"), and switches it when the
user opens another conversation from its agent browser -- so the
title, not the process, says what an attached terminal is currently
showing.  AGENTS may be listing rows or session records; both carry
name, pid, and startedAt.  Matched by exact name equality or a
\" <name>\" suffix (the glyph varies); ties prefer a live session,
then recency.  Resumed conversations never match: their records
carry a generated placeholder name, not the conversation's -- the
process walk resolves them instead."
  (when (and title (not (string-blank-p title)))
    (car (seq-sort
          (lambda (a b)
            (let ((live-a (and (alist-get 'pid a) t))
                  (live-b (and (alist-get 'pid b) t)))
              (if (eq live-a live-b)
                  (> (or (alist-get 'startedAt a) 0)
                     (or (alist-get 'startedAt b) 0))
                live-a)))
          (seq-filter (lambda (agent)
                        (when-let* ((name (alist-get 'name agent)))
                          (and (not (string-blank-p name))
                               (or (equal title name)
                                   ;; Glyph prefix only: a name that is
                                   ;; a word-suffix of another name must
                                   ;; not match that other's title.
                                   (and (string-suffix-p (concat " " name)
                                                         title)
                                        (not (string-match-p
                                              "[[:alnum:]]"
                                              (substring
                                               title 0
                                               (- (length title)
                                                  (1+ (length name)))))))))))
                      agents)))))

(defun claude-queue--buffer-session-cwd (buffer)
  "Live working directory of the claude session BUFFER views, or nil.

What the terminal *currently shows* wins: the title names the viewed
conversation, resolved through the daemon's countersigned session
records -- read fresh from disk, so no cached listing row can shadow
a live session with a stale directory (the failure that broke
re-opened conversations).  Then the launch-time knowledge: the
agent id queue-created views carry in `claude-queue--buffer-agent'.
Last, the process walk: the first claude session among the buffer
process's descendants -- the user's own `claude' run by hand, whose
/proc cwd is the only truth for TUI-hosted conversations (resumed
ones carry placeholder record names no title can match, and have no
record at all before their first message; the process chdirs on
their moves).  Attach clients found in the walk are viewers, not
sessions, and resolve through their session id.  A buffer resolving
nowhere keeps its directory -- for a conversation too new to be
named anywhere, that is the launch directory the shell already
reported, which is where the session is."
  (with-current-buffer buffer
    (or (when-let* ((title (claude-queue--terminal-title buffer))
                    (record (claude-queue--title-agent
                             title (claude-queue--session-records))))
          (claude-queue--record-cwd record))
        (and claude-queue--buffer-agent
             (claude-queue--agent-cwd claude-queue--buffer-agent))
        (when-let* (((not claude-queue--buffer-agent))
                    (process (get-buffer-process buffer))
                    ((process-live-p process))
                    (pid (process-id process))
                    (found (seq-some
                            (lambda (candidate)
                              (when-let* ((how (claude-queue--argv-session
                                                (claude-queue--process-argv
                                                 candidate))))
                                (cons how candidate)))
                            (cons pid
                                  (claude-queue--process-descendants pid)))))
          (pcase found
            (`(self . ,session-pid)
             (when-let* ((cwd (claude-queue--process-cwd session-pid)))
               (and (file-directory-p cwd)
                    (file-name-as-directory cwd))))
            (`((attach . ,id) . ,_)
             (claude-queue--agent-cwd id)))))))

(defun claude-queue--followable-buffer-p (buffer)
  "Whether BUFFER can follow a claude session's working directory.
Queue conversation buffers always can; otherwise any terminal buffer
with a live process is a candidate (whether a claude session actually
runs beneath it is decided at sync time)."
  (with-current-buffer buffer
    (or claude-queue--buffer-agent
        (and (derived-mode-p 'ghostel-mode 'term-mode)
             (when-let* ((process (get-buffer-process buffer)))
               (process-live-p process))))))

(defun claude-queue--follow-sync (buffer)
  "Point BUFFER's `default-directory' at its session's live cwd.
No-op when BUFFER views no session.  Coexists with ghostel's own
OSC 7 directory tracking: a full-screen claude emits no pwd reports,
so this value stands while the session runs, and the shell prompt
reasserts its own directory once claude exits."
  (when-let* ((cwd (claude-queue--buffer-session-cwd buffer)))
    (with-current-buffer buffer
      (unless (equal cwd default-directory)
        (setq default-directory cwd)))))

(defun claude-queue--follow-displayed ()
  "Sync every displayed followable buffer; whether any was found."
  (let ((followed nil))
    (dolist (window (window-list-1 nil nil t))
      (let ((buffer (window-buffer window)))
        (when (claude-queue--followable-buffer-p buffer)
          (setq followed t)
          (claude-queue--follow-sync buffer))))
    followed))

(defun claude-queue--follow-tick ()
  "Periodic follow sync; whether the timer should keep running.
A resolution that missed the agents cache refills it once,
asynchronously, and resyncs when the fresh listing arrives."
  (let ((followed (claude-queue--follow-displayed)))
    (when (eq claude-queue--follow-cache-miss t)
      (setq claude-queue--follow-cache-miss 'fetched)
      (claude-queue--fetch-agents
       (lambda (_agents) (claude-queue--follow-displayed))))
    followed))

(defun claude-queue--follow-refresh (buffer)
  "Sync BUFFER now, refilling the agents cache first when it misses.
The event-driven complement of the tick: a sync whose title match
missed the cache fetches immediately and resyncs when the fresh
listing arrives, instead of waiting out up to two tick periods."
  (setq claude-queue--follow-cache-miss nil)
  (claude-queue--follow-sync buffer)
  (when (eq claude-queue--follow-cache-miss t)
    (setq claude-queue--follow-cache-miss 'fetched)
    (claude-queue--fetch-agents
     (lambda (_agents)
       (when (buffer-live-p buffer)
         (claude-queue--follow-sync buffer))))))

(defun claude-queue--follow-selection (frame)
  "Resync FRAME's newly selected buffer when it views a session.
On `window-selection-change-functions': entering a claude buffer
refreshes it immediately -- ahead of any pending tick -- and
restarts the periodic timer, which stops itself when nothing is
left to follow."
  (let ((buffer (window-buffer (frame-selected-window frame))))
    (when (claude-queue--followable-buffer-p buffer)
      (claude-queue--follow-refresh buffer)
      (claude-queue--ensure-timer))))

(defvar claude-queue-follow-mode)

(defvar-local claude-queue--follow-last-title nil
  "Last title body processed for this buffer, glyph stripped.
The TUI animates the title's leading glyph as a throbber, so raw
titles churn constantly; only a changed *body* means the terminal
may be showing something new.")

(defvar-local claude-queue--follow-title-timer nil
  "Pending trailing-edge refresh for this buffer's title change.")

(defun claude-queue--title-body (title)
  "TITLE minus a leading non-alphanumeric glyph token, if any.
The invariant part of the TUI's \"<glyph> <name>\" title: the glyph
doubles as a throbber and animates while the session works."
  (if (and title
           (string-match "\\`\\([^ ]+\\) " title)
           (not (string-match-p "[[:alnum:]]" (match-string 1 title))))
      (substring title (match-end 0))
    title))

(defun claude-queue--follow-title-change (title &rest _)
  "React to a terminal title report, from `ghostel--set-title'.
The TUI retitles at the exact moment its agent browser switches
conversations, so this is the low-latency trigger for view changes
-- the tick only backstops it.  Runs in the terminal's buffer.

Built to be called at throbber frequency: an unchanged TITLE body
returns after one string compare, and a changed one only schedules
`claude-queue--follow-schedule's trailing-edge refresh -- the
process walk never runs directly in the redisplay-adjacent caller."
  (when claude-queue-follow-mode
    (let ((body (claude-queue--title-body title)))
      (unless (equal body claude-queue--follow-last-title)
        (setq claude-queue--follow-last-title body)
        (claude-queue--follow-schedule (current-buffer))))))

(defun claude-queue--follow-schedule (buffer)
  "Refresh BUFFER shortly, coalescing bursts.
One pending refresh at a time per buffer; while it is pending,
further title changes are absorbed by it instead of rescheduling, so
a flapping title cannot starve the refresh or repeat it."
  (with-current-buffer buffer
    (unless (timerp claude-queue--follow-title-timer)
      (setq claude-queue--follow-title-timer
            (run-at-time
             0.2 nil
             (lambda ()
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (setq claude-queue--follow-title-timer nil))
                 (when (and claude-queue-follow-mode
                            (claude-queue--followable-buffer-p buffer))
                   (claude-queue--follow-refresh buffer)
                   (claude-queue--ensure-timer)))))))))

(defun claude-queue-session-cwd-changed (session-id cwd)
  "Note that session SESSION-ID now works in CWD; resync at once.

Called by the nix-installed emacs-claude-cwd-hook via emacsclient --
the push complement of the polling tick.  Projects register that
command on two events (probe-verified scopes, see claude-cli.md):
CwdChanged for persisted shell `cd' moves, and PostToolUse matched
on EnterWorktree|ExitWorktree for worktree moves, which chdir the
session without emitting CwdChanged; the payload cwd is the
post-move directory in every case.  Refreshes the cached listing row
when the session is listed, keeping the list views current; the
resync itself re-reads the daemon's session records and /proc, so
resolution does not depend on this cache write.  Deliberately not
autoloaded: the hook's fboundp guard makes it a no-op until
claude-queue is in use."
  (when-let* ((agent (seq-find (lambda (agent)
                                 (equal (alist-get 'sessionId agent)
                                        session-id))
                               claude-queue--agents-cache))
              (cell (assq 'cwd agent)))
    (setcdr cell cwd))
  (when claude-queue-follow-mode
    (claude-queue--follow-displayed))
  nil)

;;;###autoload
(define-minor-mode claude-queue-follow-mode
  "Keep claude-session buffers rooted where their session works.

A buffer viewing a claude session -- a ghostel where `claude' was
run by hand, a queue attach terminal, a transcript view -- has its
`default-directory' follow the session's *current* working
directory, read live from the daemon's countersigned session
records and from /proc (worker-hosted sessions resolve by name
through the records; TUI-hosted ones by pid through the process
walk).  Directory-aware commands invoked from such buffers --
`find-file', project search, a new terminal -- then operate on the
tree the session is actually working in.

Resyncs fire on terminal title reports (the TUI retitles when its
agent browser switches conversations -- ghostel has no title hook,
so this is an advice on `ghostel--set-title', throbber-tolerant:
glyph-only churn short-circuits on a string compare and real
changes coalesce into one trailing-edge refresh; if ghostel ever adds
a title hook and this advice is removed, the mode degrades to its
timer), on window selection, on
`claude-queue-session-cwd-changed' pushes from the CwdChanged hook
where a project registers it, and on a periodic tick while
followable buffers are displayed."
  :global t :group 'claude-queue
  (if claude-queue-follow-mode
      (progn
        (add-hook 'window-selection-change-functions
                  #'claude-queue--follow-selection)
        (when (fboundp 'ghostel--set-title)
          (advice-add 'ghostel--set-title :after
                      #'claude-queue--follow-title-change))
        (claude-queue--follow-displayed)
        (claude-queue--ensure-timer))
    (remove-hook 'window-selection-change-functions
                 #'claude-queue--follow-selection)
    (when (fboundp 'ghostel--set-title)
      (advice-remove 'ghostel--set-title
                     #'claude-queue--follow-title-change))))

;;; List UI

(defun claude-queue--agent-display-state (agent &optional consent-pending)
  "Display state for a live AGENT row, or \"gone\" when nil.

An agent whose state is \"working\" but whose process reports itself
idle is shown as \"idle\": its turn has ended without the CLI marking
the session done.  Questions and permission stalls surface as
\"blocked\", not here; in the field an idle row usually means the
task finished but its final message lacked the result: line the
CLI's done-detection keys on -- read the transcript (RET) to judge.

CONSENT-PENDING is the current `claude-consent-pending-requests'
snapshot; when it holds requests for AGENT's session the row reads
\"consent ‹n›\" instead: the session is parked in a synchronous
PreToolUse hook waiting for an answer (`claude-consent-list'), which
the CLI itself cannot see -- it keeps reporting working/busy."
  (let ((consent (and agent consent-pending
                      (claude-consent-session-pending-count
                       (alist-get 'id agent) consent-pending))))
    (cond
     ((null agent) "gone")
     ((and consent (> consent 0)) (format "consent ‹%d›" consent))
     ((and (equal (alist-get 'state agent) "working")
           (equal (alist-get 'status agent) "idle"))
      "idle")
     (t (alist-get 'state agent)))))

(defun claude-queue--state-face (state)
  "Face used to display STATE in the list."
  (pcase state
    ("queued" 'warning)
    ("dispatching" 'warning)
    ("idle" 'warning)
    ("blocked" 'warning)
    ((and (pred stringp) (pred (string-prefix-p "consent"))) 'warning)
    ("failed" 'error)
    ("working" 'success)
    (_ 'shadow)))

(defun claude-queue--list-entry (id time state model name where)
  "Assemble one `tabulated-list-entries' element.
ID is the row object; TIME, STATE, MODEL, NAME, and WHERE fill the
columns."
  (list id
        (vector (format-time-string "%H:%M" time)
                (propertize state 'face (claude-queue--state-face state))
                (or model "")
                (or name "")
                (abbreviate-file-name (or where "")))))

(defun claude-queue--synthetic-entry (agent)
  "Row plist for AGENT dispatched outside the queue.
Carries :synthetic so row actions can tell it apart."
  (list :id (alist-get 'id agent)
        :name (alist-get 'name agent)
        :root (alist-get 'cwd agent)
        :time (/ (or (alist-get 'startedAt agent) 0) 1000.0)
        :synthetic t))

(defun claude-queue--list-entries (pending registry agents &optional scope retired)
  "Rows for a list buffer.

SCOPE `queue' (the default) shows PENDING items plus REGISTRY
entries; SCOPE `all' shows one row per agent in AGENTS, enriched
from REGISTRY where the agent is queue-tracked, native-agent-viewer
style.  Without RETIRED, rows are limited to agents the CLI still
lists as active; RETIRED admits the full --all history (in queue
scope, also registry rows whose session is gone entirely)."
  (let* ((scope (or scope 'queue))
         (tasks
          (pcase scope
            ('queue
             (if retired
                 registry
               (seq-filter
                (lambda (entry)
                  (when-let* ((agent (claude-queue--agent-by-id
                                      (plist-get entry :id) agents)))
                    (claude-queue--agent-active-p agent)))
                registry)))
            ('all
             (mapcar (lambda (agent)
                       (or (seq-find (lambda (entry)
                                       (equal (plist-get entry :id)
                                              (alist-get 'id agent)))
                                     registry)
                           (claude-queue--synthetic-entry agent)))
                     (if retired
                         agents
                       (seq-filter #'claude-queue--agent-active-p agents)))))))
    (append
     (when (eq scope 'queue)
       (mapcar (lambda (item)
                 (claude-queue--list-entry
                  item
                  (plist-get item :time)
                  (symbol-name (plist-get item :status))
                  (plist-get item :model)
                  (plist-get item :name)
                  (plist-get item :root)))
               pending))
     (let ((consent-pending (ignore-errors
                              (claude-consent-pending-requests))))
       (mapcar (lambda (entry)
                 (let ((agent (claude-queue--agent-by-id
                               (plist-get entry :id) agents)))
                   (claude-queue--list-entry
                    entry
                    (plist-get entry :time)
                    (claude-queue--agent-display-state agent consent-pending)
                    (plist-get entry :model)
                    (plist-get entry :name)
                    (or (and agent (alist-get 'cwd agent))
                        (plist-get entry :root)))))
               (seq-sort-by (lambda (entry) (or (plist-get entry :time) 0))
                            #'> tasks))))))

(defvar claude-queue-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'claude-queue-open)
    (define-key map (kbd "a") #'claude-queue-attach)
    (define-key map (kbd "s") #'claude-queue-stop)
    (define-key map (kbd "d") #'claude-queue-remove)
    (define-key map (kbd "c") #'claude-queue-clear-done)
    map)
  "Keymap for `claude-queue-list-mode'.")

(define-derived-mode claude-queue-list-mode tabulated-list-mode "Claude-Queue"
  "Status of Claude Code background tasks.

Four commands share this mode: `claude-queue-list' shows
queue-dispatched tasks with an active session and `claude-queue-agents'
every active background agent; the -all variants
(`claude-queue-list-all', `claude-queue-agents-all') extend either to
the CLI's full --all history, which keeps sessions the CLI has retired
from its active list (sometimes prematurely).

States: queued/dispatching live in Emacs and have not reached the
CLI yet; working, blocked (needs your approval or an answer --
attach to respond), done, stopped, and failed come from
`claude agents'; consent ‹n› is joined in from the pending-consent
spool -- the session is parked in its PreToolUse hook on n
out-of-territory edits, invisible to the CLI, answerable from
`claude-consent-list'; idle means the agent's turn ended without the CLI
marking it done -- usually a finished task whose final message
lacked a result: line, so read the transcript (RET) to judge; gone
means the CLI no longer lists the session; failed on a queue row can
also mean dispatch itself failed (RET shows the output).

\\{claude-queue-list-mode-map}"
  (setq tabulated-list-format
        [("When" 5 nil)
         ("State" 11 nil)
         ("Model" 6 nil)
         ("Task" 50 nil)
         ("Where" 0 nil)])
  (setq tabulated-list-sort-key nil)
  (setq-local revert-buffer-function #'claude-queue--revert)
  (tabulated-list-init-header))

(defun claude-queue--list-buffers ()
  "Live list buffers, each carrying its scope."
  (seq-filter #'identity
              (list (get-buffer claude-queue--list-buffer)
                    (get-buffer claude-queue--agents-buffer))))

(defun claude-queue--redraw ()
  "Redraw every live list buffer from current state."
  (dolist (buffer (claude-queue--list-buffers))
    (with-current-buffer buffer
      (setq tabulated-list-entries
            (claude-queue--list-entries claude-queue--pending
                                        (claude-queue--registry)
                                        claude-queue--agents-cache
                                        claude-queue--list-scope
                                        claude-queue--list-retired))
      (tabulated-list-print t))))

(defun claude-queue--revert (&rest _)
  "Refresh the list buffers from a fresh agent listing."
  (claude-queue--fetch-agents (lambda (_agents) (claude-queue--redraw))))

(defun claude-queue--pop-list (buffer-name scope retired)
  "Show list buffer BUFFER-NAME with SCOPE and RETIRED, refreshing it."
  (with-current-buffer (get-buffer-create buffer-name)
    (unless (derived-mode-p 'claude-queue-list-mode)
      (claude-queue-list-mode))
    (setq claude-queue--list-scope scope)
    (setq claude-queue--list-retired retired)
    (setq mode-name (concat "Claude-Queue" (when retired "[all]")))
    (claude-queue--redraw)
    (claude-queue--revert)
    (claude-queue--ensure-timer)
    (pop-to-buffer (current-buffer))))

;;;###autoload
(defun claude-queue-list ()
  "Show queue-dispatched tasks with a currently-active session."
  (interactive)
  (claude-queue--pop-list claude-queue--list-buffer 'queue nil))

;;;###autoload
(defun claude-queue-list-all ()
  "Show every queue-dispatched task ever recorded.
`claude-queue-list' over the CLI's full --all history, so tasks whose
session the CLI has retired (sometimes prematurely) stay visible."
  (interactive)
  (claude-queue--pop-list claude-queue--list-buffer 'queue t))

;;;###autoload
(defun claude-queue-agents ()
  "Show every active Claude Code background agent.
Queue-dispatched or not, native-agent-viewer style."
  (interactive)
  (claude-queue--pop-list claude-queue--agents-buffer 'all nil))

;;;###autoload
(defun claude-queue-agents-all ()
  "Show every Claude Code background agent the CLI remembers.
`claude-queue-agents' over the full --all listing, including agents
retired from the active list (sometimes prematurely)."
  (interactive)
  (claude-queue--pop-list claude-queue--agents-buffer 'all t))

(defun claude-queue--row ()
  "Row object at point: a pending item or a registry entry plist."
  (or (tabulated-list-get-id)
      (user-error "No task on this line")))

(defun claude-queue--row-pending-p (row)
  "Whether ROW is an Emacs-side pending item."
  (null (plist-get row :id)))

;;; Row actions

(defun claude-queue--project-dir-name (root)
  "Transcript directory name Claude Code derives from ROOT."
  (replace-regexp-in-string
   "[^A-Za-z0-9-]" "-"
   (directory-file-name (expand-file-name root))))

(defun claude-queue--session-transcript (session cwd)
  "Transcript file for SESSION, or nil when absent.

The store keys transcripts by the session's *starting* directory,
so the one derived from CWD is tried first; when the session has
since moved (a worktree, /cd) that directory misses, and every
project directory is searched for the session id instead."
  (when session
    (let ((jsonl (concat session ".jsonl")))
      (or (when cwd
            (let ((file (expand-file-name
                         jsonl
                         (expand-file-name
                          (claude-queue--project-dir-name cwd)
                          claude-queue-projects-directory))))
              (and (file-readable-p file) file)))
          (car (file-expand-wildcards
                (expand-file-name (concat "*/" jsonl)
                                  claude-queue-projects-directory)))))))

(defun claude-queue--transcript-file (entry)
  "Transcript file for registry ENTRY, or nil when absent.
The registry :root is the dispatch directory the session started in;
when the CLI has already forgotten the session (no session id), the
short id prefixing the file name is the fallback key."
  (let* ((agent (claude-queue--agent-by-id (plist-get entry :id)
                                           claude-queue--agents-cache))
         (session (and agent (alist-get 'sessionId agent)))
         (root (plist-get entry :root)))
    (or (claude-queue--session-transcript session root)
        (let ((dir (expand-file-name
                    (claude-queue--project-dir-name root)
                    claude-queue-projects-directory)))
          (when (file-directory-p dir)
            (car (file-expand-wildcards
                  (expand-file-name (concat (plist-get entry :id) "*.jsonl")
                                    dir))))))))

(defun claude-queue--conversation-turns (jsonl)
  "Conversation turns, oldest first, from JSONL transcript text.
Each turn is a (ROLE . TEXT) cons, ROLE \"User\" or \"Assistant\",
built from the text blocks only -- tool calls, tool results, and
thinking drop out -- skipping meta records and tolerating non-JSON
lines."
  (let (turns)
    (dolist (line (split-string jsonl "\n" t))
      (condition-case nil
          (let* ((record (json-parse-string line :object-type 'alist
                                            :array-type 'list))
                 (role (alist-get 'type record)))
            (when (and (member role '("user" "assistant"))
                       (not (eq (alist-get 'isMeta record) t)))
              (let* ((content (alist-get 'content
                                         (alist-get 'message record)))
                     (text (if (stringp content)
                               content
                             (string-join
                              (mapcar (lambda (block)
                                        (alist-get 'text block))
                                      (seq-filter
                                       (lambda (block)
                                         (equal (alist-get 'type block)
                                                "text"))
                                       content))
                              "\n"))))
                (unless (string-blank-p text)
                  (push (cons (capitalize role) text) turns)))))
        (error nil)))
    (nreverse turns)))

(defun claude-queue--render-turns (turns)
  "Readable transcript text from TURNS, sender labels as bold headers."
  (mapconcat (lambda (turn)
               (concat (propertize (concat (car turn) ":") 'face 'bold)
                       "\n" (cdr turn)))
             turns "\n\n"))

(defvar claude-queue-transcript-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'claude-queue-transcript-attach)
    map)
  "Keymap for `claude-queue-transcript-mode'.")

(define-derived-mode claude-queue-transcript-mode special-mode
  "Claude-Transcript"
  "Read-only view of a background agent's transcript.

\\{claude-queue-transcript-mode-map}")

(defun claude-queue-transcript-attach ()
  "Attach a terminal to the agent whose transcript this buffer shows."
  (interactive)
  (unless claude-queue--buffer-agent
    (user-error "No agent behind this buffer"))
  (claude-queue--attach-id claude-queue--buffer-agent))

(declare-function collab-comments-restore "collab-comments")
(defvar collab-comments-document-key)

(defun claude-queue--show-text (name text &optional id session)
  "Pop a read-only buffer titled NAME containing TEXT, point at end.
With ID the buffer belongs to that agent: `a' attaches to it, and the
buffer is rooted at the agent's live working directory (followed
under `claude-queue-follow-mode').  With SESSION the buffer is
declared as a view of that Claude session: collab-comments threads on
it persist under the document key claude-session:SESSION, and are
restored here after each erase-and-reinsert — the render replaces the
buffer text wholesale, so the store, not the collapsed overlays, is
what carries them across."
  (with-current-buffer (get-buffer-create (format "*claude-queue: %s*" name))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert text))
    (claude-queue-transcript-mode)
    (setq claude-queue--buffer-agent id)
    (when id
      (when-let* ((cwd (claude-queue--agent-cwd id)))
        (setq default-directory cwd))
      (claude-queue--ensure-timer))
    (when session
      (setq-local collab-comments-document-key
                  (concat "claude-session:" session))
      (when (require 'collab-comments nil t)
        (collab-comments-restore)))
    (goto-char (point-max))
    (pop-to-buffer (current-buffer))))

(defun claude-queue-open ()
  "Show the task at point: its transcript, or dispatch failure output.
The transcript is the session's conversation -- user and assistant
turns under sender labels; `a' in the buffer attaches to the agent."
  (interactive)
  (let ((row (claude-queue--row)))
    (cond
     ((and (claude-queue--row-pending-p row)
           (eq (plist-get row :status) 'failed))
      (claude-queue--show-text (plist-get row :name)
                               (or (plist-get row :error) "(no output)")))
     ((claude-queue--row-pending-p row)
      (message "Not dispatched yet"))
     (t
      (let ((file (claude-queue--transcript-file row)))
        (unless file
          (user-error "No transcript found for %s" (plist-get row :id)))
        (claude-queue--show-text
         (plist-get row :name)
         (let ((turns (claude-queue--conversation-turns
                       (with-temp-buffer
                         (insert-file-contents file)
                         (buffer-string)))))
           (if turns
               (claude-queue--render-turns turns)
             "(no conversation yet)"))
         (plist-get row :id)
         ;; The transcript file is named <session-id>.jsonl, so its
         ;; base name identifies the session even when the CLI has
         ;; forgotten it (the short-id glob fallback above).
         (file-name-base file)))))))

(defun claude-queue--attach-id (id)
  "Attach a terminal to the background agent ID.

Prefers an ad-hoc ghostel terminal (`ghostel-exec') and falls back to
`term'.  Re-attaching while an attach buffer for ID still has a live
process just revisits that buffer.  Attach buffers are rooted at the
agent's live working directory and follow it under
`claude-queue-follow-mode'."
  (let* ((name (format "*claude-attach-%s*" id))
         (existing (get-buffer name)))
    (if (and existing (process-live-p (get-buffer-process existing)))
        (progn
          (claude-queue--follow-sync existing)
          (pop-to-buffer existing))
      (let ((cwd (claude-queue--agent-cwd id)))
        (if (fboundp 'ghostel-exec)
            (let ((buffer (get-buffer-create name)))
              (with-current-buffer buffer
                (setq claude-queue--buffer-agent id)
                (when cwd (setq default-directory cwd)))
              ;; Display first: ghostel-exec sizes the new terminal to
              ;; the window showing the buffer (80x24 otherwise).
              (pop-to-buffer buffer)
              (ghostel-exec buffer claude-queue-program (list "attach" id)))
          (require 'term)
          (let* ((default-directory (or cwd default-directory))
                 (buffer (make-term (concat "claude-attach-" id)
                                    claude-queue-program nil
                                    "attach" id)))
            (with-current-buffer buffer
              (setq claude-queue--buffer-agent id)
              (term-char-mode))
            (pop-to-buffer buffer)))
        (claude-queue--ensure-timer)))))

(defun claude-queue-attach ()
  "Attach a terminal to the agent at point (see `claude-queue--attach-id')."
  (interactive)
  (let ((row (claude-queue--row)))
    (when (claude-queue--row-pending-p row)
      (user-error "Not dispatched yet"))
    (claude-queue--attach-id (plist-get row :id))))

;;; Agent selector

(defun claude-queue--fetch-agents-sync (&optional all)
  "Background agents, fetched synchronously for a picker.
Active ones only, or every recorded agent when ALL is non-nil.  The
fresh rows also upsert into `claude-queue--agents-cache', so an
attach that follows the pick resolves against current state; rows
absent from a non-ALL fetch are kept, not dropped."
  (with-temp-buffer
    (let ((status (apply #'call-process claude-queue-program nil t nil
                         "agents" "--json"
                         (when all '("--all")))))
      (unless (eq status 0)
        (user-error "%s agents --json failed: %s"
                    claude-queue-program (string-trim (buffer-string))))
      (let ((fresh (claude-queue--agents-from-json (buffer-string))))
        (setq claude-queue--agents-cache
              (append fresh
                      (seq-remove
                       (lambda (agent)
                         (claude-queue--agent-by-id (alist-get 'id agent)
                                                    fresh))
                       claude-queue--agents-cache)))
        fresh))))

(defun claude-queue--state-rank (state)
  "Attention order of display STATE: lower ranks pick first."
  (pcase state
    ("blocked" 0)
    ("idle" 1)
    ("working" 2)
    ("done" 3)
    ("stopped" 4)
    ("failed" 5)
    (_ 6)))

(defun claude-queue--agent-candidates (agents)
  "Completion candidates for AGENTS.

Ordered by attention -- blocked, waiting, and working before done --
then newest first within a state.  Each candidate is \"NAME [ID]\"
carrying its agent alist in the `claude-queue-agent' text property
(for grouping, annotation, and retrieval)."
  (mapcar (lambda (agent)
            (propertize (format "%s [%s]"
                                (or (alist-get 'name agent) "(unnamed)")
                                (alist-get 'id agent))
                        'claude-queue-agent agent))
          (seq-sort (lambda (a b)
                      (let ((rank-a (claude-queue--state-rank
                                     (claude-queue--agent-display-state a)))
                            (rank-b (claude-queue--state-rank
                                     (claude-queue--agent-display-state b))))
                        (if (/= rank-a rank-b)
                            (< rank-a rank-b)
                          (> (or (alist-get 'startedAt a) 0)
                             (or (alist-get 'startedAt b) 0)))))
                    agents)))

(defun claude-queue--candidate-group (candidate transform)
  "Group CANDIDATE by agent state; return it unchanged under TRANSFORM."
  (if transform
      candidate
    (claude-queue--agent-display-state
     (get-text-property 0 'claude-queue-agent candidate))))

(defun claude-queue--candidate-annotation (candidate)
  "Cwd and start time annotation for CANDIDATE."
  (when-let* ((agent (get-text-property 0 'claude-queue-agent candidate)))
    (format "  %s · %s"
            (abbreviate-file-name (or (alist-get 'cwd agent) ""))
            (format-time-string
             "%H:%M" (/ (or (alist-get 'startedAt agent) 0) 1000.0)))))

(defun claude-queue--completion-table (candidates annotation group)
  "Completion table over CANDIDATES, in their given order.
Identity sorters preserve that order; ANNOTATION and GROUP are the
metadata functions, GROUP nil leaving the list ungrouped."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        `(metadata (category . claude-queue-agent)
                   (display-sort-function . identity)
                   (cycle-sort-function . identity)
                   ,@(when group `((group-function . ,group)))
                   (annotation-function . ,annotation))
      (complete-with-action action candidates string predicate))))

(defun claude-queue--choice-id (choice candidates)
  "Agent id selected as CHOICE from propertized CANDIDATES.
The `claude-queue-agent' property survives the minibuffer round-trip
on a match from the candidate list; the [id] suffix is the fallback
for a property-stripped string."
  (let ((agent (get-text-property 0 'claude-queue-agent
                                  (or (car (member choice candidates))
                                      choice))))
    (if agent
        (alist-get 'id agent)
      (and (string-match "\\[\\([0-9a-f]+\\)\\]\\'" choice)
           (match-string 1 choice)))))

;;;###autoload
(defun claude-queue-attach-agent (&optional all)
  "Pick a background agent in the minibuffer and attach to it.

Candidates are grouped by state and annotated with working directory
and start time; covers every background agent, not only queue-
dispatched tasks.  With prefix argument ALL, include agents the CLI
has retired from its active list (sometimes prematurely)."
  (interactive "P")
  (let ((candidates (claude-queue--agent-candidates
                     (claude-queue--fetch-agents-sync all))))
    (unless candidates
      (user-error "No active background agents"))
    (let ((choice (completing-read
                   "Attach to agent: "
                   (claude-queue--completion-table
                    candidates
                    #'claude-queue--candidate-annotation
                    #'claude-queue--candidate-group)
                   nil t)))
      (claude-queue--attach-id
       (claude-queue--choice-id choice candidates)))))

;;;###autoload
(defun claude-queue-attach-agent-all ()
  "Pick from every recorded background agent and attach to it.
`claude-queue-attach-agent' over the CLI's full --all list, which
includes agents retired from the active list (sometimes prematurely)."
  (interactive)
  (claude-queue-attach-agent t))

;;; Semantic agent finder

(defvar claude-queue--embedding-table (make-hash-table :test #'equal)
  "Session id -> (STAMP . EMBEDDING) over embedded transcripts.
STAMP is `claude-queue--transcript-stamp' at embed time; a changed
stamp marks the entry stale.")

(defvar claude-queue--description-history nil
  "Minibuffer history for agent description queries.")

(defun claude-queue--agent-transcript-file (agent)
  "Transcript file for AGENT (a `claude agents' row), or nil.
Unlike `claude-queue--transcript-file' this needs no registry entry:
the row itself carries the session id and working directory.  The
row's cwd is *live* -- for an agent currently inside a worktree it
differs from the starting directory the store keys transcripts by --
so the lookup falls back to searching by session id."
  (claude-queue--session-transcript (alist-get 'sessionId agent)
                                    (alist-get 'cwd agent)))

(defun claude-queue--transcript-stamp (file)
  "Cheap freshness stamp for transcript FILE, nil when absent."
  (when-let* ((attributes (and file (file-attributes file))))
    (list (file-attribute-size attributes)
          (file-attribute-modification-time attributes))))

(defun claude-queue--conversation (jsonl)
  "Conversation turns, oldest first, from JSONL transcript text.
Each turn is \"User: …\" or \"Assistant: …\" --
`claude-queue--conversation-turns' rendered flat for embedding."
  (mapcar (lambda (turn) (format "%s: %s" (car turn) (cdr turn)))
          (claude-queue--conversation-turns jsonl)))

(defun claude-queue--agent-document (agent)
  "Text embedded for AGENT: a contextualizing prefix, its name, and a
bounded slice of its conversation.  `semantic-finder-clip' keeps the
head (the task statement) and the tail (the latest activity)."
  (concat
   (format claude-queue-semantic-document-prefix
           (or (alist-get 'name agent) "(unnamed)"))
   (let ((file (claude-queue--agent-transcript-file agent)))
     (if (not file)
         "(no transcript recorded)"
       (semantic-finder-clip
        (string-join
         (claude-queue--conversation
          (with-temp-buffer
            (insert-file-contents file)
            (buffer-string)))
         "\n\n"))))))

(defun claude-queue--ensure-embeddings (agents)
  "Embed AGENTS whose transcript changed; ((AGENT . EMBEDDING) …).
An unchanged transcript reuses its cached vector, so only agents
that talked since the last query re-embed -- in one batched request.
Agents without a session id cannot be keyed (or read) and are
dropped."
  (let* ((keyed (mapcar (lambda (agent)
                          (list agent
                                (alist-get 'sessionId agent)
                                (claude-queue--transcript-stamp
                                 (claude-queue--agent-transcript-file agent))))
                        (seq-filter (lambda (agent)
                                      (alist-get 'sessionId agent))
                                    agents)))
         (stale (seq-remove
                 (lambda (key)
                   (let ((entry (gethash (nth 1 key)
                                         claude-queue--embedding-table)))
                     (and entry (equal (car entry) (nth 2 key)))))
                 keyed)))
    (when stale
      (seq-mapn (lambda (key embedding)
                  (puthash (nth 1 key) (cons (nth 2 key) embedding)
                           claude-queue--embedding-table))
                stale
                (semantic-finder-embed
                 (mapcar (lambda (key)
                           (claude-queue--agent-document (nth 0 key)))
                         stale))))
    (mapcar (lambda (key)
              (cons (nth 0 key)
                    (cdr (gethash (nth 1 key)
                                  claude-queue--embedding-table))))
            keyed)))

(defun claude-queue--scored-annotation (candidate)
  "Similarity score plus the standard agent annotation for CANDIDATE."
  (concat
   (when-let* ((score (get-text-property 0 'claude-queue-score candidate)))
     (format "  %.2f" score))
   (claude-queue--candidate-annotation candidate)))

;;;###autoload
(defun claude-queue-find-agent (description &optional all)
  "Attach to the agent whose conversation best matches DESCRIPTION.
Every background agent's session transcript is embedded and ranked
against the typed description (semantic-finder's anchor-subtracted
scoring); candidates appear in rank order with the score annotated,
so plain RET takes the best match.  Transcripts that changed since
the last query re-embed first in one batched request -- an agent
ranks on what it has said, current to this call.  With ALL non-nil,
include agents the CLI has retired from its active list (sometimes
prematurely) -- interactively that is `claude-queue-find-agent-all'."
  (interactive
   (list (read-string "Agent description: " nil
                      'claude-queue--description-history)))
  (let* ((agents (claude-queue--fetch-agents-sync all))
         (ranked (semantic-finder-rank
                  description
                  (claude-queue--ensure-embeddings agents)
                  (format claude-queue-semantic-document-prefix "")
                  claude-queue-semantic-query-prefix))
         (candidates
          (mapcar (lambda (pair)
                    (let ((agent (car pair)))
                      (propertize
                       (format "%s [%s]"
                               (or (alist-get 'name agent) "(unnamed)")
                               (alist-get 'id agent))
                       'claude-queue-agent agent
                       'claude-queue-score (cdr pair))))
                  ranked)))
    (unless candidates
      (user-error "No agent transcripts to rank against that description"))
    (let ((choice (completing-read
                   "Agent: "
                   ;; No grouping: grouping by state would visually
                   ;; reorder the ranking this picker exists to show.
                   (claude-queue--completion-table
                    candidates #'claude-queue--scored-annotation nil)
                   nil t)))
      (claude-queue--attach-id
       (claude-queue--choice-id choice candidates)))))

;;;###autoload
(defun claude-queue-find-agent-all (description)
  "Find an agent by DESCRIPTION across the CLI's full --all history.
`claude-queue-find-agent' including agents retired from the active
list (sometimes prematurely)."
  (interactive
   (list (read-string "Agent description (all): " nil
                      'claude-queue--description-history)))
  (claude-queue-find-agent description t))

(defun claude-queue-stop ()
  "Stop the agent at point."
  (interactive)
  (let ((row (claude-queue--row)))
    (when (claude-queue--row-pending-p row)
      (user-error "Not dispatched; use `d' to drop it from the queue"))
    (when (yes-or-no-p (format "Stop %S? " (plist-get row :name)))
      (make-process
       :name "claude-queue-stop"
       :command (list claude-queue-program "stop" (plist-get row :id))
       :sentinel (lambda (process _event)
                   (unless (process-live-p process)
                     (message "claude-queue: stop %s (exit %d)"
                              (plist-get row :id)
                              (process-exit-status process))
                     (claude-queue--revert)))))))

(defun claude-queue-remove ()
  "Drop the row at point: dequeue a pending task or forget a record.

Forgetting a dispatched task only removes it from this list; the
background session itself is untouched (use `s' to stop one)."
  (interactive)
  (let ((row (claude-queue--row)))
    (cond
     ((plist-get row :synthetic)
      (user-error "Not a queue-tracked task; only the CLI forgets it"))
     ((claude-queue--row-pending-p row)
      (setq claude-queue--pending (delq row claude-queue--pending)))
     (t (claude-queue--registry-remove row)
        (ignore-errors
          (claude-consent-remove-territory (plist-get row :id)))))
    (claude-queue--redraw)))

(defun claude-queue-clear-done ()
  "Forget every task whose session is done or gone."
  (interactive)
  (dolist (entry (seq-filter
                  (lambda (entry)
                    (member (claude-queue--agent-display-state
                             (claude-queue--agent-by-id
                              (plist-get entry :id)
                              claude-queue--agents-cache))
                            '("done" "gone")))
                  (claude-queue--registry)))
    (claude-queue--registry-remove entry)
    (ignore-errors
      (claude-consent-remove-territory (plist-get entry :id))))
  (claude-queue--redraw))

;;; Timer

(defun claude-queue--ensure-timer ()
  "Start the pump/refresh timer when it is not already running."
  (unless (timerp claude-queue--timer)
    (setq claude-queue--timer
          (run-at-time claude-queue-refresh-interval
                       claude-queue-refresh-interval
                       #'claude-queue--tick))))

(defun claude-queue--tick ()
  "Pump the queue, refresh the list, follow sessions; stop when idle."
  (let ((queued (claude-queue--queued-items))
        (visible (seq-some (lambda (buffer) (get-buffer-window buffer t))
                           (claude-queue--list-buffers)))
        (followed (and claude-queue-follow-mode
                       (claude-queue--follow-tick))))
    (cond
     (queued (claude-queue--pump))
     (visible (claude-queue--revert))
     (followed)
     (t
      (when (timerp claude-queue--timer)
        (cancel-timer claude-queue--timer))
      (setq claude-queue--timer nil)))))

(provide 'claude-queue)
;;; claude-queue.el ends here
