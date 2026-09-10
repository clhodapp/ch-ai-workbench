;;; claude-consent-ert.el --- ERT tests for claude-consent -*- lexical-binding: t -*-
;; SPDX-License-Identifier: MIT
;;; Commentary:
;; Tests for the spool's server-free surface: layout creation,
;; territory-record round trips, handler registration, pending-request
;; reads with stale pruning (dead waiter, expired stored record),
;; session matching by agent-id prefix, answer delivery, option keys,
;; and the detail rendering.  The hook side (classification, the ask,
;; verdict emission) is bash and Python, exercised by their own checks;
;; nothing here talks to them.
;;; Code:

(require 'ert)
(require 'claude-consent)

(defmacro claude-consent-ert--with-spool (&rest body)
  "Run BODY with `claude-consent-directory' bound to a fresh temp spool."
  (declare (indent 0))
  `(let ((claude-consent-directory
          (expand-file-name "spool" (make-temp-file "claude-consent" t))))
     (unwind-protect
         (progn ,@body)
       (delete-directory (file-name-directory
                          (directory-file-name claude-consent-directory))
                         t))))

(defconst claude-consent-ert--dead-pid 4194301
  "A pid far above any default pid_max: no such process exists.")

(defun claude-consent-ert--request (id session &rest fields)
  "A pending request ID for SESSION with the consent hook's shape.
FIELDS override or extend the defaults (a live blocking record).
Arrays are vectors, as `json-serialize' requires; the reader
returns them as lists, which is what the package's code sees."
  (append
   fields
   `((id . ,id)
     (session_id . ,session)
     (pid . ,(emacs-pid))
     (mode . "blocking")
     (created . 1)
     (deadline . ,(+ (floor (float-time)) 60))
     (prompt . ((title . "Write outside territory")
                (detail . "Target:    /elsewhere/file")
                (options . [((value . "allow") (label . "Allow this call"))
                            ((value . "deny") (label . "Deny")
                             (text . "Deny reason"))])))
     (hook . ((tool_name . "Write")
              (tool_input . ((file_path . "/elsewhere/file")
                             (content . "hello")))
              (cwd . "/proj")))
     (territory . ((roots . ["/proj"]))))))

(defun claude-consent-ert--spool-request (request)
  "Write REQUEST into the pending directory."
  (claude-consent-ensure-directories)
  (claude-consent--write-json
   (expand-file-name (concat (alist-get 'id request) ".json")
                     (claude-consent--subdirectory "pending"))
   request))

;;; Layout, territory records, handler registration

(ert-deftest claude-consent-spool-layout ()
  (claude-consent-ert--with-spool
    (claude-consent-ensure-directories)
    (dolist (sub '("territory" "handlers" "pending" "answers" "log"))
      (should (file-directory-p (claude-consent--subdirectory sub))))
    (should (equal (file-modes claude-consent-directory) #o700))))

(ert-deftest claude-consent-territory-roundtrip ()
  (claude-consent-ert--with-spool
    (let ((file (claude-consent-record-territory
                 "abcd1234" '("/tmp/proj/") 120 "fix the frob")))
      (should (file-exists-p file))
      (let ((record (claude-consent--read-json file)))
        (should (equal (alist-get 'agent_id record) "abcd1234"))
        ;; Roots are normalized: no trailing slash survives.
        (should (equal (alist-get 'roots record) '("/tmp/proj")))
        (should (equal (alist-get 'deadline record) 120))
        (should (equal (alist-get 'name record) "fix the frob")))
      (claude-consent-remove-territory "abcd1234")
      (should-not (file-exists-p file))
      ;; Removing an absent record is a quiet no-op.
      (claude-consent-remove-territory "abcd1234"))))

(ert-deftest claude-consent-territory-non-ascii-name ()
  "A non-ASCII name (the dispatcher truncates long ones with an
ellipsis) round-trips as UTF-8 without a coding-system prompt.
`json-serialize' yields unibyte text; written raw it would leave
raw-byte characters that make `write-region' ask the user (in batch,
that read fails with end-of-file)."
  (claude-consent-ert--with-spool
    (let* ((name "check up on the state of repo convergence in github. kick if if…")
           (file (claude-consent-record-territory
                  "19d919e6" '("/tmp/proj") 300 name)))
      (should (equal (alist-get 'name (claude-consent--read-json file))
                     name))
      ;; On disk the ellipsis is its three UTF-8 bytes, not an escape.
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally file)
        (should (string-search "\342\200\246" (buffer-string)))))))

(ert-deftest claude-consent-handler-registration ()
  "Registration names this process, so the tool sees it live; removal
withdraws it and tolerates its absence."
  (claude-consent-ert--with-spool
    (let ((file (claude-consent-register-handler)))
      (should (file-exists-p file))
      (let ((handler (claude-consent--read-json file)))
        (should (equal (alist-get 'name handler) "emacs"))
        (should (equal (alist-get 'pid handler) (emacs-pid))))
      (claude-consent-remove-handler)
      (should-not (file-exists-p file))
      (claude-consent-remove-handler))))

;;; Pending requests

(ert-deftest claude-consent-pending-prunes-stale ()
  (claude-consent-ert--with-spool
    (claude-consent-ert--spool-request
     (claude-consent-ert--request "live-1" "abcd1234-rest"))
    (claude-consent-ert--spool-request
     (claude-consent-ert--request "dead-1" "ffff0000-rest"
                                  `(pid . ,claude-consent-ert--dead-pid)))
    ;; A waiter record dies with its waiter too.
    (claude-consent-ert--spool-request
     (claude-consent-ert--request "waiter-dead" "ffff0000-rest"
                                  '(mode . "waiter")
                                  `(pid . ,claude-consent-ert--dead-pid)))
    ;; Stored records have no waiter: they live until their deadline.
    (claude-consent-ert--spool-request
     (claude-consent-ert--request "stored-kept" "abcd1234-rest"
                                  '(mode . "stored") '(pid . :null)
                                  '(created . 2)))
    (claude-consent-ert--spool-request
     (claude-consent-ert--request "stored-old" "abcd1234-rest"
                                  '(mode . "stored") '(pid . :null)
                                  `(deadline . ,(- (floor (float-time)) 1))))
    (claude-consent--write-json (claude-consent--answer-file "dead-1")
                                '((id . "dead-1") (value . "allow")))
    (let ((requests (claude-consent-pending-requests)))
      (should (equal (mapcar (lambda (r) (alist-get 'id r)) requests)
                     '("live-1" "stored-kept")))
      ;; The dead entry and its unconsumed answer were pruned on read.
      (should-not (file-exists-p
                   (expand-file-name "dead-1.json"
                                     (claude-consent--subdirectory "pending"))))
      (should-not (file-exists-p (claude-consent--answer-file "dead-1"))))))

(ert-deftest claude-consent-pending-count-by-prefix ()
  (claude-consent-ert--with-spool
    (claude-consent-ert--spool-request
     (claude-consent-ert--request "r1" "abcd1234-uuid-rest"))
    (claude-consent-ert--spool-request
     (claude-consent-ert--request "r2" "abcd1234-uuid-rest"))
    (claude-consent-ert--spool-request
     (claude-consent-ert--request "r3" "eeee9999-uuid-rest"))
    (let ((requests (claude-consent-pending-requests)))
      (should (= (claude-consent-session-pending-count "abcd1234" requests) 2))
      (should (= (claude-consent-session-pending-count
                  "abcd1234-uuid-rest" requests)
                 2))
      (should (= (claude-consent-session-pending-count "eeee9999" requests) 1))
      (should (= (claude-consent-session-pending-count "0000" requests) 0)))))

;;; Answer delivery

(ert-deftest claude-consent-deliver-writes-answer ()
  (claude-consent-ert--with-spool
    (claude-consent-ensure-directories)
    (claude-consent--deliver (claude-consent-ert--request "r9" "s")
                             "deny" "wrong repo")
    (let ((answer (claude-consent--read-json
                   (claude-consent--answer-file "r9"))))
      (should (equal (alist-get 'id answer) "r9"))
      (should (equal (alist-get 'value answer) "deny"))
      (should (equal (alist-get 'text answer) "wrong repo"))
      (should (numberp (alist-get 'answered answer))))))

(ert-deftest claude-consent-deliver-omits-blank-text ()
  (claude-consent-ert--with-spool
    (claude-consent-ensure-directories)
    (claude-consent--deliver (claude-consent-ert--request "r10" "s")
                             "allow" "")
    (let ((answer (claude-consent--read-json
                   (claude-consent--answer-file "r10"))))
      (should (equal (alist-get 'value answer) "allow"))
      (should-not (assq 'text answer)))))

(ert-deftest claude-consent-deliver-refuses-stale ()
  (claude-consent-ert--with-spool
    (claude-consent-ensure-directories)
    (should-error (claude-consent--deliver
                   (claude-consent-ert--request
                    "r11" "s" `(pid . ,claude-consent-ert--dead-pid))
                   "allow")
                  :type 'user-error)
    (should-error (claude-consent--deliver
                   (claude-consent-ert--request
                    "r12" "s" '(mode . "stored") '(pid . :null)
                    '(deadline . 1))
                   "allow")
                  :type 'user-error)
    (should-error (claude-consent--deliver `((pid . ,(emacs-pid))) "allow")
                  :type 'user-error)
    ;; A stored record inside its deadline takes an answer.
    (claude-consent--deliver
     (claude-consent-ert--request "r13" "s" '(mode . "stored") '(pid . :null))
     "allow")
    (should (file-exists-p (claude-consent--answer-file "r13")))))

;;; Rendering

(ert-deftest claude-consent-format-remaining ()
  (should (equal (claude-consent--format-remaining 0) "expired"))
  (should (equal (claude-consent--format-remaining 45) "45s"))
  (should (equal (claude-consent--format-remaining 125) "2m05s")))

(ert-deftest claude-consent-option-keys ()
  "Same derivation as the tool's: first character when free, else the
lowest free digit."
  (should (equal (claude-consent--option-keys
                  '(((value . "allow")) ((value . "deny"))))
                 '(?a ?d)))
  (should (equal (claude-consent--option-keys
                  '(((value . "a1")) ((value . "a2")) ((value . "-"))))
                 '(?a ?1 ?2))))

(ert-deftest claude-consent-render-edit-request ()
  (with-temp-buffer
    (claude-consent--render-request
     (claude-consent-ert--request
      "r1" "abcd1234-uuid"
      '(prompt . ((title . "Edit outside territory")
                  (detail . "Target:    /elsewhere/file.txt")
                  (options . (((value . "allow") (label . "Allow this call"))
                              ((value . "deny") (label . "Deny")
                               (text . "Deny reason"))))))
      '(hook . ((tool_name . "Edit")
                (tool_input . ((file_path . "/elsewhere/file.txt")
                               (old_string . "old text here")
                               (new_string . "new text here")))
                (cwd . "/proj")))
      '(territory . ((roots . ("/proj")) (name . "fix the frob")))))
    (let ((rendered (buffer-string)))
      (should (string-match-p "Edit outside territory" rendered))
      (should (string-match-p "fix the frob" rendered))
      (should (string-match-p "--- replaces\nold text here" rendered))
      (should (string-match-p "--- with\nnew text here" rendered))
      (should (string-match-p "\\[a\\] Allow this call" rendered))
      (should (string-match-p "\\[d\\] Deny" rendered)))))

(ert-deftest claude-consent-render-plain-prompt ()
  "A prompt with no tool context (an async question from a Stop hook,
say) renders its question and options without tool sections."
  (with-temp-buffer
    (claude-consent--render-request
     `((id . "r2") (session_id . "abcd1234-uuid") (mode . "waiter")
       (pid . ,(emacs-pid)) (created . 1)
       (deadline . ,(+ (floor (float-time)) 30))
       (prompt . ((title . "Open a pull request?")
                  (detail . "The branch is pushed.")
                  (options . (((value . "yes")) ((value . "no"))))
                  (free_text . "Title")))
       (hook . ((hook_event_name . "Stop")))))
    (let ((rendered (buffer-string)))
      (should (string-match-p "Open a pull request\\?" rendered))
      (should (string-match-p "--- question\nThe branch is pushed." rendered))
      (should (string-match-p "\\[y\\] yes" rendered))
      (should (string-match-p "\\[t\\] Title (free text)" rendered))
      (should-not (string-match-p "--- tool input" rendered)))))

(ert-deftest claude-consent-list-entries-shape ()
  (let* ((request (claude-consent-ert--request
                   "r1" "abcd1234-uuid"
                   '(territory . ((roots . ("/proj"))))))
         (entry (car (claude-consent--list-entries (list request))))
         (columns (cadr entry)))
    (should (eq (car entry) request))
    (should (equal (aref columns 1) "abcd1234"))
    (should (equal (aref columns 2) "Write outside territory"))
    (should (string-match-p "s\\'" (aref columns 3)))
    (should (equal (aref columns 4) "/elsewhere/file"))))

(provide 'claude-consent-ert)
;;; claude-consent-ert.el ends here
