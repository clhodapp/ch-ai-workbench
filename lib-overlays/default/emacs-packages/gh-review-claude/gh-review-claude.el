;;; gh-review-claude.el --- Claude reviews for gh-review -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Adds Claude Code to a gh-review session.  Each pull request gets one
;; review conversation, run headless (`claude -p' with streamed JSON)
;; in a detached worktree at the pull request's head with read-only
;; tools.  The first turn asks the one question a review answers:
;; is this safe to merge?  Claude ends every assessment with a JSON
;; verdict; the verdict's blockers and follow-ups are drawn into the
;; diff under the lines they name, and the summary sits at the top of
;; the diff and in the conversation panel.  Questions asked from a
;; line of the diff continue the same conversation.
;;
;; `gh-review-claude-respond' turns the verdict into an action.  The
;; bias is toward merging what is safe:
;;
;; - safe: merge (a pull request the user wrote) or approve (one
;;   somebody else wrote); follow-ups go to the conversation that
;;   opened the pull request when there is one, or to a new one;
;; - needs work, opened from one of the user's conversations: the
;;   fixes go back to that conversation;
;; - needs work, any other origin: the user chooses between fixing it
;;   in a new conversation and a review requesting the fix, whose
;;   text Claude drafts.
;;
;; The conversation a pull request came from is found in the record
;; the pr-origin hook keeps (claude-pr-origin-hook.sh) and, for pull
;; requests opened before the hook existed, in the session
;; transcripts.  Nothing about it is written to git or GitHub.

;;; Code:

(require 'gh-review)
(require 'claude-queue)

(declare-function ghostel-paste-string "ghostel")
(declare-function ghostel-send-key "ghostel")
(declare-function term-send-string "term")

(defgroup gh-review-claude nil
  "Claude Code reviews in gh-review."
  :group 'gh-review)

(defcustom gh-review-claude-program "claude"
  "The Claude Code CLI."
  :type 'string)

(defcustom gh-review-claude-model "opus"
  "Model of the review conversations."
  :type 'string)

(defcustom gh-review-claude-auto-review t
  "Whether opening a pull request starts Claude's review of it.
A review runs once per head commit; a pull request whose head moved
since its last verdict is assessed again in the same conversation."
  :type 'boolean)

(defcustom gh-review-claude-review-tools
  '("Read" "Grep" "Glob" "Bash(git diff:*)" "Bash(git log:*)"
    "Bash(git show:*)" "Bash(git blame:*)" "Bash(git grep:*)"
    "Bash(git ls-files:*)")
  "Tools the review conversation may use without asking.
The conversation runs in print mode, which never asks, so a tool
missing here is denied."
  :type '(repeat string))

(defcustom gh-review-claude-denied-tools
  '("Edit" "Write" "NotebookEdit" "WebFetch" "WebSearch")
  "Tools the review conversation is denied even when a setting allows them."
  :type '(repeat string))

(defcustom gh-review-claude-origins-file
  (expand-file-name "claude-pr-origins/origins.jsonl"
                    (or (getenv "XDG_STATE_HOME") "~/.local/state"))
  "The record the pr-origin hook keeps of who created which pull request."
  :type 'file)

(defcustom gh-review-claude-projects-directory "~/.claude/projects/"
  "Where Claude Code keeps session transcripts."
  :type 'directory)

(defcustom gh-review-claude-ripgrep-program "rg"
  "ripgrep, which finds the transcripts that mention a pull request."
  :type 'string)

(defcustom gh-review-claude-checkout-roots '("~/Projects/")
  "Directories searched, three levels deep, for clones of a repository.
A new conversation working on a pull request starts in a clone of
its repository."
  :type '(repeat directory))

(defcustom gh-review-claude-paste-submit t
  "Whether a message pasted into a running conversation is also sent.
When nil the message is left in the prompt for the user to send."
  :type 'boolean)

(defface gh-review-claude-blocker
  '((((class color) (background dark)) :background "#3a1d1d" :extend t)
    (((class color) (background light)) :background "#ffe0e0" :extend t)
    (t :inherit error))
  "Face of a blocker Claude found.")

(defface gh-review-claude-follow-up
  '((((class color) (background dark)) :background "#1b2a3a" :extend t)
    (((class color) (background light)) :background "#e3f0ff" :extend t)
    (t :inherit highlight))
  "Face of a follow-up Claude suggests.")

(defface gh-review-claude-safe
  '((((class color) (background dark)) :background "#14301f" :extend t)
    (((class color) (background light)) :background "#dcffe4" :extend t)
    (t :inherit success))
  "Face of a safe verdict.")

(defface gh-review-claude-unsure
  '((((class color) (background dark)) :background "#33300f" :extend t)
    (((class color) (background light)) :background "#fff5c2" :extend t)
    (t :inherit warning))
  "Face of an unsure verdict.")

;;; State

(cl-defstruct (gh-review-claude-state (:constructor gh-review-claude-state--create)
                                      (:copier nil))
  "Claude's side of one pull request review.
SESSION is the review conversation's id; HEAD the head commit the
VERDICT is about.  ORIGIN is the conversation that opened the pull
request, `none' when there is none, nil before the lookup.  BUSY is
non-nil while a turn runs; QUEUE holds the turns waiting for it."
  session head verdict origin busy queue process)

(defun gh-review-claude--state-file (pr)
  "File keeping PR's review session and verdict."
  (expand-file-name (format "claude/%s/%s/%d.eld" (gh-review-pr-owner pr)
                            (gh-review-pr-repo pr) (gh-review-pr-number pr))
                    gh-review-cache-directory))

(defun gh-review-claude-state (pr)
  "PR's review state, read from disk on first use."
  (or (gh-review-pr-get pr :claude)
      (let* ((file (gh-review-claude--state-file pr))
             (saved (and (file-readable-p file)
                         (ignore-errors
                           (with-temp-buffer
                             (insert-file-contents file)
                             (read (current-buffer))))))
             (state (gh-review-claude-state--create
                     :session (plist-get saved :session)
                     :head (plist-get saved :head)
                     :verdict (plist-get saved :verdict)
                     :origin (plist-get saved :origin))))
        (gh-review-pr-put pr :claude state)
        state)))

(defun gh-review-claude--save (pr)
  "Write PR's review session, verdict and origin to disk."
  (let ((state (gh-review-claude-state pr))
        (file (gh-review-claude--state-file pr)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (let ((print-length nil) (print-level nil))
        (prin1 (list :session (gh-review-claude-state-session state)
                     :head (gh-review-claude-state-head state)
                     :verdict (gh-review-claude-state-verdict state)
                     :origin (gh-review-claude-state-origin state))
               (current-buffer))))))

;;; Verdicts

(defconst gh-review-claude--verdict-schema
  "```json
{\"verdict\": \"safe\" | \"safe_with_follow_ups\" | \"needs_work\" | \"unsure\",
 \"summary\": \"two or three sentences on why\",
 \"blockers\": [{\"path\": \"file\", \"line\": 12, \"side\": \"RIGHT\",
                 \"title\": \"short name\", \"detail\": \"what breaks and when\",
                 \"fix\": \"what to change\"}],
 \"follow_ups\": [{\"path\": \"file\", \"line\": 30, \"side\": \"RIGHT\",
                   \"title\": \"short name\", \"detail\": \"what to improve later\"}],
 \"questions\": [\"what you could not settle from the code\"]}
```"
  "The JSON shape every assessment ends with.")

(defun gh-review-claude--json-blocks (text)
  "The fenced json blocks of TEXT, last first."
  (let ((blocks nil) (start 0))
    (while (string-match "```json[ \t]*\n\\(\\(?:.\\|\n\\)*?\\)\n```" text start)
      (push (match-string 1 text) blocks)
      (setq start (match-end 0)))
    blocks))

(defun gh-review-claude--parse-json (string)
  "STRING parsed as JSON into alists, or nil when it is not JSON."
  (ignore-errors
    (json-parse-string string :object-type 'alist :array-type 'list
                       :null-object nil :false-object nil)))

(defun gh-review-claude--item (alist)
  "A blocker or follow-up ALIST as a plist."
  (let ((line (alist-get 'line alist)))
    (list :path (alist-get 'path alist)
          :line (and (integerp line) (> line 0) line)
          :side (if (equal (alist-get 'side alist) "LEFT") "LEFT" "RIGHT")
          :title (or (alist-get 'title alist) "")
          :detail (or (alist-get 'detail alist) "")
          :fix (alist-get 'fix alist))))

(defun gh-review-claude-parse-verdict (text)
  "The verdict at the end of the assessment TEXT, as a plist, or nil.
The plist has :verdict (`safe', `safe-with-follow-ups', `needs-work'
or `unsure'), :summary, :blockers and :follow-ups (lists of plists
with :path :line :side :title :detail and :fix) and :questions."
  (seq-some
   (lambda (block)
     (when-let* ((data (gh-review-claude--parse-json block))
                 ((listp data))
                 (kind (alist-get 'verdict data)))
       (list :verdict (pcase kind
                        ("safe" 'safe)
                        ("safe_with_follow_ups" 'safe-with-follow-ups)
                        ("needs_work" 'needs-work)
                        (_ 'unsure))
             :summary (or (alist-get 'summary data) "")
             :blockers (mapcar #'gh-review-claude--item (alist-get 'blockers data))
             :follow-ups (mapcar #'gh-review-claude--item (alist-get 'follow_ups data))
             :questions (alist-get 'questions data))))
   (gh-review-claude--json-blocks text)))

(defun gh-review-claude--verdict-label (verdict)
  "A short phrase naming VERDICT's kind."
  (pcase (plist-get verdict :verdict)
    ('safe "safe to merge")
    ('safe-with-follow-ups "safe to merge, with follow-ups")
    ('needs-work "needs work before merging")
    (_ "unsure")))

(defun gh-review-claude--verdict-face (verdict)
  "The face showing VERDICT."
  (pcase (plist-get verdict :verdict)
    ((or 'safe 'safe-with-follow-ups) 'gh-review-claude-safe)
    ('needs-work 'gh-review-claude-blocker)
    (_ 'gh-review-claude-unsure)))

;;; The chat buffer

(defvar-keymap gh-review-claude-chat-mode-map
  :doc "Keymap of `gh-review-claude-chat-mode'."
  :parent special-mode-map
  "a" #'gh-review-claude-ask
  "!" #'gh-review-claude-respond
  "g" #'gh-review-refresh)

(define-derived-mode gh-review-claude-chat-mode special-mode "PR Claude"
  "Major mode of a pull request's review conversation with Claude.

\\{gh-review-claude-chat-mode-map}"
  :interactive nil
  (setq buffer-read-only t)
  (visual-line-mode 1))

(defun gh-review-claude-chat-buffer (pr)
  "The buffer showing PR's review conversation, created when missing."
  (let ((name (format "*%s claude*" (gh-review-pr-key pr))))
    (or (get-buffer name)
        (with-current-buffer (get-buffer-create name)
          (gh-review-claude-chat-mode)
          (setq gh-review-buffer-pr pr)
          (current-buffer)))))

(defun gh-review-claude--append (pr text &optional face)
  "Append TEXT to PR's chat buffer, in FACE when given."
  (with-current-buffer (gh-review-claude-chat-buffer pr)
    (let* ((inhibit-read-only t)
           (windows (seq-filter (lambda (w) (= (window-point w) (point-max)))
                                (get-buffer-window-list nil nil t))))
      (save-excursion
        (goto-char (point-max))
        (insert (if face (propertize text 'face face) text)))
      (dolist (window windows)
        (set-window-point window (point-max))))))

(defun gh-review-claude-show-chat (pr)
  "Show PR's chat buffer below the conversation panel."
  (display-buffer-in-side-window
   (gh-review-claude-chat-buffer pr)
   `((side . right) (slot . 1) (window-width . ,gh-review-conversation-width)
     (window-height . 0.5)
     (window-parameters . ((no-delete-other-windows . t))))))

;;; Running turns

(defun gh-review-claude--command (state)
  "The command line of the next turn of the conversation in STATE.
The prompt goes to standard input, so nothing variadic can swallow it."
  (append (list gh-review-claude-program "-p"
                "--output-format" "stream-json" "--verbose"
                "--model" gh-review-claude-model
                "--permission-mode" "default"
                "--allowedTools" (string-join gh-review-claude-review-tools ",")
                "--settings" (json-serialize
                              `(:permissions
                                (:deny ,(vconcat gh-review-claude-denied-tools)))))
          (when (gh-review-claude-state-session state)
            (list "--resume" (gh-review-claude-state-session state)))))

(defun gh-review-claude--tool-summary (block)
  "One line describing the tool call BLOCK."
  (let ((input (alist-get 'input block)))
    (format "  · %s %s\n" (alist-get 'name block)
            (truncate-string-to-width
             (or (alist-get 'command input) (alist-get 'file_path input)
                 (alist-get 'pattern input) "")
             90 nil nil "…"))))

(defun gh-review-claude--handle-event (pr state turn event)
  "Apply the stream EVENT of the running TURN of PR's conversation."
  (pcase (alist-get 'type event)
    ("system"
     (when (and (equal (alist-get 'subtype event) "init")
                (alist-get 'session_id event))
       (setf (gh-review-claude-state-session state) (alist-get 'session_id event))))
    ("assistant"
     (dolist (block (alist-get 'content (alist-get 'message event)))
       (pcase (alist-get 'type block)
         ("text"
          (let ((text (alist-get 'text block)))
            (plist-put turn :text (concat (plist-get turn :text) text "\n"))
            (gh-review-claude--append pr (concat text "\n"))))
         ("tool_use"
          (gh-review-claude--append pr (gh-review-claude--tool-summary block)
                                    'shadow)))))
    ("result"
     (plist-put turn :result event)
     (when (alist-get 'is_error event)
       (gh-review-claude--append
        pr (format "\n[error: %s]\n" (or (alist-get 'result event)
                                         (alist-get 'subtype event)))
        'error))
     (when-let* ((denials (alist-get 'permission_denials event)))
       (gh-review-claude--append
        pr (format "[%d tool call%s denied]\n" (length denials)
                   (if (cdr denials) "s" ""))
        'shadow)))))

(defun gh-review-claude--filter (pr state turn)
  "A process filter feeding complete JSON lines to the event handler."
  (let ((pending ""))
    (lambda (_process output)
      (setq pending (concat pending output))
      (while (string-match "\n" pending)
        (let ((line (substring pending 0 (match-beginning 0))))
          (setq pending (substring pending (match-end 0)))
          (when-let* ((event (gh-review-claude--parse-json line)))
            (gh-review-claude--handle-event pr state turn event)))))))

(defun gh-review-claude--turn (pr prompt &rest options)
  "Send PROMPT as the next turn of PR's review conversation.
OPTIONS is a plist: :display is what the chat shows for the prompt
\(PROMPT itself by default); :callback is called with the turn's
assistant text when it ends.  A turn asked for while another runs
waits for it."
  (let ((state (gh-review-claude-state pr)))
    (if (gh-review-claude-state-busy state)
        (setf (gh-review-claude-state-queue state)
              (append (gh-review-claude-state-queue state)
                      (list (cons prompt options))))
      (gh-review-worktree
       pr
       (lambda (directory)
         (gh-review-claude--start-turn pr state directory prompt options))
       (lambda (message)
         (gh-review-claude--append pr (format "[worktree failed: %s]\n" message)
                                   'error))))))

(defun gh-review-claude--start-turn (pr state directory prompt options)
  "Run one turn of PR's conversation in DIRECTORY with PROMPT and OPTIONS."
  (let* ((turn (list :text ""))
         (default-directory (file-name-as-directory directory))
         (stderr (generate-new-buffer " *gh-review-claude stderr*"))
         (process
          (make-process
           :name "gh-review-claude"
           :command (gh-review-claude--command state)
           :connection-type 'pipe
           :coding 'utf-8
           :noquery t
           :stderr stderr
           :filter (gh-review-claude--filter pr state turn)
           :sentinel
           (lambda (process _event)
             (unless (process-live-p process)
               (gh-review-claude--finish-turn pr state turn options process stderr))))))
    (setf (gh-review-claude-state-busy state) t
          (gh-review-claude-state-process state) process)
    (gh-review-claude--append
     pr (concat "\n" (propertize "▶ " 'face 'bold)
                (or (plist-get options :display) prompt) "\n\n")
     nil)
    (gh-review-claude--refresh-views pr)
    (process-send-string process prompt)
    (process-send-eof process)))

(defun gh-review-claude--finish-turn (pr state turn options process stderr)
  "Close TURN of PR's conversation once PROCESS ended; run the next one."
  (let ((errors (with-current-buffer stderr (string-trim (buffer-string)))))
    (kill-buffer stderr)
    (when (and (not (eql (process-exit-status process) 0))
               (not (plist-get turn :result)))
      (gh-review-claude--append
       pr (format "[claude exited with %d%s]\n" (process-exit-status process)
                  (if (string-empty-p errors) "" (concat ": " errors)))
       'error)))
  (setf (gh-review-claude-state-busy state) nil
        (gh-review-claude-state-process state) nil)
  (let ((text (plist-get turn :text)))
    (when-let* ((verdict (gh-review-claude-parse-verdict text)))
      (setf (gh-review-claude-state-verdict state) verdict
            (gh-review-claude-state-head state) (gh-review-pr-head-oid pr))
      (gh-review-claude--append
       pr (format "\nVerdict: %s\n" (gh-review-claude--verdict-label verdict))
       (gh-review-claude--verdict-face verdict)))
    (gh-review-claude--save pr)
    (gh-review-claude--refresh-views pr)
    (when-let* ((callback (plist-get options :callback)))
      (funcall callback text)))
  (when-let* ((next (pop (gh-review-claude-state-queue state))))
    (apply #'gh-review-claude--turn pr (car next) (cdr next))))

(defun gh-review-claude--refresh-views (pr)
  "Redraw PR's diff, conversation and inbox row so they show Claude's state."
  (gh-review-redisplay pr)
  (gh-review-claude--inbox-redraw))

;;; Prompts

(defun gh-review-claude--thread-summary (pr)
  "The open review threads of PR as prompt text."
  (let ((open (seq-remove (lambda (thread) (alist-get 'isResolved thread))
                          (gh-review-pr-threads pr))))
    (if (null open)
        "none"
      (mapconcat
       (lambda (thread)
         (let ((first (car (alist-get 'nodes (alist-get 'comments thread)))))
           (format "- %s:%s, %s: %s" (alist-get 'path thread)
                   (or (alist-get 'line thread) (alist-get 'originalLine thread) "?")
                   (alist-get 'login (alist-get 'author first))
                   (car (split-string (or (alist-get 'body first) "") "\n")))))
       open "\n"))))

(defun gh-review-claude--checks-summary (pr)
  "PR's status checks as prompt text."
  (let* ((checks (gh-review-pr-checks pr))
         (failing (seq-filter (lambda (check)
                                (member (plist-get check :state)
                                        '("FAILURE" "ERROR" "CANCELLED" "TIMED_OUT")))
                              (plist-get checks :contexts))))
    (concat (or (plist-get checks :state) "no checks")
            (when failing
              (concat "; failing: "
                      (mapconcat (lambda (c) (plist-get c :name)) failing ", "))))))

(defun gh-review-claude-review-prompt (pr)
  "The first turn of PR's review conversation."
  (format "You are reviewing GitHub pull request %s, \"%s\", which %s wants to merge from %s into %s.
%s

The working directory is a detached checkout of the pull request's head.  The diff under review compares merge base %s with HEAD: read it with `git diff %s HEAD`, and use git log, git show, git blame, Read, Grep and Glob for the surrounding code.  You cannot edit files or run other commands.

Description:
%s

Status checks: %s
Open review threads:
%s

Answer one question: is this pull request safe to merge?  Lean toward merging.  A change that is correct and breaks nothing is safe even if it could be nicer; style and polish are follow-ups, not blockers.  A blocker is something that would break behaviour, lose data, weaken security, or fail the build or the tests.  Check the claims the description makes against the code.

Reply with a short assessment, then end with exactly one fenced json block in this shape:
%s
Line numbers refer to the head (side RIGHT) or to the merge base (side LEFT), on lines the diff changes or within 3 lines of a change.  Leave line out for a point about a whole file, and path too for a point about the whole pull request."
          (gh-review-pr-url pr) (gh-review-pr-title pr) (gh-review-pr-author pr)
          (gh-review-pr-head-ref pr) (gh-review-pr-base-ref pr)
          (if (gh-review-pr-viewer-authored-p pr)
              (format "The reviewer, %s, wrote it." (gh-review-pr-viewer pr))
            (format "The reviewer is %s." (gh-review-pr-viewer pr)))
          (gh-review-pr-merge-base pr) (gh-review-pr-merge-base pr)
          (let ((body (string-trim (or (gh-review-pr-body pr) ""))))
            (if (string-empty-p body) "(none)" body))
          (gh-review-claude--checks-summary pr)
          (gh-review-claude--thread-summary pr)
          gh-review-claude--verdict-schema))

(defun gh-review-claude--rereview-prompt (pr old-head)
  "The turn asking for a new assessment of PR since OLD-HEAD."
  (format "The pull request has new commits: its head moved from %s to %s, and the working directory now holds the new head.  Review the change since your last assessment (`git diff %s HEAD`, if that commit is still present) in the context of the whole pull request (`git diff %s HEAD`), and give a new assessment ending with the json block in the same shape."
          old-head (gh-review-pr-head-oid pr) old-head (gh-review-pr-merge-base pr)))

(defconst gh-review-claude--ask-suffix
  "\n\nIf your assessment of whether the pull request is safe to merge changes, end with an updated json block in the same shape as before."
  "Appended to every question, so a changed assessment is captured.")

;;; Reviewing and asking

(defun gh-review-claude-review (pr)
  "Start Claude's assessment of PR, or a new one if its head moved."
  (interactive (list (gh-review-current-pr)))
  (unless (eq (gh-review-pr-status pr) 'ready)
    (user-error "%s is not loaded yet" (gh-review-pr-key pr)))
  (let* ((state (gh-review-claude-state pr))
         (old-head (gh-review-claude-state-head state)))
    (gh-review-claude-show-chat pr)
    (if (and (gh-review-claude-state-session state) old-head
             (not (equal old-head (gh-review-pr-head-oid pr))))
        (gh-review-claude--turn pr (gh-review-claude--rereview-prompt pr old-head)
                                :display "Assess the new commits.")
      (setf (gh-review-claude-state-session state) nil)
      (gh-review-claude--turn pr (gh-review-claude-review-prompt pr)
                              :display (format "Is %s safe to merge?"
                                               (gh-review-pr-key pr))))
    (gh-review-claude-origin pr)))

(defun gh-review-claude--maybe-review (pr)
  "Start the review of PR when it is due; on `gh-review-refresh-hook'."
  (when (and gh-review-claude-auto-review
             (eq (gh-review-pr-status pr) 'ready))
    (let ((state (gh-review-claude-state pr)))
      (unless (or (gh-review-claude-state-busy state)
                  (equal (gh-review-claude-state-head state)
                         (gh-review-pr-head-oid pr)))
        (gh-review-claude-review pr)))))

(defun gh-review-claude--location-context ()
  "Text locating the question asked from the diff at point, or nil."
  (let ((lines (if (use-region-p)
                   (save-excursion
                     (let ((end (region-end)) (result nil))
                       (goto-char (region-beginning))
                       (while (< (point) end)
                         (when-let* ((line (gh-review-line-at-point)))
                           (push line result))
                         (forward-line 1))
                       (nreverse result)))
                 (delq nil (list (and (fboundp 'gh-review-line-at-point)
                                      (gh-review-line-at-point)))))))
    (when lines
      (let ((first (car lines)))
        (format "This is about %s, %s, %s side of the diff:\n```\n%s\n```"
                (plist-get first :path)
                (if (cdr lines)
                    (format "lines %d to %d" (plist-get first :line)
                            (plist-get (car (last lines)) :line))
                  (format "line %d" (plist-get first :line)))
                (if (equal (plist-get first :side) "LEFT")
                    "the merge base (removed lines)"
                  "the head")
                (mapconcat (lambda (line)
                             (concat (pcase (plist-get line :kind)
                                       ('add "+") ('del "-") (_ " "))
                                     (plist-get line :text)))
                           lines "\n"))))))

(defun gh-review-claude-ask (question)
  "Ask Claude QUESTION about the pull request.
From a line or region of the diff, the question carries those lines."
  (interactive (list (read-string "Ask Claude: ")))
  (let* ((pr (gh-review-current-pr))
         (context (and (derived-mode-p 'gh-review-diff-mode)
                       (gh-review-claude--location-context)))
         (state (gh-review-claude-state pr)))
    (when (use-region-p) (deactivate-mark))
    (when (string-blank-p question) (user-error "Empty question"))
    (gh-review-claude-show-chat pr)
    (unless (gh-review-claude-state-session state)
      (gh-review-claude-review pr))
    (gh-review-claude--turn pr (concat question (and context (concat "\n\n" context))
                                       gh-review-claude--ask-suffix)
                            :display (concat question
                                             (and context
                                                  (format "  (%s)" (car (split-string context "\n"))))))))

;;; Annotations

(defun gh-review-claude--annotation (item face heading)
  "The annotation of the blocker or follow-up ITEM."
  (append (list :heading (concat heading (plist-get item :title))
                :body (concat (plist-get item :detail)
                              (when (plist-get item :fix)
                                (concat "\nFix: " (plist-get item :fix))))
                :face face :claude item)
          (when (plist-get item :path)
            (list :path (plist-get item :path)
                  :side (plist-get item :side)
                  :line (plist-get item :line)))))

(defun gh-review-claude-annotations (pr)
  "Claude's verdict for PR as gh-review annotations."
  (let* ((state (gh-review-claude-state pr))
         (verdict (gh-review-claude-state-verdict state)))
    (append
     (cond
      ((gh-review-claude-state-busy state)
       (list (list :heading "Claude is reviewing…" :body ""
                   :face 'gh-review-claude-unsure)))
      (verdict
       (list (list :heading (concat "Claude: "
                                    (gh-review-claude--verdict-label verdict)
                                    (if (equal (gh-review-claude-state-head state)
                                               (gh-review-pr-head-oid pr))
                                        ""
                                      " (for an older head)"))
                   :body (plist-get verdict :summary)
                   :face (gh-review-claude--verdict-face verdict)))))
     (when verdict
       (append
        (mapcar (lambda (item)
                  (gh-review-claude--annotation item 'gh-review-claude-blocker
                                                "Blocker: "))
                (plist-get verdict :blockers))
        (mapcar (lambda (item)
                  (gh-review-claude--annotation item 'gh-review-claude-follow-up
                                                "Follow-up: "))
                (plist-get verdict :follow-ups)))))))

;;; Finding the conversation a pull request came from

(defun gh-review-claude--munge (directory)
  "The transcript directory name Claude Code derives from DIRECTORY."
  (replace-regexp-in-string "[^A-Za-z0-9-]" "-"
                            (directory-file-name (expand-file-name directory))))

(defun gh-review-claude--own-transcript-p (file)
  "Whether the transcript FILE belongs to a review conversation of ours.
Review conversations run in worktrees under the cache directory, and
the transcript directory is named after the starting directory."
  (string-prefix-p (gh-review-claude--munge gh-review-cache-directory)
                   (file-name-nondirectory
                    (directory-file-name (file-name-directory file)))))

(defun gh-review-claude--recorded-origins (pr)
  "The pr-origin hook's records of PR, newest last."
  (let ((file (expand-file-name gh-review-claude-origins-file))
        (url (gh-review-pr-url pr))
        (records nil))
    (when (and url (file-readable-p file))
      (with-temp-buffer
        (insert-file-contents file)
        (dolist (line (split-string (buffer-string) "\n" t))
          (when-let* ((data (and (string-search url line)
                                 (gh-review-claude--parse-json line)))
                      ((equal (alist-get 'url data) url))
                      (session (alist-get 'session_id data)))
            (push (list :session-id session
                        :cwd (alist-get 'cwd data)
                        :transcript (alist-get 'transcript_path data)
                        :time (alist-get 'time data)
                        :strength 'recorded)
                  records)))))
    (nreverse records)))

(defun gh-review-claude--rg-escape (string)
  "STRING with the characters a ripgrep regex treats specially escaped."
  (replace-regexp-in-string "[][.*+?(){}|^$\\\\]" "\\\\\\&" string))

(defun gh-review-claude--candidate-transcripts (pr)
  "Transcripts that mention PR's link."
  (let ((directory (expand-file-name gh-review-claude-projects-directory))
        (pattern (format "github\\.com/%s/%s/pull/%d\\b"
                         (gh-review-claude--rg-escape (gh-review-pr-owner pr))
                         (gh-review-claude--rg-escape (gh-review-pr-repo pr))
                         (gh-review-pr-number pr))))
    (when (file-directory-p directory)
      (if (executable-find gh-review-claude-ripgrep-program)
          (with-temp-buffer
            (call-process gh-review-claude-ripgrep-program nil t nil
                          "-l" "--glob" "*.jsonl" "-e" pattern directory)
            (split-string (buffer-string) "\n" t))
        (let ((regexp (format "github\\.com/%s/%s/pull/%d\\_>"
                              (regexp-quote (gh-review-pr-owner pr))
                              (regexp-quote (gh-review-pr-repo pr))
                              (gh-review-pr-number pr))))
          (seq-filter (lambda (file)
                        (with-temp-buffer
                          (insert-file-contents file)
                          (re-search-forward regexp nil t)))
                      (directory-files-recursively directory "\\.jsonl\\'")))))))

(defun gh-review-claude--transcript-origin (pr file)
  "How the session in transcript FILE relates to PR, as an origin plist.
The strength is `created' when a gh pr create or gh-stack command
of the session printed PR's link, `pushed' when the session pushed
PR's head branch, and nil when it only mentions the pull request."
  (let ((url-regexp (format "github\\.com/%s/%s/pull/%d\\_>"
                            (regexp-quote (gh-review-pr-owner pr))
                            (regexp-quote (gh-review-pr-repo pr))
                            (gh-review-pr-number pr)))
        (head (gh-review-pr-head-ref pr))
        (creating nil) (strength nil) (cwd nil) (time nil) (title nil))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (not (eobp))
        (let* ((start (point))
               (end (line-end-position))
               (line (buffer-substring-no-properties start end)))
          (when (string-match "\"cwd\":\"\\([^\"]+\\)\"" line)
            (setq cwd (match-string 1 line)))
          (when (string-match "\"timestamp\":\"\\([^\"]+\\)\"" line)
            (setq time (match-string 1 line)))
          (when (and (null title) (string-search "\"type\":\"summary\"" line))
            (setq title (alist-get 'summary (gh-review-claude--parse-json line))))
          (when (and (string-search "\"tool_use\"" line)
                     (string-match-p "gh pr create\\|gh-stack\\|git push" line))
            (dolist (block (alist-get 'content (alist-get 'message
                                                          (gh-review-claude--parse-json line))))
              (let ((command (alist-get 'command (alist-get 'input block))))
                (when (and (equal (alist-get 'type block) "tool_use") (stringp command))
                  (when (string-match-p "\\_<gh[ \t]+pr[ \t]+create\\_>\\|gh-stack" command)
                    (push (alist-get 'id block) creating))
                  (when (and head (> (length head) 3)
                             (string-match-p "\\_<git\\_>.*\\_<push\\_>" command)
                             (string-search head command)
                             (not (eq strength 'created)))
                    (setq strength 'pushed))))))
          (when (and creating (string-match-p url-regexp line)
                     (string-search "\"tool_result\"" line))
            (dolist (block (alist-get 'content (alist-get 'message
                                                          (gh-review-claude--parse-json line))))
              (when (and (equal (alist-get 'type block) "tool_result")
                         (member (alist-get 'tool_use_id block) creating))
                (setq strength 'created))))
          (goto-char (min (point-max) (1+ end))))))
    (when strength
      (list :session-id (file-name-base file) :cwd cwd :time time
            :title title :transcript file :strength strength))))

(defun gh-review-claude--first-prompt (file)
  "The first prompt of the transcript FILE, shortened, or nil."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file nil 0 200000)
      (goto-char (point-min))
      (catch 'found
        (while (re-search-forward "^.*\"type\":\"user\".*$" nil t)
          (let* ((data (gh-review-claude--parse-json (match-string 0)))
                 (content (alist-get 'content (alist-get 'message data))))
            (when (and (stringp content) (not (string-prefix-p "<" content)))
              (throw 'found (truncate-string-to-width
                             (car (split-string content "\n")) 70 nil nil "…")))))
        nil))))

(defun gh-review-claude--strength-rank (origin)
  "How strongly ORIGIN ties a session to the pull request."
  (pcase (plist-get origin :strength)
    ('manual 4) ('recorded 3) ('created 2) ('pushed 1) (_ 0)))

(defun gh-review-claude-find-origins (pr)
  "Every conversation of the user tied to PR, strongest and newest first."
  (let ((origins (append (gh-review-claude--recorded-origins pr)
                         (delq nil (mapcar (lambda (file)
                                             (unless (gh-review-claude--own-transcript-p file)
                                               (gh-review-claude--transcript-origin pr file)))
                                           (gh-review-claude--candidate-transcripts pr))))))
    (seq-uniq
     (sort origins (lambda (a b)
                     (let ((ra (gh-review-claude--strength-rank a))
                           (rb (gh-review-claude--strength-rank b)))
                       (if (= ra rb)
                           (string> (or (plist-get a :time) "") (or (plist-get b :time) ""))
                         (> ra rb)))))
     (lambda (a b) (equal (plist-get a :session-id) (plist-get b :session-id))))))

(defun gh-review-claude-origin (pr)
  "The conversation that opened PR, as a plist, or nil.
Looked up once per pull request and kept with its review state;
`gh-review-claude-set-origin' changes it."
  (let* ((state (gh-review-claude-state pr))
         (origin (gh-review-claude-state-origin state)))
    (when (null origin)
      (setq origin (or (car (gh-review-claude-find-origins pr)) 'none))
      (when (and (listp origin) (null (plist-get origin :title)))
        (setq origin (plist-put origin :title
                                (gh-review-claude--first-prompt
                                 (or (plist-get origin :transcript) "")))))
      (setf (gh-review-claude-state-origin state) origin)
      (gh-review-claude--save pr))
    (and (listp origin) origin)))

(defun gh-review-claude-set-origin (pr)
  "Choose the conversation PR came from, or none."
  (interactive (list (gh-review-current-pr)))
  (let* ((origins (gh-review-claude-find-origins pr))
         (choices (append
                   (mapcar (lambda (origin)
                             (cons (format "%s  %s (%s)"
                                           (substring (plist-get origin :session-id) 0 8)
                                           (or (plist-get origin :title) "")
                                           (plist-get origin :strength))
                                   origin))
                           origins)
                   '(("No conversation (the pull request did not come from a chat)"
                      . none))))
         (choice (completing-read "Pull request came from: " choices nil nil))
         (origin (or (cdr (assoc choice choices))
                     (and (string-match-p "\\`[0-9a-f-]\\{8,\\}\\'" choice)
                          (list :session-id choice :strength 'manual
                                :cwd (read-directory-name
                                      "Directory that session works in: "))))))
    (unless origin (user-error "Not a listed conversation or a session id"))
    (when (listp origin) (setq origin (plist-put (copy-sequence origin) :strength 'manual)))
    (setf (gh-review-claude-state-origin (gh-review-claude-state pr)) origin)
    (gh-review-claude--save pr)
    (gh-review-claude--refresh-views pr)))

;;; Sending work to conversations

(defun gh-review-claude--paste-when-ready (buffer message)
  "Paste MESSAGE into the terminal BUFFER once the session is drawn."
  (let ((tries 0) (timer nil))
    (setq timer
          (run-with-timer
           1.5 0.5
           (lambda ()
             (setq tries (1+ tries))
             (cond
              ((not (buffer-live-p buffer)) (cancel-timer timer))
              ((or (> tries 20)
                   (with-current-buffer buffer (> (buffer-size) 200)))
               (cancel-timer timer)
               (with-current-buffer buffer
                 (cond
                  ((fboundp 'ghostel-paste-string)
                   (ghostel-paste-string message)
                   (when gh-review-claude-paste-submit
                     (ghostel-send-key "return")))
                  ((fboundp 'term-send-string)
                   (term-send-string (get-buffer-process buffer)
                                     (concat message
                                             (if gh-review-claude-paste-submit "\r" "")))))))))))))

(defun gh-review-claude-send-to-origin (origin message)
  "Deliver MESSAGE to the conversation ORIGIN.
A running conversation gets it pasted into an attached terminal; a
finished one is reopened with it from the directory it last worked
in.  The message also goes to the kill ring, in case the delivery
needs a hand."
  (let ((session (plist-get origin :session-id))
        (cwd (plist-get origin :cwd)))
    (kill-new message)
    (cond
     ((claude-queue-session-live-p session)
      (let ((buffer (claude-queue-attach-session session)))
        (when buffer (gh-review-claude--paste-when-ready buffer message))
        (message "Sending to the running conversation %s (also in the kill ring)"
                 (substring session 0 8))))
     ((and cwd (file-directory-p cwd))
      (claude-queue-resume-session session cwd message)
      (message "Reopened conversation %s with the message" (substring session 0 8)))
     (t
      (user-error "The directory of conversation %s is gone (%s); the message is in the kill ring"
                  (substring session 0 8) (or cwd "unknown"))))))

(defun gh-review-claude--remote-matches-p (directory pr)
  "Whether the git checkout DIRECTORY has PR's repository as a remote."
  (let* ((dot-git (expand-file-name ".git" directory))
         (git-dir (cond ((file-directory-p dot-git) dot-git)
                        ((file-regular-p dot-git)
                         (with-temp-buffer
                           (insert-file-contents dot-git)
                           (when (re-search-forward "^gitdir: \\(.*\\)$" nil t)
                             (expand-file-name (match-string 1) directory))))))
         (config (and git-dir (expand-file-name "config" git-dir))))
    (when (and config (file-readable-p config))
      (with-temp-buffer
        (insert-file-contents config)
        (re-search-forward
         (format "url = .*github\\.com[:/]%s/%s\\(?:\\.git\\)?/?$"
                 (regexp-quote (gh-review-pr-owner pr))
                 (regexp-quote (gh-review-pr-repo pr)))
         nil t)))))

(defun gh-review-claude--git-directories (root depth)
  "Git checkouts under ROOT down to DEPTH levels."
  (when (and (> depth 0) (file-directory-p root))
    (mapcan (lambda (child)
              (if (file-exists-p (expand-file-name ".git" child))
                  (cons child (gh-review-claude--git-directories child (1- depth)))
                (gh-review-claude--git-directories child (1- depth))))
            (seq-filter #'file-directory-p
                        (directory-files root t "\\`[^.]" t)))))

(defun gh-review-claude-checkout (pr)
  "A local clone of PR's repository to start a conversation in.
The origin conversation's directory comes first, then known projects
and the clones under `gh-review-claude-checkout-roots'; with none,
the user is asked."
  (let* ((origin (gh-review-claude-origin pr))
         (candidates (append
                      (and origin (plist-get origin :cwd) (list (plist-get origin :cwd)))
                      (and (fboundp 'project-known-project-roots)
                           (project-known-project-roots))
                      (mapcan (lambda (root)
                                (gh-review-claude--git-directories (expand-file-name root) 3))
                              gh-review-claude-checkout-roots))))
    (or (seq-find (lambda (directory)
                    (and (file-directory-p directory)
                         (gh-review-claude--remote-matches-p directory pr)))
                  candidates)
        (read-directory-name
         (format "Clone of %s to work in: " (gh-review-pr-name-with-owner pr))))))

(defun gh-review-claude-new-chat (pr prompt name)
  "Start a background conversation on PR with PROMPT, named NAME."
  (claude-queue-submit prompt (gh-review-claude-checkout pr)
                       :name name :model gh-review-claude-model)
  (message "Queued %S" name))

;;; Messages

(defun gh-review-claude--items-text (items)
  "ITEMS, blockers or follow-ups, as a numbered list."
  (let ((n 0))
    (mapconcat
     (lambda (item)
       (setq n (1+ n))
       (concat (format "%d. %s" n (plist-get item :title))
               (when (plist-get item :path)
                 (format " (%s%s)" (plist-get item :path)
                         (if (plist-get item :line)
                             (format ", line %d" (plist-get item :line))
                           "")))
               "\n   " (plist-get item :detail)
               (when (plist-get item :fix)
                 (concat "\n   Fix: " (plist-get item :fix)))))
     items "\n")))

(defun gh-review-claude-follow-ups-message (pr verdict to-origin)
  "The message carrying VERDICT's follow-ups for PR.
TO-ORIGIN is non-nil for the conversation that opened PR."
  (concat
   (if to-origin
       (format "Review of %s (%s): it is safe to merge, and it is being merged.  These follow-ups came out of the review; make each one on a new branch from %s with its own pull request:\n\n"
               (gh-review-pr-url pr) (gh-review-pr-title pr) (gh-review-pr-base-ref pr))
     (format "Follow-ups from the review of %s (%s), which is safe to merge and is being merged.  Make each one on a new branch from %s with its own pull request:\n\n"
             (gh-review-pr-url pr) (gh-review-pr-title pr) (gh-review-pr-base-ref pr)))
   (gh-review-claude--items-text (plist-get verdict :follow-ups))))

(defun gh-review-claude-fixes-message (pr verdict)
  "The message sending VERDICT's blockers back to PR's own conversation."
  (format "Review of %s (%s): it is not safe to merge yet.  Fix these on the pull request's branch %s and push to it:\n\n%s"
          (gh-review-pr-url pr) (gh-review-pr-title pr) (gh-review-pr-head-ref pr)
          (gh-review-claude--items-text (plist-get verdict :blockers))))

(defun gh-review-claude-fix-prompt (pr verdict)
  "The task making PR safe to merge in a new conversation."
  (format "Make pull request %s (%s, branch %s of %s) safe to merge.  Check it out with `gh pr checkout %d` in a new git worktree of this repository, fix the problems below, run the checks this repository has, and push the fixes to the pull request's branch%s.

Problems found in review:
%s"
          (gh-review-pr-url pr) (gh-review-pr-title pr) (gh-review-pr-head-ref pr)
          (or (gh-review-pr-head-repo pr) (gh-review-pr-name-with-owner pr))
          (gh-review-pr-number pr)
          (if (or (gh-review-pr-maintainer-can-modify pr)
                  (equal (gh-review-pr-head-repo pr) (gh-review-pr-name-with-owner pr)))
              ""
            "; if the branch does not accept pushes, open a pull request against it instead")
          (gh-review-claude--items-text (plist-get verdict :blockers))))

;;; Drafting the review text

(defconst gh-review-claude--draft-prompt
  "Draft my review of this pull request asking for the blocking problems to be fixed before it merges.  Write as me, the reviewer, to the author: plain and specific, one comment per problem on the line it concerns, saying what breaks and what to change.  Do not mention Claude, AI, or any chat, and do not include links to chats or sessions.  Reply with only one fenced json block in this shape:
```json
{\"body\": \"the review's summary\",
 \"comments\": [{\"path\": \"file\", \"line\": 12, \"side\": \"RIGHT\", \"body\": \"the comment\"}]}
```
Each comment's line must be a line the diff changes or within 3 lines of one."
  "The turn asking Claude to draft a review requesting changes.")

(defun gh-review-claude-apply-draft (pr text)
  "Turn the drafted review TEXT into PR's pending comments and a body.
Comments on lines GitHub would refuse move into the body.  Return
the body, or nil when TEXT holds no draft."
  (when-let* ((block (car (gh-review-claude--json-blocks text)))
              (data (gh-review-claude--parse-json block))
              ((listp data)))
    (let ((body (or (alist-get 'body data) ""))
          (moved nil))
      (dolist (comment (alist-get 'comments data))
        (let ((path (alist-get 'path comment))
              (line (alist-get 'line comment))
              (side (if (equal (alist-get 'side comment) "LEFT") "LEFT" "RIGHT"))
              (text (alist-get 'body comment)))
          (if (and path (integerp line) text
                   (gh-review-line-commentable-p pr path side line))
              (gh-review-add-draft pr (list :path path :side side :line line
                                            :body text :source 'claude))
            (push (format "- %s%s: %s" (or path "")
                          (if (integerp line) (format " line %d" line) "")
                          (or text ""))
                  moved))))
      (if moved
          (concat body "\n\n" (string-join (nreverse moved) "\n"))
        body))))

(defun gh-review-claude-draft-review (pr event)
  "Have Claude draft a review of PR with EVENT, then open it for editing."
  (gh-review-claude-show-chat pr)
  (gh-review-claude--turn
   pr gh-review-claude--draft-prompt
   :display "Draft a review asking for the fixes."
   :callback (lambda (text)
               (let ((body (gh-review-claude-apply-draft pr text)))
                 (with-current-buffer (gh-review-diff-buffer pr)
                   (gh-review-compose-review
                    pr event
                    (or body (gh-review-claude--items-text
                              (plist-get (gh-review-claude-state-verdict
                                          (gh-review-claude-state pr))
                                         :blockers)))))))))

;;; Responding

(defun gh-review-claude-actions (verdict authored origin)
  "The responses to VERDICT on a pull request, most recommended first.
AUTHORED is non-nil when the user wrote the pull request; ORIGIN is
non-nil when it came from one of the user's conversations.  Each
response is a plist with :id and, when it applies, :recommended and
:follow-ups (`origin' or `new', where follow-ups go)."
  (let* ((kind (plist-get verdict :verdict))
         (target (if origin 'origin 'new))
         (follow-ups (and (plist-get verdict :follow-ups) target))
         (land (if authored 'merge 'approve))
         (actions nil))
    (cl-flet ((add (id &rest properties)
                (push (cons :id (cons id properties)) actions)))
      (pcase kind
        ((or 'safe 'safe-with-follow-ups)
         (add land :recommended t :follow-ups follow-ups)
         (when follow-ups
           (add land)
           (add 'follow-ups :follow-ups follow-ups)))
        ('needs-work
         (if origin
             (progn (add 'fix-in-origin :recommended t)
                    (add 'fix-myself)
                    (add 'request-changes))
           (add 'fix-myself)
           (add 'request-changes)))
        (_
         (add 'ask :recommended t)
         (if origin (add 'fix-in-origin) (add 'fix-myself))
         (add 'request-changes)
         (add land)))
      (add 'nothing))
    (nreverse actions)))

(defun gh-review-claude--action-label (action authored)
  "What choosing ACTION does, in words; AUTHORED as in the actions."
  (let ((follow-ups (pcase (plist-get action :follow-ups)
                      ('origin ", and send the follow-ups to the conversation it came from")
                      ('new ", and start a conversation for the follow-ups")
                      (_ ""))))
    (concat
     (pcase (plist-get action :id)
       ('merge (concat "Merge" follow-ups))
       ('approve (concat "Approve" follow-ups))
       ('follow-ups (if (eq (plist-get action :follow-ups) 'origin)
                        "Only send the follow-ups to the conversation it came from"
                      "Only start a conversation for the follow-ups"))
       ('fix-in-origin "Send the fixes to the conversation it came from")
       ('fix-myself "Fix it myself: start a conversation that fixes the branch")
       ('request-changes (if authored
                             "Comment on the pull request listing the needed fixes"
                           "Request changes, with comments Claude drafts"))
       ('ask "Ask Claude more before deciding")
       ('nothing "Nothing for now"))
     (if (plist-get action :recommended) "  (recommended)" ""))))

(defun gh-review-claude--send-follow-ups (pr verdict target &optional then)
  "Edit VERDICT's follow-ups for PR, then send them to TARGET.
THEN, when given, runs once the follow-ups were sent."
  (let ((origin (gh-review-claude-origin pr)))
    (gh-review-edit-text
     (if (eq target 'origin) "follow-ups for the original conversation"
       "follow-ups for a new conversation")
     (gh-review-claude-follow-ups-message pr verdict (eq target 'origin))
     (lambda (text)
       (unless (string-empty-p text)
         (if (eq target 'origin)
             (gh-review-claude-send-to-origin origin text)
           (gh-review-claude-new-chat
            pr text (format "follow-ups of %s" (gh-review-pr-key pr)))))
       (when then (funcall then)))
     pr)))

(defun gh-review-claude--perform (pr verdict action)
  "Carry out the response ACTION to VERDICT on PR."
  (let ((authored (gh-review-pr-viewer-authored-p pr))
        (follow-ups (plist-get action :follow-ups)))
    (pcase (plist-get action :id)
      ('merge
       (gh-review-merge-pr)
       (when follow-ups (gh-review-claude--send-follow-ups pr verdict follow-ups)))
      ('approve
       (let ((approve (lambda ()
                        (gh-review-compose-review pr "APPROVE"
                                                  (plist-get verdict :summary)))))
         (if follow-ups
             (gh-review-claude--send-follow-ups pr verdict follow-ups approve)
           (funcall approve))))
      ('follow-ups (gh-review-claude--send-follow-ups pr verdict follow-ups))
      ('fix-in-origin
       (let ((origin (gh-review-claude-origin pr)))
         (gh-review-edit-text
          "fixes for the original conversation"
          (gh-review-claude-fixes-message pr verdict)
          (lambda (text)
            (unless (string-empty-p text)
              (gh-review-claude-send-to-origin origin text)))
          pr)))
      ('fix-myself
       (gh-review-edit-text
        "task for a new conversation"
        (gh-review-claude-fix-prompt pr verdict)
        (lambda (text)
          (unless (string-empty-p text)
            (gh-review-claude-new-chat
             pr text (format "fix %s" (gh-review-pr-key pr)))))
        pr))
      ('request-changes
       (gh-review-claude-draft-review pr (if authored "COMMENT" "REQUEST_CHANGES")))
      ('ask (call-interactively #'gh-review-claude-ask))
      ('nothing nil))))

(defun gh-review-claude-respond ()
  "Choose what to do about the pull request from Claude's verdict."
  (interactive)
  (let* ((pr (gh-review-current-pr))
         (state (gh-review-claude-state pr))
         (verdict (gh-review-claude-state-verdict state)))
    (cond
     ((gh-review-claude-state-busy state)
      (user-error "Claude is still working on %s" (gh-review-pr-key pr)))
     ((null verdict)
      (when (y-or-n-p "Claude has not assessed this pull request; start now? ")
        (gh-review-claude-review pr)))
     (t
      (let* ((authored (gh-review-pr-viewer-authored-p pr))
             (origin (gh-review-claude-origin pr))
             (actions (gh-review-claude-actions verdict authored origin))
             (choices (mapcar (lambda (action)
                                (cons (gh-review-claude--action-label action authored)
                                      action))
                              actions))
             (choice (completing-read
                      (format "Claude: %s.  Respond: "
                              (gh-review-claude--verdict-label verdict))
                      (lambda (string predicate flag)
                        (if (eq flag 'metadata)
                            '(metadata (display-sort-function . identity))
                          (complete-with-action flag choices string predicate)))
                      nil t)))
        (with-current-buffer (gh-review-diff-buffer pr)
          (gh-review-claude--perform pr verdict (cdr (assoc choice choices)))))))))

;;; The conversation panel

(defun gh-review-claude--origin-description (origin)
  "ORIGIN in words."
  (if (null origin)
      "not from one of your conversations"
    (format "conversation %s%s, %s"
            (substring (plist-get origin :session-id) 0 8)
            (if (plist-get origin :title)
                (format " (%s)" (plist-get origin :title))
              "")
            (if (claude-queue-session-live-p (plist-get origin :session-id))
                "running"
              "not running"))))

(defun gh-review-claude-conversation-section (pr)
  "Insert Claude's section into PR's conversation panel."
  (let* ((state (gh-review-claude-state pr))
         (verdict (gh-review-claude-state-verdict state)))
    (insert "\n" (propertize "Claude" 'face '(:inherit bold :height 1.1)) "\n")
    (insert "  "
            (cond ((gh-review-claude-state-busy state)
                   (propertize "Reviewing…" 'face 'shadow))
                  (verdict
                   (propertize (gh-review-claude--verdict-label verdict)
                               'face (gh-review-claude--verdict-face verdict)))
                  (t (propertize "Not reviewed yet" 'face 'shadow)))
            "  ")
    (insert-text-button "Respond" 'action (lambda (_) (gh-review-claude-respond))
                        'follow-link t)
    (insert "  ")
    (insert-text-button "Ask" 'action (lambda (_) (call-interactively #'gh-review-claude-ask))
                        'follow-link t)
    (insert "  ")
    (insert-text-button "Review again" 'action
                        (lambda (_)
                          (setf (gh-review-claude-state-head state) nil)
                          (gh-review-claude-review pr))
                        'follow-link t)
    (insert "\n")
    (when verdict
      (insert (propertize (concat "  " (plist-get verdict :summary) "\n")
                          'face 'default))
      (dolist (item (plist-get verdict :blockers))
        (insert (propertize "  ✗ " 'face 'error) (plist-get item :title)
                (propertize (if (plist-get item :path)
                                (format "  %s:%s" (plist-get item :path)
                                        (or (plist-get item :line) ""))
                              "")
                            'face 'shadow)
                "\n"))
      (dolist (item (plist-get verdict :follow-ups))
        (insert "  • " (plist-get item :title)
                (propertize (if (plist-get item :path)
                                (format "  %s" (plist-get item :path))
                              "")
                            'face 'shadow)
                "\n"))
      (dolist (question (plist-get verdict :questions))
        (insert (propertize "  ? " 'face 'warning) question "\n")))
    (let ((origin (and (listp (gh-review-claude-state-origin state))
                       (gh-review-claude-state-origin state))))
      (insert (propertize (concat "  Opened from: "
                                  (if (null (gh-review-claude-state-origin state))
                                      "not looked up yet"
                                    (gh-review-claude--origin-description origin))
                                  "  ")
                          'face 'shadow))
      (insert-text-button "Change" 'action (lambda (_) (gh-review-claude-set-origin pr))
                          'follow-link t)
      (insert "\n"))))

;;; Publishing guard

(defun gh-review-claude-check-publish (text _pr)
  "Refuse to post TEXT that links a Claude conversation.
Session links and the Claude Code footer stay off GitHub: a pull
request keeps the history of every edit, so a posted link cannot be
taken back."
  (when (string-match-p
         "claude\\.ai/\\(?:code\\|chat\\)\\|session_[0-9A-Za-z]\\{8,\\}\\|Generated with \\[Claude Code\\]"
         text)
    (user-error "This text links a Claude conversation; remove the link before posting")))

;;; The review inbox

;; Pull requests an agent puts in front of the user, through the emacs
;; MCP server's review-pull-request tool.  Surfacing one never takes
;; the user's focus: it adds a row to the inbox, shows the inbox in a
;; window of its own, and fetches the pull request in the background,
;; so that Claude's review (with `gh-review-claude-auto-review') is
;; under way by the time the user opens it.

(defun gh-review-claude--inbox-file ()
  "File keeping the review inbox."
  (expand-file-name "claude/inbox.eld" gh-review-cache-directory))

(defvar gh-review-claude--inbox 'unread
  "The inbox entries, newest first, or `unread' before the file is read.
Each entry is a plist with :key (OWNER/REPO#N), :reference (OWNER
REPO N), :url, :note and :time.")

(defun gh-review-claude--inbox-entries ()
  "The inbox entries, read from disk on first use."
  (when (eq gh-review-claude--inbox 'unread)
    (let ((file (gh-review-claude--inbox-file)))
      (setq gh-review-claude--inbox
            (and (file-readable-p file)
                 (ignore-errors
                   (with-temp-buffer
                     (insert-file-contents file)
                     (read (current-buffer))))))))
  gh-review-claude--inbox)

(defun gh-review-claude--inbox-save ()
  "Write the inbox entries to disk."
  (let ((file (gh-review-claude--inbox-file)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (let ((print-length nil) (print-level nil))
        (prin1 (gh-review-claude--inbox-entries) (current-buffer))))))

(defun gh-review-claude--inbox-entry-pr (entry)
  "The pull request record of inbox ENTRY."
  (apply #'gh-review-pr-for (plist-get entry :reference)))

(defun gh-review-claude-surface (url &optional note)
  "Put the pull request at URL in front of the user for review.
NOTE, when given, says what the user should look at.  The pull
request joins the review inbox, the inbox is shown without taking
focus, and the pull request is fetched so its review starts.
Return a sentence saying what happened."
  (let ((reference (or (gh-review-parse-reference url)
                       (user-error "Not a pull request link: %s" url))))
    (let* ((key (apply #'format "%s/%s#%d" reference))
           (note (and note (not (string-blank-p note))
                      (truncate-string-to-width (string-trim note) 300 nil nil "…")))
           (entry (list :key key :reference reference
                        :url (format "https://%s/%s/%s/pull/%d" gh-review-host
                                     (nth 0 reference) (nth 1 reference)
                                     (nth 2 reference))
                        :note note
                        :time (format-time-string "%Y-%m-%d %H:%M")))
           (pr (gh-review-claude--inbox-entry-pr entry)))
      (setq gh-review-claude--inbox
            (cons entry (seq-remove (lambda (e) (equal (plist-get e :key) key))
                                    (gh-review-claude--inbox-entries))))
      (gh-review-claude--inbox-save)
      (when (memq (gh-review-pr-status pr) '(new error))
        (gh-review-load pr (lambda (_) (gh-review-claude--inbox-redraw))))
      (display-buffer (gh-review-claude-inbox-buffer))
      (message "%s is ready for review (RET on it in %s)" key
               (buffer-name (gh-review-claude-inbox-buffer)))
      (format "Put %s in the user's review inbox%s" key
              (if gh-review-claude-auto-review
                  "; Claude's review of it starts once it is fetched"
                "")))))

(defun gh-review-claude--inbox-status (entry)
  "What the inbox shows of ENTRY's review."
  (let* ((pr (gh-review-claude--inbox-entry-pr entry))
         (state (gh-review-claude-state pr))
         (verdict (gh-review-claude-state-verdict state)))
    (cond ((eq (gh-review-pr-status pr) 'loading) "fetching")
          ((eq (gh-review-pr-status pr) 'error) "fetch failed")
          ((gh-review-claude-state-busy state) "Claude reviewing")
          (verdict (propertize (gh-review-claude--verdict-label verdict)
                               'face (pcase (plist-get verdict :verdict)
                                       ((or 'safe 'safe-with-follow-ups) 'success)
                                       ('needs-work 'error)
                                       (_ 'warning))))
          (t ""))))

(defun gh-review-claude--inbox-rows ()
  "The inbox as `tabulated-list-entries'."
  (mapcar (lambda (entry)
            (let ((pr (gh-review-claude--inbox-entry-pr entry)))
              (list (plist-get entry :key)
                    (vector (plist-get entry :key)
                            (or (gh-review-pr-title pr) "")
                            (gh-review-claude--inbox-status entry)
                            (or (plist-get entry :note) "")
                            (plist-get entry :time)))))
          (gh-review-claude--inbox-entries)))

(defvar-keymap gh-review-claude-inbox-mode-map
  :doc "Keymap of `gh-review-claude-inbox-mode'."
  :parent tabulated-list-mode-map
  "RET" #'gh-review-claude-inbox-open
  "d" #'gh-review-claude-inbox-remove)

(define-derived-mode gh-review-claude-inbox-mode tabulated-list-mode "PR Inbox"
  "Major mode of the list of pull requests agents put up for review.

\\{gh-review-claude-inbox-mode-map}"
  :interactive nil
  (setq tabulated-list-format
        [("Pull request" 28 t) ("Title" 40 t) ("Review" 22 t)
         ("Note" 40 nil) ("Added" 16 t)])
  (setq tabulated-list-sort-key nil)
  (add-hook 'tabulated-list-revert-hook #'gh-review-claude--inbox-fill nil t)
  (tabulated-list-init-header))

(defun gh-review-claude--inbox-fill ()
  "Fill the inbox buffer's rows."
  (setq tabulated-list-entries (gh-review-claude--inbox-rows)))

(defun gh-review-claude-inbox-buffer ()
  "The review inbox buffer, filled."
  (with-current-buffer (get-buffer-create "*gh-review inbox*")
    (unless (derived-mode-p 'gh-review-claude-inbox-mode)
      (gh-review-claude-inbox-mode))
    (gh-review-claude--inbox-fill)
    (tabulated-list-print t)
    (current-buffer)))

(defun gh-review-claude--inbox-redraw ()
  "Redraw the inbox buffer when it exists."
  (when-let* ((buffer (get-buffer "*gh-review inbox*")))
    (with-current-buffer buffer
      (gh-review-claude--inbox-fill)
      (tabulated-list-print t))))

;;;###autoload
(defun gh-review-claude-inbox ()
  "Show the pull requests agents put up for review."
  (interactive)
  (pop-to-buffer (gh-review-claude-inbox-buffer)))

(defun gh-review-claude--inbox-entry-at-point ()
  "The inbox entry of the row at point, or a user error."
  (let ((key (tabulated-list-get-id)))
    (or (seq-find (lambda (e) (equal (plist-get e :key) key))
                  (gh-review-claude--inbox-entries))
        (user-error "No pull request on this line"))))

(defun gh-review-claude-inbox-open ()
  "Open the review of the pull request at point."
  (interactive)
  (apply #'gh-review-open (plist-get (gh-review-claude--inbox-entry-at-point)
                                     :reference)))

(defun gh-review-claude-inbox-remove ()
  "Take the pull request at point out of the inbox."
  (interactive)
  (let ((key (plist-get (gh-review-claude--inbox-entry-at-point) :key)))
    (setq gh-review-claude--inbox
          (seq-remove (lambda (e) (equal (plist-get e :key) key))
                      (gh-review-claude--inbox-entries)))
    (gh-review-claude--inbox-save)
    (gh-review-claude--inbox-redraw)))

;;; Wiring

(defun gh-review-claude--layout (pr)
  "Show PR's chat below the conversation when it has a conversation."
  (when (gh-review-claude-state-session (gh-review-claude-state pr))
    (gh-review-claude-show-chat pr)))

;;;###autoload
(define-minor-mode gh-review-claude-mode
  "Claude Code reviews in gh-review buffers."
  :global t
  :group 'gh-review-claude
  (let ((hooks '((gh-review-annotation-functions . gh-review-claude-annotations)
                 (gh-review-conversation-sections-functions
                  . gh-review-claude-conversation-section)
                 (gh-review-refresh-hook . gh-review-claude--maybe-review)
                 (gh-review-layout-hook . gh-review-claude--layout)
                 (gh-review-before-publish-functions . gh-review-claude-check-publish))))
    (dolist (hook hooks)
      (if gh-review-claude-mode
          (add-hook (car hook) (cdr hook))
        (remove-hook (car hook) (cdr hook))))))

(transient-append-suffix 'gh-review-dispatch '(0 -1)
  ["Claude"
   ("Q" "Ask about point" gh-review-claude-ask)
   ("!" "Respond to the verdict" gh-review-claude-respond)
   ("@" "Review again" gh-review-claude-review)
   ("O" "Set the conversation it came from" gh-review-claude-set-origin)])

(provide 'gh-review-claude)
;;; gh-review-claude.el ends here
