;;; ai-commit --- Generate commit messages with an LLM -*- lexical-binding: t -*-
;; SPDX-License-Identifier: MIT
;;; Commentary:
;; Generates a commit message for the current git-commit buffer from
;; the staged diff, via one of two parallel backends:
;;
;; - `claude-cli': shells out to the claude CLI, so generation rides
;;   the Claude subscription (no per-token API billing) and the CLI
;;   picks up the repository's CLAUDE.md conventions.
;; - `gptel': goes through the configured gptel backend, for API-key
;;   providers and non-Claude models.
;;
;; Both backends share `ai-commit-prompt' and the insertion path.
;; Entry points: `ai-commit-generate' (inside a commit buffer) and
;; `ai-commit-create' (start a commit and auto-generate).  A prefix
;; argument selects the backend interactively.
;;; Code:

(require 'subr-x)

(declare-function gptel-request "gptel-request")
(declare-function magit-commit-create "magit-commit")

(defgroup ai-commit nil
  "Generate commit messages with an LLM."
  :group 'tools
  :prefix "ai-commit-")

(defcustom ai-commit-backend 'claude-cli
  "Backend used by `ai-commit-generate' when none is given.
`claude-cli' shells out to `ai-commit-claude-program' (subscription
auth); `gptel' uses the active gptel backend (API key)."
  :type '(choice (const claude-cli) (const gptel)))

(defcustom ai-commit-claude-program "claude"
  "Name of the claude CLI executable."
  :type 'string)

(defcustom ai-commit-claude-model nil
  "Model passed to the claude CLI via --model, or nil for its default."
  :type '(choice (const :tag "CLI default" nil) string))

(defcustom ai-commit-claude-args '("--output-format" "text")
  "Extra arguments passed to the claude CLI."
  :type '(repeat string))

(defcustom ai-commit-max-input-chars 120000
  "Truncate the diff context sent to the model beyond this size."
  :type 'natnum)

(defcustom ai-commit-prompt
  "Write a git commit message for the staged changes.

Structure: <type>(<scope>): <description>, Conventional Commits
style.  Allowed types: feat, fix, docs, style, refactor, test,
maint, checkpoint.  Never use chore; use maint instead.  Do not
emit semver footers such as BREAKING CHANGE:.

Subject: imperative mood, concise.  Add a short body only when the
why is not obvious from the diff.  Match the style of the recent
commit subjects provided.  If the repository declares its own
commit conventions (e.g. in CLAUDE.md), those take precedence.

The input contains recent commit subjects and the staged diff.
Reply with ONLY the commit message text: no code fences, no
commentary, and do not use any tools."
  "Instructions sent to the model alongside the staged diff."
  :type 'string)

(defvar ai-commit--cli-process nil
  "The in-flight claude CLI process, if any.")

(defun ai-commit--git-string (&rest args)
  "Run git with ARGS and return stdout, or \"\" on failure."
  (with-temp-buffer
    (if (eq 0 (apply #'call-process "git" nil '(t nil) nil args))
        (buffer-string)
      "")))

(defun ai-commit--truncate (string)
  "Clip STRING to `ai-commit-max-input-chars', marking the cut."
  (if (<= (length string) ai-commit-max-input-chars)
      string
    (concat (substring string 0 ai-commit-max-input-chars)
            "\n[input truncated]")))

(defun ai-commit--input ()
  "Collect the model input: recent subjects plus the staged diff.
Signal `user-error' when nothing is staged."
  (let ((subjects (ai-commit--git-string "log" "-15" "--format=%s"))
        (diff (ai-commit--git-string "diff" "--cached" "--no-color")))
    (when (string-empty-p (string-trim diff))
      (user-error "No staged changes to describe"))
    (ai-commit--truncate
     (concat "Recent commit subjects for style reference:\n" subjects
             "\nStaged diff:\n" diff))))

(defun ai-commit--clean (response)
  "Strip code fences and surrounding whitespace from RESPONSE."
  (let ((text (string-trim (or response ""))))
    (when (string-match
           "\\````[^\n]*\n\\(\\(?:.\\|\n\\)*?\\)\n?```\\'" text)
      (setq text (string-trim (match-string 1 text))))
    text))

