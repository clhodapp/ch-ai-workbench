;;; claude-consent.el --- Answer Claude Code hook prompts from Emacs -*- lexical-binding: t -*-
;; SPDX-License-Identifier: MIT

;;; Commentary:
;; The Emacs answerer for the consent spool (ch-nix-workspace
;; docs/development/consent-gate.md).  Claude Code hooks raise
;; questions for the user through `claude-consent ask', which writes a
;; pending record into $XDG_RUNTIME_DIR/claude-consent and waits for
;; an answer file; this package is one answerer over that spool: a
;; filenotify-driven list of open prompts, a detail view (the
;; escalated edit, rendered from the hook payload the record carries),
;; and a menu over the prompt's options, plus the territory-record API
;; the dispatcher (claude-queue) writes through.
;;
;; While `claude-consent-mode' is on, Emacs is registered as an
;; attached answerer (handlers/emacs.json, keyed by this process's
;; pid); a hook that finds an attached answerer waits for its answer,
;; and one that finds none falls back to the CLI's own prompt or to a
;; stored answer given later in a terminal (`claude-consent answer').
;; Emacs never talks to the CLI -- the waiting hook process is the
;; verdict courier -- so an Emacs restart just re-reads the spool.
;; Records whose waiter is gone, or whose stored deadline passed, are
;; pruned on read rather than trusting cleanup events.  Answers are
;; per-request and never memoized: a re-ask re-escalates.  A session
;; parked in a hook reports working/busy to the CLI, never blocked;
;; the queue list joins this spool by session id to show "consent
;; ‹n›", and the global mode's mode-line count covers frames without
;; a list.

;;; Code:

(require 'cl-lib)
(require 'filenotify)
(require 'seq)
(require 'subr-x)
(require 'tabulated-list)

(defgroup claude-consent nil
  "Answer prompts raised by Claude Code hooks."
  :group 'tools
  :prefix "claude-consent-")

(defcustom claude-consent-directory
  (expand-file-name "claude-consent"
                    (or (getenv "XDG_RUNTIME_DIR")
                        (format "/run/user/%d" (user-uid))))
  "Consent spool directory shared with the hooks (`claude-consent').
Holds territory/ (dispatch-time grants keyed by agent id), handlers/
(attached answerers), pending/ (prompts written by hooks), answers/
(answers written here, picked up by the waiting hook), and log/
(output of asynchronous re-entries)."
  :type 'directory
  :group 'claude-consent)

(defconst claude-consent--list-buffer "*claude-consent*"
  "Name of the pending-prompt list buffer.")

(defconst claude-consent--handler-name "emacs"
  "This answerer's name in the spool's handlers/ directory.")

;;; Spool primitives

(defun claude-consent--subdirectory (name)
  "Absolute path of spool subdirectory NAME."
  (expand-file-name name claude-consent-directory))

(defun claude-consent-ensure-directories ()
  "Create the spool layout owner-only and return the spool root."
  (dolist (dir (cons claude-consent-directory
                     (mapcar #'claude-consent--subdirectory
                             '("territory" "handlers" "pending" "answers" "log"))))
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
Every reader polls, so a partially written file must never be
visible under its final name.

The file is a protocol surface read by other programs, so it is
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

(defun claude-consent--pid-live-p (pid)
  "Whether process PID exists."
  (and pid (file-directory-p (format "/proc/%s" pid))))

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

;;; Handler registration (this Emacs as an attached answerer)

(defun claude-consent--handler-file ()
  "Path of this answerer's registration in the spool."
  (expand-file-name (concat claude-consent--handler-name ".json")
                    (claude-consent--subdirectory "handlers")))

(defun claude-consent-register-handler ()
  "Register this Emacs as an attached answerer, keyed by its pid.
A hook finding a live registration waits for an answer from the
spool instead of falling back; the registration is live exactly as
long as this process is, so a crash needs no cleanup."
  (claude-consent-ensure-directories)
  (claude-consent--write-json
   (claude-consent--handler-file)
   `((name . ,claude-consent--handler-name)
     (pid . ,(emacs-pid))
     (created . ,(floor (float-time)))))
  (claude-consent--handler-file))

(defun claude-consent-remove-handler ()
  "Withdraw this Emacs as an attached answerer."
  (let ((file (claude-consent--handler-file)))
    (when (file-exists-p file)
      (ignore-errors (delete-file file)))))

;;; Pending requests

(defun claude-consent--request-stale-p (request)
  "Whether nothing can still consume REQUEST.
A blocking or waiter record is stale once the process named by its
pid is gone; a stored record (nobody waits, the answer is kept for a
later ask) is stale once its deadline passed."
  (if (equal (alist-get 'mode request) "stored")
      (let ((deadline (alist-get 'deadline request)))
        (and (numberp deadline) (<= deadline (float-time))))
    (not (claude-consent--pid-live-p (alist-get 'pid request)))))

(defun claude-consent--answer-file (id)
  "Answer-file path for request ID."
  (expand-file-name (concat id ".json")
                    (claude-consent--subdirectory "answers")))

(defun claude-consent-pending-requests ()
  "Pending requests as alists, oldest first.
Stale entries (see `claude-consent--request-stale-p') are pruned
here -- on read -- along with any answer file they never consumed;
unparseable files are skipped."
  (let ((dir (claude-consent--subdirectory "pending"))
        (requests nil))
    (when (file-directory-p dir)
      (dolist (file (directory-files dir t "\\.json\\'"))
        (when-let* ((request (claude-consent--read-json file)))
          (if (not (claude-consent--request-stale-p request))
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

;;; The prompt inside a request

(defun claude-consent--prompt (request)
  "The question REQUEST carries: title, detail, options, free_text."
  (alist-get 'prompt request))

(defun claude-consent--options (request)
  "REQUEST's options, each an alist of value, label, and optional text."
  (alist-get 'options (claude-consent--prompt request)))

(defun claude-consent--hook (request)
  "The hook context REQUEST carries: tool_name, tool_input, cwd."
  (alist-get 'hook request))

(defun claude-consent--target (request)
  "The file the escalated tool call targets, or nil."
  (alist-get 'file_path (alist-get 'tool_input (claude-consent--hook request))))

(defun claude-consent--title (request)
  "The one-line question of REQUEST."
  (or (alist-get 'title (claude-consent--prompt request))
      (format "%s outside territory"
              (or (alist-get 'tool_name (claude-consent--hook request)) "?"))))

(defun claude-consent--option-keys (options)
  "One distinct key character per option, as the tool derives them:
the first character of the value when free, else the lowest free
digit, so Emacs and the terminal show the same keys."
  (let ((keys nil))
    (dolist (option options)
      (let* ((value (format "%s" (or (alist-get 'value option) "")))
             (candidate (and (> (length value) 0)
                             (downcase (aref value 0)))))
        (unless (and candidate
                     (not (memq candidate keys))
                     (or (and (>= candidate ?a) (<= candidate ?z))
                         (and (>= candidate ?0) (<= candidate ?9))))
          (setq candidate (seq-find (lambda (digit) (not (memq digit keys)))
                                    (number-sequence ?1 ?9))))
        (push candidate keys)))
    (nreverse keys)))

;;; Answering

(defvar-local claude-consent--request nil
  "Request rendered by this detail buffer, or nil elsewhere.")

(defun claude-consent--deliver (request value &optional text)
  "Write VALUE (an option value string) for REQUEST, with optional TEXT.
The waiting hook process picks the answer up; the answer covers
exactly this request and is never replayed -- a re-ask re-escalates."
  (let ((id (alist-get 'id request)))
    (unless id
      (user-error "Malformed consent request (no id)"))
    (when (claude-consent--request-stale-p request)
      (user-error "The request is stale (its waiter is gone or its deadline passed)"))
    (claude-consent--write-json
     (claude-consent--answer-file id)
     (append `((id . ,id)
               (value . ,value)
               (answered . ,(floor (float-time))))
             (when (and text (not (string-blank-p text)))
               `((text . ,text)))))
    (message "claude-consent: %s -> %s" (claude-consent--title request) value)))

(defun claude-consent--request-here ()
  "The consent request this buffer or line refers to."
  (or claude-consent--request
      (tabulated-list-get-id)
      (user-error "No consent request here")))

(defun claude-consent--read-answer (request)
  "Ask the user for REQUEST's answer; return (VALUE . TEXT).
A menu over the prompt's options, with free text where the prompt
or the chosen option asks for it."
  (let* ((prompt (claude-consent--prompt request))
         (options (claude-consent--options request))
         (keys (claude-consent--option-keys options))
         (free-text (alist-get 'free_text prompt))
         (choices (append
                   (cl-mapcar (lambda (key option)
                                (list key (format "%s" (or (alist-get 'label option)
                                                           (alist-get 'value option)))))
                              keys options)
                   (when free-text
                     (list (list ?t (format "%s (free text)" free-text))))))
         (chosen (car (read-multiple-choice
                       (claude-consent--title request) choices))))
    (if (and free-text (eq chosen ?t)
             (not (memq ?t keys)))
        (cons "text" (read-string (format "%s: " free-text)))
      (let* ((index (seq-position keys chosen))
             (option (nth index options))
             (text-prompt (alist-get 'text option)))
        (cons (format "%s" (alist-get 'value option))
              (and text-prompt (read-string (format "%s: " text-prompt))))))))

(defun claude-consent-answer ()
  "Answer the consent request at point from a menu of its options."
  (interactive)
  (let* ((request (claude-consent--request-here))
         (answer (claude-consent--read-answer request)))
    (claude-consent--deliver request (car answer) (cdr answer))
    (claude-consent--after-answer)))

(defun claude-consent--after-answer ()
  "Leave an answered detail view; refresh what remains."
  (when claude-consent--request
    (quit-window t))
  (claude-consent--refresh))

;;; Detail view

(defvar claude-consent-detail-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "a" #'claude-consent-answer)
    map)
  "Keymap for `claude-consent-detail-mode'.")

(define-derived-mode claude-consent-detail-mode special-mode "Claude-Consent-Detail"
  "One prompt from a Claude Code hook, rendered for an answer.

\\{claude-consent-detail-mode-map}")

(defun claude-consent--insert-section (title text)
  "Insert a titled TEXT section; TITLE names it."
  (insert (propertize (format "--- %s\n" title) 'face 'shadow))
  (insert text)
  (unless (or (string-empty-p text) (string-suffix-p "\n" text))
    (insert "\n")))

(defun claude-consent--render-request (request)
  "Fill the current buffer with a decision view of REQUEST."
  (let* ((prompt (claude-consent--prompt request))
         (hook (claude-consent--hook request))
         (input (alist-get 'tool_input hook))
         (territory (alist-get 'territory request))
         (tool (alist-get 'tool_name hook))
         (target (claude-consent--target request))
         (options (claude-consent--options request))
         (keys (claude-consent--option-keys options)))
    (insert (propertize (format "%s\n" (claude-consent--title request)) 'face 'warning))
    (insert (format "Session:   %s%s\n"
                    (or (alist-get 'session_id request) "?")
                    (if-let* ((name (alist-get 'name territory)))
                        (format "  (%s)" name)
                      "")))
    (when tool
      (insert (format "Tool:      %s\n" tool)))
    (when target
      (insert (format "Target:    %s\n" (abbreviate-file-name target))))
    (when-let* ((cwd (alist-get 'cwd hook)))
      (insert (format "Cwd:       %s\n" (abbreviate-file-name cwd))))
    (when territory
      (insert (format "Territory: %s\n"
                      (mapconcat #'abbreviate-file-name
                                 (alist-get 'roots territory)
                                 ", "))))
    (insert (format "Deadline:  %s\n"
                    (claude-consent--format-remaining
                     (claude-consent--remaining request))))
    (when-let* ((buffer (and target (find-buffer-visiting target))))
      (when (buffer-modified-p buffer)
        (insert (propertize
                 "Note: a live buffer visits this file with unsaved changes;\nwhat is on disk is not the newest state.\n"
                 'face 'warning))))
    (insert "\n")
    (let ((detail (alist-get 'detail prompt)))
      (when (and detail (not (string-blank-p detail)))
        (claude-consent--insert-section "question" detail)))
    (pcase tool
      ("Edit"
       (claude-consent--insert-section
        "replaces" (or (alist-get 'old_string input) ""))
       (claude-consent--insert-section
        "with" (or (alist-get 'new_string input) "")))
      ("Write"
       (when (and target (file-exists-p target))
         (insert (propertize "Overwrites an existing file.\n" 'face 'warning)))
       (claude-consent--insert-section
        "content" (or (alist-get 'content input) "")))
      ((pred null) nil)
      (_
       (claude-consent--insert-section "tool input"
                                       (format "%S" input))))
    (insert "\n")
    (claude-consent--insert-section
     "options"
     (concat
      (mapconcat (lambda (pair)
                   (format "[%c] %s" (car pair)
                           (or (alist-get 'label (cdr pair))
                               (alist-get 'value (cdr pair)))))
                 (cl-mapcar #'cons keys options)
                 "\n")
      (if-let* ((free-text (alist-get 'free_text prompt)))
          (format "\n[t] %s (free text)" free-text)
        "")))
    (insert (substitute-command-keys
             "\nType \\[claude-consent-answer] to answer.\n"))))

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
    (define-key map "a" #'claude-consent-answer)
    map)
  "Keymap for `claude-consent-list-mode'.")

(define-derived-mode claude-consent-list-mode tabulated-list-mode "Claude-Consent"
  "Pending prompts from Claude Code hooks.

Each row is one question waiting on an answer; RET shows the full
request, `a' answers it from a menu of its options.  Unanswered
requests self-resolve at their deadline; rows whose waiter died are
pruned on refresh.

\\{claude-consent-list-mode-map}"
  (setq tabulated-list-format
        [("When" 5 nil)
         ("Session" 12 nil)
         ("Prompt" 28 nil)
         ("Left" 7 nil)
         ("Target" 0 nil)])
  (setq tabulated-list-sort-key nil)
  (setq-local revert-buffer-function (lambda (&rest _)
                                       (claude-consent--refresh)))
  (tabulated-list-init-header))

(defun claude-consent--list-entries (requests)
  "Rows for the list buffer from REQUESTS."
  (mapcar (lambda (request)
            (let ((territory (alist-get 'territory request))
                  (target (claude-consent--target request)))
              (list request
                    (vector
                     (format-time-string
                      "%H:%M" (or (alist-get 'created request) 0))
                     (or (alist-get 'name territory)
                         (substring (or (alist-get 'session_id request) "?")
                                    0 (min 8 (length (or (alist-get 'session_id request) "?")))))
                     (claude-consent--title request)
                     (claude-consent--format-remaining
                      (claude-consent--remaining request))
                     (if target (abbreviate-file-name target) "")))))
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
  "Watch the consent spool and answer prompts from Emacs.
Registers this Emacs as an attached answerer, arms a filenotify
watch on the pending directory, keeps a mode-line count of
unanswered requests, and refreshes the `claude-consent-list' buffer
as requests arrive and resolve.  Enable in the resident session that
answers for dispatched agents."
  :global t
  :group 'claude-consent
  (if claude-consent-mode
      (condition-case err
          (progn
            (claude-consent-ensure-directories)
            (claude-consent-register-handler)
            (add-hook 'kill-emacs-hook #'claude-consent-remove-handler)
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
         (claude-consent-remove-handler)
         (message "claude-consent: spool unavailable, mode stays off (%s)"
                  (error-message-string err))))
    (claude-consent-remove-handler)
    (remove-hook 'kill-emacs-hook #'claude-consent-remove-handler)
    (when claude-consent--watch
      (ignore-errors (file-notify-rm-watch claude-consent--watch))
      (setq claude-consent--watch nil))
    (setq global-mode-string
          (delq claude-consent--mode-line-construct global-mode-string))
    (setq claude-consent--pending-count 0)))

(provide 'claude-consent)
;;; claude-consent.el ends here
