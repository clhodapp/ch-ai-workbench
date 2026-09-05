;;; collab-comments-ert.el --- Tests for the collab-comments integration -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: MIT

;;; Commentary:
;;
;; Batch-run against the full init, like mcp-tools-ert.el: the
;; add-comment/list-comments MCP tools with their edit-contract anchor
;; matching, and threads surviving the re-renders of `present' and the
;; claude-queue transcript views.  The package's own suite (model,
;; anchors under replacement, thread view, persistence) runs in its
;; repository, github:clhodapp/collab-comments.

;;; Code:

(require 'ert)
(require 'cl-lib)

(package-activate-all)

(unless (featurep 'ch-emacs-config-default)
  (require 'ch-emacs-config-default))

(require 'collab-comments)
(require 'mcp-server-lib)

(defmacro ch-collab-tests--with-buffer (content &rest body)
  "Run BODY in a fresh buffer holding CONTENT, cleaning up after."
  (declare (indent 1))
  `(let ((buffer (generate-new-buffer "ch-collab-test")))
     (unwind-protect
         (with-current-buffer buffer
           (insert ,content)
           (goto-char (point-min))
           ,@body)
       (mapc #'collab-comments-dismiss-thread
             (collab-comments-threads buffer))
       (kill-buffer buffer))))

(defun ch-collab-tests--thread-on (text comment)
  "Start a thread on the unique occurrence of TEXT with body COMMENT."
  (goto-char (point-min))
  (search-forward text)
  (collab-comments-add-thread (match-beginning 0) (match-end 0)
                              "tester" comment))

(defmacro ch-collab-tests--with-store (&rest body)
  "Run BODY against a private, throwaway persistence store."
  (declare (indent 0))
  `(let ((collab-comments-store-file
          (make-temp-file "collab-store" nil ".eld"))
         (collab-comments--store 'unloaded))
     (unwind-protect
         (progn ,@body)
       (when (file-exists-p collab-comments-store-file)
         (delete-file collab-comments-store-file)))))

(defun ch-collab-tests--anchor (overlay)
  "Anchor text of OVERLAY."
  (buffer-substring-no-properties (overlay-start overlay)
                                  (overlay-end overlay)))

;;; Re-renders by this config's surfaces

(ert-deftest ch-collab-mcp-present-re-render-keeps-threads ()
  "Re-running `present' under the same name keeps threads on their text."
  (let ((name "ert-collab-present"))
    (unwind-protect
        (progn
          (ch-emacs-config-mcp--present name "alpha beta gamma\n" nil "no")
          (with-current-buffer (format "*agent/%s*" name)
            (let ((overlay (ch-collab-tests--thread-on "beta" "draft note")))
              (ch-emacs-config-mcp--present
               name "# Revised\n\nalpha beta gamma\n\nmore\n" nil "no")
              (should (equal "beta" (ch-collab-tests--anchor overlay)))
              (ch-emacs-config-mcp--edit-buffer
               "beta gamma" "beta delta" (buffer-name))
              (should (equal "beta" (ch-collab-tests--anchor overlay)))
              (ch-emacs-config-mcp--edit-buffer
               "alpha beta delta" "rewritten entirely" (buffer-name))
              (should (= (overlay-start overlay) (overlay-end overlay)))
              (should-not (= (overlay-end overlay) (point-max))))))
      (when-let* ((buffer (get-buffer (format "*agent/%s*" name))))
        (mapc #'collab-comments-dismiss-thread
              (collab-comments-threads buffer))
        (kill-buffer buffer)))))

(ert-deftest ch-collab-present-does-not-re-enter-the-major-mode ()
  "`present' leaves a mode it has already set alone.
A major mode function runs `change-major-mode-hook' even when the
buffer is already in that mode, and a mode that keeps overlays of its
own (Emacs 31's `markdown-ts-mode') cleans up there with
`remove-overlays', deleting every thread in the buffer outright rather
than collapsing it.  The threads survive only because `present' skips
the redundant call, so check that directly: an overlay still attached
to its buffer, not merely anchored somewhere."
  (let ((name "ert-collab-mode"))
    (unwind-protect
        (progn
          (ch-emacs-config-mcp--present name "alpha beta gamma\n" nil "no")
          (with-current-buffer (format "*agent/%s*" name)
            (let ((mode major-mode)
                  (overlay (ch-collab-tests--thread-on "beta" "draft note")))
              (ch-emacs-config-mcp--present name "alpha beta gamma\n" nil "no")
              (should (eq major-mode mode))
              (should (overlay-buffer overlay))
              (should (equal "beta" (ch-collab-tests--anchor overlay))))))
      (when-let* ((buffer (get-buffer (format "*agent/%s*" name))))
        (mapc #'collab-comments-dismiss-thread
              (collab-comments-threads buffer))
        (kill-buffer buffer)))))

