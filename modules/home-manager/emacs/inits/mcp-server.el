;; SPDX-License-Identifier: MIT
;;; -*- lexical-binding: t -*-
;; init mcp-server
;;
;; The agent-facing tool set is designed in
;; docs/development/emacs-mcp-agent-tools.md: session-unique answers only
;; (warm LSP, unsaved buffer state, user attention, the editing engine),
;; positions in as 1-based file/line/col, locations out as grep-format
;; lines, results capped with true totals.  Server-side security filters
;; (client-territory write scope, the agent-safe elisp gate) extend the
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
  (require 'unsafep)
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
(declare-function unsafep "unsafep")
(defvar safe-functions)

(defvar ch-emacs-config-mcp-auto-open-scope 'session-projects
  "Scope of files the MCP tools may open into new buffers.
`session-projects' allows only files under a project that already has
file-visiting buffers in this session; `any-project' allows any readable
file.  Files under the calling client's own territory (see
`ch-emacs-config-mcp--client-territory') and files already visited by a
buffer are always in scope.")

(defvar ch-emacs-config-mcp-write-scope 'client-project
  "Which files the MCP write verbs may touch.
`client-project' (the default) confines `edit-file', `transform', and
`edit-buffer' on file-visiting buffers to the calling client's
territory — the project containing the client session's launch
directory (see `ch-emacs-config-mcp--client-territory').
`unrestricted' disables the check.  Set by the resident user only;
gated elisp cannot reach it.")
(put 'ch-emacs-config-mcp-write-scope 'risky-local-variable t)

(defvar ch-emacs-config-mcp-elisp-scope 'agent-safe
  "Which elisp the MCP elisp-taking tools will evaluate.
`agent-safe' (the default) accepts only forms `unsafep' proves free of
side effects, extended by `ch-emacs-config-mcp-agent-safe-functions'
(and, for `transform', `ch-emacs-config-mcp-agent-safe-editing-functions').
`unrestricted' disables the gate — the resident user's explicit say-so
for a stateful co-driving session; gated elisp cannot reach it.")
(put 'ch-emacs-config-mcp-elisp-scope 'risky-local-variable t)

(defvar ch-emacs-config-mcp-agent-safe-functions '(error ignore)
  "Functions the elisp gate accepts beyond Emacs's own safety metadata.
`unsafep' already admits everything marked `pure', `side-effect-free',
or `safe-function'; list here functions that are innocuous for agents
to call but carry no such marking.  Seeds: `error' so gated code can
signal validation failures, `ignore' as the no-op it is.  Extended by
the resident user (or by modes declaring their own functions); gated
elisp cannot grow it.")
(put 'ch-emacs-config-mcp-agent-safe-functions 'risky-local-variable t)

(defvar ch-emacs-config-mcp-agent-safe-editing-functions
  '(save-excursion save-restriction widen narrow-to-region
    goto-char move-to-column
    forward-char backward-char forward-line forward-word backward-word
    forward-sexp backward-sexp up-list down-list backward-up-list
    beginning-of-line end-of-line beginning-of-defun end-of-defun
    search-forward search-backward re-search-forward re-search-backward
    looking-at looking-back
    skip-chars-forward skip-chars-backward
    skip-syntax-forward skip-syntax-backward
    insert delete-region delete-char replace-match
    indent-region indent-according-to-mode
    upcase-region downcase-region capitalize-region
    sort-lines sort-fields fill-region fill-paragraph
    delete-trailing-whitespace delete-blank-lines delete-indentation)
  "Buffer-editing functions the elisp gate accepts for `transform' only.
Motion, search, and current-buffer mutation: enough for the transform
recipes (computed replacements, sexp-aware edits, reindentation)
without a path out of the buffer.  Deliberately absent: `set-buffer'
and friends (mutation must stay in the transform's target buffer),
the kill ring (`kill-region', `kill-sexp' — they overwrite the user's
clipboard; use `delete-region'), and the `replace-regexp' family
(their replacement strings evaluate embedded `\\,(...)' elisp,
bypassing this gate).  Extended by the resident user; gated elisp
cannot grow it.")
(put 'ch-emacs-config-mcp-agent-safe-editing-functions 'risky-local-variable t)

(defvar ch-emacs-config-mcp-lsp-timeout 5
  "Seconds before a synchronous LSP request degrades to a tool error.
Every LSP call runs inside the interactive session; the timeout keeps a
hung server from freezing both Emacs and the MCP bridge.")

(defvar ch-emacs-config-mcp-result-limit 100
  "Default cap on result lines the MCP tools return inline.")

;;; Shared helpers

(defun ch-emacs-config-mcp--opt (value)
  "VALUE, with the empty string normalized to nil (an omitted parameter)."
  (and value (not (equal value "")) value))

(defun ch-emacs-config-mcp--as-number (value name)
  "VALUE as a number; throw a tool error naming NAME when it is not one."
  (cond ((numberp value) value)
        ((and (stringp value) (string-match-p "\\`[0-9]+\\'" value))
         (string-to-number value))
        (t (mcp-server-lib-tool-throw
            (format "%s must be a positive integer, got %S" name value)))))

(defun ch-emacs-config-mcp--capped (lines limit what)
  "Join LINES up to LIMIT, appending the true total of WHAT when truncated."
  (let ((total (length lines))
        (limit (or limit ch-emacs-config-mcp-result-limit)))
    (if (<= total limit)
        (mapconcat #'identity lines "\n")
      (concat (mapconcat #'identity (seq-take lines limit) "\n")
              (format "\n... %d more (%d %s total)"
                      (- total limit) total what)))))

(defun ch-emacs-config-mcp--session-file-p (file)
  "Whether FILE lies in a project that already has buffers in this session."
  (when-let* ((project (project-current nil (file-name-directory file)))
              (root (expand-file-name (project-root project))))
    (seq-some (lambda (buffer)
                (when-let* ((name (buffer-file-name buffer)))
                  (string-prefix-p root (expand-file-name name))))
              (buffer-list))))

(defun ch-emacs-config-mcp--client-territory ()
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

(defun ch-emacs-config-mcp--territory-file-p (file)
  "Whether FILE lies inside the calling client's territory."
  (string-prefix-p (ch-emacs-config-mcp--client-territory)
                   (file-truename (expand-file-name file))))

(defun ch-emacs-config-mcp--check-file-write (file)
  "Throw a tool error when FILE is outside the calling client's territory.
The write-scope filter (`ch-emacs-config-mcp-write-scope'): the write
verbs only touch files under the client's own project, mirroring the
CLI-side workdir sandbox the MCP server would otherwise bypass."
  (when (and (eq ch-emacs-config-mcp-write-scope 'client-project)
             (not (ch-emacs-config-mcp--territory-file-p file)))
    (mcp-server-lib-tool-throw
     (format "%s is outside this session's territory %s (the project of the client's launch directory); MCP writes are confined to it (ch-emacs-config-mcp-write-scope)"
             file (ch-emacs-config-mcp--client-territory)))))

(defun ch-emacs-config-mcp--gate-elisp (form what editing)
  "Throw a tool error unless FORM passes the agent elisp safety gate.
WHAT names the tool for the error message.  With EDITING, the
buffer-editing registry is allowed too (the `transform' case).
The gate (`ch-emacs-config-mcp-elisp-scope') accepts only forms
`unsafep' proves harmless given Emacs's own safety metadata plus the
agent-safe registries; everything else — mutation, I/O, indirect
calls — is rejected before evaluation."
  (when (eq ch-emacs-config-mcp-elisp-scope 'agent-safe)
    (require 'unsafep)
    (let* ((safe-functions
            (if (eq safe-functions t)
                t
              (append ch-emacs-config-mcp-agent-safe-functions
                      (and editing
                           ch-emacs-config-mcp-agent-safe-editing-functions)
                      safe-functions)))
           (reason (unsafep form)))
      (when reason
        (mcp-server-lib-tool-throw
         (format "%s rejected as unsafe: %S. In agent-safe scope only elisp provably free of side effects runs (unsafep over Emacs's safety metadata plus the ch-emacs-config-mcp-agent-safe%s registries). %s"
                 what reason
                 (if editing "(-editing)" "")
                 (if editing
                     "Stick to motion, search, and current-buffer editing functions; anything else is the resident user's to allow."
                   "Reads are fine; for edits use edit-file, edit-buffer, or transform.")))))))

(defun ch-emacs-config-mcp--maybe-revert (buffer)
  "Revert BUFFER when it is unmodified but stale against its file.
Without this, tools reading buffer state quietly lie after files change
on disk (e.g. after the agent's own native edits)."
  (with-current-buffer buffer
    (when (and buffer-file-name
               (not (buffer-modified-p))
               (file-exists-p buffer-file-name)
               (not (verify-visited-file-modtime (current-buffer))))
      (revert-buffer :ignore-auto :noconfirm))))

(defun ch-emacs-config-mcp--file-buffer (file)
  "Live buffer visiting FILE; stale unmodified buffers are reverted first.
Unvisited files are opened (booting LSP via the usual mode hooks) when
`ch-emacs-config-mcp-auto-open-scope' allows it; otherwise this throws."
  (let* ((file (expand-file-name file))
         (buffer (find-buffer-visiting file)))
    (cond
     (buffer
      (ch-emacs-config-mcp--maybe-revert buffer)
      buffer)
     ((not (file-readable-p file))
      (mcp-server-lib-tool-throw (format "No readable file %s" file)))
     ((or (eq ch-emacs-config-mcp-auto-open-scope 'any-project)
          (ch-emacs-config-mcp--territory-file-p file)
          (ch-emacs-config-mcp--session-file-p file))
      (find-file-noselect file))
     (t
      (mcp-server-lib-tool-throw
       (format "%s is not visited and lies outside the client territory and every session project (auto-open scope: %s)"
               file ch-emacs-config-mcp-auto-open-scope))))))

(defun ch-emacs-config-mcp--call-at (file line col fn)
  "Call FN with FILE's buffer current and point at LINE:COL (1-based)."
  (let ((line (ch-emacs-config-mcp--as-number line "line"))
        (col (ch-emacs-config-mcp--as-number col "col")))
    (with-current-buffer (ch-emacs-config-mcp--file-buffer file)
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

(defun ch-emacs-config-mcp--unified-diff (old-file new-file old-label new-label)
  "Unified diff of OLD-FILE against NEW-FILE, labelled OLD-LABEL/NEW-LABEL."
  (with-temp-buffer
    (let ((status (call-process "diff" nil t nil "-u"
                                "--label" old-label "--label" new-label
                                old-file new-file)))
      (cond ((eq status 0) "")
            ((eq status 1) (buffer-string))
            (t (mcp-server-lib-tool-throw
                (format "diff failed (%s): %s" status (buffer-string))))))))

(defun ch-emacs-config-mcp--text-diff (old new old-label new-label)
  "Unified diff between the strings OLD and NEW."
  (let ((old-file (make-temp-file "mcp-diff-old"))
        (new-file (make-temp-file "mcp-diff-new")))
    (unwind-protect
        (let ((coding-system-for-write 'utf-8-unix))
          (write-region old nil old-file nil 'silent)
          (write-region new nil new-file nil 'silent)
          (ch-emacs-config-mcp--unified-diff
           old-file new-file old-label new-label))
      (delete-file old-file)
      (delete-file new-file))))

;;; Original tools

(defun ch-emacs-config-mcp--eval-elisp (elisp)
  "Evaluate ELISP and return the value of the last form, printed with %S.

Gated: in the default `agent-safe' scope only elisp provably free of
side effects is accepted (see `ch-emacs-config-mcp--gate-elisp'), so
this is a read-only escape hatch — inspecting variables, buffer state,
and session facts the dedicated tools don't cover.  Mutation belongs
to the edit verbs and `transform'.

MCP Parameters:
  elisp - Emacs Lisp source text; multiple forms allowed, evaluated in order"
  (mcp-server-lib-with-error-handling
    (let ((form (car (read-from-string (concat "(progn\n" elisp "\n)")))))
      (ch-emacs-config-mcp--gate-elisp form "eval-elisp" nil)
      (format "%S" (eval form t)))))

(defun ch-emacs-config-mcp--context ()
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

(defun ch-emacs-config-mcp--list-buffers ()
  "List live buffers, one per line: name | major mode | file.

MCP Parameters:"
  (mcp-server-lib-with-error-handling
    (mapconcat (lambda (buffer)
                 (with-current-buffer buffer
                   (format "%s | %s | %s"
                           (buffer-name)
                           major-mode
                           (or buffer-file-name ""))))
               (buffer-list)
               "\n")))

(defun ch-emacs-config-mcp--buffer-text (name &optional start-line end-line numbered)
  "Return the text of the buffer named NAME, without properties.

Optionally limited to the 1-based inclusive line range
START-LINE..END-LINE, for paging large buffers.  With NUMBERED, each
line is prefixed with its absolute line number in the buffer, matching
the agent's native Read format — use it when the answer will feed
line-addressed tools or the user needs line references.

MCP Parameters:
  name - name of a live buffer, as listed by the list-buffers tool
  start-line - first line to include (1-based; default 1)
  end-line - last line to include, inclusive (default: end of buffer)
  numbered - yes to prefix each line with its 1-based buffer line number"
  (mcp-server-lib-with-error-handling
    (let ((buffer (get-buffer name))
          (start-line (ch-emacs-config-mcp--opt start-line))
          (end-line (ch-emacs-config-mcp--opt end-line)))
      (unless buffer
        (mcp-server-lib-tool-throw (format "No buffer named %s" name)))
      (with-current-buffer buffer
        (save-excursion
          (save-restriction
            (widen)
            (let* ((from (if start-line
                             (ch-emacs-config-mcp--as-number start-line "start-line")
                           1))
                   (start (progn (goto-char (point-min))
                                 (forward-line (1- from))
                                 (point)))
                   (end (if end-line
                            (progn (goto-char (point-min))
                                   (forward-line
                                    (ch-emacs-config-mcp--as-number end-line "end-line"))
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

(defun ch-emacs-config-mcp--buffer-diagnostic-state (buffer)
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

(defun ch-emacs-config-mcp--file-diagnostics (file limit)
  "Diagnostics report for FILE's buffer, capped at LIMIT lines."
  (let* ((state (ch-emacs-config-mcp--buffer-diagnostic-state
                 (ch-emacs-config-mcp--file-buffer file)))
         (status (car state))
         (lines (cdr state))
         (body (and lines
                    (ch-emacs-config-mcp--capped lines limit "diagnostics"))))
    (pcase status
      ('checked (or body "No diagnostics (check finished)"))
      ('pending (concat (or body "No diagnostics yet")
                        "\n(check pending or running — not yet checked; retry shortly)"))
      ('no-checker (format "No checker enabled in the buffer visiting %s" file))
      (other (concat (or body "No diagnostics")
                     (format "\n(checker status: %s)" other))))))

(defun ch-emacs-config-mcp--all-diagnostics (limit)
  "Diagnostics report over all file-visiting buffers, capped at LIMIT lines."
  (let ((lines nil) (pending nil) (clean 0) (no-checker 0))
    (dolist (buffer (buffer-list))
      (when (buffer-file-name buffer)
        (ch-emacs-config-mcp--maybe-revert buffer)
        (let* ((state (ch-emacs-config-mcp--buffer-diagnostic-state buffer))
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
         (ch-emacs-config-mcp--capped lines limit "diagnostics")
       "No diagnostics")
     (format "\n(%d buffers checked clean, %d without a checker)"
             clean no-checker)
     (when pending
       (concat "\nStill checking (results incomplete): "
               (mapconcat #'identity (nreverse pending) ", "))))))

(defun ch-emacs-config-mcp--diagnostics (&optional file limit)
  "Current diagnostics as \"path:line:col: severity: message\" lines.

Covers FILE's buffer, or every file-visiting buffer when FILE is
omitted.  Diagnostics reflect buffers: stale unmodified buffers are
reverted first, and buffers whose check is still pending are reported as
such rather than as clean.

MCP Parameters:
  file - absolute path; omit to sweep all file-visiting buffers
  limit - max diagnostic lines returned inline (default 100)"
  (mcp-server-lib-with-error-handling
    (let ((file (ch-emacs-config-mcp--opt file))
          (limit (when-let* ((raw (ch-emacs-config-mcp--opt limit)))
                   (ch-emacs-config-mcp--as-number raw "limit"))))
      (if file
          (ch-emacs-config-mcp--file-diagnostics file limit)
        (ch-emacs-config-mcp--all-diagnostics limit)))))

;;; Xref-backed navigation

(defun ch-emacs-config-mcp--xref-line (item)
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

(defun ch-emacs-config-mcp--xref-items (kind file line col)
  "Xref items of KIND (`references' or `definitions') at FILE:LINE:COL."
  (ch-emacs-config-mcp--call-at
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
       (with-timeout (ch-emacs-config-mcp-lsp-timeout
                      (mcp-server-lib-tool-throw
                       (format "%s lookup timed out after %ds"
                               kind ch-emacs-config-mcp-lsp-timeout)))
         (if (eq kind 'references)
             (xref-backend-references backend identifier)
           (xref-backend-definitions backend identifier)))))))

(defun ch-emacs-config-mcp--find-references (file line col &optional limit)
  "References to the symbol at FILE:LINE:COL, one grep-format line each.

MCP Parameters:
  file - absolute path of the file
  line - 1-based line number of the symbol
  col - 1-based column of the symbol, as in grep line:col output
  limit - max lines returned inline (default 100)"
  (mcp-server-lib-with-error-handling
    (let ((items (ch-emacs-config-mcp--xref-items 'references file line col))
          (limit (when-let* ((raw (ch-emacs-config-mcp--opt limit)))
                   (ch-emacs-config-mcp--as-number raw "limit"))))
      (if (null items)
          "No references found"
        (ch-emacs-config-mcp--capped
         (mapcar #'ch-emacs-config-mcp--xref-line items)
         limit "references")))))

(defun ch-emacs-config-mcp--find-definition (file line col)
  "Definition(s) of the symbol at FILE:LINE:COL, one grep-format line each.

MCP Parameters:
  file - absolute path of the file
  line - 1-based line number of the symbol
  col - 1-based column of the symbol, as in grep line:col output"
  (mcp-server-lib-with-error-handling
    (let ((items (ch-emacs-config-mcp--xref-items 'definitions file line col)))
      (if (null items)
          "No definition found"
        (ch-emacs-config-mcp--capped
         (mapcar #'ch-emacs-config-mcp--xref-line items)
         nil "definitions")))))

;;; LSP hover

(defun ch-emacs-config-mcp--hover-string (contents)
  "Flatten LSP hover CONTENTS (MarkupContent, MarkedString, or list)."
  (cond
   ((null contents) "")
   ((stringp contents) contents)
   ((vectorp contents)
    (mapconcat #'ch-emacs-config-mcp--hover-string contents "\n"))
   ((plistp contents) (or (plist-get contents :value) ""))
   (t (format "%S" contents))))

(defun ch-emacs-config-mcp--symbol-info (file line col)
  "LSP hover (type signature and docs) for the symbol at FILE:LINE:COL.

MCP Parameters:
  file - absolute path of the file
  line - 1-based line number of the symbol
  col - 1-based column of the symbol"
  (mcp-server-lib-with-error-handling
    (ch-emacs-config-mcp--call-at
     file line col
     (lambda ()
       (let ((server (and (featurep 'eglot) (eglot-current-server))))
         (unless server
           (mcp-server-lib-tool-throw
            (format "No LSP (eglot) server manages %s" file)))
         (let* ((response (jsonrpc-request
                           server :textDocument/hover
                           (eglot--TextDocumentPositionParams)
                           :timeout ch-emacs-config-mcp-lsp-timeout))
                (text (ch-emacs-config-mcp--hover-string
                       (and response (plist-get response :contents)))))
           (if (string-empty-p text)
               "No hover information at this position"
             text)))))))

;;; Document outline

(defun ch-emacs-config-mcp--outline-lines (items depth)
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
                 (ch-emacs-config-mcp--outline-lines tail (1+ depth))))
          (t nil))))
     items)))

(defun ch-emacs-config-mcp--document-outline (file)
  "Outline of FILE (imenu / LSP documentSymbol) as a \"line: name\" tree.

MCP Parameters:
  file - absolute path of the file"
  (mcp-server-lib-with-error-handling
    (with-current-buffer (ch-emacs-config-mcp--file-buffer file)
      (require 'imenu)
      (let* ((imenu-auto-rescan t)
             (imenu-auto-rescan-maxout most-positive-fixnum)
             (index (save-excursion
                      (condition-case err
                          (imenu--make-index-alist t)
                        (error (mcp-server-lib-tool-throw
                                (format "No outline for %s: %s" file
                                        (error-message-string err)))))))
             (lines (ch-emacs-config-mcp--outline-lines index 0)))
        (if lines
            (ch-emacs-config-mcp--capped lines nil "entries")
          (format "No outline entries in %s" file))))))

;;; Unsaved buffer state

(defun ch-emacs-config-mcp--modified-buffers ()
  "File-visiting buffers whose content differs from disk, one path per line.

MCP Parameters:"
  (mcp-server-lib-with-error-handling
    (let (files)
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (and buffer-file-name (buffer-modified-p))
            (push buffer-file-name files))))
      (if files
          (mapconcat #'identity (nreverse files) "\n")
        "No file-visiting buffers have unsaved changes"))))

(defun ch-emacs-config-mcp--buffer-diff (file)
  "Unified diff of FILE's unsaved buffer state against the file on disk.

MCP Parameters:
  file - absolute path of a file visited by some buffer"
  (mcp-server-lib-with-error-handling
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
                  (let ((diff (ch-emacs-config-mcp--unified-diff
                               file temp
                               (concat file " (disk)")
                               (concat file " (buffer)"))))
                    (if (string-empty-p diff)
                        "Buffer matches disk (no unsaved changes)"
                      diff)))
              (delete-file temp))))))))

;;; Presenting to the user

(defvar ch-emacs-config-mcp-mermaid-timeout 30
  "Seconds before a mermaid render is killed and reported as a tool error.
A hung renderer must not freeze the interactive session.")

(defvar ch-emacs-config-mcp-mermaid-command '("mmdc")
  "Command list prefix for an mmdc-compatible mermaid renderer.
Input, output, and rendering flags are appended.  The home-manager
module points this at the nix-installed merman (the same drv the
language-server table spawns); the bare-name default only works when
an mmdc is on PATH.")

(defun ch-emacs-config-mcp--render-mermaid (source)
  "Render mermaid SOURCE to an SVG data string via the mmdc CLI.
The theme follows the selected frame's background mode.  Render errors
carry the renderer's own message, so the agent can fix the diagram
source from the tool error alone."
  (unless (executable-find (car ch-emacs-config-mcp-mermaid-command))
    (mcp-server-lib-tool-throw
     (format "%s (mmdc-compatible mermaid renderer) not found on PATH; cannot render mermaid"
             (car ch-emacs-config-mcp-mermaid-command))))
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
                        :command (append ch-emacs-config-mcp-mermaid-command
                                         (list "-i" in "-o" out "-q"
                                               "-c" config
                                               "-t" (if dark "dark" "default")
                                               "-b" (if dark "transparent" "white")))
                        :buffer log
                        :stderr log
                        :noquery t))
              (deadline (+ (float-time) ch-emacs-config-mcp-mermaid-timeout)))
          (while (and (process-live-p process) (< (float-time) deadline))
            (accept-process-output process 0.2))
          (when (process-live-p process)
            (delete-process process)
            (mcp-server-lib-tool-throw
             (format "mermaid render timed out after %ds"
                     ch-emacs-config-mcp-mermaid-timeout)))
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

(defun ch-emacs-config-mcp--set-major-mode (mode)
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

(defun ch-emacs-config-mcp--present (name content &optional mode display)
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
    (let ((mode (or (ch-emacs-config-mcp--opt mode) "markdown")))
      (unless (member mode '("markdown" "diff" "locations" "mermaid"))
        (mcp-server-lib-tool-throw
         (format "Unknown mode %s (expected markdown, diff, locations, or mermaid)"
                 mode)))
      (let ((svg (and (equal mode "mermaid")
                      (ch-emacs-config-mcp--render-mermaid content)))
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
             (ch-emacs-config-mcp--set-major-mode #'markdown-ts-mode)
             (visual-line-mode 1))
            ("diff" (ch-emacs-config-mcp--set-major-mode #'diff-mode))
            ("locations"
             (ch-emacs-config-mcp--set-major-mode #'fundamental-mode)
             (compilation-minor-mode 1))
            ("mermaid"
             (ch-emacs-config-mcp--set-major-mode #'fundamental-mode)))
          (set-buffer-modified-p nil)
          (goto-char (point-min)))
        (if (equal display "no")
            (format "Wrote %s (not displayed)" (buffer-name buffer))
          (display-buffer buffer)
          (format "Presented %s" (buffer-name buffer)))))))

;;; Sidebars

(defcustom ch-emacs-config-mcp-sidebar-width 0.2
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

(defun ch-emacs-config-mcp--sidebar (name content &optional display)
  "Show CONTENT beside the user's work in a right-hand sidebar window.

A sidebar is for material the user reads once alongside the main
reply — anticipated questions with answers, a glossary, a checklist —
not for an artifact they will keep open (use `present' for that).  The
buffer *agent/sidebar/NAME* holds CONTENT as soft-wrapped, read-only
markdown and is shown in a side window on the frame's right edge at
`ch-emacs-config-mcp-sidebar-width' of the frame width; `q' in it closes
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
        (ch-emacs-config-mcp--set-major-mode #'markdown-ts-mode)
        (visual-line-mode 1)
        (ch-emacs-config-sidebar-mode 1)
        (set-buffer-modified-p nil)
        (goto-char (point-min)))
      (if (equal display "no")
          (format "Wrote %s (not displayed)" (buffer-name buffer))
        (display-buffer buffer
                        `((display-buffer-in-side-window)
                          (side . right)
                          (slot . 0)
                          (window-width . ,ch-emacs-config-mcp-sidebar-width)))
        (format "Presented %s in a sidebar" (buffer-name buffer))))))

;;; The editing engine

(defun ch-emacs-config-mcp--transform (file elisp &optional save)
  "Run ELISP with FILE's buffer current; return a unified diff of the change.

For bulk/structural edits where one form beats many single edits:
computed replacements, sexp-aware transforms, mode-canonical
`indent-region'.  Gated twice: FILE must lie in the calling client's
territory (`ch-emacs-config-mcp--check-file-write'), and ELISP must
pass the agent-safe gate with the buffer-editing registry allowed
(motion, search, current-buffer mutation — see
`ch-emacs-config-mcp-agent-safe-editing-functions').  Refuses buffers
holding unsaved user modifications.  Begin with (goto-char
\(point-min)) — point is wherever the user left it.  On error the
buffer is restored untouched.  Saves unless SAVE is no.

MCP Parameters:
  file - absolute path of the file to transform
  elisp - elisp source run with the buffer current; edits the buffer
      directly via buffer functions
  save - no to leave the change unsaved in the buffer (default: save)"
  (mcp-server-lib-with-error-handling
    (ch-emacs-config-mcp--check-file-write file)
    (let ((form (car (read-from-string (concat "(progn\n" elisp "\n)")))))
      (ch-emacs-config-mcp--gate-elisp form "transform" t)
      (with-current-buffer (ch-emacs-config-mcp--file-buffer file)
        (when (buffer-modified-p)
          (mcp-server-lib-tool-throw
           (format "%s has unsaved modifications; refusing to transform (see buffer-diff)"
                   file)))
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
                  (let ((diff (ch-emacs-config-mcp--text-diff
                               old new
                               (concat file " (before)")
                               (concat file " (after)"))))
                    (unless (equal save "no")
                      (save-buffer))
                    diff))))))))))

(defun ch-emacs-config-mcp--replace-literal (label old-string new-string replace-all)
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
        (ch-emacs-config-mcp--text-diff
         old
         (buffer-substring-no-properties (point-min) (point-max))
         (concat label " (before)")
         (concat label " (after)"))))))

(defun ch-emacs-config-mcp--edit-buffer (old-string new-string buffer &optional replace-all)
  "Replace OLD-STRING with NEW-STRING in live BUFFER, exactly once by default.

The buffer-target editing verb: buffer mutation only, never a disk
write — the disk half lives in `ch-emacs-config-mcp--edit-file', a
separate tool name so restricted dispatch profiles can withhold disk
writing structurally (consent-gate.md).  The contract mirrors the
agent's native Edit tool so its editing instincts transfer (see
`ch-emacs-config-mcp--replace-literal'), and the unified diff returned
is the verification step.  Non-file buffers (e.g. *agent/...*
collaboration buffers) are edited in place; a file-visiting buffer is
left modified — a staged edit the user reviews and saves.  Unsaved
user modifications are therefore workable state here, not an error:
the change stays in the buffer under the user's eyes, and the
uniqueness rule is the drift guard against their concurrent editing.
A buffer backed by a file outside the calling client's territory is
refused (`ch-emacs-config-mcp--check-file-write'); buffers without a
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
      ;; when the mutation never writes disk; territory applies.
      (when file
        (ch-emacs-config-mcp--check-file-write file))
      (with-current-buffer target
        (ch-emacs-config-mcp--replace-literal
         buffer old-string new-string (equal replace-all "yes"))))))

(defun ch-emacs-config-mcp--edit-file (old-string new-string file &optional replace-all)
  "Replace OLD-STRING with NEW-STRING in FILE and save, exactly once by default.

The file-target editing verb — the one that writes disk, a separate
tool name from `ch-emacs-config-mcp--edit-buffer' so restricted
dispatch profiles can withhold disk writing structurally
\(consent-gate.md).  Same native-Edit contract (see
`ch-emacs-config-mcp--replace-literal'); returns the unified diff.
FILE must lie in the calling client's territory
\(`ch-emacs-config-mcp--check-file-write').
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
    (ch-emacs-config-mcp--check-file-write file)
    (with-current-buffer (ch-emacs-config-mcp--file-buffer file)
      (when (buffer-modified-p)
        (mcp-server-lib-tool-throw
         (format "%s has unsaved modifications; refusing to write disk over newer buffer state (see buffer-diff, or stage the change with edit-buffer)"
                 file)))
      (prog1 (ch-emacs-config-mcp--replace-literal
              file old-string new-string (equal replace-all "yes"))
        (save-buffer)))))

;;; Comment threads (collab-comments)

(defun ch-emacs-config-mcp--add-comment (text &optional file buffer anchor thread)
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
    (let ((file (ch-emacs-config-mcp--opt file))
          (buffer-name (ch-emacs-config-mcp--opt buffer))
          (anchor (ch-emacs-config-mcp--opt anchor))
          (thread (ch-emacs-config-mcp--opt thread)))
      (when (string-empty-p (string-trim text))
        (mcp-server-lib-tool-throw "text must be non-empty"))
      (cond
       (thread
        (when (or file buffer-name anchor)
          (mcp-server-lib-tool-throw
           "Pass thread alone (reply) or file/buffer with anchor (new thread)"))
        (let* ((id (ch-emacs-config-mcp--as-number thread "thread"))
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
                          (ch-emacs-config-mcp--file-buffer file)
                        (or (get-buffer buffer-name)
                            (mcp-server-lib-tool-throw
                             (format "No buffer named %s" buffer-name)))))
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

(defun ch-emacs-config-mcp--list-comments (&optional file buffer)
  "Comment threads with their ids, anchors, authors, and bodies.

Covers the buffer named by FILE or BUFFER, or every buffer when both
are omitted.  User comments show up here; reply to a thread by id via
add-comment.

MCP Parameters:
  file - absolute path; only threads in the buffer visiting it
  buffer - buffer name; only threads in that buffer"
  (mcp-server-lib-with-error-handling
    (require 'collab-comments)
    (let* ((file (ch-emacs-config-mcp--opt file))
           (buffer-name (ch-emacs-config-mcp--opt buffer))
           (threads
            (cond
             (file
              (collab-comments-threads
               (or (find-buffer-visiting (expand-file-name file))
                   (mcp-server-lib-tool-throw
                    (format "No buffer is visiting %s" file)))))
             (buffer-name
              (collab-comments-threads
               (or (get-buffer buffer-name)
                   (mcp-server-lib-tool-throw
                    (format "No buffer named %s" buffer-name)))))
             (t (collab-comments-all-threads)))))
      (if (null threads)
          "No comment threads"
        (mapconcat #'collab-comments-render-thread threads "\n\n")))))

;;; Server lifecycle and registration

(defun ch-emacs-config-mcp-server-start ()
  "Start handling MCP requests.  Idempotent: concurrent MCP clients each
call this via the stdio bridge's --init-function, and the first one wins.
No paired stop function is wired up, so one client exiting cannot stall
the others."
  (unless (bound-and-true-p mcp-server-lib--running)
    (mcp-server-lib-start))
  t)

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
           "reading the user's notes -> list-comments. eval-elisp is "
           "the read-only escape hatch for everything else: it accepts "
           "side-effect-free elisp only, and writes are confined to the "
           "session's own project.")
   :tools
   (list
    (list #'ch-emacs-config-mcp--eval-elisp
          :id "eval-elisp"
          :description
          "Evaluate side-effect-free Emacs Lisp in the running Emacs and return the result (mutation is rejected; use the edit tools)")
    (list #'ch-emacs-config-mcp--context
          :id "context"
          :description
          "Where the user is: buffer, file, project, defun, region, visible windows"
          :read-only t)
    (list #'ch-emacs-config-mcp--list-buffers
          :id "list-buffers"
          :description "List live buffers with their major modes and files"
          :read-only t)
    (list #'ch-emacs-config-mcp--buffer-text
          :id "buffer-text"
          :description "Text of a named buffer, optionally a 1-based line range"
          :read-only t)
    (list #'ch-emacs-config-mcp--diagnostics
          :id "diagnostics"
          :description
          "Current errors/warnings from the session's checkers, as path:line:col lines"
          :read-only t)
    (list #'ch-emacs-config-mcp--find-references
          :id "find-references"
          :description
          "References to the symbol at file:line:col (LSP/xref), grep-format lines"
          :read-only t)
    (list #'ch-emacs-config-mcp--find-definition
          :id "find-definition"
          :description
          "Definition of the symbol at file:line:col (LSP/xref), grep-format lines"
          :read-only t)
    (list #'ch-emacs-config-mcp--symbol-info
          :id "symbol-info"
          :description
          "Type signature and docs (LSP hover) for the symbol at file:line:col"
          :read-only t)
    (list #'ch-emacs-config-mcp--document-outline
          :id "document-outline"
          :description
          "Outline of a file (imenu/LSP) as an indented line: name tree"
          :read-only t)
    (list #'ch-emacs-config-mcp--modified-buffers
          :id "modified-buffers"
          :description
          "Files with unsaved buffer changes; check before editing near the user"
          :read-only t)
    (list #'ch-emacs-config-mcp--buffer-diff
          :id "buffer-diff"
          :description
          "Unified diff of a file's unsaved buffer state vs the file on disk"
          :read-only t)
    (list #'ch-emacs-config-mcp--present
          :id "present"
          :description
          "Present content to the user in an *agent/...* Emacs buffer (markdown, diff, clickable locations, or a rendered mermaid diagram)")
    (list #'ch-emacs-config-mcp--sidebar
          :id "sidebar"
          :description
          "Show read-once markdown (anticipated questions, a glossary, a checklist) in a right-hand sidebar window the user dismisses with q")
    (list #'ch-emacs-config-mcp--edit-buffer
          :id "edit-buffer"
          :description
          "Replace a literal string in a live buffer, never writing disk (must match exactly once unless replace-all=yes); returns a unified diff")
    (list #'ch-emacs-config-mcp--edit-file
          :id "edit-file"
          :description
          "Replace a literal string in a file and save it (must match exactly once unless replace-all=yes); returns a unified diff")
    (list #'ch-emacs-config-mcp--transform
          :id "transform"
          :description
          "Eval buffer-editing elisp (motion/search/current-buffer mutation only) in a file's buffer for bulk/structural edits; returns a unified diff; saves unless save=no")
    (list #'ch-emacs-config-mcp--add-comment
          :id "add-comment"
          :description
          "Comment on buffer text: start a thread on a unique literal anchor, or reply to a thread id; never modifies the text")
    (list #'ch-emacs-config-mcp--list-comments
          :id "list-comments"
          :description
          "Comment threads (ids, anchors, authors, bodies) in one buffer or everywhere"
          :read-only t))))

