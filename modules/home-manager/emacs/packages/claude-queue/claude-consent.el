;;; claude-consent.el --- Consent spool for headless Claude sessions -*- lexical-binding: t -*-
;; SPDX-License-Identifier: MIT

;;; Commentary:
;; The Emacs half of the consent-gate design (ch-nix-workspace
;; docs/development/consent-gate.md).  Dispatched headless Claude Code
;; sessions run under a PreToolUse territory classifier
;; (emacs-claude-consent-hook); when a session's Edit/Write leaves its
;; territory, the blocked hook writes a request into the
;; pending-consent spool ($XDG_RUNTIME_DIR/claude-consent) and polls
;; for an answer file.  This package is the viewer/answerer over that
;; spool: a filenotify-driven list of pending requests, a detail view
;; of the escalated edit, per-request allow/deny, and the
;; territory-record API the dispatcher (claude-queue) writes through.
;;
;; Emacs never talks to the CLI -- the blocked hook process is the
;; verdict courier in both directions -- so an Emacs restart just
;; re-reads the spool, and requests whose hook process died are pruned
;; on read rather than trusting cleanup events.  Answers are per-call
;; and never memoized: a re-ask re-escalates.  A session parked in the
;; hook reports working/busy to the CLI, never blocked; the queue list
;; joins this spool by session id to show "consent ‹n›", and the
;; global mode's mode-line count covers frames without a list.

;;; Code:

(require 'filenotify)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)

(defgroup claude-consent nil
  "Answer consent requests from headless Claude Code sessions."
  :group 'tools
  :prefix "claude-consent-")

(defcustom claude-consent-directory
  (expand-file-name "claude-consent"
                    (or (getenv "XDG_RUNTIME_DIR")
                        (format "/run/user/%d" (user-uid))))
  "Consent spool directory shared with the PreToolUse hook.
Holds territory/ (dispatch-time grants keyed by agent id), pending/
(requests written by blocked hooks), and answers/ (verdicts written
here, picked up by the hook's poll)."
  :type 'directory
  :group 'claude-consent)

(defconst claude-consent--list-buffer "*claude-consent*"
  "Name of the pending-request list buffer.")

;;; Spool primitives

(defun claude-consent--subdirectory (name)
  "Absolute path of spool subdirectory NAME."
  (expand-file-name name claude-consent-directory))

(defun claude-consent-ensure-directories ()
  "Create the spool layout owner-only and return the spool root."
  (dolist (dir (list claude-consent-directory
                     (claude-consent--subdirectory "territory")
                     (claude-consent--subdirectory "pending")
                     (claude-consent--subdirectory "answers")))
    (make-directory dir t))
  (set-file-modes claude-consent-directory #o700)
  claude-consent-directory)

(defun claude-consent--read-json (file)
  "Parse FILE as JSON into an alist, or nil on any failure."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file)
        (json-parse-buffer :object-type 'alist :array-type 'list
                           :null-object nil :false-object nil))
    (error nil)))

(defun claude-consent--write-json (file object)
  "Serialize OBJECT (an alist) to FILE atomically (write then rename).
The hook polls the answers directory, so a partially written file
must never be visible under its final name.

The file is a protocol surface read by the bash hook, so it is
always UTF-8 regardless of the daemon's locale.  `json-serialize'
returns a unibyte string (Emacs 30); inserting that as-is would
plant raw-byte characters in the buffer, which no Unicode coding
system accepts, and `write-region' would then stop to ask the user
for a coding system on every non-ASCII name."
  (let ((tmp (concat file ".tmp"))
        (coding-system-for-write 'utf-8-unix))
    (with-temp-file tmp
      (insert (decode-coding-string (json-serialize object) 'utf-8)))
    (rename-file tmp file t)))

;;; Territory records (the dispatcher's API)

(defun claude-consent-record-territory (agent-id roots &optional deadline name)
  "Record dispatch-time territory for the session known as AGENT-ID.
AGENT-ID is the CLI's agent id -- the leading 8 hex digits of the
session UUID, which is how the hook joins a session to its record.
ROOTS is the list of directories granted by the dispatch itself (the
grant is structural, recorded here, never parsed from instruction
text).  DEADLINE bounds each escalation in seconds -- unanswered
requests self-deny so a forgotten consent cannot freeze the queue's
FIFO -- and NAME labels escalations in the viewer.  Returns the
record's file name."
  (claude-consent-ensure-directories)
  (let ((file (expand-file-name (concat agent-id ".json")
                                (claude-consent--subdirectory "territory"))))
    (claude-consent--write-json
     file
     (append
      `((agent_id . ,agent-id)
        (roots . ,(vconcat (mapcar (lambda (root)
                                     (directory-file-name
                                      (expand-file-name root)))
                                   roots)))
        (created . ,(floor (float-time))))
      (when deadline `((deadline . ,deadline)))
      (when name `((name . ,name)))))
    file))

