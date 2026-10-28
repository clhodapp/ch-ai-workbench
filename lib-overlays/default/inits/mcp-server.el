;; SPDX-License-Identifier: MIT
;;; -*- lexical-binding: t -*-
;; init mcp-server
;;
;; The agent-facing tool set is designed in
;; docs/development/emacs-mcp-agent-tools.md: session-unique answers only
;; (warm LSP, unsaved buffer state, user attention, the editing engine),
;; positions in as 1-based file/line/col, locations out as grep-format
;; lines, results capped with true totals.  Server-side security filters
;; (client-territory write scope, agent elisp confined to a sandboxed
;; child Emacs) extend the
;; consent-gate design (workspace docs/development/consent-gate.md): the
;; MCP server is a side-channel around the CLI's permission machinery,
;; so the filters live here, where every client passes.
(eval-when-compile
  (require 'mcp-server-lib)
  (require 'subr-x)
  (require 'flymake)
  (require 'eglot)
  (require 'xref)
  (require 'project)
  (require 'imenu)
  (require 'which-func)
  (require 'markdown-ts-mode))
;; The compile-time requires above make these known to the byte compiler,
;; but each is loaded lazily at runtime (mode activation, package
;; autoloads, or the explicit requires in the handlers), so declare them
;; to silence the might-not-be-defined-at-runtime escalation.
(declare-function mcp-server-lib-register-server "mcp-server-lib")
(declare-function mcp-server-lib-tool-throw "mcp-server-lib")
(declare-function mcp-server-lib-start "mcp-server-lib-commands")
(declare-function server-running-p "server")
(declare-function string-trim "subr-x")
(declare-function string-empty-p "subr-x")
(declare-function project-root "project")
(declare-function flymake-running-backends "flymake")
(declare-function flymake-diagnostics "flymake")
(declare-function flymake-diagnostic-beg "flymake")
(declare-function flymake-diagnostic-type "flymake")
(declare-function flymake-diagnostic-text "flymake")
(declare-function eglot-current-server "eglot")
(declare-function eglot--TextDocumentPositionParams "eglot")
(declare-function jsonrpc-request "jsonrpc")
(declare-function xref-find-backend "xref")
(declare-function xref-backend-identifier-at-point "xref")
(declare-function xref-backend-references "xref")
(declare-function xref-backend-definitions "xref")
(declare-function xref-item-location "xref")
(declare-function xref-item-summary "xref")
(declare-function xref-location-group "xref")
(declare-function xref-location-line "xref")
(declare-function xref-file-location-p "xref")
(declare-function xref-file-location-column "xref")
(declare-function imenu--make-index-alist "imenu")
(declare-function which-function "which-func")
(declare-function markdown-ts-mode "markdown-ts-mode")
(declare-function collab-comments-find "collab-comments")
(declare-function collab-comments-append "collab-comments")
(declare-function collab-comments-add-thread "collab-comments")
(declare-function collab-comments-render-thread "collab-comments")
(declare-function collab-comments-threads "collab-comments")
(declare-function collab-comments-all-threads "collab-comments")
;; The child's lifecycle loads parenting on first spawn.
(declare-function parenting-spawn "parenting-parent")
(declare-function parenting-eval "parenting-parent")
(declare-function parenting-shutdown "parenting")
(declare-function parenting-connection-live-p "parenting")
(defvar safe-functions)
;; Read by the session-fact tools through `bound-and-true-p' only: evil
;; and ghostel are never required here, so a session without either
;; reports "none".
(defvar evil-state)
(defvar ghostel--input-mode)

(defvar ch-mcp-server-auto-open-scope 'session-projects
  "Scope of files the MCP tools may open into new buffers.
`session-projects' allows only files under a project that already has
file-visiting buffers in this session; `any-project' allows any readable
file.  Files under the calling client's own territory (see
`ch-mcp-server--client-territory') and files already visited by a
buffer are always in scope.")

(defvar ch-mcp-server-write-scope 'client-project
  "Which files the MCP write verbs may touch.
`client-project' (the default) confines `edit-file', `transform', and
`edit-buffer' on file-visiting buffers to the calling client's
territory — the project containing the client session's launch
directory (see `ch-mcp-server--client-territory').
`unrestricted' disables the check.  Set by the resident user only;
gated elisp cannot reach it.")
(put 'ch-mcp-server-write-scope 'risky-local-variable t)

(defvar ch-mcp-server-elisp-scope 'agent-safe
  "Where the MCP elisp-taking tools evaluate.
`agent-safe' (the default): `eval-elisp' and `transform' run in the
sandboxed child Emacs (see \"The child\"), which holds the
configuration and copies of the readable buffers and nothing else of
this session; only text comes back, through the checks of
`ch-mcp-server--land-text'.  `unrestricted' runs both in this Emacs:
the resident user's explicit say-so for a stateful co-driving
session.")
(put 'ch-mcp-server-elisp-scope 'risky-local-variable t)

(defvar ch-mcp-server-hidden-buffer-names '("\\`\\*gptel-log\\*\\'")
  "Regexps for non-file buffer names the MCP read tools must never expose.
The read scope predicate (`ch-mcp-server--buffer-readable-p') hides
a buffer whose name matches any entry here, on top of Emacs's own
convention that a leading space marks an internal buffer.  Seeded with
`*gptel-log*', which logs full prompt/response traffic.  Extended by the
resident user; gated elisp cannot reach it.")
(put 'ch-mcp-server-hidden-buffer-names 'risky-local-variable t)

(defvar ch-mcp-server-debug-leak-knobs
  '((url-debug . nil)
    (auth-source-debug . nil)
    (gptel-log-level . nil)
    (debug-on-error . nil)
    (smtpmail-debug-info . nil)
    (tramp-verbose . 3))
  "Variables that make libraries print secrets, each paired with its off value.
The debug-knob latch (`ch-mcp-server--log-buffer-blocked-p') refuses
the log buffers while any of these is on, since verbose debug output
routinely carries tokens, passwords, and full request bodies.  Off means
`equal' to the listed value for every knob EXCEPT `tramp-verbose', whose
off value is a threshold: a value greater than the listed number counts
as on (tramp escalates verbosity numerically).  Extended by the resident
user; gated elisp cannot reach it.")
(put 'ch-mcp-server-debug-leak-knobs 'risky-local-variable t)

(defvar ch-mcp-server-log-buffer-names
  '("*Messages*" "*Warnings*" "*Backtrace*")
  "Log buffers the debug-knob latch guards.
These accumulate whatever libraries print, so text written while a
`ch-mcp-server-debug-leak-knobs' variable is on is treated as
tainted until it clears.")

(defvar ch-mcp-server-lsp-timeout 5
  "Seconds before a synchronous LSP request degrades to a tool error.
Every LSP call runs inside the interactive session; the timeout keeps a
hung server from freezing both Emacs and the MCP bridge.")

(defvar ch-mcp-server-result-limit 100
  "Default cap on result lines the MCP tools return inline.")

;;; Shared helpers

(defun ch-mcp-server--opt (value)
  "VALUE, with the empty string normalized to nil (an omitted parameter)."
  (and value (not (equal value "")) value))

(defun ch-mcp-server--as-number (value name)
  "VALUE as a number; throw a tool error naming NAME when it is not one."
  (cond ((numberp value) value)
        ((and (stringp value) (string-match-p "\\`[0-9]+\\'" value))
         (string-to-number value))
        (t (mcp-server-lib-tool-throw
            (format "%s must be a positive integer, got %S" name value)))))

(defun ch-mcp-server--capped (lines limit what)
  "Join LINES up to LIMIT, appending the true total of WHAT when truncated."
  (let ((total (length lines))
        (limit (or limit ch-mcp-server-result-limit)))
    (if (<= total limit)
        (mapconcat #'identity lines "\n")
      (concat (mapconcat #'identity (seq-take lines limit) "\n")
              (format "\n... %d more (%d %s total)"
                      (- total limit) total what)))))

(defun ch-mcp-server--session-file-p (file)
  "Whether FILE lies in a project that already has buffers in this session."
  (when-let* ((project (project-current nil (file-name-directory file)))
              (root (expand-file-name (project-root project))))
    (seq-some (lambda (buffer)
                (when-let* ((name (buffer-file-name buffer)))
                  (string-prefix-p root (expand-file-name name))))
              (buffer-list))))

(defun ch-mcp-server--client-territory ()
  "Territory root of the calling MCP client, as a truename directory.
Each request reaches Emacs through emacsclient, which binds
`default-directory' to the stdio bridge process's working directory —
the directory the client session was launched from.  The territory is
that directory's project root (project.el), or the directory itself
outside any project.  Containment under this single root is the whole
check, so a workspace client reaches its submodule checkouts and
`.claude/worktrees/' trees, while a client launched inside a submodule
or worktree checkout is confined to it.  Must be called while
`default-directory' still belongs to the request, before the handler
rebinds the current buffer."
  (let* ((dir (file-truename (expand-file-name default-directory)))
         (project (project-current nil dir)))
    (file-name-as-directory
     (if project
         (file-truename (expand-file-name (project-root project)))
       dir))))

(defun ch-mcp-server--territory-file-p (file)
  "Whether FILE lies inside the calling client's territory."
  (string-prefix-p (ch-mcp-server--client-territory)
                   (file-truename (expand-file-name file))))

(defun ch-mcp-server--check-file-write (file)
  "Throw a tool error when FILE is outside the calling client's territory.
The write-scope filter (`ch-mcp-server-write-scope'): the write
verbs only touch files under the client's own project, mirroring the
CLI-side workdir sandbox the MCP server would otherwise bypass."
  (when (and (eq ch-mcp-server-write-scope 'client-project)
             (not (ch-mcp-server--territory-file-p file)))
    (mcp-server-lib-tool-throw
     (format "%s is outside this session's territory %s (the project of the client's launch directory); MCP writes are confined to it (ch-mcp-server-write-scope)"
             file (ch-mcp-server--client-territory)))))

(defun ch-mcp-server--maybe-revert (buffer)
  "Revert BUFFER when it is unmodified but stale against its file.
Without this, tools reading buffer state quietly lie after files change
on disk (e.g. after the agent's own native edits)."
  (with-current-buffer buffer
    (when (and buffer-file-name
               (not (buffer-modified-p))
               (file-exists-p buffer-file-name)
               (not (verify-visited-file-modtime (current-buffer))))
      (revert-buffer :ignore-auto :noconfirm))))

(defun ch-mcp-server--file-in-scope-p (file)
  "Whether FILE passes the auto-open read scope.
The single rule tying read scope to open scope: any file under
`any-project', else one in the calling client's territory or a session
project.  Applied both when opening an unvisited file
\(`ch-mcp-server--file-buffer') and when deciding whether an
already-visiting buffer may be read (`ch-mcp-server--buffer-readable-p')."
  (or (eq ch-mcp-server-auto-open-scope 'any-project)
      (ch-mcp-server--territory-file-p file)
      (ch-mcp-server--session-file-p file)))

(defun ch-mcp-server--file-buffer (file)
  "Live buffer visiting FILE; stale unmodified buffers are reverted first.
Unvisited files are opened (booting LSP via the usual mode hooks) when
`ch-mcp-server-auto-open-scope' allows it; otherwise this throws."
  (let* ((file (expand-file-name file))
         (buffer (find-buffer-visiting file)))
    (cond
     (buffer
      (ch-mcp-server--maybe-revert buffer)
      buffer)
     ((not (file-readable-p file))
      (mcp-server-lib-tool-throw (format "No readable file %s" file)))
     ((ch-mcp-server--file-in-scope-p file)
      (find-file-noselect file))
     (t
      (mcp-server-lib-tool-throw
       (format "%s is not visited and lies outside the client territory and every session project (auto-open scope: %s)"
               file ch-mcp-server-auto-open-scope))))))

;;; Buffer sensitivity: one per-buffer state, with a default by kind

(defvar ch-mcp-server-buffer-sensitivity nil
  "This buffer's sensitivity to the agent: nil, `sensitive', or `exposed'.
A sensitive buffer is withheld from the agent: the read predicate
\(`ch-mcp-server--buffer-sensitive-p') refuses it before any other test,
so no read tool returns it and it is omitted from listings.

nil means unset, and the default decides
\(`ch-mcp-server--default-sensitive-p'): sensitive for a terminal
\(`ch-mcp-server-terminal-modes') or a buffer visiting a file whose name
matches `ch-mcp-server-sensitive-file-patterns', not for anything else.
`sensitive' and `exposed' are explicit overrides in either direction,
so a terminal or `.env' the user trusts can be exposed and an ordinary
buffer holding a secret can be withheld.  Set by the toggle
\(`ch-mcp-server-toggle-buffer-sensitive') or by
`ch-mcp-server-visit-sensitive'; never by a file-local variable, so a
file being read cannot expose itself.")
(make-variable-buffer-local 'ch-mcp-server-buffer-sensitivity)
;; A file may not set this via a file-local: `null' is the only accepted
;; value, so a file can at most re-assert nil (unset), never set
;; `exposed' on itself.
(put 'ch-mcp-server-buffer-sensitivity 'safe-local-variable #'null)

(defvar ch-mcp-server-terminal-modes
  '(ghostel-mode comint-mode term-mode vterm-mode eshell-mode)
  "Major modes whose buffers are terminals, sensitive by default.
A buffer whose major mode derives from any of these is withheld from
the agent unless its `ch-mcp-server-buffer-sensitivity' is `exposed',
since a terminal's text is whatever ran in it and may include echoed
secrets.
`comint-mode' is the base of `shell-mode' and many REPLs, so matching
by `derived-mode-p' covers those without listing each.  The user runs
terminals in ghostel; the rest are here so a stray `shell'/`term'/
`eshell'/`vterm' is gated the same way rather than left readable.
Extended by the resident user; gated elisp cannot reach it.")
(put 'ch-mcp-server-terminal-modes 'risky-local-variable t)

(defun ch-mcp-server--terminal-p (&optional buffer)
  "Whether BUFFER (default current) is a terminal.
A terminal is a buffer whose major mode derives from one in
`ch-mcp-server-terminal-modes'."
  (with-current-buffer (or buffer (current-buffer))
    (apply #'derived-mode-p ch-mcp-server-terminal-modes)))

(defvar ch-mcp-server-sensitive-file-patterns
  '("/\\.authinfo\\(?:\\.gpg\\)?\\'"
    "\\.gpg\\'"
    "\\.age\\'"
    "/\\.env\\(?:\\.[^/]*\\)?\\'")
  "Regexps for file names whose buffers are sensitive by default.
A buffer visiting a file whose name matches any entry is withheld from
the agent unless its `ch-mcp-server-buffer-sensitivity' is `exposed',
the same way a terminal is; the match is part of the default
\(`ch-mcp-server--default-sensitive-p'), so it needs no hook and holds
however the buffer came to visit the file.
Each regexp is matched against the full file name (so the leading `/'
anchors on a path segment boundary, `\\'' on the end).  Seeds:
`.authinfo' and `.authinfo.gpg', any `.gpg' or `.age' file, and `.env'
and `.env.*'.  Extended by the resident user; gated elisp cannot reach
it.")
(put 'ch-mcp-server-sensitive-file-patterns 'risky-local-variable t)

(defun ch-mcp-server--default-sensitive-p ()
  "Whether the current buffer is sensitive by default.
Sensitive when it is a terminal (`ch-mcp-server-terminal-modes') or
visits a file whose name matches `ch-mcp-server-sensitive-file-patterns';
not otherwise.  This is what an unset
`ch-mcp-server-buffer-sensitivity' falls back to."
  (or (ch-mcp-server--terminal-p)
      (and buffer-file-name
           (seq-some (lambda (re) (string-match-p re buffer-file-name))
                     ch-mcp-server-sensitive-file-patterns)
           t)))

(defun ch-mcp-server--buffer-sensitive-p (buffer)
  "Whether BUFFER must be withheld from the agent as sensitive.
The effective state of `ch-mcp-server-buffer-sensitivity': an explicit
`sensitive' or `exposed' wins; unset falls back to
`ch-mcp-server--default-sensitive-p'."
  (with-current-buffer buffer
    (pcase ch-mcp-server-buffer-sensitivity
      ('sensitive t)
      ('exposed nil)
      (_ (ch-mcp-server--default-sensitive-p)))))

(defun ch-mcp-server-visit-sensitive (filename)
  "Visit FILENAME with its buffer marked sensitive before its content shows.
Like `find-file', but sets `ch-mcp-server-buffer-sensitivity' to
`sensitive' in the resulting buffer, so the buffer is withheld from the
agent the moment it exists, for a file the user knows is sensitive and
no pattern in `ch-mcp-server-sensitive-file-patterns' anticipated."
  (interactive "FVisit sensitive file: ")
  (let ((buffer (find-file filename)))
    (with-current-buffer buffer
      (setq ch-mcp-server-buffer-sensitivity 'sensitive))
    buffer))

(defun ch-mcp-server-toggle-buffer-sensitive ()
  "Toggle this buffer's sensitivity to the agent.
Flips the effective state (`ch-mcp-server--buffer-sensitive-p'): a
withheld buffer becomes `exposed', a readable one becomes `sensitive'.
Works in any buffer; in a terminal, which starts sensitive, the first
press exposes it.  This is the quick per-buffer override of the
defaults."
  (interactive)
  (setq ch-mcp-server-buffer-sensitivity
        (if (ch-mcp-server--buffer-sensitive-p (current-buffer))
            'exposed
          'sensitive))
  (force-mode-line-update)
  (message "Buffer %s the agent"
           (if (eq ch-mcp-server-buffer-sensitivity 'sensitive)
               "withheld from"
             "exposed to")))

;;; Mode-line indicator: can the agent see this buffer?

(defvar ch-mcp-server-mode-line-withheld " agent:hidden"
  "Mode-line text shown in a buffer the agent cannot read.")

(defvar ch-mcp-server-mode-line-visible " agent:visible"
  "Mode-line text shown in a buffer the agent can read.")

(defconst ch-mcp-server--mode-line-construct
  '(:eval (ch-mcp-server--mode-line))
  "Entry added to `global-mode-string' by this init.")

(defun ch-mcp-server--mode-line ()
  "Mode-line fragment for the current buffer's visibility to the agent.
Reflects the two buffer-intrinsic gates: the sensitivity state
\(`ch-mcp-server--buffer-sensitive-p') and the debug-knob latch on the
log buffers (`ch-mcp-server--log-buffer-blocked-p').  The read scope
\(client territory) is a fact about the calling client, so a mode line
cannot show it and it is left out; a buffer marked visible here can
still be refused to a client whose territory excludes its file."
  (let ((buffer (current-buffer)))
    (if (or (ch-mcp-server--buffer-sensitive-p buffer)
            (ch-mcp-server--log-buffer-blocked-p buffer))
        (propertize ch-mcp-server-mode-line-withheld 'face 'warning)
      ch-mcp-server-mode-line-visible)))

(unless global-mode-string
  (setq global-mode-string '("")))
(unless (memq ch-mcp-server--mode-line-construct global-mode-string)
  (setq global-mode-string
        (append global-mode-string
                (list ch-mcp-server--mode-line-construct))))

;; The quick key for the toggle, in the shared `<leader> a' ("ai")
;; prefix that gptel, gptel-agent, and claude-queue each bind their own
;; keys into.  `a t' is free there.
(declare-function ch/leader-prefix-title "evil")
(with-eval-after-load 'evil
  (ch/leader-prefix-title "a" "ai")
  (evil-global-set-key 'motion (kbd "<leader> a t")
                       #'ch-mcp-server-toggle-buffer-sensitive))

;;; Buffer read scope: readability predicate plus the debug-knob latch

(defun ch-mcp-server--buffer-readable-p (buffer)
  "Whether the agent may read BUFFER's contents or see it in a listing.
A sensitive buffer (`ch-mcp-server--buffer-sensitive-p': the
per-buffer mark, or a terminal not explicitly exposed) is never
readable, before any other test.  Otherwise a file-visiting buffer is
readable exactly when its file passes the auto-open read scope
(`ch-mcp-server--file-in-scope-p'), tying read scope to open scope
through one rule.  A buffer without a file is readable unless its name
marks it internal (a leading space, Emacs's own convention, and where
the HTTP response buffers live) or matches
`ch-mcp-server-hidden-buffer-names'."
  (and (not (ch-mcp-server--buffer-sensitive-p buffer))
       (let ((file (buffer-file-name buffer)))
         (if file
             (ch-mcp-server--file-in-scope-p file)
           (let ((name (buffer-name buffer)))
             (not (or (null name)
                      (string-prefix-p " " name)
                      (seq-some (lambda (re) (string-match-p re name))
                                ch-mcp-server-hidden-buffer-names))))))))

;; The debug-knob latch.  Each guarded log buffer carries a taint-start
;; marker: the position of the earliest still-present text written while a
;; leak knob was on, or nil when the buffer holds no tainted text.  A
;; variable watcher on every knob drops the marker when the first knob
;; turns on, whatever else is happening, so the region is recorded even
;; with no sync in progress.  The marker is stored in a module-level hash
;; keyed by buffer name, so a killed-and-reborn buffer starts clean, and
;; it lives in the buffer itself (an insertion marker), so ordinary
;; `message-log-max' rolling, `erase-buffer', and killing all empty the
;; region without the latch doing anything: once the marker reaches
;; `point-max' there is no tainted text left to withhold.

(defvar ch-mcp-server--log-taint (make-hash-table :test 'equal)
  "Hash of log buffer name -> taint-start marker (or nil).
See `ch-mcp-server--log-buffer-blocked-p'.")

(defvar ch-mcp-server--log-watchers-installed nil
  "Non-nil once the debug-knob variable watchers are installed.
Guards `ch-mcp-server--install-log-watchers' against stacking
watchers when this file is re-evaluated.")

(defun ch-mcp-server--knob-value-on-p (knob value)
  "Whether VALUE counts as on for debug leak KNOB (a symbol).
Off is `equal' to the value paired with KNOB in
`ch-mcp-server-debug-leak-knobs', except `tramp-verbose', whose
paired value is a ceiling: a number above it counts as on."
  (let ((off (cdr (assq knob ch-mcp-server-debug-leak-knobs))))
    (if (eq knob 'tramp-verbose)
        (and (numberp value) (numberp off) (> value off))
      (not (equal value off)))))

(defun ch-mcp-server--knob-on-p (knob)
  "Whether debug leak KNOB (a symbol) is currently on, by its live value."
  (and (boundp knob)
       (ch-mcp-server--knob-value-on-p knob (symbol-value knob))))

(defun ch-mcp-server--any-knob-on-p ()
  "Whether any `ch-mcp-server-debug-leak-knobs' variable is on."
  (seq-some (lambda (cell) (ch-mcp-server--knob-on-p (car cell)))
            ch-mcp-server-debug-leak-knobs))

(defun ch-mcp-server--taint-log-buffers ()
  "Record a taint-start marker in each existing log buffer that lacks one.
Called when a knob turns on: the marker sits at `point-max', a
non-inserting marker so appended text lands after it and falls inside the
tainted region."
  (dolist (name ch-mcp-server-log-buffer-names)
    (let ((buffer (get-buffer name)))
      (when (and buffer (not (gethash name ch-mcp-server--log-taint)))
        (with-current-buffer buffer
          (puthash name (copy-marker (point-max) nil)
                   ch-mcp-server--log-taint))))))

(defun ch-mcp-server--log-knob-watcher (symbol newval &rest _)
  "Variable-watcher body: drop taint markers when a knob turns on.
The watcher fires while SYMBOL still holds its old value, so the
transition is read from the incoming NEWVAL for SYMBOL and the live
values for the rest.  When any knob is (about to be) on, ensure every log
buffer has a marker.  Markers are cleared lazily by
`ch-mcp-server--log-buffer-blocked-p' once the tainted text drains,
so the off transition needs no work here."
  (when (or (ch-mcp-server--knob-value-on-p symbol newval)
            (ch-mcp-server--any-knob-on-p))
    (ch-mcp-server--taint-log-buffers)))

(defun ch-mcp-server--install-log-watchers ()
  "Install idempotent variable watchers on the debug leak knobs.
Any existing watcher for a knob is removed first, so re-evaluating this
file never stacks watchers."
  (dolist (cell ch-mcp-server-debug-leak-knobs)
    (let ((knob (car cell)))
      (remove-variable-watcher knob #'ch-mcp-server--log-knob-watcher)
      (add-variable-watcher knob #'ch-mcp-server--log-knob-watcher)))
  (setq ch-mcp-server--log-watchers-installed t))

(defun ch-mcp-server--log-buffer-blocked-p (buffer)
  "The offending knob symbol when BUFFER is a log buffer with tainted text.
Returns nil when BUFFER is not a guarded log buffer, when no knob is on,
or when the tainted region has drained.  The marker is stored at
`point-max' when a knob turns on; text written since then sits after it.
Once the marker has reached `point-max' again (through `message-log-max'
rolling, `erase-buffer', or a kill) the region is empty and cleared, so
the buffer unblocks itself."
  (let* ((name (buffer-name buffer))
         (marker (and (member name ch-mcp-server-log-buffer-names)
                      (gethash name ch-mcp-server--log-taint))))
    (when marker
      (if (and (marker-buffer marker)
               (eq (marker-buffer marker) buffer)
               (< (marker-position marker)
                  (with-current-buffer buffer (point-max))))
          ;; Tainted text remains.  Name the first knob still on; if every
          ;; knob is now off but the region has not drained, keep
          ;; withholding under the first declared knob until it does.
          (or (seq-find #'ch-mcp-server--knob-on-p
                        (mapcar #'car ch-mcp-server-debug-leak-knobs))
              (car (car ch-mcp-server-debug-leak-knobs)))
        ;; Region drained (or marker detached): clear the latch.
        (remhash name ch-mcp-server--log-taint)
        nil))))

(defun ch-mcp-server--buffer-accessible-p (buffer)
  "Whether the agent may read BUFFER: readable in scope AND not latched.
The two gates are independent; a buffer must pass both."
  (and (ch-mcp-server--buffer-readable-p buffer)
       (not (ch-mcp-server--log-buffer-blocked-p buffer))))

(defun ch-mcp-server--buffer-accessible-or-throw (buffer)
  "Throw a tool error unless the agent may read BUFFER; else return BUFFER.
For the by-name resolvers: an out-of-scope or hidden buffer and a
latched log buffer are both refused, each with its own message."
  (when (ch-mcp-server--buffer-sensitive-p buffer)
    (mcp-server-lib-tool-throw
     (format "Buffer %s is withheld as sensitive" (buffer-name buffer))))
  (unless (ch-mcp-server--buffer-readable-p buffer)
    (mcp-server-lib-tool-throw
     (format "Buffer %s is not readable (outside scope)" (buffer-name buffer))))
  (let ((knob (ch-mcp-server--log-buffer-blocked-p buffer)))
    (when knob
      (mcp-server-lib-tool-throw
       (format "Buffer %s withheld: %s is enabled (verbose debug output may contain secrets); clear the buffer to unblock"
               (buffer-name buffer) knob))))
  buffer)

(defun ch-mcp-server--call-at (file line col fn)
  "Call FN with FILE's buffer current and point at LINE:COL (1-based)."
  (let ((line (ch-mcp-server--as-number line "line"))
        (col (ch-mcp-server--as-number col "col")))
    (with-current-buffer (ch-mcp-server--file-buffer file)
      (save-excursion
        (save-restriction
          (widen)
          (let ((last-line (line-number-at-pos (point-max))))
            (when (> line last-line)
              (mcp-server-lib-tool-throw
               (format "Line %d is beyond the end of %s (%d lines)"
                       line file last-line))))
          (goto-char (point-min))
          (forward-line (1- line))
          (move-to-column (max 0 (1- col)))
          (funcall fn))))))

(defun ch-mcp-server--unified-diff (old-file new-file old-label new-label)
  "Unified diff of OLD-FILE against NEW-FILE, labelled OLD-LABEL/NEW-LABEL."
  (with-temp-buffer
    (let ((status (call-process "diff" nil t nil "-u"
                                "--label" old-label "--label" new-label
                                old-file new-file)))
      (cond ((eq status 0) "")
            ((eq status 1) (buffer-string))
            (t (mcp-server-lib-tool-throw
                (format "diff failed (%s): %s" status (buffer-string))))))))

(defun ch-mcp-server--text-diff (old new old-label new-label)
  "Unified diff between the strings OLD and NEW."
  (let ((old-file (make-temp-file "mcp-diff-old"))
        (new-file (make-temp-file "mcp-diff-new")))
    (unwind-protect
        (let ((coding-system-for-write 'utf-8-unix))
          (write-region old nil old-file nil 'silent)
          (write-region new nil new-file nil 'silent)
          (ch-mcp-server--unified-diff
           old-file new-file old-label new-label))
      (delete-file old-file)
      (delete-file new-file))))

;;; Original tools

(defun ch-mcp-server--eval-elisp (elisp)
  "Evaluate ELISP and return the value of the last form, printed with %S.

In the default `agent-safe' scope the forms run in the sandboxed child
Emacs (see `ch-mcp-server--child-eval'): the same configuration as
this session, plain-text copies of the buffers the agent may read
(refreshed first, secrets redacted), and none of this session's
variables, environment, or files, so a stateful form changes only the
child.  Facts about the live session that are not buffer text come
from the named read-only tools.  In `unrestricted' scope the forms
run in this Emacs, ungated.

MCP Parameters:
  elisp - Emacs Lisp source text; multiple forms allowed, evaluated in order"
  (mcp-server-lib-with-error-handling
    (let ((form (car (read-from-string (concat "(progn\n" elisp "\n)")))))
      (if (eq ch-mcp-server-elisp-scope 'unrestricted)
          (format "%S" (eval form t))
        (ch-mcp-server--child-eval form)))))

(defun ch-mcp-server--context ()
  "Summarize the state of the interactive Emacs session.

MCP Parameters:"
  (mcp-server-lib-with-error-handling
    (with-current-buffer (window-buffer (selected-window))
      (require 'which-func)
      (let ((project (project-current))
            (region (when (use-region-p)
                      (buffer-substring-no-properties
                       (region-beginning) (region-end)))))
        (format (concat "buffer: %s\n"
                        "file: %s\n"
                        "project: %s\n"
                        "major-mode: %s\n"
                        "line: %d of %d\n"
                        "defun: %s\n"
                        "modified: %s\n"
                        "visible buffers: %s\n"
                        "%s")
                (buffer-name)
                (or buffer-file-name "none")
                (if project (project-root project) "none")
                major-mode
                (line-number-at-pos (point))
                (line-number-at-pos (point-max))
                (or (ignore-errors (which-function)) "none")
                (if (buffer-modified-p) "yes" "no")
                (mapconcat (lambda (window)
                             (with-current-buffer (window-buffer window)
                               (concat (buffer-name)
                                       (and buffer-file-name
                                            (buffer-modified-p)
                                            " (modified)"))))
                           (window-list)
                           ", ")
                (if region
                    (format "region (%d chars): %s"
                            (length region)
                            (if (> (length region) 2000)
                                (concat (substring region 0 2000) "…")
                              region))
                  "region: none"))))))

(defun ch-mcp-server--list-buffers ()
  "List live buffers, one per line: name | major mode | file.

MCP Parameters:"
  (mcp-server-lib-with-error-handling
    (mapconcat (lambda (buffer)
                 (with-current-buffer buffer
                   (format "%s | %s | %s"
                           (buffer-name)
                           major-mode
                           (or buffer-file-name ""))))
               ;; Omit buffers the agent may not read: out-of-scope files,
               ;; hidden internal buffers, and latched log buffers.
               (seq-filter #'ch-mcp-server--buffer-accessible-p
                           (buffer-list))
               "\n")))

(defun ch-mcp-server--buffer-text (name &optional start-line end-line numbered
                                         approval)
  "Return the text of the buffer named NAME, without properties.

Optionally limited to the 1-based inclusive line range
START-LINE..END-LINE, for paging large buffers.  With NUMBERED, each
line is prefixed with its absolute line number in the buffer, matching
the native Read format of the agent; use it when the answer will feed
line-addressed tools or the user needs line references.  APPROVAL is
filled in by the reveal hook when the user allows a redacted read to
be shown once; see `ch-mcp-server--use-approval'.

MCP Parameters:
  name - name of a live buffer, as listed by the list-buffers tool
  start-line - first line to include (1-based; default 1)
  end-line - last line to include, inclusive (default: end of buffer)
  numbered - yes to prefix each line with its 1-based buffer line number
  approval - leave empty; set only by the user's reveal prompt"
  (mcp-server-lib-with-error-handling
    (ch-mcp-server--use-approval approval)
    (let ((buffer (get-buffer name))
          (start-line (ch-mcp-server--opt start-line))
          (end-line (ch-mcp-server--opt end-line)))
      (unless buffer
        (mcp-server-lib-tool-throw (format "No buffer named %s" name)))
      (ch-mcp-server--buffer-accessible-or-throw buffer)
      (with-current-buffer buffer
        (save-excursion
          (save-restriction
            (widen)
            (let* ((from (if start-line
                             (ch-mcp-server--as-number start-line "start-line")
                           1))
                   (start (progn (goto-char (point-min))
                                 (forward-line (1- from))
                                 (point)))
                   (end (if end-line
                            (progn (goto-char (point-min))
                                   (forward-line
                                    (ch-mcp-server--as-number end-line "end-line"))
                                   (point))
                          (point-max)))
                   (text (buffer-substring-no-properties start end)))
              (if (not (equal numbered "yes"))
                  text
                (let* ((lines (split-string text "\n"))
                       (trailing-newline (and lines (equal (car (last lines)) "")))
                       (lines (if trailing-newline (butlast lines) lines))
                       (line-number (1- from)))
                  (concat (mapconcat (lambda (line)
                                       (setq line-number (1+ line-number))
                                       (format "%6d\t%s" line-number line))
                                     lines "\n")
                          (if trailing-newline "\n" "")))))))))))

;;; Diagnostics

(defun ch-mcp-server--buffer-diagnostic-state (buffer)
  "Diagnostic state of BUFFER as (STATUS . LINES).
STATUS is `checked', `pending' (a check is running or has not run), or a
symbol describing why there are no results (e.g. `no-checker')."
  (with-current-buffer buffer
    (cond
     ((bound-and-true-p flymake-mode)
      (cons (if (flymake-running-backends) 'pending 'checked)
            (save-excursion
              (save-restriction
                (widen)
                (mapcar (lambda (diag)
                          (let ((beg (flymake-diagnostic-beg diag))
                                (type (flymake-diagnostic-type diag)))
                            (goto-char beg)
                            (format "%s:%d:%d: %s: %s"
                                    buffer-file-name
                                    (line-number-at-pos beg t)
                                    (1+ (current-column))
                                    (let ((name (symbol-name type)))
                                      (if (keywordp type) (substring name 1) name))
                                    (flymake-diagnostic-text diag))))
                        (flymake-diagnostics))))))
     (t (cons 'no-checker nil)))))

(defun ch-mcp-server--file-diagnostics (file limit)
  "Diagnostics report for FILE's buffer, capped at LIMIT lines."
  (let* ((state (ch-mcp-server--buffer-diagnostic-state
                 (ch-mcp-server--file-buffer file)))
         (status (car state))
         (lines (cdr state))
         (body (and lines
                    (ch-mcp-server--capped lines limit "diagnostics"))))
    (pcase status
      ('checked (or body "No diagnostics (check finished)"))
      ('pending (concat (or body "No diagnostics yet")
                        "\n(check pending or running — not yet checked; retry shortly)"))
      ('no-checker (format "No checker enabled in the buffer visiting %s" file))
      (other (concat (or body "No diagnostics")
                     (format "\n(checker status: %s)" other))))))

(defun ch-mcp-server--all-diagnostics (limit)
  "Diagnostics report over all file-visiting buffers, capped at LIMIT lines."
  (let ((lines nil) (pending nil) (clean 0) (no-checker 0))
    (dolist (buffer (buffer-list))
      ;; Only file-visiting buffers carry diagnostics, and only those the
      ;; agent could read anyway: an out-of-scope file's path and check
      ;; results are as much a disclosure as its text.
      (when (and (buffer-file-name buffer)
                 (ch-mcp-server--buffer-accessible-p buffer))
        (ch-mcp-server--maybe-revert buffer)
        (let* ((state (ch-mcp-server--buffer-diagnostic-state buffer))
               (status (car state))
               (buffer-lines (cdr state)))
          (setq lines (nconc lines buffer-lines))
          (pcase status
            ('pending (push (buffer-file-name buffer) pending))
            ('checked (unless buffer-lines (setq clean (1+ clean))))
            ('no-checker (setq no-checker (1+ no-checker)))
            (_ nil)))))
    (concat
     (if lines
         (ch-mcp-server--capped lines limit "diagnostics")
       "No diagnostics")
     (format "\n(%d buffers checked clean, %d without a checker)"
             clean no-checker)
     (when pending
       (concat "\nStill checking (results incomplete): "
               (mapconcat #'identity (nreverse pending) ", "))))))

(defun ch-mcp-server--diagnostics (&optional file limit)
  "Current diagnostics as \"path:line:col: severity: message\" lines.

Covers FILE's buffer, or every file-visiting buffer when FILE is
omitted.  Diagnostics reflect buffers: stale unmodified buffers are
reverted first, and buffers whose check is still pending are reported as
such rather than as clean.

MCP Parameters:
  file - absolute path; omit to sweep all file-visiting buffers
  limit - max diagnostic lines returned inline (default 100)"
  (mcp-server-lib-with-error-handling
    (let ((file (ch-mcp-server--opt file))
          (limit (when-let* ((raw (ch-mcp-server--opt limit)))
                   (ch-mcp-server--as-number raw "limit"))))
      (if file
          (ch-mcp-server--file-diagnostics file limit)
        (ch-mcp-server--all-diagnostics limit)))))

;;; Xref-backed navigation

(defun ch-mcp-server--xref-line (item)
  "Render xref ITEM as a grep-format \"path:line:col: summary\" line."
  (let* ((location (xref-item-location item))
         (line (or (xref-location-line location) 0))
         (col (1+ (or (and (xref-file-location-p location)
                           (xref-file-location-column location))
                      0))))
    (format "%s:%d:%d: %s"
            (xref-location-group location)
            line col
            (string-trim (or (xref-item-summary item) "")))))

(defun ch-mcp-server--xref-items (kind file line col)
  "Xref items of KIND (`references' or `definitions') at FILE:LINE:COL."
  (ch-mcp-server--call-at
   file line col
   (lambda ()
     (require 'xref)
     ;; The default (grep-based) references implementation prompts for a
     ;; project when there is none; degrade that to a tool error instead
     ;; of hanging the server on a minibuffer read.
     (let* ((project-prompter
             (lambda (&rest _)
               (mcp-server-lib-tool-throw
                "No project found for the reference search")))
            (backend (xref-find-backend))
            (identifier (xref-backend-identifier-at-point backend)))
       (unless identifier
         (mcp-server-lib-tool-throw
          (format "No identifier at %s:%s:%s (xref backend: %s)"
                  file line col backend)))
       (with-timeout (ch-mcp-server-lsp-timeout
                      (mcp-server-lib-tool-throw
                       (format "%s lookup timed out after %ds"
                               kind ch-mcp-server-lsp-timeout)))
         (if (eq kind 'references)
             (xref-backend-references backend identifier)
           (xref-backend-definitions backend identifier)))))))

(defun ch-mcp-server--find-references (file line col &optional limit)
  "References to the symbol at FILE:LINE:COL, one grep-format line each.

MCP Parameters:
  file - absolute path of the file
  line - 1-based line number of the symbol
  col - 1-based column of the symbol, as in grep line:col output
  limit - max lines returned inline (default 100)"
  (mcp-server-lib-with-error-handling
    (let ((items (ch-mcp-server--xref-items 'references file line col))
          (limit (when-let* ((raw (ch-mcp-server--opt limit)))
                   (ch-mcp-server--as-number raw "limit"))))
      (if (null items)
          "No references found"
        (ch-mcp-server--capped
         (mapcar #'ch-mcp-server--xref-line items)
         limit "references")))))

(defun ch-mcp-server--find-definition (file line col)
  "Definition(s) of the symbol at FILE:LINE:COL, one grep-format line each.

MCP Parameters:
  file - absolute path of the file
  line - 1-based line number of the symbol
  col - 1-based column of the symbol, as in grep line:col output"
  (mcp-server-lib-with-error-handling
    (let ((items (ch-mcp-server--xref-items 'definitions file line col)))
      (if (null items)
          "No definition found"
        (ch-mcp-server--capped
         (mapcar #'ch-mcp-server--xref-line items)
         nil "definitions")))))

;;; LSP hover

(defun ch-mcp-server--hover-string (contents)
  "Flatten LSP hover CONTENTS (MarkupContent, MarkedString, or list)."
  (cond
   ((null contents) "")
   ((stringp contents) contents)
   ((vectorp contents)
    (mapconcat #'ch-mcp-server--hover-string contents "\n"))
   ((plistp contents) (or (plist-get contents :value) ""))
   (t (format "%S" contents))))

(defun ch-mcp-server--symbol-info (file line col)
  "LSP hover (type signature and docs) for the symbol at FILE:LINE:COL.

MCP Parameters:
  file - absolute path of the file
  line - 1-based line number of the symbol
  col - 1-based column of the symbol"
  (mcp-server-lib-with-error-handling
    (ch-mcp-server--call-at
     file line col
     (lambda ()
       (let ((server (and (featurep 'eglot) (eglot-current-server))))
         (unless server
           (mcp-server-lib-tool-throw
            (format "No LSP (eglot) server manages %s" file)))
         (let* ((response (jsonrpc-request
                           server :textDocument/hover
                           (eglot--TextDocumentPositionParams)
                           :timeout ch-mcp-server-lsp-timeout))
                (text (ch-mcp-server--hover-string
                       (and response (plist-get response :contents)))))
           (if (string-empty-p text)
               "No hover information at this position"
             text)))))))

;;; Document outline

(defun ch-mcp-server--outline-lines (items depth)
  "Flatten imenu ITEMS into indented \"line: name\" strings at DEPTH."
  (let ((indent (make-string (* 2 depth) ?\s)))
    (mapcan
     (lambda (item)
       (let ((name (car-safe item))
             (tail (cdr-safe item)))
         (cond
          ((or (not (stringp name)) (equal name "*Rescan*")) nil)
          ((or (markerp tail) (and (numberp tail) (>= tail 0)))
           (list (format "%s%d: %s" indent (line-number-at-pos tail t) name)))
          ((and (consp tail) (number-or-marker-p (car tail)))
           (list (format "%s%d: %s" indent
                         (line-number-at-pos (car tail) t) name)))
          ((and tail (listp tail))
           (cons (format "%s%s:" indent name)
                 (ch-mcp-server--outline-lines tail (1+ depth))))
          (t nil))))
     items)))

(defun ch-mcp-server--document-outline (file)
  "Outline of FILE (imenu / LSP documentSymbol) as a \"line: name\" tree.

MCP Parameters:
  file - absolute path of the file"
  (mcp-server-lib-with-error-handling
    (with-current-buffer (ch-mcp-server--file-buffer file)
      (require 'imenu)
      (let* ((imenu-auto-rescan t)
             (imenu-auto-rescan-maxout most-positive-fixnum)
             (index (save-excursion
                      (condition-case err
                          (imenu--make-index-alist t)
                        (error (mcp-server-lib-tool-throw
                                (format "No outline for %s: %s" file
                                        (error-message-string err)))))))
             (lines (ch-mcp-server--outline-lines index 0)))
        (if lines
            (ch-mcp-server--capped lines nil "entries")
          (format "No outline entries in %s" file))))))

;;; Unsaved buffer state

(defun ch-mcp-server--modified-buffers ()
  "File-visiting buffers whose content differs from disk, one path per line.

MCP Parameters:"
  (mcp-server-lib-with-error-handling
    (let (files)
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          ;; A modified out-of-scope file's path is a disclosure like its
          ;; text; only report buffers the agent could read.
          (when (and buffer-file-name (buffer-modified-p)
                     (ch-mcp-server--buffer-accessible-p buffer))
            (push buffer-file-name files))))
      (if files
          (mapconcat #'identity (nreverse files) "\n")
        "No file-visiting buffers have unsaved changes"))))

(defun ch-mcp-server--buffer-diff (file &optional approval)
  "Unified diff of FILE's unsaved buffer state against the file on disk.
APPROVAL is as for `ch-mcp-server--buffer-text'.

MCP Parameters:
  file - absolute path of a file visited by some buffer
  approval - leave empty; set only by the user's reveal prompt"
  (mcp-server-lib-with-error-handling
    (ch-mcp-server--use-approval approval)
    (let* ((file (expand-file-name file))
           (buffer (find-buffer-visiting file)))
      (unless buffer
        (mcp-server-lib-tool-throw (format "No buffer is visiting %s" file)))
      (with-current-buffer buffer
        (if (not (buffer-modified-p))
            "Buffer matches disk (no unsaved changes)"
          (let ((temp (make-temp-file "mcp-buffer-state")))
            (unwind-protect
                (progn
                  (save-restriction
                    (widen)
                    (write-region (point-min) (point-max) temp nil 'silent))
                  (let ((diff (ch-mcp-server--unified-diff
                               file temp
                               (concat file " (disk)")
                               (concat file " (buffer)"))))
                    (if (string-empty-p diff)
                        "Buffer matches disk (no unsaved changes)"
                      diff)))
              (delete-file temp))))))))

;;; Session facts

;; Facts about the live session that are not buffer text (whether a
;; feature is loaded, what sits on a hook, a buffer's mode and state,
;; what a key resolves to), each answered by a small named read-only
;; tool (docs/development/agent-elisp-isolation.md, "What runs where").
;; The tools return facts, never arbitrary variable values: reading an
;; arbitrary global is the confidentiality hole an open evaluator opens.
;; Anything that names a buffer passes the same read scope as the text
;; tools, so a withheld buffer is refused here as everywhere else.

(defun ch-mcp-server--yes-no (value)
  "\"yes\" when VALUE is non-nil, else \"no\"."
  (if value "yes" "no"))

(defun ch-mcp-server--named-buffer (name)
  "The live buffer called NAME the agent may read, or a tool error.
The by-name resolver the session-fact tools share: the missing-buffer
message the text tools use, then `ch-mcp-server--buffer-accessible-or-throw'."
  (ch-mcp-server--buffer-accessible-or-throw
   (or (get-buffer name)
       (mcp-server-lib-tool-throw (format "No buffer named %s" name)))))

(defun ch-mcp-server--function-label (function)
  "FUNCTION as a printable name: a symbol's name, else <lambda>.
An anonymous function may close over data, so its body is never
printed; the special hook value t is rendered as its meaning."
  (cond ((eq function t) "t (run the global hook too)")
        ((symbolp function) (symbol-name function))
        (t "<lambda>")))

(defun ch-mcp-server--hook-functions (value)
  "The functions in hook VALUE as a list.
A hook variable may hold a single function instead of a list."
  (cond ((null value) nil)
        ((functionp value) (list value))
        ((listp value) value)
        (t (list value))))

(defun ch-mcp-server--feature-loaded (feature)
  "Whether FEATURE is loaded, and whether its symbol is fboundp or boundp.

A session fact the agent cannot get by reading buffer text: `featurep'
on FEATURE, plus `fboundp' and `boundp' on the same symbol for
convenience.  Only the three facts are returned, never the value of a
variable.

MCP Parameters:
  feature - a feature or library name, e.g. ch-evil-ghostel"
  (mcp-server-lib-with-error-handling
    (let ((symbol (intern-soft (string-trim feature))))
      (format "feature: %s\nloaded: %s\nfboundp: %s\nboundp: %s"
              (string-trim feature)
              (ch-mcp-server--yes-no (and symbol (featurep symbol)))
              (ch-mcp-server--yes-no (and symbol (fboundp symbol)))
              (ch-mcp-server--yes-no (and symbol (boundp symbol)))))))

(defun ch-mcp-server--hooks (hook &optional buffer)
  "The functions on HOOK: its global value, and the local value in BUFFER.

Each function is printed by name; an anonymous function prints as
<lambda> (its body may close over data).  In the local value, t means
the global hook runs too and is shown as a line saying so.  Refuses a
symbol that is not a bound variable, and a BUFFER the agent may not
read.

MCP Parameters:
  hook - a hook variable name, e.g. find-file-hook
  buffer - name of a live buffer whose local value to show as well"
  (mcp-server-lib-with-error-handling
    (let* ((name (string-trim hook))
           (symbol (intern-soft name))
           (buffer-name (ch-mcp-server--opt buffer))
           (target (and buffer-name
                        (ch-mcp-server--named-buffer buffer-name))))
      (unless (and symbol (boundp symbol))
        (mcp-server-lib-tool-throw
         (format "%s is not a bound variable" name)))
      (let ((global (ch-mcp-server--hook-functions (default-value symbol)))
            (local (and target
                        (local-variable-p symbol target)
                        (ch-mcp-server--hook-functions
                         (buffer-local-value symbol target))))
            (lines nil))
        (push (format "hook: %s" name) lines)
        (if global
            (dolist (function global)
              (push (format "global: %s" (ch-mcp-server--function-label function))
                    lines))
          (push "global: (none)" lines))
        (when target
          (push (format "buffer: %s" (buffer-name target)) lines)
          (cond
           ((not (local-variable-p symbol target))
            (push "local: (no buffer-local value)" lines))
           ((null local)
            (push "local: (none)" lines))
           (t
            (dolist (function local)
              (push (format "local: %s" (ch-mcp-server--function-label function))
                    lines)))))
        (ch-mcp-server--capped (nreverse lines) nil "lines")))))

(defvar ch-mcp-server-minor-mode-limit 40
  "How many enabled minor modes `buffer-state' lists before truncating.")

(defun ch-mcp-server--buffer-state (buffer)
  "Non-text facts about the live buffer named BUFFER, one per line.

File, major mode, enabled minor modes, read-only and modified flags,
size, point as line:col (1-based, as the position tools report), the
evil state, a terminal's input mode, the sensitivity mark, and whether
the agent may see the buffer.  Refuses a buffer the agent may not
read, so a withheld buffer yields no facts.

MCP Parameters:
  buffer - name of a live buffer, as listed by the list-buffers tool"
  (mcp-server-lib-with-error-handling
    (let ((target (ch-mcp-server--named-buffer buffer)))
      (with-current-buffer target
        (let* ((modes (seq-filter (lambda (mode)
                                    (and (boundp mode) (symbol-value mode)))
                                  minor-mode-list))
               (total (length modes))
               (limit ch-mcp-server-minor-mode-limit)
               (shown (mapconcat #'symbol-name (seq-take modes limit) " ")))
          (format (concat "buffer: %s\n"
                          "file: %s\n"
                          "major-mode: %s\n"
                          "minor-modes: %s\n"
                          "read-only: %s\n"
                          "modified: %s\n"
                          "size: %d\n"
                          "point: %d:%d\n"
                          "evil-state: %s\n"
                          "input-mode: %s\n"
                          "sensitivity: %s\n"
                          "agent-visible: %s")
                  (buffer-name)
                  (or buffer-file-name "none")
                  major-mode
                  (if (> total limit)
                      (format "%s ... %d more (%d total)"
                              shown (- total limit) total)
                    shown)
                  (ch-mcp-server--yes-no buffer-read-only)
                  (ch-mcp-server--yes-no (buffer-modified-p))
                  (buffer-size)
                  (line-number-at-pos (point))
                  (1+ (current-column))
                  (or (bound-and-true-p evil-state) "none")
                  (or (bound-and-true-p ghostel--input-mode) "none")
                  (or ch-mcp-server-buffer-sensitivity "unset")
                  (ch-mcp-server--yes-no
                   (ch-mcp-server--buffer-accessible-p target))))))))

(defun ch-mcp-server--binding-label (binding)
  "BINDING, the result of `key-binding', as a printable line.
A command symbol prints by name, a prefix as <keymap (prefix)>, an
anonymous command as <lambda>, a keyboard macro as <macro>, and
nothing (or a key sequence longer than any binding) as unbound."
  (cond ((or (null binding) (numberp binding)) "unbound")
        ((keymapp binding) "<keymap (prefix)>")
        ((symbolp binding) (symbol-name binding))
        ((or (stringp binding) (vectorp binding)) "<macro>")
        ((functionp binding) "<lambda>")
        (t (format "<%s>" (type-of binding)))))

(defun ch-mcp-server--key-binding (keys &optional buffer)
  "What KEYS resolve to in BUFFER (default: the buffer in the selected window).

The live answer, with every active keymap in that buffer's context
\(major and minor modes, evil's state maps): a command symbol, <keymap
\(prefix)> for a prefix, <lambda> for an anonymous command, or unbound.
Under evil the leader is SPC in motion state, so write a leader
binding as SPC p p, not <leader> p p.  Refuses a named BUFFER the
agent may not read.

MCP Parameters:
  keys - a key description as kbd reads it, e.g. SPC p p or C-c C-t
  buffer - name of a live buffer to resolve in (default: the buffer in
      the selected window)"
  (mcp-server-lib-with-error-handling
    (let* ((buffer-name (ch-mcp-server--opt buffer))
           (target (if buffer-name
                       (ch-mcp-server--named-buffer buffer-name)
                     (window-buffer (selected-window))))
           (key (condition-case err
                    (kbd keys)
                  (error (mcp-server-lib-tool-throw
                          (format "Cannot read key description %S: %s"
                                  keys (error-message-string err)))))))
      (with-current-buffer target
        ;; Built newest-first and reversed at the end.
        (let ((lines (list (format "buffer: %s" (buffer-name))
                           (format "keys: %s" (key-description key)))))
          (when (featurep 'evil)
            (push (format "evil-state: %s"
                          (or (bound-and-true-p evil-state) "none"))
                  lines))
          (push (format "binding: %s"
                        (ch-mcp-server--binding-label (key-binding key)))
                lines)
          (mapconcat #'identity (nreverse lines) "\n"))))))

;;; Agent buffer history

;; `present' and `sidebar' write into a buffer named for a slug and
;; erase whatever was there.  Two things are lost that way: a
;; presentation superseded under the same name, and every presentation
;; at all when the Emacs daemon rotates.  Each write is therefore
;; appended to a store on disk as a timestamped revision, and
;; `ch-mcp-server-history' reads them back.  The store is the record;
;; the live buffer is a view of its newest revision.

(defcustom ch-mcp-server-history-file
  (expand-file-name "Emacs/agent-buffer-history.eld"
                    (or (getenv "XDG_DATA_HOME")
                        (expand-file-name "~/.local/share")))
  "File holding the revision history of agent presentation buffers.
Data rather than configuration, so it follows the other persisted
state (savehist, save-place) under XDG_DATA_HOME instead of the user
Emacs directory."
  :type 'file
  :group 'ch-emacs-config)

(defcustom ch-mcp-server-history-limit 200
  "Number of revisions kept in `ch-mcp-server-history-file'.
Oldest revisions past this count are dropped on the next write.  The
cap is global rather than per name: a session that presents one buffer
fifty times should not push out fifty other buffers' history."
  :type 'integer
  :group 'ch-emacs-config)

(defcustom ch-mcp-server-history-max-bytes 1000000
  "Largest revision body stored, in bytes.
Bodies over this size are stored truncated, with a marker line, so one
oversized presentation cannot make the store unreadable.  The limit sits
above the documents actually presented, a long design document running
to a few hundred kilobytes, and below a mermaid render gone wrong, which
is an SVG that can reach megabytes."
  :type 'integer
  :group 'ch-emacs-config)

(defvar ch-mcp-server--history nil
  "Cached revision list, newest first, or nil when not yet loaded.
Each element is a plist: :name buffer name, :time an Emacs time value,
:mode the presentation mode string, :content the body.")

(defvar ch-mcp-server--history-loaded nil
  "Whether `ch-mcp-server--history' reflects the file on disk.")

(defun ch-mcp-server--history-load ()
  "Return the revision list, reading the store on first use."
  (unless ch-mcp-server--history-loaded
    (setq ch-mcp-server--history
          (when (file-readable-p ch-mcp-server-history-file)
            ;; A truncated or hand-edited store must not break
            ;; presenting; an unreadable file starts an empty history.
            (ignore-errors
              (with-temp-buffer
                (insert-file-contents ch-mcp-server-history-file)
                (goto-char (point-min))
                (read (current-buffer)))))
          ch-mcp-server--history-loaded t))
  ch-mcp-server--history)

(defun ch-mcp-server--history-record (name content mode)
  "Append a revision of buffer NAME holding CONTENT in MODE to the store.
Returns nil.  Every failure is swallowed: history is a convenience, and
a full disk must not turn a presentation into a tool error."
  (ignore-errors
    (let* ((body (if (> (string-bytes content) ch-mcp-server-history-max-bytes)
                     ;; Cut on the byte count the limit is expressed in,
                     ;; then decode back, discarding a multibyte
                     ;; character the cut landed inside.
                     (concat (decode-coding-string
                              (substring (encode-coding-string content 'utf-8)
                                         0 ch-mcp-server-history-max-bytes)
                              'utf-8 t)
                             "\n\n[truncated by ch-mcp-server-history-max-bytes]")
                   content))
           (revision (list :name name
                           :time (current-time)
                           :mode mode
                           :content body))
           (history (cons revision (ch-mcp-server--history-load))))
      (setq ch-mcp-server--history
            (seq-take history ch-mcp-server-history-limit))
      (make-directory (file-name-directory ch-mcp-server-history-file) t)
      (with-temp-file ch-mcp-server-history-file
        (let ((print-length nil)
              (print-level nil))
          (prin1 ch-mcp-server--history (current-buffer))))))
  nil)

(defun ch-mcp-server--history-label (revision)
  "A completing-read line for REVISION: time, buffer name, first line."
  (let* ((content (or (plist-get revision :content) ""))
         (first-line (car (split-string content "\n")))
         (summary (string-trim (or first-line ""))))
    (format "%s  %-28s  %s"
            (format-time-string "%Y-%m-%d %H:%M" (plist-get revision :time))
            (or (plist-get revision :name) "?")
            (truncate-string-to-width summary 60))))

(defun ch-mcp-server-history ()
  "Pick a stored agent presentation revision and show it read-only.
Candidates are every revision in `ch-mcp-server-history-file', newest
first, labelled with the time, the buffer name, and the first line of
the body.  The chosen revision opens in its own buffer rather than the
live *agent/...* one, so reviewing history never overwrites what an
agent last presented."
  (interactive)
  (setq ch-mcp-server--history-loaded nil)
  (let ((history (ch-mcp-server--history-load)))
    (unless history
      (user-error "No agent presentation history in %s"
                  ch-mcp-server-history-file))
    (let* (;; Two revisions of one buffer written in the same minute
           ;; with the same first line label identically, and `assoc'
           ;; would then reach only the newer.  The index makes every
           ;; candidate distinct without being what the eye reads.
           (index 0)
           (candidates
            (mapcar (lambda (revision)
                      (setq index (1+ index))
                      (cons (format "%s  #%d"
                                    (ch-mcp-server--history-label revision)
                                    index)
                            revision))
                    history))
           ;; The labels lead with a timestamp and the list is already
           ;; newest first; keep that order rather than letting
           ;; completion sort it alphabetically.
           (completion-table
            (lambda (string predicate action)
              (if (eq action 'metadata)
                  '(metadata (display-sort-function . identity)
                             (cycle-sort-function . identity))
                (complete-with-action action candidates string predicate))))
           (choice (completing-read "Agent revision: " completion-table nil t))
           (revision (cdr (assoc choice candidates)))
           (buffer (get-buffer-create
                    (format "*agent-history/%s*"
                            (plist-get revision :name)))))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (or (plist-get revision :content) "")))
        (if (equal (plist-get revision :mode) "diff")
            (ch-mcp-server--set-major-mode #'diff-mode)
          (ch-mcp-server--set-major-mode #'markdown-ts-mode)
          (visual-line-mode 1))
        (setq buffer-read-only t)
        (set-buffer-modified-p nil)
        (goto-char (point-min)))
      (pop-to-buffer buffer))))

;; `<leader> a' is the ai prefix the gptel and claude-queue bundles also
;; bind under; h for history.  Motion state covers visual state too.
(declare-function evil-global-set-key "evil-core")
(with-eval-after-load 'evil
  (evil-global-set-key 'motion (kbd "<leader> a h") #'ch-mcp-server-history))

;;; Presenting to the user

(defvar ch-mcp-server-mermaid-timeout 30
  "Seconds before a mermaid render is killed and reported as a tool error.
A hung renderer must not freeze the interactive session.")

(defvar ch-mcp-server-mermaid-command '("mmdc")
  "Command list prefix for an mmdc-compatible mermaid renderer.
Input, output, and rendering flags are appended.  The home-manager
module points this at the nix-installed merman (the same drv the
language-server table spawns); the bare-name default only works when
an mmdc is on PATH.")

(defvar ch-mcp-server-betterleaks-command '("betterleaks")
  "Command list prefix for running betterleaks.
The copies sent to the child are run through it, with the subcommand
and flags appended.  The
home-manager module points this at the nix-installed betterleaks from the
pinned nixpkgs, so the rule set moves with the pin; the bare-name
default only works when a betterleaks is on PATH.")

(defun ch-mcp-server--render-mermaid (source)
  "Render mermaid SOURCE to an SVG data string via the mmdc CLI.
The theme follows the selected frame's background mode.  Render errors
carry the renderer's own message, so the agent can fix the diagram
source from the tool error alone."
  (unless (executable-find (car ch-mcp-server-mermaid-command))
    (mcp-server-lib-tool-throw
     (format "%s (mmdc-compatible mermaid renderer) not found on PATH; cannot render mermaid"
             (car ch-mcp-server-mermaid-command))))
  (let* ((dark (eq (frame-parameter nil 'background-mode) 'dark))
         (in (make-temp-file "mcp-mermaid" nil ".mmd" source))
         (out (make-temp-file "mcp-mermaid" nil ".svg"))
         ;; Mermaid's default HTML labels come out as SVG <foreignObject>
         ;; elements, which librsvg (Emacs's SVG renderer) silently drops —
         ;; a diagram with invisible labels. htmlLabels=false makes it emit
         ;; native <text> instead (both keys needed: top-level covers edge
         ;; labels, flowchart covers node labels).
         (config (make-temp-file
                  "mcp-mermaid" nil ".json"
                  "{\"htmlLabels\": false, \"flowchart\": {\"htmlLabels\": false}}"))
         (log (generate-new-buffer " *mcp-mermaid*")))
    (unwind-protect
        (let ((process (make-process
                        :name "mcp-mermaid"
                        :command (append ch-mcp-server-mermaid-command
                                         (list "-i" in "-o" out "-q"
                                               "-c" config
                                               "-t" (if dark "dark" "default")
                                               "-b" (if dark "transparent" "white")))
                        :buffer log
                        :stderr log
                        :noquery t))
              (deadline (+ (float-time) ch-mcp-server-mermaid-timeout)))
          (while (and (process-live-p process) (< (float-time) deadline))
            (accept-process-output process 0.2))
          (when (process-live-p process)
            (delete-process process)
            (mcp-server-lib-tool-throw
             (format "mermaid render timed out after %ds"
                     ch-mcp-server-mermaid-timeout)))
          (unless (eq (process-exit-status process) 0)
            (mcp-server-lib-tool-throw
             (format "mermaid render failed:\n%s"
                     (with-current-buffer log (string-trim (buffer-string))))))
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally out)
            (buffer-string)))
      (kill-buffer log)
      (delete-file in)
      (delete-file config)
      (when (file-exists-p out) (delete-file out)))))

(defun ch-mcp-server--set-major-mode (mode)
  "Put the current buffer in major MODE unless it is already in it.
Re-invoking the major mode a buffer already has is not a no-op: the
mode function runs `change-major-mode-hook', and a mode that keeps
overlays of its own cleans up on that hook with `remove-overlays',
which deletes every other overlay in the buffer as well, including
collab-comments threads.  Emacs 31's `markdown-ts-mode' does exactly
this, so a viewer that re-renders under a stable name must leave a
mode it has already set alone."
  (unless (eq major-mode mode)
    (funcall mode)))

(defun ch-mcp-server--present (name content &optional mode display)
  "Show CONTENT to the user in the buffer *agent/NAME*.

The buffer is (re)written and displayed without stealing focus, so
`display-buffer-alist' governs placement.  Intended pattern: before
asking the user a non-trivial question, present the full context here
and ask with terse labels referencing it.  In mermaid mode CONTENT is
mermaid source, rendered and shown as an image (raw SVG text on a
display that cannot render images); rendering happens before the buffer
is touched, so a failed render never wipes an existing presentation.

MCP Parameters:
  name - short slug; the buffer is named *agent/<name>*
  content - the text to present (mermaid source in mermaid mode)
  mode - markdown (default), diff, locations (clickable path:line:col
      lines), or mermaid (rendered diagram)
  display - no to write the buffer without raising a window"
  (mcp-server-lib-with-error-handling
    (let ((mode (or (ch-mcp-server--opt mode) "markdown")))
      (unless (member mode '("markdown" "diff" "locations" "mermaid"))
        (mcp-server-lib-tool-throw
         (format "Unknown mode %s (expected markdown, diff, locations, or mermaid)"
                 mode)))
      (let ((svg (and (equal mode "mermaid")
                      (ch-mcp-server--render-mermaid content)))
            (buffer (get-buffer-create (format "*agent/%s*" name))))
        (when (buffer-file-name buffer)
          (mcp-server-lib-tool-throw
           (format "%s visits %s; present only writes *agent/...* scratch buffers"
                   (buffer-name buffer) (buffer-file-name buffer))))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (if svg
                (if (image-type-available-p 'svg)
                    (insert-image (create-image svg 'svg t) " ")
                  (insert svg))
              (insert content)))
          (pcase mode
            ;; Presented prose is written as long lines and read in
            ;; whatever window width the user has; soft-wrap it.  The
            ;; other modes carry line-structured content (hunks,
            ;; file:line hits, an image) and keep hard lines.
            ("markdown"
             (ch-mcp-server--set-major-mode #'markdown-ts-mode)
             (visual-line-mode 1))
            ("diff" (ch-mcp-server--set-major-mode #'diff-mode))
            ("locations"
             (ch-mcp-server--set-major-mode #'fundamental-mode)
             (compilation-minor-mode 1))
            ("mermaid"
             (ch-mcp-server--set-major-mode #'fundamental-mode)))
          (set-buffer-modified-p nil)
          (goto-char (point-min)))
        ;; Store the mermaid source rather than the rendered SVG: the
        ;; source is what a later reader can re-render or edit, and an
        ;; SVG blob would blow past the body size cap for no gain.
        (ch-mcp-server--history-record (buffer-name buffer) content mode)
        (if (equal display "no")
            (format "Wrote %s (not displayed)" (buffer-name buffer))
          (display-buffer buffer)
          (format "Presented %s" (buffer-name buffer)))))))

;;; Sidebars

(defcustom ch-mcp-server-sidebar-width 0.2
  "Width of an agent sidebar window as a fraction of the frame."
  :type 'number
  :group 'ch-emacs-config)

(defun ch-emacs-config-sidebar-quit ()
  "Close the sidebar window and kill its buffer, like a help viewer."
  (interactive)
  (quit-window t))

(defvar ch-emacs-config-sidebar-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'ch-emacs-config-sidebar-quit)
    map)
  "Keymap for `ch-emacs-config-sidebar-mode'.")

(define-minor-mode ch-emacs-config-sidebar-mode
  "Minor mode for agent sidebars: read-only, and `q' closes and kills.
A sidebar exists to be read once beside the main reply, so leaving it
disposes of it; re-running the tool under the same name recreates it."
  :lighter " Sidebar"
  :keymap ch-emacs-config-sidebar-mode-map
  (setq buffer-read-only ch-emacs-config-sidebar-mode))

;; Under evil, `q' in normal state records a macro; the minor-mode
;; binding below takes precedence in sidebar buffers.  The quoted mode
;; symbol makes `evil-define-key' expand to the minor-mode variant,
;; which the byte-compiler cannot see through `with-eval-after-load'.
(declare-function evil-define-minor-mode-key "evil-core")
(with-eval-after-load 'evil
  (evil-define-key 'normal 'ch-emacs-config-sidebar-mode
    (kbd "q") #'ch-emacs-config-sidebar-quit))

(defun ch-mcp-server--sidebar (name content &optional display)
  "Show CONTENT beside the user's work in a right-hand sidebar window.

A sidebar is for material the user reads once alongside the main
reply — anticipated questions with answers, a glossary, a checklist —
not for an artifact they will keep open (use `present' for that).  The
buffer *agent/sidebar/NAME* holds CONTENT as soft-wrapped, read-only
markdown and is shown in a side window on the frame's right edge at
`ch-mcp-server-sidebar-width' of the frame width; `q' in it closes
the window and kills the buffer, like a help viewer.  Write paragraphs
as single long lines: hard wraps reflow raggedly under soft wrap.

MCP Parameters:
  name - short slug; the buffer is named *agent/sidebar/<name>*
  content - markdown text
  display - no to write the buffer without showing it"
  (mcp-server-lib-with-error-handling
    (let ((buffer (get-buffer-create (format "*agent/sidebar/%s*" name))))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert content))
        (ch-mcp-server--set-major-mode #'markdown-ts-mode)
        (visual-line-mode 1)
        (ch-emacs-config-sidebar-mode 1)
        (set-buffer-modified-p nil)
        (goto-char (point-min)))
      (ch-mcp-server--history-record (buffer-name buffer) content "markdown")
      (if (equal display "no")
          (format "Wrote %s (not displayed)" (buffer-name buffer))
        (display-buffer buffer
                        `((display-buffer-in-side-window)
                          (side . right)
                          (slot . 0)
                          (window-width . ,ch-mcp-server-sidebar-width)))
        (format "Presented %s in a sidebar" (buffer-name buffer))))))

;;; The editing engine

(defun ch-mcp-server--transform (file elisp &optional save)
  "Run ELISP against FILE's text; land the result; return a unified diff.

For bulk/structural edits where one form beats many single edits:
computed replacements, sexp-aware transforms, mode-canonical
`indent-region'.  FILE must lie in the calling client's territory
(`ch-mcp-server--check-file-write'), and its buffer must hold no
unsaved user modifications.  In the default `agent-safe' scope the
form runs in the sandboxed child against the buffer's copy, with the
copy current, and any elisp is allowed there; only the copy's text
comes back, and it lands through `ch-mcp-server--land-text'.  In
`unrestricted' scope the form runs in this Emacs, in the buffer
itself.  Begin with (goto-char (point-min)): point is wherever the
last form left it.  An error in the form changes nothing.  Saves
unless SAVE is no.

MCP Parameters:
  file - absolute path of the file to transform
  elisp - elisp source run with the buffer current; edits the buffer
      directly via buffer functions
  save - no to leave the change unsaved in the buffer (default: save)"
  (mcp-server-lib-with-error-handling
    (ch-mcp-server--check-file-write file)
    (let ((form (car (read-from-string (concat "(progn\n" elisp "\n)"))))
          (buffer (ch-mcp-server--file-buffer file)))
      (when (buffer-modified-p buffer)
        (mcp-server-lib-tool-throw
         (format "%s has unsaved modifications; refusing to transform (see buffer-diff)"
                 file)))
      (if (eq ch-mcp-server-elisp-scope 'unrestricted)
          (ch-mcp-server--transform-here buffer file form save)
        (ch-mcp-server--transform-in-child buffer file form save)))))

(defun ch-mcp-server--transform-here (buffer file form save)
  "Run FORM in BUFFER, visiting FILE, here; diff, then save unless SAVE is no.
The `unrestricted' path of `ch-mcp-server--transform'.  On error the
buffer is restored untouched."
  (with-current-buffer buffer
    (save-excursion
      (save-restriction
        (widen)
        (let ((old (buffer-substring-no-properties (point-min) (point-max))))
          (condition-case err
              (eval form t)
            (error
             (delete-region (point-min) (point-max))
             (insert old)
             (set-buffer-modified-p nil)
             (mcp-server-lib-tool-throw
              (format "transform failed (buffer restored): %s"
                      (error-message-string err)))))
          (widen)
          (let ((new (buffer-substring-no-properties (point-min) (point-max))))
            (if (equal old new)
                (progn (set-buffer-modified-p nil)
                       "No changes")
              (let ((diff (ch-mcp-server--text-diff
                           old new
                           (concat file " (before)")
                           (concat file " (after)"))))
                (unless (equal save "no")
                  (save-buffer))
                diff))))))))

;; Defined with the child, further down; the transform reads it here.
(defvar ch-mcp-server--copies)

(defun ch-mcp-server--transform-in-child (buffer file form save)
  "Run FORM in the child against BUFFER's copy and land the text here.
The `agent-safe' path of `ch-mcp-server--transform': the copies are
refreshed, FORM runs with the copy current, and the copy's text comes
back to `ch-mcp-server--land-text' with the tick the copy was taken
at and the redacted spans to put back.  A buffer with no copy
(withheld from the agent) is refused.  The copy is re-sent on the next
refresh whatever happened, since FORM may have changed it."
  (let* ((name (buffer-name buffer))
         (conn (ch-mcp-server--child-connection)))
    (ch-mcp-server--copies-sync conn)
    (let ((entry (gethash name ch-mcp-server--copies)))
      (unless entry
        (mcp-server-lib-tool-throw
         (format "%s is withheld from the agent, so it cannot be transformed"
                 file)))
      (let ((tick (plist-get entry :tick))
            (new (unwind-protect
                     (ch-mcp-server--in-child
                      conn
                      `(with-current-buffer ,name
                         (save-restriction
                           (widen)
                           ,form
                           (widen)
                           (buffer-substring-no-properties (point-min)
                                                           (point-max)))))
                   (remhash name ch-mcp-server--copies))))
        (unless (stringp new)
          (mcp-server-lib-tool-throw "transform: the child returned no text"))
        (ch-mcp-server--land-text buffer file new tick save
                                  (plist-get entry :spans))))))

(defun ch-mcp-server--land-text (buffer file new tick save &optional spans)
  "Put NEW into BUFFER, visiting FILE, if its text is still the one at TICK.
The back contract: text from the child lands only in a buffer that is
not read-only and whose `buffer-chars-modified-tick' still equals
TICK, the tick its copy was taken at, so a change made meanwhile is
never overwritten.  SPANS, when non-nil, are the redacted spans of the
copy NEW came from (`ch-mcp-server--redact-spans'); their originals
are put back in place of the placeholders here, in the parent, before
anything touches the buffer, so the buffer never receives a
placeholder.  Returns a unified diff, or \"No changes\"; saves unless
SAVE is no.  The replacement keeps point and markers where the
unchanged text allows."
  (when spans
    (setq new (ch-mcp-server--splice-spans new spans)))
  (with-current-buffer buffer
    (when buffer-read-only
      (mcp-server-lib-tool-throw (format "%s is read-only" file)))
    (unless (eql tick (buffer-chars-modified-tick))
      (mcp-server-lib-tool-throw
       (format "%s changed while the form ran; nothing landed, run the transform again"
               file)))
    (save-restriction
      (widen)
      (let ((old (buffer-substring-no-properties (point-min) (point-max))))
        (if (equal old new)
            "No changes"
          (replace-region-contents (point-min) (point-max) (lambda () new))
          (let ((diff (ch-mcp-server--text-diff
                       old new
                       (concat file " (before)")
                       (concat file " (after)"))))
            (unless (equal save "no")
              (save-buffer))
            diff))))))

(defun ch-mcp-server--replace-literal (label old-string new-string replace-all)
  "Replace OLD-STRING with NEW-STRING in the current buffer; diff back.
The engine shared by the edit verbs: OLD-STRING is matched literally
\(no regex), must be found, and must be unique unless REPLACE-ALL (a
boolean) — a non-unique match is an error naming the count, so an
anchor gone stale under concurrent editing fails loudly instead of
editing the wrong occurrence.  An empty OLD-STRING inserts into an
empty buffer only.  Returns a unified diff labeled with LABEL."
  (when (equal old-string new-string)
    (mcp-server-lib-tool-throw
     "old-string and new-string are identical; nothing to do"))
  (save-excursion
    (save-restriction
      (widen)
      (let ((old (buffer-substring-no-properties (point-min) (point-max)))
            (matches 0))
        (if (equal old-string "")
            ;; The empty match is only unambiguous in an empty
            ;; buffer, where it means: insert.
            (if (> (length old) 0)
                (mcp-server-lib-tool-throw
                 (format "old-string is empty but %s has content; empty old-string only inserts into an empty buffer"
                         label))
              (goto-char (point-min))
              (insert new-string))
          (goto-char (point-min))
          (while (search-forward old-string nil t)
            (setq matches (1+ matches)))
          (cond
           ((= matches 0)
            (mcp-server-lib-tool-throw
             (format "old-string not found in %s (it must match exactly, including whitespace)"
                     label)))
           ((and (> matches 1) (not replace-all))
            (mcp-server-lib-tool-throw
             (format "old-string matches %d times in %s; add distinguishing context or pass replace-all yes"
                     matches label))))
          ;; search-forward leaves point after each replacement, so a
          ;; NEW-STRING containing OLD-STRING cannot be re-matched.
          (goto-char (point-min))
          (while (search-forward old-string nil t)
            (replace-match new-string t t)
            (unless replace-all (goto-char (point-max)))))
        (ch-mcp-server--text-diff
         old
         (buffer-substring-no-properties (point-min) (point-max))
         (concat label " (before)")
         (concat label " (after)"))))))

(defun ch-mcp-server--edit-buffer (old-string new-string buffer &optional replace-all)
  "Replace OLD-STRING with NEW-STRING in live BUFFER, exactly once by default.

The buffer-target editing verb: buffer mutation only, never a disk
write — the disk half lives in `ch-mcp-server--edit-file', a
separate tool name so restricted dispatch profiles can withhold disk
writing structurally (consent-gate.md).  The contract mirrors the
agent's native Edit tool so its editing instincts transfer (see
`ch-mcp-server--replace-literal'), and the unified diff returned
is the verification step.  Non-file buffers (e.g. *agent/...*
collaboration buffers) are edited in place; a file-visiting buffer is
left modified — a staged edit the user reviews and saves.  Unsaved
user modifications are therefore workable state here, not an error:
the change stays in the buffer under the user's eyes, and the
uniqueness rule is the drift guard against their concurrent editing.
A buffer backed by a file outside the calling client's territory is
refused (`ch-mcp-server--check-file-write'); buffers without a
file (the co-drafting surface) are always editable.  As the only
write path into a fresh buffer, an empty OLD-STRING inserts
NEW-STRING into an *empty* buffer (and is an error when the buffer
has content).

MCP Parameters:
  old-string - literal text to replace; must match exactly once
      unless replace-all; empty inserts into an empty buffer
  new-string - replacement text; must differ from old-string
  buffer - name of the live buffer to edit
  replace-all - yes to replace every occurrence of old-string"
  (mcp-server-lib-with-error-handling
    (let* ((target (or (get-buffer buffer)
                       (mcp-server-lib-tool-throw
                        (format "No buffer named %s" buffer))))
           (file (buffer-file-name (or (buffer-base-buffer target) target))))
      ;; A buffer backed by a file is that file's staging area even
      ;; when the mutation never writes disk; territory applies.  A
      ;; non-file buffer carries no territory, so the read predicate is
      ;; the only scope check standing between this verb and an internal
      ;; or hidden buffer resolved by name.
      (if file
          (ch-mcp-server--check-file-write file)
        (ch-mcp-server--buffer-accessible-or-throw target))
      (with-current-buffer target
        (ch-mcp-server--replace-literal
         buffer old-string new-string (equal replace-all "yes"))))))

(defun ch-mcp-server--edit-file (old-string new-string file &optional replace-all)
  "Replace OLD-STRING with NEW-STRING in FILE and save, exactly once by default.

The file-target editing verb — the one that writes disk, a separate
tool name from `ch-mcp-server--edit-buffer' so restricted
dispatch profiles can withhold disk writing structurally
\(consent-gate.md).  Same native-Edit contract (see
`ch-mcp-server--replace-literal'); returns the unified diff.
FILE must lie in the calling client's territory
\(`ch-mcp-server--check-file-write').
Edits the file's buffer (opening it within the auto-open scope) and
always saves — staging an unsaved change is edit-buffer's job.  A
buffer holding unsaved user modifications is refused: writing disk
over newer buffer state escalates to the resident side instead (see
buffer-diff; or stage the change with edit-buffer).  An empty
OLD-STRING inserts NEW-STRING into an *empty* file.

MCP Parameters:
  old-string - literal text to replace; must match exactly once
      unless replace-all; empty inserts into an empty file
  new-string - replacement text; must differ from old-string
  file - absolute path of the file to edit
  replace-all - yes to replace every occurrence of old-string"
  (mcp-server-lib-with-error-handling
    (ch-mcp-server--check-file-write file)
    (with-current-buffer (ch-mcp-server--file-buffer file)
      (when (buffer-modified-p)
        (mcp-server-lib-tool-throw
         (format "%s has unsaved modifications; refusing to write disk over newer buffer state (see buffer-diff, or stage the change with edit-buffer)"
                 file)))
      (prog1 (ch-mcp-server--replace-literal
              file old-string new-string (equal replace-all "yes"))
        (save-buffer)))))

;;; Comment threads (collab-comments)

(defun ch-mcp-server--add-comment (text &optional file buffer anchor thread)
  "Comment on buffer text as the agent: start a thread or reply to one.

Comments are overlays — never text writes — so the territory write
filter does not apply here.  Two modes.  With ANCHOR, a new thread is
attached to the anchor text
inside FILE or BUFFER (exactly one of them); the anchor is matched
literally and must occur exactly once, as in the edit tool.  With
THREAD, the comment is appended to that existing thread (ids come from
list-comments or a previous add-comment).  Comments live in overlays —
the text itself is never modified — and the user sees a highlight, a
comment-count badge, and the thread on hover or in the thread view.

MCP Parameters:
  text - the comment body
  file - absolute path holding the anchor (new thread; this or buffer)
  buffer - name of the buffer holding the anchor (new thread; this
      or file)
  anchor - literal text the new thread attaches to; must occur
      exactly once in the target
  thread - id of an existing thread to reply to (instead of
      file/buffer/anchor)"
  (mcp-server-lib-with-error-handling
    (require 'collab-comments)
    (let ((file (ch-mcp-server--opt file))
          (buffer-name (ch-mcp-server--opt buffer))
          (anchor (ch-mcp-server--opt anchor))
          (thread (ch-mcp-server--opt thread)))
      (when (string-empty-p (string-trim text))
        (mcp-server-lib-tool-throw "text must be non-empty"))
      (cond
       (thread
        (when (or file buffer-name anchor)
          (mcp-server-lib-tool-throw
           "Pass thread alone (reply) or file/buffer with anchor (new thread)"))
        (let* ((id (ch-mcp-server--as-number thread "thread"))
               (overlay (or (collab-comments-find id)
                            (mcp-server-lib-tool-throw
                             (format "No live comment thread %d (see list-comments)"
                                     id)))))
          (collab-comments-append overlay "claude" text)
          (collab-comments-render-thread overlay)))
       (t
        (unless anchor
          (mcp-server-lib-tool-throw
           "Provide anchor (new thread) or thread (reply)"))
        (when (eq (null file) (null buffer-name))
          (mcp-server-lib-tool-throw "Provide exactly one of file or buffer"))
        (let ((target (if file
                          (ch-mcp-server--file-buffer file)
                        (ch-mcp-server--buffer-accessible-or-throw
                         (or (get-buffer buffer-name)
                             (mcp-server-lib-tool-throw
                              (format "No buffer named %s" buffer-name))))))
              (label (or file buffer-name)))
          (with-current-buffer target
            (save-excursion
              (save-restriction
                (widen)
                (let ((matches 0) beg end)
                  (goto-char (point-min))
                  (while (search-forward anchor nil t)
                    (setq matches (1+ matches)
                          beg (match-beginning 0)
                          end (match-end 0)))
                  (cond
                   ((= matches 0)
                    (mcp-server-lib-tool-throw
                     (format "anchor not found in %s (it must match exactly, including whitespace)"
                             label)))
                   ((> matches 1)
                    (mcp-server-lib-tool-throw
                     (format "anchor matches %d times in %s; add distinguishing context"
                             matches label))))
                  (collab-comments-render-thread
                   (collab-comments-add-thread beg end "claude" text))))))))))))

(defun ch-mcp-server--list-comments (&optional file buffer)
  "Comment threads with their ids, anchors, authors, and bodies.

Covers the buffer named by FILE or BUFFER, or every buffer when both
are omitted.  User comments show up here; reply to a thread by id via
add-comment.

MCP Parameters:
  file - absolute path; only threads in the buffer visiting it
  buffer - buffer name; only threads in that buffer"
  (mcp-server-lib-with-error-handling
    (require 'collab-comments)
    (let* ((file (ch-mcp-server--opt file))
           (buffer-name (ch-mcp-server--opt buffer))
           (threads
            (cond
             (file
              (collab-comments-threads
               (or (find-buffer-visiting (expand-file-name file))
                   (mcp-server-lib-tool-throw
                    (format "No buffer is visiting %s" file)))))
             (buffer-name
              (collab-comments-threads
               (ch-mcp-server--buffer-accessible-or-throw
                (or (get-buffer buffer-name)
                    (mcp-server-lib-tool-throw
                     (format "No buffer named %s" buffer-name))))))
             (t (collab-comments-all-threads)))))
      (if (null threads)
          "No comment threads"
        (mapconcat #'collab-comments-render-thread threads "\n\n")))))

;;; The child

;; The parent is this Emacs: it runs the MCP server, owns the live
;; session, and decides every policy.  The child is a second Emacs
;; from the same configuration, spawned on first use into a bwrap jail
;; by `parenting-spawn' (docs/development/agent-elisp-isolation.md,
;; "Architecture"): a scrubbed environment and a filesystem view of the
;; Nix store, the configuration, and whatever `ch-mcp-server-child-ro-
;; binds' adds.  It is keyed to the running configuration's store path
;; so a switch replaces it, stopped after idle, and dies with the
;; connection.  `eval-elisp' and `transform' run in it, after the
;; readable buffers' text is copied in (next section); the CLI
;; transform is a later piece.
;;
;; The child never performs a trusted step.  Every filter, the betterleaks
;; run and the redaction, the redaction record, and the landing checks
;; run here, before text goes to the child or after text comes back,
;; and so does putting the redacted spans back when text lands.
;; Everything the child returns is data, read but never evaluated, and
;; type-checked before use.  This holds from the first spawn, not from
;; the first agent form, so nothing here has to know whether agent code
;; has run yet.

(defvar ch-mcp-server-child-idle-seconds 600
  "Seconds of no use before the child is shut down.
Every `ch-mcp-server--child-ensure' re-arms the timer; when it fires,
`ch-mcp-server-child-stop' runs and the next use spawns afresh.")

(defvar ch-mcp-server-child-spawn-timeout 60
  "Seconds to wait for the child to connect and load.
Passed as the `parenting-spawn' :timeout, which also bounds the
bootstrap form; longer than parenting's default because the child
loads the whole configuration before it answers.")

(defvar ch-mcp-server-eval-timeout 30
  "Seconds an `eval-elisp' form may run in the child.
A form still running at the deadline is not interrupted: the child is
stopped instead (`ch-mcp-server-child-stop'), so the next use starts
a fresh one, and the call returns a tool error naming the timeout.")

(defvar ch-mcp-server-child-ro-binds nil
  "Extra paths bound read-only into the child's jail.
Passed as the sandbox :ro-binds: the place for the project directories
the child may read.  Each entry is a path or a (SRC . DEST) cons.
Parenting itself binds the Nix store, its socket directory, and its
sources.  Set by the resident user only; gated elisp cannot reach it.")
(put 'ch-mcp-server-child-ro-binds 'risky-local-variable t)

(defvar ch-mcp-server-child-network nil
  "Whether the child's jail shares the host network.
Passed as the sandbox :network; nil, the default, gives the child no
network at all.  Set by the resident user only; gated elisp cannot
reach it.")
(put 'ch-mcp-server-child-network 'risky-local-variable t)

(defvar ch-mcp-server--child nil
  "The live `parenting' connection to the child, or nil.")

(defvar ch-mcp-server--child-key nil
  "The `ch-mcp-server--config-key' the child was spawned from.")

(defvar ch-mcp-server--child-idle-timer nil
  "Timer that stops the child after `ch-mcp-server-child-idle-seconds'.")

(defun ch-mcp-server--config-key ()
  "A string identifying the running configuration.
The directory of the loaded init package, a store path that changes
on every rebuild, so a child spawned from an older configuration is
replaced after a switch.  Falls back to `invocation-directory' when
the library is not found.  The child runs the same Emacs binary as
the parent (parenting's :emacs default), so the two share one package
set."
  (let ((library (locate-library "ch-emacs-config-default")))
    (if library
        (file-name-directory library)
      invocation-directory)))

(defconst ch-mcp-server--child-bootstrap
  '(progn
     (package-activate-all)
     (require 'ch-emacs-config-default)
     (when (fboundp 'eglot-ensure)
       (mapatoms (lambda (sym)
                   (when (and (boundp sym)
                              (string-suffix-p "-mode-hook" (symbol-name sym))
                              (listp (symbol-value sym))
                              (memq 'eglot-ensure (symbol-value sym)))
                     (remove-hook sym #'eglot-ensure)))))
     t)
  "Form evaluated in the child right after it connects.
The child has none of this file's code, so the form is self-contained:
it activates the package set and loads the configuration the parent
runs.  The workbench neutralizes the configuration's spawners from its
side; the editor is not changed for this.  `after-init-hook' and
`emacs-startup-hook' have already run in a -Q child that connected
before this load, so `envrc-global-mode' and `global-jinx-mode' never
start; no client frame ever exists, so ghostel's
`initial-buffer-choice' never fires; the one live spawner is
`eglot-ensure' on the mode hooks, which the form removes from every
hook that carries it.")

(defun ch-mcp-server--child-touch ()
  "Re-arm the idle timer: the child was just used."
  (when ch-mcp-server--child-idle-timer
    (cancel-timer ch-mcp-server--child-idle-timer))
  (setq ch-mcp-server--child-idle-timer
        (run-with-timer ch-mcp-server-child-idle-seconds nil
                        #'ch-mcp-server-child-stop)))

(defun ch-mcp-server--child-spawn ()
  "Spawn the child and return its connection.
A daemon child (the full interactive environment, for major modes and
indentation) kept at -Q: the configuration comes from the bootstrap
form, not from init files.  Records the configuration key the child
was spawned from and arms the idle timer."
  (require 'parenting-parent)
  (let ((conn (parenting-spawn
               :daemon (format "ch-mcp-child-%d" (emacs-pid))
               :quick t
               :sandbox (list :ro-binds ch-mcp-server-child-ro-binds
                              :network ch-mcp-server-child-network)
               :timeout ch-mcp-server-child-spawn-timeout
               :init ch-mcp-server--child-bootstrap
               :name "ch-mcp-server-child")))
    (setq ch-mcp-server--child conn
          ch-mcp-server--child-key (ch-mcp-server--config-key))
    (ch-mcp-server--copies-reset t)
    (ch-mcp-server--child-touch)
    conn))

(defun ch-mcp-server--child-ensure ()
  "Return a live connection to the child, spawning one if needed.
A live child spawned from the running configuration is reused and its
idle timer re-armed; a dead one, or one from an older configuration,
is stopped and replaced."
  (if (and ch-mcp-server--child
           (parenting-connection-live-p ch-mcp-server--child)
           (equal ch-mcp-server--child-key (ch-mcp-server--config-key)))
      (progn
        (ch-mcp-server--child-touch)
        ch-mcp-server--child)
    (ch-mcp-server-child-stop)
    (ch-mcp-server--child-spawn)))

(defun ch-mcp-server-child-stop ()
  "Shut the child down and clear its state.
A no-op without a child.  Run by the idle timer, before a replacement
spawn, and by hand when the resident user wants the child gone."
  (interactive)
  (ch-mcp-server--copies-reset nil)
  (when ch-mcp-server--child-idle-timer
    (cancel-timer ch-mcp-server--child-idle-timer)
    (setq ch-mcp-server--child-idle-timer nil))
  (when ch-mcp-server--child
    (let ((conn ch-mcp-server--child))
      (setq ch-mcp-server--child nil
            ch-mcp-server--child-key nil)
      (parenting-shutdown conn))))

;;; Copies of buffer text in the child

;; Before each evaluation the parent copies the text of every buffer the
;; agent may read into the child (docs/development/agent-elisp-isolation.md,
;; "Forward contract"): `buffer-substring-no-properties', the buffer
;; name, and the file name; nothing else crosses.  The child recreates a
;; plain buffer under the same name and picks the major mode from the
;; file name.  The same text is written to a file in the copy directory,
;; where betterleaks runs; a finding replaces the secret in the copy with a
;; numbered placeholder, and the parent keeps the original beside the
;; copy's record so a landing puts it back.  Copies are incremental: a buffer is
;; re-sent only when `buffer-chars-modified-tick' moved, and a buffer
;; that died or stopped being readable is removed from the child.

(defvar ch-mcp-server--copy-directory nil
  "Directory holding the file copy of each buffer's text, or nil.
Created with the child and deleted with it.")

(defvar ch-mcp-server--copies (make-hash-table :test #'equal)
  "Buffer name to the state of its copy in the child.
Each value is a plist: :tick, the `buffer-chars-modified-tick' the
copy was taken at; :file, the copy's path; :redacted, non-nil when
betterleaks found a secret in the copy; :spans, the placeholder-to-original
alist `ch-mcp-server--redact-spans' returned, put back when text
lands.")

(defun ch-mcp-server--copies-reset (create)
  "Forget every copy and delete the copy directory; with CREATE, make a new one."
  (clrhash ch-mcp-server--copies)
  (when (and ch-mcp-server--copy-directory
             (file-directory-p ch-mcp-server--copy-directory))
    (delete-directory ch-mcp-server--copy-directory t))
  (setq ch-mcp-server--copy-directory
        (and create (make-temp-file "ch-mcp-copies-" t))))

(defun ch-mcp-server--copy-file-name (name &optional directory)
  "The path of the copy for the buffer named NAME, in DIRECTORY.
DIRECTORY defaults to the copy directory.  The buffer name is the file
name, with every character outside letters, digits, dot, dash, and
underscore replaced by `%', so `modules/default.nix' and `*Messages*'
each make one plain file."
  (expand-file-name (replace-regexp-in-string "[^A-Za-z0-9._-]" "%" name)
                    (or directory ch-mcp-server--copy-directory)))

(defun ch-mcp-server--redact-text (text findings)
  "Return TEXT with each of FINDINGS replaced by a placeholder.
FINDINGS are betterleaks report entries for this one text, alists with
the symbols RuleID, Secret, StartLine, and EndLine (1-based,
inclusive).  Each secret is replaced on its reported lines by
`[REDACTED:<rule>]' by matching the reported text, since the report's
columns are byte offsets.  A secret not found on those lines (a
multi-line match) has its whole line range replaced: the placeholder
on the first line, the rest emptied."
  (let ((lines (vconcat (split-string text "\n"))))
    (dolist (finding findings)
      (let* ((rule (alist-get 'RuleID finding))
             (secret (alist-get 'Secret finding))
             (start (alist-get 'StartLine finding))
             (end (alist-get 'EndLine finding))
             (placeholder (format "[REDACTED:%s]" rule))
             (hit nil))
        (when (and (integerp start) (integerp end)
                   (stringp secret) (not (string-empty-p secret)))
          (let ((i (1- start))
                (limit (min end (length lines))))
            (while (< i limit)
              (when (string-search secret (aref lines i))
                (aset lines i (string-replace secret placeholder (aref lines i)))
                (setq hit t))
              (setq i (1+ i)))
            (unless hit
              (setq i (1- start))
              (while (< i limit)
                (aset lines i (if (= i (1- start)) placeholder ""))
                (setq i (1+ i))))))))
    (mapconcat #'identity lines "\n")))

(defun ch-mcp-server--redact-spans (text findings)
  "Return (TEXT . SPANS): TEXT with FINDINGS replaced by numbered placeholders.
Like `ch-mcp-server--redact-text', but every placeholder is unique,
`[REDACTED:<rule>:<n>]' with n counting the findings from 1, and SPANS
is an alist of (PLACEHOLDER . ORIGINAL) that
`ch-mcp-server--splice-spans' puts back when text lands.  A secret
found on its reported lines is replaced where it stands; one not found
there (a multi-line match) has its line range collapsed to one
placeholder line, and ORIGINAL is those lines' text.  A finding whose
secret is already mapped adds nothing."
  (let ((lines (vconcat (split-string text "\n")))
        (spans nil)
        (ranges nil)
        (n 0))
    (dolist (finding findings)
      (let ((rule (alist-get 'RuleID finding))
            (secret (alist-get 'Secret finding))
            (start (alist-get 'StartLine finding))
            (end (alist-get 'EndLine finding)))
        (when (and (integerp start) (integerp end)
                   (stringp secret) (not (string-empty-p secret))
                   (<= 1 start end (length lines)))
          (let ((i (1- start))
                (hit nil))
            (while (< i end)
              (when (string-search secret (aref lines i))
                (setq hit t))
              (setq i (1+ i)))
            (cond
             (hit
              (setq n (1+ n))
              (let ((placeholder (format "[REDACTED:%s:%d]" rule n)))
                (setq i (1- start))
                (while (< i end)
                  (aset lines i (string-replace secret placeholder (aref lines i)))
                  (setq i (1+ i)))
                (push (cons placeholder secret) spans)))
             ((rassoc secret spans) nil)
             (t (push (list start end rule) ranges)))))))
    ;; Collapse the multi-line ranges from the bottom up, so the line
    ;; numbers of the ranges above stay true.
    (let ((list (append lines nil)))
      (dolist (range (sort ranges (lambda (a b) (> (car a) (car b)))))
        (pcase-let ((`(,start ,end ,rule) range))
          (setq n (1+ n))
          (let ((placeholder (format "[REDACTED:%s:%d]" rule n))
                (original (mapconcat #'identity
                                     (seq-subseq list (1- start) end) "\n")))
            (push (cons placeholder original) spans)
            (setq list (append (seq-take list (1- start))
                               (list placeholder)
                               (seq-drop list end))))))
      (cons (mapconcat #'identity list "\n") (nreverse spans)))))

(defun ch-mcp-server--splice-spans (text spans)
  "Return TEXT with each placeholder in SPANS replaced by its original.
SPANS is the alist `ch-mcp-server--redact-spans' returned.  A numbered
placeholder left in TEXT that SPANS does not map (altered, or from
another copy) is a tool error, and nothing lands: a buffer must never
receive a placeholder."
  (dolist (span spans)
    (setq text (string-replace (car span) (cdr span) text)))
  (when (string-match "\\[REDACTED:[A-Za-z0-9._-]+:[0-9]+\\]" text)
    (mcp-server-lib-tool-throw
     (format "the text holds a redaction placeholder this copy cannot map (%s); nothing landed. Delete or move a placeholder whole, never alter or invent one"
             (match-string 0 text))))
  text)

(defun ch-mcp-server--betterleaks-report (subcommand input &rest args)
  "Run betterleaks SUBCOMMAND with ARGS; return its findings as a list.
INPUT, when non-nil, is the text fed to standard input (the `stdin'
subcommand); ARGS follow the fixed flags (the `dir' subcommand takes
the path).  Each finding is a report entry as
`ch-mcp-server--redact-text' takes.  A betterleaks that cannot run, or
fails, is a tool error: no text passes before betterleaks has passed
over it."
  (with-temp-buffer
    (let* ((output (current-buffer))
           (command (append ch-mcp-server-betterleaks-command
                            (list subcommand "--no-banner" "--log-level" "error"
                                  "--report-format" "json"
                                  "--report-path" "-" "--exit-code" "0")
                            args))
           (status (condition-case err
                       (if input
                           (with-temp-buffer
                             (insert input)
                             (apply #'call-process-region (point-min) (point-max)
                                    (car command) nil (list output nil) nil
                                    (cdr command)))
                         (apply #'call-process (car command) nil
                                (list output nil) nil (cdr command)))
                     (error
                      (mcp-server-lib-tool-throw
                       (format "betterleaks could not run (%s): %s"
                               (car command) (error-message-string err)))))))
      (unless (eq status 0)
        (mcp-server-lib-tool-throw
         (format "betterleaks failed (exit %s): %s"
                 status (string-trim (buffer-string)))))
      (condition-case nil
          (json-parse-string (buffer-string)
                             :object-type 'alist
                             :array-type 'list
                             :null-object nil)
        (error nil)))))

(defun ch-mcp-server--betterleaks-findings ()
  "Run betterleaks over the copy directory; return findings by copy file name.
An alist of (BASENAME . FINDINGS)."
  (let ((by-file nil))
    (dolist (finding (ch-mcp-server--betterleaks-report
                      "dir" nil ch-mcp-server--copy-directory))
      (let ((file (file-name-nondirectory (alist-get 'File finding))))
        (push finding (alist-get file by-file nil nil #'equal))))
    by-file))

(defun ch-mcp-server--copy-form (name file text)
  "The form the child evaluates to hold TEXT as the buffer named NAME.
FILE, when non-nil, only picks the major mode through `set-auto-mode';
the child's buffer visits nothing."
  `(let ((buffer (get-buffer-create ,name)))
     (with-current-buffer buffer
       (setq buffer-read-only nil)
       (erase-buffer)
       (insert ,text)
       (goto-char (point-min))
       ,@(and file
              `((let ((buffer-file-name ,file))
                  (set-auto-mode))))
       (set-buffer-modified-p nil))
     t))

(defun ch-mcp-server--copies-sync (conn)
  "Bring the child's copies up to date with the buffers the agent may read.
Writes each changed buffer's text into the copy directory, runs
betterleaks over the directory, sends every changed copy (redacted where
betterleaks found a secret) to the child on CONN, and removes from the
child each buffer that died or is no longer readable."
  (let ((changed nil)
        (live (make-hash-table :test #'equal)))
    ;; A copy the child no longer holds (a form killed it) counts as
    ;; changed, so it is sent again.
    (let ((present (ch-mcp-server--in-child
                    conn '(mapcar #'buffer-name (buffer-list))))
          (missing nil))
      (maphash (lambda (name _entry)
                 (unless (member name present) (push name missing)))
               ch-mcp-server--copies)
      (dolist (name missing)
        (remhash name ch-mcp-server--copies)))
    (dolist (buffer (buffer-list))
      (when (ch-mcp-server--buffer-accessible-p buffer)
        (let* ((name (buffer-name buffer))
               (tick (buffer-chars-modified-tick buffer))
               (entry (gethash name ch-mcp-server--copies)))
          (puthash name t live)
          (unless (and entry (eql (plist-get entry :tick) tick))
            (let ((file (ch-mcp-server--copy-file-name name))
                  (text (with-current-buffer buffer
                          (save-restriction
                            (widen)
                            (buffer-substring-no-properties (point-min)
                                                            (point-max))))))
              (let ((coding-system-for-write 'utf-8-unix))
                (with-temp-file file (insert text)))
              (puthash name (list :tick tick :file file :redacted nil :spans nil)
                       ch-mcp-server--copies)
              (push (list name (buffer-file-name buffer) text) changed))))))
    (let ((gone nil))
      (maphash (lambda (name _entry)
                 (unless (gethash name live) (push name gone)))
               ch-mcp-server--copies)
      (dolist (name gone)
        (let ((file (plist-get (gethash name ch-mcp-server--copies) :file)))
          (when (and file (file-exists-p file))
            (delete-file file)))
        (remhash name ch-mcp-server--copies)
        (ch-mcp-server--in-child
         conn `(when (get-buffer ,name) (kill-buffer ,name)))))
    (when changed
      (let ((findings (ch-mcp-server--betterleaks-findings)))
        (dolist (item (nreverse changed))
          (pcase-let* ((`(,name ,file ,text) item)
                       (entry (gethash name ch-mcp-server--copies))
                       (copy (plist-get entry :file))
                       (hits (alist-get (file-name-nondirectory copy) findings
                                        nil nil #'equal)))
            (when hits
              (let ((redaction (ch-mcp-server--redact-spans text hits)))
                (setq text (car redaction))
                (plist-put entry :spans (cdr redaction))
                (plist-put entry :redacted t))
              (let ((coding-system-for-write 'utf-8-unix))
                (with-temp-file copy (insert text))))
            (ch-mcp-server--in-child
             conn (ch-mcp-server--copy-form name file text))))))))

(defun ch-mcp-server--child-connection ()
  "The live connection to the child, spawning one if needed.
A child that cannot be started is a tool error naming the cause."
  (condition-case err
      (ch-mcp-server--child-ensure)
    (error
     (mcp-server-lib-tool-throw
      (format "the child Emacs could not be started: %s"
              (error-message-string err))))))

(defun ch-mcp-server--in-child (conn form)
  "Evaluate FORM in the child on CONN and return its value.
An error in the child becomes a tool error carrying the child's
message.  A form still running at `ch-mcp-server-eval-timeout' cannot
be interrupted, so the child is stopped, the next call starts a fresh
one, and this call is a tool error saying so.  A child that cannot be
reached is a tool error naming the cause."
  (condition-case err
      (parenting-eval conn form ch-mcp-server-eval-timeout)
    (parenting-timeout
     (ch-mcp-server-child-stop)
     (mcp-server-lib-tool-throw
      (format "the child Emacs timed out after %ss; it was stopped and the next call starts a fresh one"
              ch-mcp-server-eval-timeout)))
    (parenting-remote-error
     (let ((symbol (nth 1 err))
           (data (nth 2 err)))
       (mcp-server-lib-tool-throw
        (format "the child Emacs signalled: %s"
                (condition-case nil
                    (error-message-string (cons symbol data))
                  (error (format "%S %S" symbol data)))))))
    (parenting-error
     (mcp-server-lib-tool-throw
      (format "the child Emacs could not be reached: %s"
              (error-message-string err))))))

(defun ch-mcp-server--child-eval (form)
  "Evaluate FORM in the child after refreshing the copies; print with %S.
The printing happens in the child, so a value with no readable form
(a buffer, a marker) arrives as its %S text."
  (let ((conn (ch-mcp-server--child-connection)))
    (ch-mcp-server--copies-sync conn)
    (ch-mcp-server--in-child conn (list 'format "%S" form))))

;;; Copies for the CLI

;; The CLI transform (docs/development/agent-elisp-isolation.md, "What
;; runs where"): the agent asks for a buffer as a file, edits it with
;; its own command-line tools, and asks for the text to land.  The file
;; lives in the calling client's territory under
;; .agent-sandbox/, the directory the agent-sandbox CLI already
;; uses as per-checkout scratch: sandboxed commands can write the
;; checkout and nothing else, and that directory is kept out of `git
;; status' through the clone's exclude file, which this writes too where
;; the sandbox has not.  The text passes the same filters as every copy
;; (the buffer predicate, then betterleaks), and the text lands through
;; `ch-mcp-server--land-text' with the tick recorded when the file was
;; written; a redacted file lands nothing.  The file is a copy: editing
;; it changes no buffer until land-buffer-file runs, and a landed or
;; refused file is removed.

(defvar ch-mcp-server--cli-copies (make-hash-table :test #'equal)
  "Buffer name to the state of its file for the CLI transform.
A plist: :file, the path; :tick, the buffer's chars-modified tick when
the file was written; :redacted, non-nil when betterleaks found a secret
in it; :spans, the placeholder-to-original alist put back when the
file lands.")

(defconst ch-mcp-server--cli-copy-subdirectory
  ".agent-sandbox/mcp-copies"
  "Where, under the client's territory, the CLI transform's files live.
Under the directory the CLI's sandbox uses for per-checkout scratch, so
the exclude-file line the sandbox writes covers it.")

(defun ch-mcp-server--exclude-scratch (root)
  "Keep the sandbox scratch directory under ROOT out of `git status'.
Appends the line the sandbox itself writes to the clone's info/exclude,
resolved through git so a worktree shares the main clone's file.  ROOT
without a git directory, or git failing, changes nothing."
  (let ((exclude (condition-case nil
                     (with-temp-buffer
                       (when (eq 0 (call-process "git" nil t nil "-C" root
                                                 "rev-parse" "--git-path"
                                                 "info/exclude"))
                         (expand-file-name (string-trim (buffer-string)) root)))
                   (error nil)))
        (line "/.agent-sandbox/"))
    (when exclude
      (condition-case nil
          (let ((existing (if (file-exists-p exclude)
                              (with-temp-buffer
                                (insert-file-contents exclude)
                                (buffer-string))
                            "")))
            (unless (member line (split-string existing "\n"))
              (make-directory (file-name-directory exclude) t)
              (with-temp-buffer
                (insert existing)
                (unless (or (string-empty-p existing)
                            (string-suffix-p "\n" existing))
                  (insert "\n"))
                (insert line "\n")
                (write-region (point-min) (point-max) exclude nil 'quiet))))
        (error nil)))))

(defun ch-mcp-server--buffer-file (name)
  "Write the text of the buffer NAME to a file in the territory; return its path.

The file is for reading or editing with your own command-line tools:
the buffer's text without properties, passed through betterleaks like
every copy, so a recognized secret arrives as [REDACTED:<rule>] and
such a file cannot be landed.  Editing the file changes nothing in
Emacs; call land-buffer-file with the same name to land its text,
which is refused if the buffer changed meanwhile.  The file lives under
the client's territory in .agent-sandbox/mcp-copies/, which
the CLI's sandbox can write and git ignores.

MCP Parameters:
  name - name of a live buffer, as listed by the list-buffers tool"
  (mcp-server-lib-with-error-handling
    (let ((buffer (get-buffer name)))
      (unless buffer
        (mcp-server-lib-tool-throw (format "No buffer named %s" name)))
      (ch-mcp-server--buffer-accessible-or-throw buffer)
      (let* ((root (ch-mcp-server--client-territory))
             (directory (expand-file-name ch-mcp-server--cli-copy-subdirectory
                                          root))
             (file (ch-mcp-server--copy-file-name name directory))
             (tick (buffer-chars-modified-tick buffer))
             (text (with-current-buffer buffer
                     (save-restriction
                       (widen)
                       (buffer-substring-no-properties (point-min) (point-max)))))
             (findings (ch-mcp-server--betterleaks-report "stdin" text))
             (redaction (and findings
                             (ch-mcp-server--redact-spans text findings))))
        (when redaction
          (setq text (car redaction)))
        (make-directory directory t)
        (set-file-modes directory #o700)
        (ch-mcp-server--exclude-scratch root)
        (let ((coding-system-for-write 'utf-8-unix))
          (with-temp-file file (insert text)))
        (set-file-modes file #o600)
        (puthash name (list :file file :tick tick :redacted (and findings t)
                            :spans (cdr redaction))
                 ch-mcp-server--cli-copies)
        (if findings
            (format "%s\n(betterleaks redacted %d span%s in this copy: %s, as numbered placeholders; the originals are put back when the file lands, so delete or move a placeholder whole, never alter or invent one)"
                    file (length findings) (if (= 1 (length findings)) "" "s")
                    (string-join
                     (seq-uniq (mapcar (lambda (finding)
                                         (format "%s" (alist-get 'RuleID finding)))
                                       findings))
                     ", "))
          file)))))

(defun ch-mcp-server--land-buffer-file (name &optional save)
  "Land the text of the file buffer-file wrote for the buffer NAME.

Returns a unified diff, or \"No changes\".  Refused when no file was
requested for NAME, when the buffer changed since the file was written
(ask for the file again), when the buffer is read-only or has a
process, and, for a file-visiting buffer, when its file lies outside
the client's territory.  A redacted file lands with its original
spans put back in place of the placeholders; a placeholder altered or
invented refuses the landing.  The file is removed afterwards, landed
or refused, so a stale copy never lands later.  Saves a file-visiting
buffer unless SAVE is no.

MCP Parameters:
  name - the buffer name given to buffer-file
  save - no to leave the change unsaved in the buffer (default: save)"
  (mcp-server-lib-with-error-handling
    (let ((entry (gethash name ch-mcp-server--cli-copies))
          (buffer (get-buffer name)))
      (unless entry
        (mcp-server-lib-tool-throw
         (format "No file was requested for buffer %s; call buffer-file first"
                 name)))
      (remhash name ch-mcp-server--cli-copies)
      (unwind-protect
          (let ((path (plist-get entry :file))
                (file (and buffer (buffer-file-name buffer))))
            (unless buffer
              (mcp-server-lib-tool-throw
               (format "Buffer %s no longer exists" name)))
            (unless (file-readable-p path)
              (mcp-server-lib-tool-throw
               (format "The file for %s is gone (%s); call buffer-file again"
                       name path)))
            (when (get-buffer-process buffer)
              (mcp-server-lib-tool-throw
               (format "%s has a process attached; text lands only in file-visiting or plain buffers"
                       name)))
            (when file
              (ch-mcp-server--check-file-write file))
            (let ((text (with-temp-buffer
                          (let ((coding-system-for-read 'utf-8-unix))
                            (insert-file-contents path))
                          (buffer-string))))
              (ch-mcp-server--land-text buffer (or file name) text
                                        (plist-get entry :tick)
                                        (if file save "no")
                                        (plist-get entry :spans))))
        (ignore-errors (delete-file (plist-get entry :file)))))))

;;; Redaction of tool results

;; Every tool result passes through betterleaks here, in the parent, on its
;; way to the agent's context (docs/development/agent-elisp-isolation.md,
;; "Redaction covers every file view"): the read tools, the diffs the
;; edit verbs return (their context lines are buffer text), and what the
;; child returns for `eval-elisp'.  Each finding is replaced by
;; `[REDACTED:<rule>]' and a note naming the rules is appended, so the
;; agent knows a redaction occurred.  The filter is :filter-return advice
;; on every registered tool function, which leaves the tool schemas that
;; mcp-server-lib derives from the functions' docstrings untouched.

;; A redacted read can be shown once more, unredacted, when the user
;; allows it.  The CLI's reveal hook asks the user when the identical
;; call is re-issued; on allow it writes a random token into a file under
;; $XDG_RUNTIME_DIR/claude-redact/mcp-approved/ and adds the token to the
;; call as the `approval' argument (a PreToolUse hook may rewrite a
;; call's input; the model's own record of the call keeps the original).
;; A tool taking `approval' passes it to `ch-mcp-server--use-approval',
;; which consumes the file and marks this one call unredacted.  A token
;; with no file is a tool error, so a model cannot approve its own read.

(defvar ch-mcp-server--skip-redaction nil
  "Non-nil while a tool call runs under a consumed approval.
Bound to nil around every tool call by `ch-mcp-server--filter-result',
so an approval covers exactly the call that presented it, even when
that call signals.")

(defun ch-mcp-server--approval-directory ()
  "Where the reveal hook writes approval tokens, or nil without a runtime dir."
  (let ((runtime (getenv "XDG_RUNTIME_DIR")))
    (and runtime (not (string-empty-p runtime))
         (expand-file-name "claude-redact/mcp-approved" runtime))))

(defun ch-mcp-server--use-approval (approval)
  "Consume APPROVAL, a token from the reveal hook, for the current call.
Nil or empty APPROVAL does nothing.  A token whose file exists is
deleted and the current call is left unredacted; anything else is a
tool error."
  (when (and approval (not (string-empty-p approval)))
    (let ((directory (ch-mcp-server--approval-directory)))
      (unless (and directory
                   (string-match-p "\\`[A-Za-z0-9]\\{32,128\\}\\'" approval)
                   (file-exists-p (expand-file-name approval directory)))
        (mcp-server-lib-tool-throw
         "approval is not a valid token; only the user's answer to a redaction prompt produces one, so leave it empty"))
      (delete-file (expand-file-name approval directory))
      (setq ch-mcp-server--skip-redaction t))))

(defun ch-mcp-server--filter-result (tool &rest args)
  "Run TOOL on ARGS and pass its result through the redaction filter.
The :around advice on every tool function; skipped for the one call
that consumed an approval."
  (let ((ch-mcp-server--skip-redaction nil))
    (let ((result (apply tool args)))
      (if ch-mcp-server--skip-redaction
          result
        (ch-mcp-server--redact-result result)))))

(defun ch-mcp-server--redact-result (result)
  "Return RESULT with the secrets betterleaks finds replaced, plus a note.
A string result is run through betterleaks; each finding is replaced on
its lines by `[REDACTED:<rule>]' (`ch-mcp-server--redact-text') and a
line \"[betterleaks redacted N spans: RULES]\" is appended.  A non-string
or empty result passes unchanged.  betterleaks failing to run is a tool
error, so no text reaches the agent without passing through it."
  (if (or (not (stringp result)) (string-empty-p result))
      result
    (let ((findings (ch-mcp-server--betterleaks-report "stdin" result)))
      (if (null findings)
          result
        (concat (ch-mcp-server--redact-text result findings)
                (format "\n\n[betterleaks redacted %d span%s: %s]"
                        (length findings)
                        (if (= 1 (length findings)) "" "s")
                        (string-join
                         (seq-uniq (mapcar (lambda (finding)
                                             (format "%s" (alist-get 'RuleID finding)))
                                           findings))
                         ", ")))))))

(defconst ch-mcp-server--tool-functions
  '(ch-mcp-server--eval-elisp
    ch-mcp-server--context
    ch-mcp-server--list-buffers
    ch-mcp-server--buffer-text
    ch-mcp-server--diagnostics
    ch-mcp-server--find-references
    ch-mcp-server--find-definition
    ch-mcp-server--symbol-info
    ch-mcp-server--document-outline
    ch-mcp-server--modified-buffers
    ch-mcp-server--buffer-diff
    ch-mcp-server--feature-loaded
    ch-mcp-server--hooks
    ch-mcp-server--buffer-state
    ch-mcp-server--key-binding
    ch-mcp-server--present
    ch-mcp-server--sidebar
    ch-mcp-server--edit-buffer
    ch-mcp-server--edit-file
    ch-mcp-server--transform
    ch-mcp-server--buffer-file
    ch-mcp-server--land-buffer-file
    ch-mcp-server--add-comment
    ch-mcp-server--list-comments)
  "Every registered tool function; each carries the result filter.
Kept beside the registration below, and a test holds the two lists to
the same length.")

(dolist (fn ch-mcp-server--tool-functions)
  (advice-remove fn #'ch-mcp-server--redact-result)
  (advice-add fn :around #'ch-mcp-server--filter-result))

;;; Server lifecycle and registration

(defun ch-mcp-server-start ()
  "Start handling MCP requests.  Idempotent: concurrent MCP clients each
call this via the stdio bridge's --init-function, and the first one wins.
No paired stop function is wired up, so one client exiting cannot stall
the others."
  (unless (bound-and-true-p mcp-server-lib--running)
    (mcp-server-lib-start))
  t)

;; Watch the debug-leak knobs so the log-buffer latch records a tainted
;; region the moment a knob turns on, whether or not a tool is running.
;; Idempotent, so re-evaluating this file never stacks watchers.
(ch-mcp-server--install-log-watchers)

(use-package mcp-server-lib
  :demand t
  :config
  (mcp-server-lib-register-server
   :id "emacs"
   :name "Emacs"
   :instructions
   (concat "Tools backed by the user's live Emacs session: warm LSP servers, "
           "unsaved buffer state, and the user's attention. Positions are "
           "1-based file/line/col as in grep output. Triggers: "
           "type/signature/callers question -> find-references, "
           "find-definition, symbol-info; current errors -> diagnostics; "
           "orienting in a big file -> document-outline; before editing in "
           "the user's active project -> modified-buffers, then buffer-diff "
           "on any hit; before asking the user a non-trivial question -> "
           "present the context in a buffer first; read-once material "
           "beside a reply (anticipated questions, a glossary) -> sidebar; "
           "a single literal "
           "replacement -> edit-file to write disk, edit-buffer to mutate a "
           "live/shared buffer without saving (both carry the native Edit "
           "contract: unique match, fails loudly on drift); leaving or "
           "answering review notes on text under discussion -> add-comment, "
           "reading the user's notes -> list-comments; a session fact that "
           "is not buffer text (is a feature loaded, what is on a hook, a "
           "buffer's mode/state/visibility, what a key does) -> "
           "feature-loaded, hooks, buffer-state, key-binding. eval-elisp "
           "runs in a sandboxed child Emacs that has this session's "
           "configuration and plain-text copies of the buffers you may "
           "read, and none of its other state: it answers questions about "
           "the configuration and about buffer text, not about the live "
           "session's variables, and cannot change the session. Writes "
           "are confined to the session's own project. Every result passes "
           "through betterleaks first: a recognized secret arrives as "
           "[REDACTED:<rule>] with a note, and the redaction is a boundary "
           "like a refusal.")
   :tools
   (list
    (list #'ch-mcp-server--eval-elisp
          :id "eval-elisp"
          :description
          "Evaluate Emacs Lisp in a sandboxed child Emacs running this session's configuration and holding plain-text copies of the readable buffers (secrets redacted), with none of the live session's variables or files; edits go through the edit tools")
    (list #'ch-mcp-server--context
          :id "context"
          :description
          "Where the user is: buffer, file, project, defun, region, visible windows"
          :read-only t)
    (list #'ch-mcp-server--list-buffers
          :id "list-buffers"
          :description "List live buffers with their major modes and files"
          :read-only t)
    (list #'ch-mcp-server--buffer-text
          :id "buffer-text"
          :description "Text of a named buffer, optionally a 1-based line range"
          :read-only t)
    (list #'ch-mcp-server--diagnostics
          :id "diagnostics"
          :description
          "Current errors/warnings from the session's checkers, as path:line:col lines"
          :read-only t)
    (list #'ch-mcp-server--find-references
          :id "find-references"
          :description
          "References to the symbol at file:line:col (LSP/xref), grep-format lines"
          :read-only t)
    (list #'ch-mcp-server--find-definition
          :id "find-definition"
          :description
          "Definition of the symbol at file:line:col (LSP/xref), grep-format lines"
          :read-only t)
    (list #'ch-mcp-server--symbol-info
          :id "symbol-info"
          :description
          "Type signature and docs (LSP hover) for the symbol at file:line:col"
          :read-only t)
    (list #'ch-mcp-server--document-outline
          :id "document-outline"
          :description
          "Outline of a file (imenu/LSP) as an indented line: name tree"
          :read-only t)
    (list #'ch-mcp-server--modified-buffers
          :id "modified-buffers"
          :description
          "Files with unsaved buffer changes; check before editing near the user"
          :read-only t)
    (list #'ch-mcp-server--buffer-diff
          :id "buffer-diff"
          :description
          "Unified diff of a file's unsaved buffer state vs the file on disk"
          :read-only t)
    (list #'ch-mcp-server--feature-loaded
          :id "feature-loaded"
          :description
          "Whether a feature is loaded in the live session (featurep), plus fboundp/boundp on its symbol; a session fact buffer text cannot give"
          :read-only t)
    (list #'ch-mcp-server--hooks
          :id "hooks"
          :description
          "Functions on a hook variable in the live session: the global value, and a buffer's local value when a buffer is named (lambdas print as <lambda>)"
          :read-only t)
    (list #'ch-mcp-server--buffer-state
          :id "buffer-state"
          :description
          "Non-text facts about a live buffer: file, major/minor modes, read-only, modified, size, point, evil state, terminal input mode, sensitivity, agent visibility"
          :read-only t)
    (list #'ch-mcp-server--key-binding
          :id "key-binding"
          :description
          "What a key sequence (kbd syntax, e.g. SPC p p; the evil leader is SPC in motion state) resolves to in a buffer's live context: command, <keymap (prefix)>, <lambda>, or unbound"
          :read-only t)
    (list #'ch-mcp-server--present
          :id "present"
          :description
          "Present content to the user in an *agent/...* Emacs buffer (markdown, diff, clickable locations, or a rendered mermaid diagram)")
    (list #'ch-mcp-server--sidebar
          :id "sidebar"
          :description
          "Show read-once markdown (anticipated questions, a glossary, a checklist) in a right-hand sidebar window the user dismisses with q")
    (list #'ch-mcp-server--edit-buffer
          :id "edit-buffer"
          :description
          "Replace a literal string in a live buffer, never writing disk (must match exactly once unless replace-all=yes); returns a unified diff")
    (list #'ch-mcp-server--edit-file
          :id "edit-file"
          :description
          "Replace a literal string in a file and save it (must match exactly once unless replace-all=yes); returns a unified diff")
    (list #'ch-mcp-server--transform
          :id "transform"
          :description
          "Run elisp against a file's buffer for bulk/structural edits: the form runs in the sandboxed child on the buffer's copy and only the resulting text lands (refused if the buffer changed meanwhile; redacted spans are put back on landing); returns a unified diff; saves unless save=no")
    (list #'ch-mcp-server--buffer-file
          :id "buffer-file"
          :description
          "A plain-text copy of a buffer as a file under this session's territory (.agent-sandbox/mcp-copies/), for reading or editing with your own tools; secrets appear as numbered placeholders that are put back when the text lands; land the edited text with land-buffer-file")
    (list #'ch-mcp-server--land-buffer-file
          :id "land-buffer-file"
          :description
          "Land the edited text of a buffer-file copy into its buffer, with redacted spans put back in place of their placeholders (refused if the buffer changed meanwhile or a placeholder was altered; the file is removed either way); returns a unified diff; saves unless save=no")
    (list #'ch-mcp-server--add-comment
          :id "add-comment"
          :description
          "Comment on buffer text: start a thread on a unique literal anchor, or reply to a thread id; never modifies the text")
    (list #'ch-mcp-server--list-comments
          :id "list-comments"
          :description
          "Comment threads (ids, anchors, authors, bodies) in one buffer or everywhere"
          :read-only t))))