(ert-deftest ch-collab-persist-transcript-view-re-render ()
  "Threads on a claude-queue transcript view survive its re-render.
The view refreshes by erase-and-reinsert, which collapses every
overlay; `claude-queue--show-text' keys the buffer to the session and
restores from the store, re-anchoring against the appended text."
  (require 'claude-queue)
  (ch-collab-tests--with-store
    (let ((buffer nil))
      (unwind-protect
          (progn
            (claude-queue--show-text "collab-test" "alpha beta gamma\n"
                                     nil "ert-session")
            (setq buffer (get-buffer "*claude-queue: collab-test*"))
            (should buffer)
            (with-current-buffer buffer
              (should (equal collab-comments-document-key
                             "claude-session:ert-session"))
              (ch-collab-tests--thread-on "beta" "transcript note"))
            ;; Re-render with a turn appended, as a refresh does.
            (claude-queue--show-text
             "collab-test" "alpha beta gamma\nanother turn\n"
             nil "ert-session")
            (with-current-buffer buffer
              (let ((overlay (car (collab-comments-threads))))
                (should overlay)
                (should (equal "beta"
                               (buffer-substring-no-properties
                                (overlay-start overlay)
                                (overlay-end overlay))))
                (should (string-match-p
                         "transcript note"
                         (collab-comments-render-thread overlay))))))
        (when buffer
          (mapc #'collab-comments-dismiss-thread
                (collab-comments-threads buffer))
          (kill-buffer buffer))))))

;;; MCP tools

(ert-deftest ch-collab-mcp-add-comment-anchor-contract ()
  (ch-collab-tests--with-buffer "alpha beta gamma\nbeta again\n"
    (let ((name (buffer-name)))
      ;; Ambiguous anchor: named with its count, nothing created.
      (should-error (ch-emacs-config-mcp--add-comment
                     "note" nil name "beta" nil)
                    :type 'mcp-server-lib-tool-error)
      (should-not (collab-comments-threads))
      ;; Missing anchor.
      (should-error (ch-emacs-config-mcp--add-comment
                     "note" nil name "missing text" nil)
                    :type 'mcp-server-lib-tool-error)
      ;; Unique anchor: thread created, rendering returned.
      (let ((result (ch-emacs-config-mcp--add-comment
                     "note" nil name "gamma" nil)))
        (should (string-match-p "\"gamma\"" result))
        (should (string-match-p "^  claude" result))
        (should (= 1 (length (collab-comments-threads))))))))

(ert-deftest ch-collab-mcp-add-comment-reply-by-thread-id ()
  (ch-collab-tests--with-buffer "alpha beta gamma\n"
    (let* ((overlay (ch-collab-tests--thread-on "beta" "user note"))
           (id (collab-comments-thread-id overlay))
           (result (ch-emacs-config-mcp--add-comment
                    "agent reply" nil nil nil (number-to-string id))))
      (should (string-match-p "^  tester" result))
      (should (string-match-p "^    agent reply" result))
      (should (= 2 (length (collab-comments-thread-comments overlay)))))))

(ert-deftest ch-collab-mcp-add-comment-argument-errors ()
  (ch-collab-tests--with-buffer "alpha\n"
    (let ((name (buffer-name)))
      ;; thread and anchor together
      (should-error (ch-emacs-config-mcp--add-comment
                     "note" nil name "alpha" "1")
                    :type 'mcp-server-lib-tool-error)
      ;; unknown thread id
      (should-error (ch-emacs-config-mcp--add-comment
                     "note" nil nil nil "999999")
                    :type 'mcp-server-lib-tool-error)
      ;; neither anchor nor thread
      (should-error (ch-emacs-config-mcp--add-comment "note" nil name nil nil)
                    :type 'mcp-server-lib-tool-error)
      ;; empty body
      (should-error (ch-emacs-config-mcp--add-comment "  " nil name "alpha" nil)
                    :type 'mcp-server-lib-tool-error))))

(ert-deftest ch-collab-mcp-list-comments ()
  (ch-collab-tests--with-buffer "alpha beta gamma\n"
    (let ((name (buffer-name)))
      (should (equal "No comment threads"
                     (ch-emacs-config-mcp--list-comments nil name)))
      (ch-collab-tests--thread-on "alpha" "one")
      (ch-collab-tests--thread-on "gamma" "two")
      (let ((result (ch-emacs-config-mcp--list-comments nil name)))
        (should (string-match-p "\"alpha\"" result))
        (should (string-match-p "\"gamma\"" result))
        (should (string-match-p "^    one" result)))
      ;; The unfiltered sweep includes this buffer's threads too.
      (should (string-match-p "\"alpha\""
                              (ch-emacs-config-mcp--list-comments)))
      (should-error (ch-emacs-config-mcp--list-comments nil "no such buffer")
                    :type 'mcp-server-lib-tool-error))))

(ert-deftest ch-collab-mcp-add-comment-on-file ()
  (ch-collab-tests--with-store
  (let* ((file (make-temp-file "collab-comments-test" nil ".txt"))
         (buffer nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert "one two three\n"))
          (setq buffer (find-file-noselect file))
          (let ((result (ch-emacs-config-mcp--add-comment
                         "file note" file nil "two" nil)))
            (should (string-match-p "\"two\"" result))
            (should (= 1 (length (collab-comments-threads buffer)))))
          (should (string-match-p
                   "\"two\"" (ch-emacs-config-mcp--list-comments file))))
      (when buffer
        (mapc #'collab-comments-dismiss-thread
              (collab-comments-threads buffer))
        (kill-buffer buffer))
      (delete-file file)))))

(provide 'collab-comments-ert)
;;; collab-comments-ert.el ends here
