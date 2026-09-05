;;; claude-consent-ert.el --- ERT tests for claude-consent -*- lexical-binding: t -*-
;; SPDX-License-Identifier: MIT
;;; Commentary:
;; Tests for the spool's server-free surface: layout creation,
;; territory-record round trips, pending-request reads with dead-pid
;; pruning, session matching by agent-id prefix, answer delivery, and
;; the detail rendering.  The hook side (classification, polling,
;; verdict emission) is bash exercised end to end against the real
;; CLI; nothing here talks to it.
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

(defun claude-consent-ert--spool-request (id session pid &rest extra)
  "Write a pending request ID for SESSION owned by PID; EXTRA is appended."
  (claude-consent-ensure-directories)
  (claude-consent--write-json
   (expand-file-name (concat id ".json")
                     (claude-consent--subdirectory "pending"))
   (append `((id . ,id)
             (session_id . ,session)
             (pid . ,pid)
             (created . 1)
             (deadline . ,(+ (floor (float-time)) 60))
             (tool_name . "Write")
             (target . "/elsewhere/file"))
           extra)))

;;; Layout and territory records

(ert-deftest claude-consent-spool-layout ()
  (claude-consent-ert--with-spool
    (claude-consent-ensure-directories)
    (dolist (sub '("territory" "pending" "answers"))
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

;;; Pending requests

(ert-deftest claude-consent-pending-prunes-dead-hooks ()
  (claude-consent-ert--with-spool
    (claude-consent-ert--spool-request "live-1" "abcd1234-rest" (emacs-pid))
    ;; A pid far above any default pid_max: the owning hook is gone.
    (claude-consent-ert--spool-request "dead-1" "ffff0000-rest" 4194301)
    (claude-consent--write-json (claude-consent--answer-file "dead-1")
                                '((id . "dead-1") (decision . "allow")))
    (let ((requests (claude-consent-pending-requests)))
      (should (equal (mapcar (lambda (r) (alist-get 'id r)) requests)
                     '("live-1")))
      ;; The dead entry and its unconsumed answer were pruned on read.
      (should-not (file-exists-p
                   (expand-file-name "dead-1.json"
                                     (claude-consent--subdirectory "pending"))))
      (should-not (file-exists-p (claude-consent--answer-file "dead-1"))))))

(ert-deftest claude-consent-pending-count-by-prefix ()
  (claude-consent-ert--with-spool
    (claude-consent-ert--spool-request "r1" "abcd1234-uuid-rest" (emacs-pid))
    (claude-consent-ert--spool-request "r2" "abcd1234-uuid-rest" (emacs-pid))
    (claude-consent-ert--spool-request "r3" "eeee9999-uuid-rest" (emacs-pid))
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
    (claude-consent--deliver `((id . "r9") (pid . ,(emacs-pid))
                               (tool_name . "Edit") (target . "/x"))
                             'deny "wrong repo")
    (let ((answer (claude-consent--read-json
                   (claude-consent--answer-file "r9"))))
      (should (equal (alist-get 'decision answer) "deny"))
      (should (equal (alist-get 'reason answer) "wrong repo")))))

(ert-deftest claude-consent-deliver-omits-blank-reason ()
  (claude-consent-ert--with-spool
    (claude-consent-ensure-directories)
    (claude-consent--deliver `((id . "r10") (pid . ,(emacs-pid))
                               (tool_name . "Write") (target . "/x"))
                             'allow "")
    (let ((answer (claude-consent--read-json
                   (claude-consent--answer-file "r10"))))
      (should (equal (alist-get 'decision answer) "allow"))
      (should-not (assq 'reason answer)))))

(ert-deftest claude-consent-deliver-refuses-dead-hook ()
  (claude-consent-ert--with-spool
    (claude-consent-ensure-directories)
    (should-error (claude-consent--deliver
                   '((id . "r11") (pid . 4194301))
                   'allow)
                  :type 'user-error)
    (should-error (claude-consent--deliver
                   `((pid . ,(emacs-pid)))
                   'allow)
                  :type 'user-error)))

;;; Rendering

(ert-deftest claude-consent-format-remaining ()
  (should (equal (claude-consent--format-remaining 0) "expired"))
  (should (equal (claude-consent--format-remaining 45) "45s"))
  (should (equal (claude-consent--format-remaining 125) "2m05s")))

(ert-deftest claude-consent-render-edit-request ()
  (with-temp-buffer
    (claude-consent--render-request
     `((id . "r1")
       (session_id . "abcd1234-uuid")
       (tool_name . "Edit")
       (target . "/elsewhere/file.txt")
       (cwd . "/proj")
       (deadline . ,(+ (floor (float-time)) 90))
       (territory . ((roots . ("/proj")) (name . "fix the frob")))
       (tool_input . ((file_path . "/elsewhere/file.txt")
                      (old_string . "old text here")
                      (new_string . "new text here")))))
    (let ((rendered (buffer-string)))
      (should (string-match-p "Edit outside territory" rendered))
      (should (string-match-p "fix the frob" rendered))
      (should (string-match-p "--- replaces\nold text here" rendered))
      (should (string-match-p "--- with\nnew text here" rendered)))))

(ert-deftest claude-consent-list-entries-shape ()
  (let* ((request `((id . "r1")
                    (session_id . "abcd1234-uuid")
                    (created . 1)
                    (deadline . ,(+ (floor (float-time)) 30))
                    (tool_name . "Write")
                    (target . "/elsewhere/file.txt")
                    (territory . ((roots . ("/proj"))))))
         (entry (car (claude-consent--list-entries (list request))))
         (columns (cadr entry)))
    (should (eq (car entry) request))
    (should (equal (aref columns 1) "abcd1234"))
    (should (equal (aref columns 2) "Write"))
    (should (string-match-p "s\\'" (aref columns 3)))
    (should (equal (aref columns 4) "/elsewhere/file.txt"))))

(provide 'claude-consent-ert)
;;; claude-consent-ert.el ends here