(defun ai-commit--insert (buffer message backend-name)
  "Insert MESSAGE at the top of BUFFER, crediting BACKEND-NAME."
  (cond
   ((not (buffer-live-p buffer))
    (message "ai-commit: commit buffer gone; dropped %s reply" backend-name))
   ((string-empty-p message)
    (message "ai-commit: %s returned an empty message" backend-name))
   (t
    (with-current-buffer buffer
      (save-excursion
        (goto-char (point-min))
        (insert message "\n")))
    (message "ai-commit: message inserted (%s)" backend-name))))

(defun ai-commit--cli-command ()
  "Build the claude CLI argv for one generation request."
  `(,ai-commit-claude-program
    "-p" ,ai-commit-prompt
    ,@(and ai-commit-claude-model (list "--model" ai-commit-claude-model))
    ,@ai-commit-claude-args))

(defun ai-commit--generate-claude-cli (buffer input)
  "Generate a message for BUFFER from INPUT via the claude CLI."
  (when (process-live-p ai-commit--cli-process)
    (kill-process ai-commit--cli-process))
  (let* ((stdout-buf (generate-new-buffer " *ai-commit-cli*"))
         (stderr-buf (generate-new-buffer " *ai-commit-cli-stderr*"))
         (stderr-pipe (make-pipe-process
                       :name "ai-commit-claude-stderr"
                       :buffer stderr-buf
                       :sentinel #'ignore)))
    (setq ai-commit--cli-process
          (make-process
           :name "ai-commit-claude"
           :command (ai-commit--cli-command)
           :buffer stdout-buf
           :stderr stderr-pipe
           :connection-type 'pipe
           :sentinel
           (lambda (proc event)
             (unless (process-live-p proc)
               (let ((output (with-current-buffer stdout-buf
                               (buffer-string)))
                     (errors (with-current-buffer stderr-buf
                               (buffer-string))))
                 (when (process-live-p stderr-pipe)
                   (delete-process stderr-pipe))
                 (kill-buffer stdout-buf)
                 (kill-buffer stderr-buf)
                 (if (and (string-prefix-p "finished" event)
                          (eq 0 (process-exit-status proc)))
                     (ai-commit--insert
                      buffer (ai-commit--clean output) "claude CLI")
                   (message "ai-commit: claude CLI failed (%s): %s"
                            (string-trim event)
                            (string-trim errors))))))))
    (process-send-string ai-commit--cli-process input)
    (process-send-eof ai-commit--cli-process)
    (message "ai-commit: asking claude CLI...")))

(defun ai-commit--generate-gptel (buffer input)
  "Generate a message for BUFFER from INPUT via gptel."
  (require 'gptel)
  (gptel-request input
    :system ai-commit-prompt
    :callback (lambda (response info)
                (if (stringp response)
                    (ai-commit--insert
                     buffer (ai-commit--clean response) "gptel")
                  (message "ai-commit: gptel error: %s"
                           (plist-get info :status)))))
  (message "ai-commit: asking gptel..."))

(defun ai-commit--read-backend ()
  "Read a backend choice when called with a prefix argument."
  (when current-prefix-arg
    (intern (completing-read "ai-commit backend: "
                             '("claude-cli" "gptel") nil t))))

;;;###autoload
(defun ai-commit-generate (&optional backend)
  "Generate a commit message into the current buffer asynchronously.
BACKEND overrides `ai-commit-backend'; interactively, a prefix
argument prompts for it.  The reply is inserted at the top of the
buffer when it arrives."
  (interactive (list (ai-commit--read-backend)))
  (let ((backend (or backend ai-commit-backend))
        (buffer (current-buffer))
        (input (ai-commit--input)))
    (pcase backend
      ('claude-cli (ai-commit--generate-claude-cli buffer input))
      ('gptel (ai-commit--generate-gptel buffer input))
      (_ (user-error "Unknown ai-commit backend: %s" backend)))))

;;;###autoload
(defun ai-commit-create (&optional backend)
  "Start a commit via magit and auto-generate its message.
BACKEND overrides `ai-commit-backend'; interactively, a prefix
argument prompts for it."
  (interactive (list (ai-commit--read-backend)))
  (require 'magit)
  (letrec ((hook (lambda ()
                   (remove-hook 'git-commit-setup-hook hook)
                   (ai-commit-generate backend))))
    (add-hook 'git-commit-setup-hook hook))
  (magit-commit-create))

(provide 'ai-commit)
;;; ai-commit.el ends here
