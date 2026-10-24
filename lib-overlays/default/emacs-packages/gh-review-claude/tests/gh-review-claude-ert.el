;;; gh-review-claude-ert.el --- Tests of gh-review-claude -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Everything but the real CLI and GitHub: verdict parsing, the
;; response policy, finding the conversation a pull request came from
;; (hook records and transcripts), turning a drafted review into
;; pending comments, the publishing guard, and whole review turns
;; against a fake claude that streams canned JSON.

;;; Code:

(require 'ert)
(require 'gh-review-claude)

(defvar gh-review-claude-test--root nil
  "Scratch directory of the running test.")

(defmacro gh-review-claude-test--with-scratch (&rest body)
  "Run BODY with the cache and record locations in a scratch directory."
  (declare (indent 0))
  `(let* ((gh-review-claude-test--root (make-temp-file "ghrc" t))
          (gh-review-cache-directory
           (file-name-as-directory (expand-file-name "cache" gh-review-claude-test--root)))
          (gh-review-claude-origins-file
           (expand-file-name "origins.jsonl" gh-review-claude-test--root))
          (gh-review-claude-projects-directory
           (file-name-as-directory (expand-file-name "projects" gh-review-claude-test--root))))
     (unwind-protect (progn ,@body)
       (delete-directory gh-review-claude-test--root t))))

(defun gh-review-claude-test--pr (&rest slots)
  "A loaded pull request o/r#7 with SLOTS overriding the defaults."
  (let* ((file (gh-review-file--create
                :path "src/a.el" :old-path "src/a.el" :status 'modified
                :additions 1 :deletions 1
                :new-lines (vconcat (mapcar (lambda (n) (format "line %d" n))
                                            (number-sequence 1 30)))
                :old-lines (vconcat (mapcar (lambda (n) (format "line %d" n))
                                            (number-sequence 1 30)))
                :hunks (list (gh-review-hunk--create
                              :old-start 15 :old-count 1 :new-start 15 :new-count 1
                              :lines '((del . "old 15") (add . "new 15"))))))
         (pr (gh-review-pr--create
              :owner "o" :repo "r" :number 7 :url "https://github.com/o/r/pull/7"
              :title "Fix things" :author "alice" :viewer "me" :state "OPEN"
              :base-ref "main" :head-ref "fix-things" :head-oid "headoid"
              :merge-base "baseoid" :status 'ready :files (list file))))
    ;; The contents agree with the hunk: line 15 is what changed.
    (aset (gh-review-file-old-lines file) 14 "old 15")
    (aset (gh-review-file-new-lines file) 14 "new 15")
    (while slots
      (setf (cl-struct-slot-value 'gh-review-pr (pop slots) pr) (pop slots)))
    pr))

;;; Verdicts

(defconst gh-review-claude-test--answer
  "Looks fine overall.

```json
{\"verdict\": \"needs_work\",
 \"summary\": \"Breaks parsing of empty input.\",
 \"blockers\": [{\"path\": \"src/a.el\", \"line\": 15, \"side\": \"RIGHT\",
                 \"title\": \"Empty input\", \"detail\": \"nil is not handled\",
                 \"fix\": \"check for nil\"}],
 \"follow_ups\": [{\"title\": \"Rename helper\", \"detail\": \"clearer\"}],
 \"questions\": [\"Is the old format still produced?\"]}
```
")

(ert-deftest gh-review-claude-parse-verdict-fields ()
  (let ((verdict (gh-review-claude-parse-verdict gh-review-claude-test--answer)))
    (should (eq (plist-get verdict :verdict) 'needs-work))
    (should (equal (plist-get verdict :summary) "Breaks parsing of empty input."))
    (let ((blocker (car (plist-get verdict :blockers))))
      (should (equal (plist-get blocker :path) "src/a.el"))
      (should (= (plist-get blocker :line) 15))
      (should (equal (plist-get blocker :side) "RIGHT"))
      (should (equal (plist-get blocker :fix) "check for nil")))
    (should (equal (plist-get (car (plist-get verdict :follow-ups)) :title) "Rename helper"))
    (should-not (plist-get (car (plist-get verdict :follow-ups)) :path))
    (should (equal (plist-get verdict :questions) '("Is the old format still produced?")))))

(ert-deftest gh-review-claude-parse-verdict-takes-last-block ()
  (let ((text (concat "```json\n{\"verdict\": \"needs_work\", \"summary\": \"a\"}\n```\n"
                      "Later:\n```json\n{\"verdict\": \"safe\", \"summary\": \"b\"}\n```\n")))
    (should (eq (plist-get (gh-review-claude-parse-verdict text) :verdict) 'safe)))
  (should-not (gh-review-claude-parse-verdict "no json here"))
  (should-not (gh-review-claude-parse-verdict "```json\n{\"body\": \"x\"}\n```\n")))

;;; The response policy

(defun gh-review-claude-test--ids (actions)
  "The ids of ACTIONS, the recommended ones marked with a star."
  (mapcar (lambda (action)
            (let ((name (symbol-name (plist-get action :id))))
              (intern (concat name
                              (pcase (plist-get action :follow-ups)
                                ('origin "+origin") ('new "+new") (_ ""))
                              (if (plist-get action :recommended) "*" "")))))
          actions))

(ert-deftest gh-review-claude-actions-policy ()
  (let ((safe '(:verdict safe))
        (safe-follow '(:verdict safe-with-follow-ups :follow-ups ((:title "x"))))
        (work '(:verdict needs-work :blockers ((:title "y"))))
        (unsure '(:verdict unsure))
        (origin '(:session-id "s")))
    ;; Safe, and the user wrote it: merge.
    (should (equal (gh-review-claude-test--ids (gh-review-claude-actions safe t nil))
                   '(merge* nothing)))
    ;; Safe, and somebody else wrote it: approve.
    (should (equal (gh-review-claude-test--ids (gh-review-claude-actions safe nil nil))
                   '(approve* nothing)))
    ;; Follow-ups go to the originating conversation when there is one...
    (should (equal (gh-review-claude-test--ids (gh-review-claude-actions safe-follow t origin))
                   '(merge+origin* merge follow-ups+origin nothing)))
    ;; ...and to a new one otherwise.
    (should (equal (gh-review-claude-test--ids (gh-review-claude-actions safe-follow nil nil))
                   '(approve+new* approve follow-ups+new nothing)))
    ;; Needed work from one of the user's conversations goes back there.
    (should (equal (car (gh-review-claude-test--ids (gh-review-claude-actions work nil origin)))
                   'fix-in-origin*))
    ;; Otherwise the user chooses: fix it in a new conversation, or ask
    ;; for the fix; neither is preselected.
    (should (equal (gh-review-claude-test--ids (gh-review-claude-actions work nil nil))
                   '(fix-myself request-changes nothing)))
    (should (equal (car (gh-review-claude-test--ids (gh-review-claude-actions unsure t nil)))
                   'ask*))))

(ert-deftest gh-review-claude-action-labels ()
  (should (string-match-p "Merge, and send the follow-ups to the conversation"
                          (gh-review-claude--action-label
                           '(:id merge :follow-ups origin :recommended t) t)))
  (should (string-match-p "(recommended)"
                          (gh-review-claude--action-label '(:id merge :recommended t) t)))
  (should (string-match-p "Comment" (gh-review-claude--action-label '(:id request-changes) t)))
  (should (string-match-p "Request changes"
                          (gh-review-claude--action-label '(:id request-changes) nil))))

;;; Messages

(ert-deftest gh-review-claude-messages-carry-items ()
  (let* ((pr (gh-review-claude-test--pr))
         (verdict (gh-review-claude-parse-verdict gh-review-claude-test--answer)))
    (let ((fixes (gh-review-claude-fixes-message pr verdict)))
      (should (string-search "https://github.com/o/r/pull/7" fixes))
      (should (string-search "fix-things" fixes))
      (should (string-search "1. Empty input (src/a.el, line 15)" fixes))
      (should (string-search "Fix: check for nil" fixes)))
    (should (string-search "gh pr checkout 7" (gh-review-claude-fix-prompt pr verdict)))
    (should (string-search "Rename helper"
                           (gh-review-claude-follow-ups-message pr verdict t)))))

;;; Origins

(defun gh-review-claude-test--write (file lines)
  "Write LINES, each a value serialized as JSON, to FILE."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (dolist (line lines)
      (insert (json-serialize line) "\n"))))

(defun gh-review-claude-test--tool-use (id command)
  "A transcript line where the assistant runs COMMAND as tool call ID."
  `(:type "assistant" :cwd "/w/repo" :timestamp "2026-10-01T10:00:00Z"
    :message (:content [(:type "tool_use" :id ,id :name "Bash"
                         :input (:command ,command))])))

(defun gh-review-claude-test--tool-result (id output)
  "A transcript line carrying OUTPUT as the result of tool call ID."
  `(:type "user" :cwd "/w/repo" :timestamp "2026-10-01T10:00:05Z"
    :message (:content [(:type "tool_result" :tool_use_id ,id :content ,output)])))

(ert-deftest gh-review-claude-origin-from-transcripts ()
  (gh-review-claude-test--with-scratch
    (let* ((pr (gh-review-claude-test--pr))
           (projects gh-review-claude-projects-directory)
           (creator (expand-file-name "-w-repo/aaaaaaaa-1111.jsonl" projects))
           (pusher (expand-file-name "-w-repo/bbbbbbbb-2222.jsonl" projects))
           (bystander (expand-file-name "-w-other/cccccccc-3333.jsonl" projects))
           (review-transcript
            (expand-file-name
             (concat (gh-review-claude--munge gh-review-cache-directory)
                     "-worktrees-o-r-7/dddddddd-4444.jsonl")
             projects)))
      (gh-review-claude-test--write
       creator
       (list '(:type "user" :message (:content "Fix the empty input bug"))
             (gh-review-claude-test--tool-use "t1" "gh pr create --fill")
             (gh-review-claude-test--tool-result "t1" "https://github.com/o/r/pull/7")))
      (gh-review-claude-test--write
       pusher
       (list (gh-review-claude-test--tool-use "t2" "git push origin fix-things")
             (gh-review-claude-test--tool-result
              "t2" "see https://github.com/o/r/pull/7 for the PR")))
      (gh-review-claude-test--write
       bystander
       (list (gh-review-claude-test--tool-use "t3" "gh pr view 7")
             (gh-review-claude-test--tool-result "t3" "https://github.com/o/r/pull/7")))
      (gh-review-claude-test--write
       review-transcript
       (list (gh-review-claude-test--tool-use "t4" "gh pr create")
             (gh-review-claude-test--tool-result "t4" "https://github.com/o/r/pull/7")))
      ;; A link to pull request 70 must not count for 7.
      (gh-review-claude-test--write
       (expand-file-name "-w-repo/eeeeeeee-5555.jsonl" projects)
       (list (gh-review-claude-test--tool-use "t5" "gh pr create")
             (gh-review-claude-test--tool-result "t5" "https://github.com/o/r/pull/70")))
      (let ((origins (gh-review-claude-find-origins pr)))
        (should (equal (mapcar (lambda (o) (plist-get o :session-id)) origins)
                       '("aaaaaaaa-1111" "bbbbbbbb-2222")))
        (should (eq (plist-get (car origins) :strength) 'created))
        (should (equal (plist-get (car origins) :cwd) "/w/repo"))
        (should (eq (plist-get (cadr origins) :strength) 'pushed)))
      (let ((origin (gh-review-claude-origin pr)))
        (should (equal (plist-get origin :session-id) "aaaaaaaa-1111"))
        (should (equal (plist-get origin :title) "Fix the empty input bug"))))))

(ert-deftest gh-review-claude-origin-record-wins ()
  (gh-review-claude-test--with-scratch
    (let ((pr (gh-review-claude-test--pr)))
      (gh-review-claude-test--write
       gh-review-claude-origins-file
       (list '(:url "https://github.com/o/r/pull/70" :session_id "wrong" :cwd "/x"
               :transcript_path "" :time "2026-10-02T00:00:00Z")
             '(:url "https://github.com/o/r/pull/7" :session_id "older" :cwd "/a"
               :transcript_path "" :time "2026-10-01T00:00:00Z")
             '(:url "https://github.com/o/r/pull/7" :session_id "newer" :cwd "/b"
               :transcript_path "" :time "2026-10-03T00:00:00Z")))
      (let ((origins (gh-review-claude-find-origins pr)))
        (should (equal (mapcar (lambda (o) (plist-get o :session-id)) origins)
                       '("newer" "older")))
        (should (equal (plist-get (car origins) :cwd) "/b"))))))

(ert-deftest gh-review-claude-origin-none-is-kept ()
  (gh-review-claude-test--with-scratch
    (let ((pr (gh-review-claude-test--pr)))
      (should-not (gh-review-claude-origin pr))
      (should (eq (gh-review-claude-state-origin (gh-review-claude-state pr)) 'none))
      ;; A fresh record of the same pull request reads the saved state.
      (let ((again (gh-review-claude-test--pr)))
        (should (eq (gh-review-claude-state-origin (gh-review-claude-state again)) 'none))))))

;;; Drafted reviews

(ert-deftest gh-review-claude-apply-draft-splits-comments ()
  (gh-review-claude-test--with-scratch
    (let* ((pr (gh-review-claude-test--pr))
           (text "```json
{\"body\": \"Two problems.\",
 \"comments\": [{\"path\": \"src/a.el\", \"line\": 15, \"side\": \"RIGHT\", \"body\": \"Handle nil.\"},
                {\"path\": \"src/a.el\", \"line\": 2, \"side\": \"RIGHT\", \"body\": \"Far away.\"}]}
```"))
      (let ((body (gh-review-claude-apply-draft pr text)))
        (should (equal (mapcar (lambda (d) (plist-get d :line)) (gh-review-pr-drafts pr))
                       '(15)))
        (should (string-prefix-p "Two problems." body))
        (should (string-search "src/a.el line 2: Far away." body))))))

;;; The publishing guard

(ert-deftest gh-review-claude-check-publish-refuses-links ()
  (should-not (gh-review-claude-check-publish "Please handle nil here." nil))
  (should-error (gh-review-claude-check-publish
                 "see https://claude.ai/code/session_0123456789abcdef" nil)
                :type 'user-error)
  (should-error (gh-review-claude-check-publish
                 "Generated with [Claude Code](https://claude.com/claude-code)" nil)
                :type 'user-error))

;;; Annotations

(ert-deftest gh-review-claude-annotations-anchor-items ()
  (gh-review-claude-test--with-scratch
    (let* ((pr (gh-review-claude-test--pr))
           (state (gh-review-claude-state pr)))
      (setf (gh-review-claude-state-verdict state)
            (gh-review-claude-parse-verdict gh-review-claude-test--answer)
            (gh-review-claude-state-head state) "headoid")
      (let ((annotations (gh-review-claude-annotations pr)))
        (should (string-match-p "needs work" (plist-get (car annotations) :heading)))
        (should-not (plist-get (car annotations) :path))
        (let ((blocker (cadr annotations)))
          (should (equal (plist-get blocker :path) "src/a.el"))
          (should (= (plist-get blocker :line) 15))
          (should (string-match-p "Fix: check for nil" (plist-get blocker :body))))))))

;;; Whole turns against a fake CLI

(defun gh-review-claude-test--fake-claude (directory)
  "Write a fake claude into DIRECTORY and return its path.
It records its arguments and standard input, then streams an init
event, the canned answer and a result."
  (let ((script (expand-file-name "fake-claude" directory))
        (answer (json-serialize
                 `(:type "assistant"
                   :message (:content [(:type "tool_use" :id "t" :name "Bash"
                                         :input (:command "git diff baseoid HEAD"))
                                       (:type "text" :text ,gh-review-claude-test--answer)])))))
    (with-temp-file script
      (insert "#!/bin/sh\n"
              "printf '%s\\n' \"$*\" >> \"" directory "/args\"\n"
              "cat >> \"" directory "/stdin\"\n"
              "echo '{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"sess-42\"}'\n"
              "cat <<'EOF'\n" answer "\nEOF\n"
              "echo '{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"done\"}'\n"))
    (set-file-modes script #o755)
    script))

(defun gh-review-claude-test--wait (state)
  "Wait until no turn of STATE runs."
  (let ((deadline (+ (float-time) 10)))
    (while (and (or (gh-review-claude-state-busy state)
                    (gh-review-claude-state-queue state))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))))

(ert-deftest gh-review-claude-review-turns ()
  (gh-review-claude-test--with-scratch
    (let* ((directory gh-review-claude-test--root)
           (gh-review-claude-program (gh-review-claude-test--fake-claude directory))
           (pr (gh-review-claude-test--pr))
           (state (gh-review-claude-state pr)))
      (cl-letf (((symbol-function 'gh-review-worktree)
                 (lambda (_pr callback &optional _on-error) (funcall callback directory)))
                ((symbol-function 'gh-review-claude-show-chat) #'ignore))
        (gh-review-claude-review pr)
        (gh-review-claude-test--wait state)
        (should (equal (gh-review-claude-state-session state) "sess-42"))
        (should (equal (gh-review-claude-state-head state) "headoid"))
        (should (eq (plist-get (gh-review-claude-state-verdict state) :verdict) 'needs-work))
        (with-current-buffer (gh-review-claude-chat-buffer pr)
          (should (string-search "git diff baseoid HEAD" (buffer-string)))
          (should (string-search "Verdict: needs work" (buffer-string))))
        ;; The first turn starts a conversation, the question resumes it.
        (let ((gh-review-claude-auto-review nil))
          (with-temp-buffer
            (setq gh-review-buffer-pr pr)
            (gh-review-claude-ask "Why is nil a problem?")))
        (gh-review-claude-test--wait state)
        (let ((args (with-temp-buffer
                      (insert-file-contents (expand-file-name "args" directory))
                      (split-string (buffer-string) "\n" t))))
          (should (= (length args) 2))
          (should-not (string-search "--resume" (car args)))
          (should (string-search "--resume sess-42" (cadr args)))
          (should (string-search "--permission-mode default" (car args))))
        (let ((stdin (with-temp-buffer
                       (insert-file-contents (expand-file-name "stdin" directory))
                       (buffer-string))))
          (should (string-search "is this pull request safe to merge?" stdin))
          (should (string-search "Why is nil a problem?" stdin)))
        ;; The state survives on disk for the next session.
        (setf (gh-review-pr-plist pr) nil)
        (should (equal (gh-review-claude-state-session (gh-review-claude-state pr))
                       "sess-42"))))))

(ert-deftest gh-review-claude-maybe-review-once-per-head ()
  (gh-review-claude-test--with-scratch
    (let* ((pr (gh-review-claude-test--pr))
           (state (gh-review-claude-state pr))
           (started 0))
      (cl-letf (((symbol-function 'gh-review-claude-review)
                 (lambda (_) (setq started (1+ started)))))
        (gh-review-claude--maybe-review pr)
        (should (= started 1))
        (setf (gh-review-claude-state-head state) "headoid")
        (gh-review-claude--maybe-review pr)
        (should (= started 1))
        (setf (gh-review-pr-head-oid pr) "newhead")
        (gh-review-claude--maybe-review pr)
        (should (= started 2))
        (let ((gh-review-claude-auto-review nil))
          (setf (gh-review-pr-head-oid pr) "newer")
          (gh-review-claude--maybe-review pr)
          (should (= started 2)))))))

(ert-deftest gh-review-claude-location-context-from-diff ()
  (gh-review-claude-test--with-scratch
    (let ((pr (gh-review-claude-test--pr)))
      (with-temp-buffer
        (gh-review-diff-mode)
        (setq gh-review-buffer-pr pr)
        (let ((gh-review-fontify nil)) (gh-review-render))
        (goto-char (point-min))
        (search-forward "new 15")
        (let ((context (gh-review-claude--location-context)))
          (should (string-search "src/a.el, line 15, the head" context))
          (should (string-search "+new 15" context)))))))

;;; The review inbox

(ert-deftest gh-review-claude-inbox-surface ()
  (gh-review-claude-test--with-scratch
    (let ((gh-review-claude--inbox 'unread)
          (fetched nil)
          (opened nil))
      (cl-letf (((symbol-function 'gh-review-load)
                 ;; Like the real load, the record leaves `new' at once.
                 (lambda (pr &optional _callback)
                   (setf (gh-review-pr-status pr) 'loading)
                   (push (gh-review-pr-key pr) fetched)))
                ((symbol-function 'display-buffer) #'ignore)
                ((symbol-function 'gh-review-open)
                 (lambda (&rest reference) (setq opened reference))))
        (gh-review-claude-surface "https://github.com/a/b/pull/1" "first note")
        (gh-review-claude-surface "https://github.com/a/b/pull/2" nil)
        ;; Surfacing the same pull request again replaces its entry.
        (gh-review-claude-surface "https://github.com/a/b/pull/1/files" "second note")
        (let ((entries (gh-review-claude--inbox-entries)))
          (should (equal (mapcar (lambda (e) (plist-get e :key)) entries)
                         '("a/b#1" "a/b#2")))
          (should (equal (plist-get (car entries) :note) "second note"))
          (should (equal (plist-get (car entries) :url) "https://github.com/a/b/pull/1")))
        ;; Each pull request is fetched once; a loaded one is not fetched again.
        (should (equal (sort fetched #'string<) '("a/b#1" "a/b#2")))
        ;; The inbox survives on disk.
        (setq gh-review-claude--inbox 'unread)
        (should (= (length (gh-review-claude--inbox-entries)) 2))
        (with-current-buffer (gh-review-claude-inbox-buffer)
          (should (string-search "second note" (buffer-string)))
          (goto-char (point-min))
          (search-forward "a/b#2")
          (gh-review-claude-inbox-open)
          (should (equal opened '("a" "b" 2)))
          (gh-review-claude-inbox-remove)
          (should (equal (mapcar (lambda (e) (plist-get e :key))
                                 (gh-review-claude--inbox-entries))
                         '("a/b#1"))))
        (should-error (gh-review-claude-surface "not a link") :type 'user-error))
      (kill-buffer "*gh-review inbox*"))))

;;; gh-review-claude-ert.el ends here