(defun claude-consent-remove-territory (agent-id)
  "Delete the territory record for AGENT-ID, if any."
  (let ((file (expand-file-name (concat agent-id ".json")
                                (claude-consent--subdirectory "territory"))))
    (when (file-exists-p file)
      (ignore-errors (delete-file file)))))

;;; Pending requests

(defun claude-consent--hook-live-p (request)
  "Whether the hook process that spooled REQUEST is still alive."
  (when-let* ((pid (alist-get 'pid request)))
    (file-directory-p (format "/proc/%s" pid))))

(defun claude-consent--answer-file (id)
  "Answer-file path for request ID."
  (expand-file-name (concat id ".json")
                    (claude-consent--subdirectory "answers")))

(defun claude-consent-pending-requests ()
  "Pending consent requests as alists, oldest first.
A killed session orphans its request, so entries whose hook pid is
dead are pruned here -- on read -- along with any answer file they
never consumed; unparseable files are skipped."
  (let ((dir (claude-consent--subdirectory "pending"))
        (requests nil))
    (when (file-directory-p dir)
      (dolist (file (directory-files dir t "\\.json\\'"))
        (when-let* ((request (claude-consent--read-json file)))
          (if (claude-consent--hook-live-p request)
              (push request requests)
            (ignore-errors (delete-file file))
            (when-let* ((id (alist-get 'id request)))
              (ignore-errors (delete-file (claude-consent--answer-file id))))))))
    (seq-sort-by (lambda (request) (or (alist-get 'created request) 0))
                 #'< requests)))

(defun claude-consent-session-pending-count (id &optional requests)
  "Count pending requests for the session matching ID.
ID may be a full session UUID or a prefix (the CLI's 8-hex agent id).
REQUESTS avoids a re-read when the caller already fetched
`claude-consent-pending-requests'."
  (seq-count (lambda (request)
               (string-prefix-p id (or (alist-get 'session_id request) "")))
             (or requests (claude-consent-pending-requests))))

(defun claude-consent--remaining (request)
  "Seconds until REQUEST's deadline, never negative."
  (max 0 (- (or (alist-get 'deadline request) 0) (floor (float-time)))))

(defun claude-consent--format-remaining (seconds)
  "Render SECONDS of remaining deadline compactly."
  (cond ((zerop seconds) "expired")
        ((< seconds 60) (format "%ds" seconds))
        (t (format "%dm%02ds" (/ seconds 60) (% seconds 60)))))

;;; Answering

(defvar-local claude-consent--request nil
  "Request rendered by this detail buffer, or nil elsewhere.")

(defun claude-consent--deliver (request decision &optional reason)
  "Write DECISION (`allow' or `deny') for REQUEST, with optional REASON.
The blocked hook's poll picks the answer up and emits the
permissionDecision; the answer covers exactly this request and is
never replayed -- a re-ask re-escalates."
  (let ((id (alist-get 'id request)))
    (unless id
      (user-error "Malformed consent request (no id)"))
    (unless (claude-consent--hook-live-p request)
      (user-error "The requesting hook is gone; nothing to answer"))
    (claude-consent--write-json
     (claude-consent--answer-file id)
     (append `((id . ,id)
               (decision . ,(symbol-name decision)))
             (when (and reason (not (string-blank-p reason)))
               `((reason . ,reason)))))
    (message "claude-consent: %s %s -> %s"
             (symbol-name decision)
             (or (alist-get 'tool_name request) "?")
             (alist-get 'target request))))

(defun claude-consent--request-here ()
  "The consent request this buffer or line refers to."
  (or claude-consent--request
      (tabulated-list-get-id)
      (user-error "No consent request here")))

(defun claude-consent-allow ()
  "Allow the consent request at point (this call only)."
  (interactive)
  (claude-consent--deliver (claude-consent--request-here) 'allow)
  (claude-consent--after-answer))

(defun claude-consent-deny (reason)
  "Deny the consent request at point, sending REASON back to the model."
  (interactive (list (read-string "Deny reason (returned to the model): ")))
  (claude-consent--deliver (claude-consent--request-here) 'deny reason)
  (claude-consent--after-answer))

(defun claude-consent--after-answer ()
  "Leave an answered detail view; refresh what remains."
  (when claude-consent--request
    (quit-window t))
  (claude-consent--refresh))

;;; Detail view

(defvar claude-consent-detail-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "a" #'claude-consent-allow)
    (define-key map "d" #'claude-consent-deny)
    map)
  "Keymap for `claude-consent-detail-mode'.")

(define-derived-mode claude-consent-detail-mode special-mode "Claude-Consent-Detail"
  "One escalated edit, rendered for a decision.

\\{claude-consent-detail-mode-map}")

(defun claude-consent--insert-section (title text)
  "Insert a titled TEXT section; TITLE names it."
  (insert (propertize (format "--- %s\n" title) 'face 'shadow))
  (insert text)
  (unless (or (string-empty-p text) (string-suffix-p "\n" text))
    (insert "\n")))

(defun claude-consent--render-request (request)
  "Fill the current buffer with a decision view of REQUEST."
  (let* ((input (alist-get 'tool_input request))
         (territory (alist-get 'territory request))
         (tool (or (alist-get 'tool_name request) "?"))
         (target (or (alist-get 'target request)
                     (alist-get 'file_path input)
                     "?")))
    (insert (propertize (format "%s outside territory\n" tool) 'face 'warning))
    (insert (format "Session:   %s%s\n"
                    (or (alist-get 'session_id request) "?")
                    (if-let* ((name (alist-get 'name territory)))
                        (format "  (%s)" name)
                      "")))
    (insert (format "Target:    %s\n" (abbreviate-file-name target)))
    (insert (format "Cwd:       %s\n"
                    (abbreviate-file-name (or (alist-get 'cwd request) "?"))))
    (insert (format "Territory: %s\n"
                    (mapconcat #'abbreviate-file-name
                               (alist-get 'roots territory)
                               ", ")))
    (insert (format "Deadline:  %s\n"
                    (claude-consent--format-remaining
                     (claude-consent--remaining request))))
    (when-let* ((buffer (find-buffer-visiting target)))
      (when (buffer-modified-p buffer)
        (insert (propertize
                 "Note: a live buffer visits this file with unsaved changes;\nwhat is on disk is not the newest state.\n"
                 'face 'warning))))
    (insert "\n")
    (pcase tool
      ("Edit"
       (claude-consent--insert-section
        "replaces" (or (alist-get 'old_string input) ""))
       (claude-consent--insert-section
        "with" (or (alist-get 'new_string input) "")))
      ("Write"
       (when (file-exists-p target)
         (insert (propertize "Overwrites an existing file.\n" 'face 'warning)))
       (claude-consent--insert-section
        "content" (or (alist-get 'content input) "")))
      (_
       (claude-consent--insert-section "tool input"
                                       (format "%S" input))))
    (insert (substitute-command-keys
             "\nType \\[claude-consent-allow] to allow this call, \\[claude-consent-deny] to deny with a reason.\n"))))

(defun claude-consent-open ()
  "Show the consent request at point in a detail buffer."
  (interactive)
  (let ((request (claude-consent--request-here)))
    (with-current-buffer
        (get-buffer-create (format "*claude-consent %s*"
                                   (or (alist-get 'id request) "?")))
      (claude-consent-detail-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (claude-consent--render-request request))
      (goto-char (point-min))
      (setq claude-consent--request request)
      (pop-to-buffer (current-buffer)))))

;;; List view

(defvar claude-consent-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'claude-consent-open)
    (define-key map "a" #'claude-consent-allow)
    (define-key map "d" #'claude-consent-deny)
    map)
  "Keymap for `claude-consent-list-mode'.")

(define-derived-mode claude-consent-list-mode tabulated-list-mode "Claude-Consent"
  "Pending consent requests from headless Claude Code sessions.

Each row is one blocked tool call waiting on an answer; RET shows
the full edit, `a' allows exactly that call, `d' denies it with a
reason that reaches the model verbatim.  Unanswered requests
self-deny at their deadline; rows whose session died are pruned on
refresh.

\\{claude-consent-list-mode-map}"
  (setq tabulated-list-format
        [("When" 5 nil)
         ("Session" 12 nil)
         ("Tool" 5 nil)
         ("Left" 7 nil)
         ("Target" 0 nil)])
  (setq tabulated-list-sort-key nil)
  (setq-local revert-buffer-function (lambda (&rest _)
                                       (claude-consent--refresh)))
  (tabulated-list-init-header))

(defun claude-consent--list-entries (requests)
  "Rows for the list buffer from REQUESTS."
  (mapcar (lambda (request)
            (let ((territory (alist-get 'territory request)))
              (list request
                    (vector
                     (format-time-string
                      "%H:%M" (or (alist-get 'created request) 0))
                     (or (alist-get 'name territory)
                         (substring (or (alist-get 'session_id request) "?")
                                    0 (min 8 (length (or (alist-get 'session_id request) "?")))))
                     (or (alist-get 'tool_name request) "?")
                     (claude-consent--format-remaining
                      (claude-consent--remaining request))
                     (abbreviate-file-name
                      (or (alist-get 'target request) "?"))))))
          requests))

;;;###autoload
(defun claude-consent-list ()
  "Show pending consent requests."
  (interactive)
  (with-current-buffer (get-buffer-create claude-consent--list-buffer)
    (unless (derived-mode-p 'claude-consent-list-mode)
      (claude-consent-list-mode))
    (claude-consent--refresh)
    (pop-to-buffer (current-buffer))))

;;; Watcher and mode-line

(defvar claude-consent--watch nil
  "Active filenotify descriptor on the pending directory, or nil.")

(defvar claude-consent--pending-count 0
  "Pending requests at the last refresh, for the mode-line count.")

(defconst claude-consent--mode-line-construct
  '(:eval (claude-consent--mode-line))
  "Entry added to `global-mode-string' while the mode is on.")

(defun claude-consent--mode-line ()
  "Mode-line fragment: the pending count, or nil when quiet."
  (when (> claude-consent--pending-count 0)
    (propertize (format " consent‹%d›" claude-consent--pending-count)
                'face 'warning)))

(defun claude-consent--refresh (&rest _)
  "Re-read the spool: update the count, the list buffer, the mode-line."
  (let* ((requests (claude-consent-pending-requests))
         (count (length requests)))
    (when (> count claude-consent--pending-count)
      (message "claude-consent: %d request%s awaiting an answer (M-x claude-consent-list)"
               count (if (= count 1) "" "s")))
    (setq claude-consent--pending-count count)
    (when-let* ((buffer (get-buffer claude-consent--list-buffer)))
      (with-current-buffer buffer
        (setq tabulated-list-entries (claude-consent--list-entries requests))
        (tabulated-list-print t)))
    (force-mode-line-update t)))

;;;###autoload
(define-minor-mode claude-consent-mode
  "Watch the consent spool and surface pending requests.
Arms a filenotify watch on the pending directory, keeps a mode-line
count of unanswered requests, and refreshes the
`claude-consent-list' buffer as requests arrive and resolve.  Enable
in the resident session that answers for dispatched agents."
  :global t
  :group 'claude-consent
  (if claude-consent-mode
      (condition-case err
          (progn
            (claude-consent-ensure-directories)
            (setq claude-consent--watch
                  (file-notify-add-watch
                   (claude-consent--subdirectory "pending")
                   '(change) #'claude-consent--refresh))
            (unless global-mode-string
              (setq global-mode-string '("")))
            (unless (memq claude-consent--mode-line-construct global-mode-string)
              (setq global-mode-string
                    (append global-mode-string
                            (list claude-consent--mode-line-construct))))
            (claude-consent--refresh))
        (error
         (setq claude-consent-mode nil)
         (message "claude-consent: spool unavailable, mode stays off (%s)"
                  (error-message-string err))))
    (when claude-consent--watch
      (ignore-errors (file-notify-rm-watch claude-consent--watch))
      (setq claude-consent--watch nil))
    (setq global-mode-string
          (delq claude-consent--mode-line-construct global-mode-string))
    (setq claude-consent--pending-count 0)))

(provide 'claude-consent)
;;; claude-consent.el ends here
