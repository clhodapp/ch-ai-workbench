;;; mcp-tools-ert.el --- Smoke tests for the MCP agent tools -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: MIT

;;; Commentary:
;;
;; Batch-run against the full init, loaded the way load-init.el loads it
;; (package activation fires the autoload hook).  Covers: registration of
;; every tool (which also validates the MCP Parameters docstrings),
;; the non-LSP tools end to end on temp files, the auto-open scope
;; policy, the security filters (client-territory write scope, the
;; transform gate, eval-elisp in the sandboxed child), and a clean tool
;; error, not a hang, from
;; the LSP-backed tools when no server is available.

;;; Code:

(require 'ert)
(require 'cl-lib)

(package-activate-all)

(unless (featurep 'ch-emacs-config-default)
  (require 'ch-emacs-config-default))

(require 'mcp-server-lib)

;; The debug-leak knobs the latch watches.  Declaring them special here
;; makes `let'/`setq' in the latch tests bind the dynamic global the
;; watcher and `symbol-value' actually observe, whether or not the owning
;; library (url, auth-source, tramp) has loaded in this batch session.
(defvar url-debug)
(defvar auth-source-debug)
(defvar tramp-verbose)

(defun ch-mcp-tests--temp-file (content &optional suffix)
  "Create a temp file holding CONTENT (optionally with SUFFIX)."
  (let ((file (make-temp-file "mcp-tools-test" nil (or suffix ".txt"))))
    (with-temp-file file (insert content))
    file))

(defmacro ch-mcp-tests--in-territory (&rest body)
  "Run BODY with the client territory covering the test temp files.
The write verbs derive the client's territory from `default-directory'
(the stdio bridge's cwd in production); tests simulate a client
launched where the temp files live."
  (declare (indent 0))
  `(let ((default-directory temporary-file-directory))
     ,@body))

(defun ch-mcp-tests--project-dir (parent &rest children)
  "Create a project directory under PARENT: a `.git' dir plus CHILDREN.
Returns the project root.  project.el's vc detection is filesystem-only,
so a bare `.git' directory suffices without a git binary."
  (let ((root (file-name-as-directory
               (expand-file-name (make-temp-name "proj") parent))))
    (make-directory (expand-file-name ".git" root) t)
    (dolist (child children)
      (make-directory (expand-file-name child root) t))
    root))

;; Every `present' and `sidebar' call records a revision of the buffer it
;; writes.  Point the store at a throwaway file for the whole batch run so
;; no test, here or added later, writes the real history under
;; XDG_DATA_HOME.
(setq ch-mcp-server-history-file
      (make-temp-file "mcp-tools-test-history" nil ".eld"))

(defmacro ch-mcp-tests--with-history (&rest body)
  "Run BODY against a history store of its own, empty at entry.
The session-wide store above keeps tests out of the user's real file;
this isolates one test's revisions from every other test's."
  (declare (indent 0))
  `(let ((ch-mcp-server-history-file (make-temp-file "mcp-history" nil ".eld"))
         (ch-mcp-server--history nil)
         (ch-mcp-server--history-loaded nil))
     (unwind-protect
         (progn ,@body)
       (when (file-exists-p ch-mcp-server-history-file)
         (delete-file ch-mcp-server-history-file)))))

(ert-deftest ch-mcp-tools-all-registered ()
  "Every designed tool is registered under the emacs server id."
  (let ((tools (gethash "emacs" mcp-server-lib--tools)))
    (should (hash-table-p tools))
    (dolist (id '("eval-elisp" "context" "list-buffers" "buffer-text"
                  "diagnostics" "find-references" "find-definition"
                  "symbol-info" "document-outline" "modified-buffers"
                  "buffer-diff" "present" "sidebar" "edit-buffer" "edit-file"
                  "transform" "add-comment" "list-comments"
                  "feature-loaded" "hooks" "buffer-state" "key-binding"))
      (should (gethash id tools)))
    ;; The disk-writing verb is a separate name from buffer mutation so
    ;; restricted dispatch profiles can deny it structurally; a rejoined
    ;; "edit" would silently re-widen every profile built on the split.
    (should-not (gethash "edit" tools))))

(ert-deftest ch-mcp-tools-context-smoke ()
  (let ((context (ch-mcp-server--context)))
    (should (string-match-p "^buffer: " context))
    (should (string-match-p "^project: " context))
    (should (string-match-p "^region: " context))))

(ert-deftest ch-mcp-tools-buffer-text-range ()
  (with-current-buffer (get-buffer-create "ch-mcp-tests-range")
    (erase-buffer)
    (insert "l1\nl2\nl3\n"))
  (should (equal "l2\n"
                 (ch-mcp-server--buffer-text "ch-mcp-tests-range" "2" "2")))
  (should (equal "l1\nl2\nl3\n"
                 (ch-mcp-server--buffer-text "ch-mcp-tests-range")))
  (should (equal "l2\nl3\n"
                 (ch-mcp-server--buffer-text "ch-mcp-tests-range" "2"))))

(ert-deftest ch-mcp-tools-auto-open-scope ()
  "Unvisited files outside the territory and every session project are
refused by default."
  (let ((file (ch-mcp-tests--temp-file "hello\n"))
        (elsewhere (make-temp-file "mcp-elsewhere" t)))
    (let ((default-directory (file-name-as-directory elsewhere)))
      (should-error (ch-mcp-server--file-buffer file)
                    :type 'mcp-server-lib-tool-error)
      (let ((ch-mcp-server-auto-open-scope 'any-project))
        (should (buffer-live-p (ch-mcp-server--file-buffer file)))))))

(ert-deftest ch-mcp-tools-auto-open-client-territory ()
  "Files under the client's own territory auto-open without any session
buffer in their project — the agent-worktree case."
  (let ((file (ch-mcp-tests--temp-file "hello\n")))
    (ch-mcp-tests--in-territory
      (should (buffer-live-p (ch-mcp-server--file-buffer file))))))

(ert-deftest ch-mcp-tools-modified-buffers-and-diff ()
  (let* ((file (ch-mcp-tests--temp-file "one\ntwo\n"))
         (buffer (find-file-noselect file)))
    (should (equal (ch-mcp-server--buffer-diff file)
                   "Buffer matches disk (no unsaved changes)"))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert "three\n"))
    (should (string-match-p (regexp-quote file)
                            (ch-mcp-server--modified-buffers)))
    (let ((diff (ch-mcp-server--buffer-diff file)))
      (should (string-match-p "^\\+three" diff))
      (should (string-match-p "(disk)" diff))
      (should (string-match-p "(buffer)" diff)))))

(ert-deftest ch-mcp-tools-diagnostics-states-are-legible ()
  "A clean unchecked buffer is never reported as a bare empty result."
  (let* ((file (ch-mcp-tests--temp-file "plain text\n")))
    (find-file-noselect file)
    ;; Whether flymake is enabled in a plain-text buffer varies; what must
    ;; hold is that the answer names its state instead of quietly lying.
    (should (string-match-p
             "No checker enabled\\|No diagnostics\\|not yet checked"
             (ch-mcp-server--diagnostics file)))
    ;; The sweep form runs and reports the summary counts.
    (should (string-match-p "buffers checked clean"
                            (ch-mcp-server--diagnostics)))))

(ert-deftest ch-mcp-tools-find-definition-elisp ()
  "The native elisp xref backend serves definition lookups in batch."
  (let* ((file (ch-mcp-tests--temp-file
                (concat "(defun ch-mcp-tests-target ()\n  nil)\n"
                        "(defun ch-mcp-tests-caller ()\n"
                        "  (ch-mcp-tests-target))\n")
                ".el"))
         (buffer (find-file-noselect file)))
    (should buffer)
    (load file nil t)
    (let ((result (ch-mcp-server--find-definition file "4" "4")))
      (should (string-match-p "ch-mcp-tests-target" result)))))

(ert-deftest ch-mcp-tools-find-references-no-identifier ()
  (let* ((file (ch-mcp-tests--temp-file "   \n")))
    (find-file-noselect file)
    (should-error (ch-mcp-server--find-references file "1" "1")
                  :type 'mcp-server-lib-tool-error)))

(ert-deftest ch-mcp-tools-position-past-eof ()
  (let* ((file (ch-mcp-tests--temp-file "short\n")))
    (find-file-noselect file)
    (should-error (ch-mcp-server--find-definition file "99" "1")
                  :type 'mcp-server-lib-tool-error)))

(ert-deftest ch-mcp-tools-symbol-info-no-server ()
  "LSP-backed hover degrades to a clean tool error without a server."
  (let* ((file (ch-mcp-tests--temp-file "words here\n")))
    (find-file-noselect file)
    (should-error (ch-mcp-server--symbol-info file "1" "1")
                  :type 'mcp-server-lib-tool-error)))

(ert-deftest ch-mcp-tools-document-outline ()
  (let* ((file (ch-mcp-tests--temp-file
                (concat "(defun ch-mcp-tests-outline-one ()\n  nil)\n"
                        "(defvar ch-mcp-tests-outline-var nil)\n")
                ".el")))
    (find-file-noselect file)
    (let ((outline (ch-mcp-server--document-outline file)))
      (should (string-match-p "ch-mcp-tests-outline-one" outline))
      (should (string-match-p "^1: " outline)))))

(ert-deftest ch-mcp-tools-present ()
  (ch-mcp-server--present "ert-present" "# Title\n\nbody" nil "no")
  (with-current-buffer "*agent/ert-present*"
    (should (derived-mode-p 'markdown-ts-mode))
    (should visual-line-mode)
    (should (string-match-p "Title" (buffer-string)))
    (should-not (buffer-modified-p)))
  (ch-mcp-server--present "ert-present" "a.el:1:1: hit" "locations" "no")
  (with-current-buffer "*agent/ert-present*"
    (should (bound-and-true-p compilation-minor-mode))
    (should-not visual-line-mode))
  (should-error (ch-mcp-server--present "ert-present" "x" "nonsense" "no")
                :type 'mcp-server-lib-tool-error))

(ert-deftest ch-mcp-tools-sidebar ()
  "A sidebar is soft-wrapped read-only markdown that `q' disposes of."
  (ch-mcp-server--sidebar "ert-sidebar" "# Q\n\nA" "no")
  (with-current-buffer "*agent/sidebar/ert-sidebar*"
    (should (derived-mode-p 'markdown-ts-mode))
    (should visual-line-mode)
    (should ch-emacs-config-sidebar-mode)
    (should buffer-read-only)
    (should (eq (lookup-key ch-emacs-config-sidebar-mode-map (kbd "q"))
                #'ch-emacs-config-sidebar-quit))
    (should-not (buffer-modified-p)))
  (ch-mcp-server--sidebar "ert-sidebar" "again" nil)
  (let ((window (get-buffer-window "*agent/sidebar/ert-sidebar*")))
    (should window)
    (should (eq (window-parameter window 'window-side) 'right))
    (with-selected-window window
      (ch-emacs-config-sidebar-quit))
    (should-not (get-buffer "*agent/sidebar/ert-sidebar*"))))

(ert-deftest ch-mcp-tools-present-mermaid-requires-renderer ()
  "Without mmdc on PATH the error names the missing renderer."
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
    (let ((err (should-error
                (ch-mcp-server--present "ert-mermaid" "graph LR\n a --> b"
                                              "mermaid" "no")
                :type 'mcp-server-lib-tool-error)))
      (should (string-match-p "mmdc" (error-message-string err))))))

(ert-deftest ch-mcp-tools-present-mermaid-renders ()
  "A rendered diagram lands in the buffer: an image on capable displays,
raw SVG text otherwise (the batch case)."
  (skip-unless (executable-find "mmdc"))
  (ch-mcp-server--present "ert-mermaid" "graph LR\n a --> b" "mermaid" "no")
  (with-current-buffer "*agent/ert-mermaid*"
    (should-not (buffer-modified-p))
    (if (image-type-available-p 'svg)
        (should (get-char-property (point-min) 'display))
      (should (string-match-p "<svg" (buffer-string))))))

(ert-deftest ch-mcp-tools-present-mermaid-render-error-is-legible ()
  "Broken mermaid source comes back as a tool error, not a wiped buffer."
  (skip-unless (executable-find "mmdc"))
  (ch-mcp-server--present "ert-mermaid-err" "kept" "markdown" "no")
  (should-error
   (ch-mcp-server--present "ert-mermaid-err" "graph LR\n a -->" "mermaid" "no")
   :type 'mcp-server-lib-tool-error)
  (with-current-buffer "*agent/ert-mermaid-err*"
    (should (string-match-p "kept" (buffer-string)))))

(ert-deftest ch-mcp-tools-mermaid-labels-are-librsvg-legible ()
  "Rendered SVGs must carry labels as native <text>, never <foreignObject>.
librsvg (Emacs's SVG renderer) silently drops foreignObject, producing a
diagram whose every label is invisible — found live on first use."
  (skip-unless (executable-find "mmdc"))
  (let ((svg (ch-mcp-server--render-mermaid
              "graph LR\n a -->|edge label| b[node label]")))
    (should-not (string-match-p "foreignObject" svg))
    (should (string-match-p "<text" svg))))

(ert-deftest ch-mcp-tools-buffer-text-numbered ()
  (with-current-buffer (get-buffer-create "ch-mcp-tests-numbered")
    (erase-buffer)
    (insert "l1\nl2\nl3\n"))
  (should (equal (format "%6d\tl2\n" 2)
                 (ch-mcp-server--buffer-text
                  "ch-mcp-tests-numbered" "2" "2" "yes")))
  (should (equal (concat (format "%6d\tl2\n" 2) (format "%6d\tl3\n" 3))
                 (ch-mcp-server--buffer-text
                  "ch-mcp-tests-numbered" "2" nil "yes"))))

(ert-deftest ch-mcp-tools-edit-file-unique-match ()
  "The native-Edit happy path: unique match, diff back, saved to disk."
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "alpha\nbeta\ngamma\n")))
      (find-file-noselect file)
      (let ((diff (ch-mcp-server--edit-file "beta" "delta" file)))
        (should (string-match-p "^-beta" diff))
        (should (string-match-p "^\\+delta" diff)))
      (with-temp-buffer
        (insert-file-contents file)
        (should (equal (buffer-string) "alpha\ndelta\ngamma\n")))
      (should-not (buffer-modified-p (find-buffer-visiting file))))))

(ert-deftest ch-mcp-tools-edit-file-not-found ()
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "alpha\n")))
      (find-file-noselect file)
      (should-error (ch-mcp-server--edit-file "missing" "x" file)
                    :type 'mcp-server-lib-tool-error))))

(ert-deftest ch-mcp-tools-edit-file-non-unique-names-count ()
  "A multi-match without replace-all fails loudly, naming the count."
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "dup\ndup\ndup\n")))
      (find-file-noselect file)
      (let ((err (should-error (ch-mcp-server--edit-file "dup" "x" file)
                               :type 'mcp-server-lib-tool-error)))
        (should (string-match-p "3 times" (error-message-string err))))
      ;; And the buffer was left untouched.
      (with-temp-buffer
        (insert-file-contents file)
        (should (equal (buffer-string) "dup\ndup\ndup\n"))))))

(ert-deftest ch-mcp-tools-edit-file-replace-all ()
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "dup one\ndup two\n")))
      (find-file-noselect file)
      (ch-mcp-server--edit-file "dup" "rep" file "yes")
      (with-temp-buffer
        (insert-file-contents file)
        (should (equal (buffer-string) "rep one\nrep two\n"))))))

(ert-deftest ch-mcp-tools-edit-file-replacement-containing-target ()
  "NEW-STRING containing OLD-STRING must not be re-matched (no runaway)."
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "a\n")))
      (find-file-noselect file)
      (ch-mcp-server--edit-file "a" "aa" file "yes")
      (with-temp-buffer
        (insert-file-contents file)
        (should (equal (buffer-string) "aa\n"))))))

(ert-deftest ch-mcp-tools-edit-file-identical-strings ()
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "alpha\n")))
      (find-file-noselect file)
      (should-error (ch-mcp-server--edit-file "alpha" "alpha" file)
                    :type 'mcp-server-lib-tool-error))))

(ert-deftest ch-mcp-tools-edit-buffer-no-such-buffer ()
  (should-error (ch-mcp-server--edit-buffer "a" "b" "no-such-buffer")
                :type 'mcp-server-lib-tool-error))

(ert-deftest ch-mcp-tools-edit-buffer-non-file ()
  "Non-file buffers (the collaboration case) are edited in place."
  (with-current-buffer (get-buffer-create "*agent/ert-edit*")
    (erase-buffer)
    (insert "shared state\n"))
  (let ((diff (ch-mcp-server--edit-buffer "shared" "common"
                                                "*agent/ert-edit*")))
    (should (string-match-p "^\\+common state" diff)))
  (with-current-buffer "*agent/ert-edit*"
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "common state\n"))))

(ert-deftest ch-mcp-tools-edit-buffer-empty-old-inserts-into-empty-buffer ()
  "The only write path into a fresh buffer: empty OLD-STRING inserts."
  (with-current-buffer (get-buffer-create "*agent/ert-edit-empty*")
    (erase-buffer))
  (let ((diff (ch-mcp-server--edit-buffer "" "a poem\n"
                                                "*agent/ert-edit-empty*")))
    (should (string-match-p "^\\+a poem" diff)))
  (with-current-buffer "*agent/ert-edit-empty*"
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "a poem\n"))))

(ert-deftest ch-mcp-tools-edit-file-empty-old-inserts-into-empty-file ()
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "")))
      (find-file-noselect file)
      (ch-mcp-server--edit-file "" "content\n" file)
      (with-temp-buffer
        (insert-file-contents file)
        (should (equal (buffer-string) "content\n"))))))

(ert-deftest ch-mcp-tools-edit-file-empty-old-rejected-on-content ()
  "An empty OLD-STRING is ambiguous anywhere but an empty buffer."
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "alpha\n")))
      (find-file-noselect file)
      (let ((err (should-error (ch-mcp-server--edit-file "" "x" file)
                               :type 'mcp-server-lib-tool-error)))
        (should (string-match-p "empty buffer" (error-message-string err)))))))

(ert-deftest ch-mcp-tools-edit-file-refuses-dirty-buffer ()
  "Disk writes over newer buffer state escalate instead (consent-gate.md)."
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "alpha\n"))
           (buffer (find-file-noselect file)))
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert "user edit\n"))
      (let ((err (should-error (ch-mcp-server--edit-file "alpha" "beta" file)
                               :type 'mcp-server-lib-tool-error)))
        (should (string-match-p "edit-buffer" (error-message-string err))))
      ;; Neither disk nor the buffer moved.
      (with-temp-buffer
        (insert-file-contents file)
        (should (equal (buffer-string) "alpha\n")))
      (with-current-buffer buffer
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       "alpha\nuser edit\n"))))))

(ert-deftest ch-mcp-tools-edit-buffer-stages-file-buffer ()
  "Buffer-target editing of a file's buffer never writes disk: the
change stays as a staged (modified, unsaved) edit for the user."
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "alpha\n"))
           (buffer (find-file-noselect file)))
      (ch-mcp-server--edit-buffer "alpha" "beta" (buffer-name buffer))
      (should (buffer-modified-p buffer))
      (with-temp-buffer
        (insert-file-contents file)
        (should (equal (buffer-string) "alpha\n"))))))

(ert-deftest ch-mcp-tools-edit-buffer-accepts-dirty-file-buffer ()
  "Unsaved user modifications are workable state for buffer mutation --
the correction case the buffer verb exists for -- and still never
reach disk from here."
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "alpha\n"))
           (buffer (find-file-noselect file)))
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert "user edit\n"))
      (let ((diff (ch-mcp-server--edit-buffer "user edit" "user edit, corrected"
                                                    (buffer-name buffer))))
        (should (string-match-p "^\\+user edit, corrected" diff)))
      (should (buffer-modified-p buffer))
      (with-temp-buffer
        (insert-file-contents file)
        (should (equal (buffer-string) "alpha\n"))))))

(ert-deftest ch-mcp-tools-transform ()
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "alpha\nbeta\n")))
      (find-file-noselect file)
      (let ((diff (ch-mcp-server--transform
                   file
                   (concat "(goto-char (point-min))"
                           "(while (re-search-forward \"beta\" nil t)"
                           "  (replace-match \"gamma\"))"))))
        (should (string-match-p "^-beta" diff))
        (should (string-match-p "^\\+gamma" diff)))
      ;; Saved by default: the change reached disk and the buffer is clean.
      (with-temp-buffer
        (insert-file-contents file)
        (should (equal (buffer-string) "alpha\ngamma\n")))
      (should-not (buffer-modified-p (find-buffer-visiting file))))))

(ert-deftest ch-mcp-tools-transform-no-save ()
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "alpha\n")))
      (find-file-noselect file)
      (let ((diff (ch-mcp-server--transform
                   file
                   "(goto-char (point-max)) (insert \"omega\\n\")"
                   "no")))
        (should (string-match-p "^\\+omega" diff)))
      (should (buffer-modified-p (find-buffer-visiting file)))
      (with-temp-buffer
        (insert-file-contents file)
        (should (equal (buffer-string) "alpha\n"))))))

(ert-deftest ch-mcp-tools-transform-refuses-dirty-buffer ()
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "alpha\n"))
           (buffer (find-file-noselect file)))
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert "user edit\n"))
      (should-error (ch-mcp-server--transform file "(ignore)")
                    :type 'mcp-server-lib-tool-error))))

(ert-deftest ch-mcp-tools-transform-restores-on-error ()
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "alpha\n"))
           (buffer (find-file-noselect file)))
      (should-error (ch-mcp-server--transform
                     file
                     "(goto-char (point-max)) (insert \"junk\") (error \"boom\")")
                    :type 'mcp-server-lib-tool-error)
      (with-current-buffer buffer
        (should (equal (buffer-substring-no-properties (point-min) (point-max))
                       "alpha\n"))
        (should-not (buffer-modified-p))))))

(ert-deftest ch-mcp-tools-transform-no-changes ()
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "alpha\n")))
      (find-file-noselect file)
      (should (equal "No changes"
                     (ch-mcp-server--transform file "(ignore)"))))))

;;; Security filters: client-territory write scope

(ert-deftest ch-mcp-tools-write-scope-nested-projects-are-territory ()
  "A client at a workspace root writes into nested submodule checkouts
and worktrees: territory is path containment under the client's
project root, not project identity."
  (let* ((ws (ch-mcp-tests--project-dir temporary-file-directory))
         (sub (ch-mcp-tests--project-dir (concat ws "projects/")))
         (file (concat sub "inner.txt")))
    (with-temp-file file (insert "alpha\n"))
    (let ((default-directory ws))
      (should (string-match-p "^\\+beta"
                              (ch-mcp-server--edit-file
                               "alpha" "beta" file))))))

(ert-deftest ch-mcp-tools-write-scope-blocks-outside-territory ()
  "A client launched inside one project cannot write a sibling's or the
parent's files; the error names the territory."
  (let* ((ws (ch-mcp-tests--project-dir temporary-file-directory))
         (sub (ch-mcp-tests--project-dir (concat ws "projects/")))
         (outer (concat ws "outer.txt")))
    (with-temp-file outer (insert "alpha\n"))
    (find-file-noselect outer)
    (let ((default-directory sub))
      (let ((err (should-error
                  (ch-mcp-server--edit-file "alpha" "beta" outer)
                  :type 'mcp-server-lib-tool-error)))
        (should (string-match-p "territory" (error-message-string err))))
      (should-error (ch-mcp-server--transform
                     outer "(goto-char (point-min)) (insert \"x\")")
                    :type 'mcp-server-lib-tool-error))
    ;; Nothing reached disk.
    (with-temp-buffer
      (insert-file-contents outer)
      (should (equal (buffer-string) "alpha\n")))))

(ert-deftest ch-mcp-tools-write-scope-worktree-is-confined ()
  "A client launched in a worktree checkout under the main tree stays
confined to it: the main checkout's files are out of territory."
  (let* ((ws (ch-mcp-tests--project-dir temporary-file-directory))
         (wt (ch-mcp-tests--project-dir (concat ws ".claude/worktrees/")))
         (main-file (concat ws "main.txt"))
         (wt-file (concat wt "inner.txt")))
    (with-temp-file main-file (insert "alpha\n"))
    (with-temp-file wt-file (insert "alpha\n"))
    (find-file-noselect main-file)
    (let ((default-directory wt))
      (should-error (ch-mcp-server--edit-file "alpha" "beta" main-file)
                    :type 'mcp-server-lib-tool-error)
      (should (string-match-p "^\\+beta"
                              (ch-mcp-server--edit-file
                               "alpha" "beta" wt-file))))))

(ert-deftest ch-mcp-tools-write-scope-edit-buffer-file-backed ()
  "edit-buffer refuses buffers backed by out-of-territory files even
though it never writes disk; non-file buffers stay editable."
  (let* ((ws (ch-mcp-tests--project-dir temporary-file-directory))
         (file (ch-mcp-tests--temp-file "alpha\n"))
         (buffer (find-file-noselect file)))
    (let ((default-directory ws))
      (should-error (ch-mcp-server--edit-buffer
                     "alpha" "beta" (buffer-name buffer))
                    :type 'mcp-server-lib-tool-error)
      (with-current-buffer (get-buffer-create "*agent/ert-territory*")
        (erase-buffer)
        (insert "alpha\n"))
      (should (string-match-p "^\\+beta"
                              (ch-mcp-server--edit-buffer
                               "alpha" "beta" "*agent/ert-territory*"))))))

(ert-deftest ch-mcp-tools-write-scope-unrestricted-knob ()
  "The resident user can lift the write scope."
  (let* ((ws (ch-mcp-tests--project-dir temporary-file-directory))
         (file (ch-mcp-tests--temp-file "alpha\n")))
    (find-file-noselect file)
    (let ((default-directory ws)
          (ch-mcp-server-write-scope 'unrestricted))
      (should (string-match-p "^\\+beta"
                              (ch-mcp-server--edit-file
                               "alpha" "beta" file))))))

;;; Security filters: eval-elisp in the child, the transform gate

(ert-deftest ch-mcp-tools-eval-elisp-runs-in-the-child ()
  "eval-elisp answers from the sandboxed child: the configuration is
there, this session's state is not, and a stateful form changes only
the child."
  (unless (ch-mcp-tests--bwrap-usable-p)
    (ert-skip "bwrap cannot create a user namespace here"))
  (unwind-protect
      (progn
        (should (equal "3" (ch-mcp-server--eval-elisp "(+ 1 2)")))
        (should (equal "t" (ch-mcp-server--eval-elisp
                            "(featurep 'ch-emacs-config-default)")))
        ;; A value with no readable form still prints, in the child.
        (should (string-prefix-p "#<buffer"
                                 (ch-mcp-server--eval-elisp "(current-buffer)")))
        ;; This session's buffers and environment are not there.
        (get-buffer-create "ch-mcp-tests-parent-only")
        (should (equal "nil" (ch-mcp-server--eval-elisp
                              "(get-buffer \"ch-mcp-tests-parent-only\")")))
        (should-not (equal (format "%S" (getenv "HOME"))
                           (ch-mcp-server--eval-elisp "(getenv \"HOME\")")))
        ;; A stateful form runs, and changes only the child.
        (should (equal "1" (ch-mcp-server--eval-elisp
                            "(setq ch-mcp-tests--child-only 1)")))
        (should-not (boundp 'ch-mcp-tests--child-only)))
    (ch-mcp-server-child-stop)))

(ert-deftest ch-mcp-tools-eval-elisp-child-error-is-a-tool-error ()
  "An error signalled in the child comes back as a tool error carrying
the child's message."
  (unless (ch-mcp-tests--bwrap-usable-p)
    (ert-skip "bwrap cannot create a user namespace here"))
  (unwind-protect
      (let ((err (should-error (ch-mcp-server--eval-elisp
                                "(error \"boom %d\" 7)")
                               :type 'mcp-server-lib-tool-error)))
        (should (string-match-p "boom 7" (error-message-string err))))
    (ch-mcp-server-child-stop)))

(ert-deftest ch-mcp-tools-eval-elisp-timeout-discards-the-child ()
  "A form past the deadline is a tool error, the child is stopped, and
the next call answers from a fresh one."
  (unless (ch-mcp-tests--bwrap-usable-p)
    (ert-skip "bwrap cannot create a user namespace here"))
  (unwind-protect
      (progn
        (let ((ch-mcp-server-eval-timeout 1))
          (let ((err (should-error (ch-mcp-server--eval-elisp "(sleep-for 3)")
                                   :type 'mcp-server-lib-tool-error)))
            (should (string-match-p "timed out" (error-message-string err)))))
        (should-not ch-mcp-server--child)
        (should (equal "3" (ch-mcp-server--eval-elisp "(+ 1 2)"))))
    (ch-mcp-server-child-stop)))

(ert-deftest ch-mcp-tools-eval-elisp-unrestricted-knob ()
  "The resident user's say-so path: `unrestricted' scope evaluates in
this Emacs, ungated."
  (let ((ch-mcp-server-elisp-scope 'unrestricted))
    (should (equal "42" (ch-mcp-server--eval-elisp
                         "(with-temp-buffer (insert \"42\") (string-to-number (buffer-string)))")))))

(ert-deftest ch-mcp-tools-transform-gate-blocks-side-effects ()
  "The transform gate rejects mutation outside the buffer, I/O, and
indirect calls before evaluation, naming the offender."
  (dolist (bad '((delete-file "/tmp/x")
                 (setq some-global-var 1)
                 (funcall (intern "delete-file") "/tmp/x")
                 (eval '(delete-file "/tmp/x"))
                 (shell-command "true")))
    (let ((err (should-error (ch-mcp-server--gate-elisp bad "transform" t)
                             :type 'mcp-server-lib-tool-error)))
      (should (string-match-p "unsafe" (error-message-string err))))))

(ert-deftest ch-mcp-tools-transform-gate-protects-its-own-knobs ()
  "Gated elisp can neither set nor bind the filter configuration."
  (dolist (bad '((setq ch-mcp-server-elisp-scope 'unrestricted)
                 (let ((ch-mcp-server-elisp-scope 'unrestricted)) (eval '(+ 1 2)))
                 (setq ch-mcp-server-write-scope 'unrestricted)
                 (push 'shell-command ch-mcp-server-agent-safe-functions)))
    (should-error (ch-mcp-server--gate-elisp bad "transform" t)
                  :type 'mcp-server-lib-tool-error)))

(ert-deftest ch-mcp-tools-transform-agent-safe-registry ()
  "The user-extensible registry admits functions unsafep does not know."
  (defun ch-mcp-tests--blessed () "blessed")
  (should-error (ch-mcp-server--gate-elisp '(ch-mcp-tests--blessed)
                                           "transform" t)
                :type 'mcp-server-lib-tool-error)
  (let ((ch-mcp-server-agent-safe-functions
         (cons 'ch-mcp-tests--blessed ch-mcp-server-agent-safe-functions)))
    (should-not (ch-mcp-server--gate-elisp '(ch-mcp-tests--blessed)
                                           "transform" t))))

(ert-deftest ch-mcp-tools-transform-gate-blocks-escapes ()
  "transform's elisp may move and edit in the target buffer only: no
shell, no other buffers, no replace-regexp (its replacements evaluate
embedded elisp), no kill ring."
  (ch-mcp-tests--in-territory
    (let ((file (ch-mcp-tests--temp-file "alpha\n")))
      (find-file-noselect file)
      (dolist (bad '("(shell-command \"true\")"
                     "(set-buffer (other-buffer))"
                     "(with-current-buffer (other-buffer) (insert \"x\"))"
                     "(replace-regexp \"a\" \"b\")"
                     "(kill-region (point-min) (point-max))"
                     "(save-buffer)"
                     "(write-region (point-min) (point-max) \"/tmp/out\")"))
        (let ((err (should-error (ch-mcp-server--transform file bad)
                                 :type 'mcp-server-lib-tool-error)))
          (should (string-match-p "unsafe" (error-message-string err)))))
      ;; And the buffer never moved.
      (with-temp-buffer
        (insert-file-contents file)
        (should (equal (buffer-string) "alpha\n"))))))

(ert-deftest ch-mcp-tools-knobs-are-risky ()
  "The filter knobs and registries carry `risky-local-variable', the
property unsafep keys its binding refusals on."
  (dolist (var '(ch-mcp-server-write-scope
                 ch-mcp-server-elisp-scope
                 ch-mcp-server-agent-safe-functions
                 ch-mcp-server-agent-safe-editing-functions
                 ch-mcp-server-hidden-buffer-names
                 ch-mcp-server-debug-leak-knobs))
    (should (get var 'risky-local-variable))))

(ert-deftest ch-mcp-tools-present-refuses-file-buffers ()
  "present only writes *agent/...* scratch buffers; a file-visiting
buffer squatting on the name is refused, not erased."
  (let ((buffer (find-file-noselect (ch-mcp-tests--temp-file "keep\n"))))
    (with-current-buffer buffer
      (rename-buffer "*agent/ert-squatter*"))
    (unwind-protect
        (progn
          (should-error (ch-mcp-server--present
                         "ert-squatter" "new content" nil "no")
                        :type 'mcp-server-lib-tool-error)
          (with-current-buffer "*agent/ert-squatter*"
            (should (string-match-p "keep" (buffer-string)))))
      (kill-buffer buffer))))

;;; Read scope: the buffer-readability predicate

(ert-deftest ch-mcp-tools-buffer-readable-file-in-territory ()
  "A file-visiting buffer in scope is readable; one outside scope is not."
  (let* ((file (ch-mcp-tests--temp-file "hello\n"))
         (buffer (find-file-noselect file))
         (elsewhere (make-temp-file "mcp-readable-elsewhere" t)))
    (ch-mcp-tests--in-territory
      (should (ch-mcp-server--buffer-readable-p buffer)))
    (let ((default-directory (file-name-as-directory elsewhere)))
      ;; No session buffer in the temp file's own project, and the client
      ;; sits elsewhere, so the default session-projects scope hides it.
      (should-not (ch-mcp-server--buffer-readable-p buffer))
      (let ((ch-mcp-server-auto-open-scope 'any-project))
        (should (ch-mcp-server--buffer-readable-p buffer))))))

(ert-deftest ch-mcp-tools-buffer-readable-non-file ()
  "A normal no-file buffer is readable; internal and hidden names are not."
  (with-current-buffer (get-buffer-create "ch-mcp-tests-normal")
    (should (ch-mcp-server--buffer-readable-p (current-buffer))))
  (with-current-buffer (get-buffer-create " ch-mcp-tests-internal")
    (should-not (ch-mcp-server--buffer-readable-p (current-buffer))))
  (with-current-buffer (get-buffer-create "*gptel-log*")
    (should-not (ch-mcp-server--buffer-readable-p (current-buffer))))
  ;; The hidden list is honoured dynamically.
  (with-current-buffer (get-buffer-create "ch-mcp-tests-secret")
    (let ((ch-mcp-server-hidden-buffer-names
           '("\\`ch-mcp-tests-secret\\'")))
      (should-not (ch-mcp-server--buffer-readable-p (current-buffer))))))

;;; Read scope: the sensitive-buffer mark and the terminal default

(ert-deftest ch-mcp-tools-buffer-sensitivity-explicit ()
  "A normal buffer is readable; an explicit `sensitive' withholds it."
  (with-current-buffer (get-buffer-create "ch-mcp-tests-sensitive")
    (should (ch-mcp-server--buffer-readable-p (current-buffer)))
    (setq ch-mcp-server-buffer-sensitivity 'sensitive)
    (should-not (ch-mcp-server--buffer-readable-p (current-buffer)))
    (should (ch-mcp-server--buffer-sensitive-p (current-buffer)))))

(ert-deftest ch-mcp-tools-terminal-sensitive-by-default ()
  "A ghostel terminal is withheld by default; the toggle exposes and withholds."
  (with-current-buffer (get-buffer-create "ch-mcp-tests-terminal")
    ;; `derived-mode-p' reads the buffer-local `major-mode', so setting it
    ;; makes the buffer look like a terminal without the package.
    (setq-local major-mode 'ghostel-mode)
    (should-not (ch-mcp-server--buffer-readable-p (current-buffer)))
    (should (ch-mcp-server--buffer-sensitive-p (current-buffer)))
    (ch-mcp-server-toggle-buffer-sensitive)
    (should (eq ch-mcp-server-buffer-sensitivity 'exposed))
    (should (ch-mcp-server--buffer-readable-p (current-buffer)))
    (ch-mcp-server-toggle-buffer-sensitive)
    (should (eq ch-mcp-server-buffer-sensitivity 'sensitive))
    (should-not (ch-mcp-server--buffer-readable-p (current-buffer)))))

(ert-deftest ch-mcp-tools-toggle-works-in-any-buffer ()
  "The toggle is generic: it withholds a readable buffer and exposes it again."
  (with-current-buffer (get-buffer-create "ch-mcp-tests-not-terminal")
    (should (ch-mcp-server--buffer-readable-p (current-buffer)))
    (ch-mcp-server-toggle-buffer-sensitive)
    (should (eq ch-mcp-server-buffer-sensitivity 'sensitive))
    (should-not (ch-mcp-server--buffer-readable-p (current-buffer)))
    (ch-mcp-server-toggle-buffer-sensitive)
    (should (eq ch-mcp-server-buffer-sensitivity 'exposed))
    (should (ch-mcp-server--buffer-readable-p (current-buffer)))))

(ert-deftest ch-mcp-tools-mode-line-shows-visibility ()
  "The mode-line fragment says hidden for a withheld buffer and visible
otherwise, tracks the toggle, and is installed in `global-mode-string'."
  (should (memq ch-mcp-server--mode-line-construct global-mode-string))
  (with-current-buffer (get-buffer-create "ch-mcp-tests-modeline-plain")
    (should (equal (ch-mcp-server--mode-line)
                   ch-mcp-server-mode-line-visible))
    (ch-mcp-server-toggle-buffer-sensitive)
    (should (equal (ch-mcp-server--mode-line)
                   ch-mcp-server-mode-line-withheld)))
  (with-current-buffer (get-buffer-create "ch-mcp-tests-modeline-term")
    (setq-local major-mode 'ghostel-mode)
    (should (equal (ch-mcp-server--mode-line)
                   ch-mcp-server-mode-line-withheld))))

(ert-deftest ch-mcp-tools-terminal-modes-beyond-ghostel ()
  "Every mode in `ch-mcp-server-terminal-modes' is gated, others are not.
Uses `define-derived-mode' so the parent chain is real (what
`derived-mode-p' walks), covering a comint-derived shell as well as the
listed modes; a mode outside the list stays readable."
  ;; A throwaway comint child, to prove `comint-mode' in the list gates
  ;; shells/REPLs derived from it without each being listed.
  (define-derived-mode ch-mcp-tests--fake-shell-mode comint-mode "FakeShell")
  (define-derived-mode ch-mcp-tests--plain-mode fundamental-mode "Plain")
  (let ((ch-mcp-server-terminal-modes '(comint-mode eshell-mode term-mode)))
    (with-current-buffer (get-buffer-create "ch-mcp-tests-fake-shell")
      (ch-mcp-tests--fake-shell-mode)
      (should (ch-mcp-server--terminal-p))
      (should-not (ch-mcp-server--buffer-readable-p (current-buffer)))
      (ch-mcp-server-toggle-buffer-sensitive)
      (should (ch-mcp-server--buffer-readable-p (current-buffer))))
    (with-current-buffer (get-buffer-create "ch-mcp-tests-plain")
      (ch-mcp-tests--plain-mode)
      (should-not (ch-mcp-server--terminal-p))
      (should (ch-mcp-server--buffer-readable-p (current-buffer))))))

(ert-deftest ch-mcp-tools-sensitive-file-patterns-are-a-default ()
  "A buffer visiting a matching file name is sensitive by default, with
the state still unset; the toggle exposes it like a terminal."
  (with-current-buffer (get-buffer-create "ch-mcp-tests-authinfo")
    (setq ch-mcp-server-buffer-sensitivity nil)
    (let ((buffer-file-name (expand-file-name ".authinfo" temporary-file-directory)))
      (should (ch-mcp-server--buffer-sensitive-p (current-buffer)))
      (should-not ch-mcp-server-buffer-sensitivity)
      (should-not (ch-mcp-server--buffer-readable-p (current-buffer)))
      (ch-mcp-server-toggle-buffer-sensitive)
      (should (eq ch-mcp-server-buffer-sensitivity 'exposed))
      (should (ch-mcp-server--buffer-readable-p (current-buffer)))))
  (with-current-buffer (get-buffer-create "ch-mcp-tests-env")
    (setq ch-mcp-server-buffer-sensitivity nil)
    (let ((buffer-file-name (expand-file-name ".env.local" temporary-file-directory)))
      (should (ch-mcp-server--buffer-sensitive-p (current-buffer)))))
  (with-current-buffer (get-buffer-create "ch-mcp-tests-plain")
    (setq ch-mcp-server-buffer-sensitivity nil)
    (let ((buffer-file-name (expand-file-name "notes.txt" temporary-file-directory)))
      (should-not (ch-mcp-server--buffer-sensitive-p (current-buffer))))))

(ert-deftest ch-mcp-tools-buffer-sensitivity-safe-local-variable ()
  "A file cannot expose itself via a file-local variable: the
`safe-local-variable' guard admits only nil (unset)."
  (should (eq (get 'ch-mcp-server-buffer-sensitivity 'safe-local-variable)
              #'null))
  (should (safe-local-variable-p 'ch-mcp-server-buffer-sensitivity nil))
  (should-not (safe-local-variable-p 'ch-mcp-server-buffer-sensitivity 'exposed))
  (should-not (safe-local-variable-p 'ch-mcp-server-buffer-sensitivity 'sensitive)))

(ert-deftest ch-mcp-tools-buffer-text-refuses-sensitive ()
  "buffer-text throws for a flagged buffer and for a default terminal."
  (with-current-buffer (get-buffer-create "ch-mcp-tests-bt-sensitive")
    (erase-buffer)
    (insert "secret\n")
    (setq ch-mcp-server-buffer-sensitivity 'sensitive))
  (let ((err (should-error
              (ch-mcp-server--buffer-text "ch-mcp-tests-bt-sensitive")
              :type 'mcp-server-lib-tool-error)))
    (should (string-match-p "sensitive" (error-message-string err))))
  (with-current-buffer (get-buffer-create "ch-mcp-tests-bt-terminal")
    (erase-buffer)
    (insert "prompt$\n")
    (setq-local major-mode 'ghostel-mode))
  (let ((err (should-error
              (ch-mcp-server--buffer-text "ch-mcp-tests-bt-terminal")
              :type 'mcp-server-lib-tool-error)))
    (should (string-match-p "sensitive" (error-message-string err)))))

(ert-deftest ch-mcp-tools-list-buffers-omits-sensitive ()
  "list-buffers omits a flagged buffer and a default terminal."
  (with-current-buffer (get-buffer-create "ch-mcp-tests-lb-sensitive")
    (setq ch-mcp-server-buffer-sensitivity 'sensitive))
  (with-current-buffer (get-buffer-create "ch-mcp-tests-lb-terminal")
    (setq-local major-mode 'ghostel-mode))
  (get-buffer-create "ch-mcp-tests-lb-visible")
  (let ((listing (ch-mcp-server--list-buffers)))
    (should (string-match-p "ch-mcp-tests-lb-visible" listing))
    (should-not (string-match-p "ch-mcp-tests-lb-sensitive" listing))
    (should-not (string-match-p "ch-mcp-tests-lb-terminal" listing))))

(ert-deftest ch-mcp-tools-buffer-text-refuses-unreadable ()
  "buffer-text throws on an out-of-scope file buffer, and still throws the
missing-buffer error for a name with no buffer."
  (let* ((file (ch-mcp-tests--temp-file "secret\n"))
         (buffer (find-file-noselect file))
         (elsewhere (make-temp-file "mcp-bt-elsewhere" t)))
    (let ((default-directory (file-name-as-directory elsewhere)))
      (let ((err (should-error
                  (ch-mcp-server--buffer-text (buffer-name buffer))
                  :type 'mcp-server-lib-tool-error)))
        (should (string-match-p "not readable" (error-message-string err)))))
    (let ((err (should-error
                (ch-mcp-server--buffer-text "ch-mcp-tests-no-such")
                :type 'mcp-server-lib-tool-error)))
      (should (string-match-p "No buffer named" (error-message-string err))))))

(ert-deftest ch-mcp-tools-list-buffers-omits-unreadable ()
  "list-buffers omits an out-of-scope file buffer and a hidden buffer."
  (let* ((file (ch-mcp-tests--temp-file "secret\n"))
         (buffer (find-file-noselect file))
         (elsewhere (make-temp-file "mcp-lb-elsewhere" t)))
    (get-buffer-create "*gptel-log*")
    (get-buffer-create "ch-mcp-tests-visible")
    (let ((default-directory (file-name-as-directory elsewhere)))
      (let ((listing (ch-mcp-server--list-buffers)))
        (should (string-match-p "ch-mcp-tests-visible" listing))
        (should-not (string-match-p "gptel-log" listing))
        (should-not (string-match-p (regexp-quote (buffer-name buffer))
                                    listing))))))

;;; Session facts: the four named read-only tools

(ert-deftest ch-mcp-tools-feature-loaded ()
  "A loaded feature reports loaded; a made-up one does not; a defined
function reports fboundp, and no value is ever printed."
  (let ((result (ch-mcp-server--feature-loaded "ert")))
    (should (string-match-p "^feature: ert$" result))
    (should (string-match-p "^loaded: yes$" result)))
  (let ((result (ch-mcp-server--feature-loaded "ch-mcp-tests-no-such-feature")))
    (should (string-match-p "^loaded: no$" result))
    (should (string-match-p "^fboundp: no$" result))
    (should (string-match-p "^boundp: no$" result)))
  (let ((result (ch-mcp-server--feature-loaded "ch-mcp-server--capped")))
    (should (string-match-p "^loaded: no$" result))
    (should (string-match-p "^fboundp: yes$" result)))
  ;; A variable reports boundp, and only that: never its value.
  (defvar ch-mcp-tests--secret-var "hunter2")
  (let ((result (ch-mcp-server--feature-loaded "ch-mcp-tests--secret-var")))
    (should (string-match-p "^boundp: yes$" result))
    (should-not (string-match-p "hunter2" result))))

(defvar ch-mcp-tests--hook nil
  "A hook variable for the hooks tool tests.")

(defun ch-mcp-tests--hook-fn ()
  "A named function to put on `ch-mcp-tests--hook'."
  nil)

(ert-deftest ch-mcp-tools-hooks-global ()
  "A named function shows by name, a lambda as <lambda> with no body."
  (let ((ch-mcp-tests--hook (list #'ch-mcp-tests--hook-fn
                                  (lambda () 'closed-over-secret))))
    (let ((result (ch-mcp-server--hooks "ch-mcp-tests--hook")))
      (should (string-match-p "^hook: ch-mcp-tests--hook$" result))
      (should (string-match-p "^global: ch-mcp-tests--hook-fn$" result))
      (should (string-match-p "^global: <lambda>$" result))
      (should-not (string-match-p "closed-over-secret" result)))))

(ert-deftest ch-mcp-tools-hooks-unbound-symbol-is-refused ()
  (let ((err (should-error (ch-mcp-server--hooks "ch-mcp-tests-no-such-hook")
                           :type 'mcp-server-lib-tool-error)))
    (should (string-match-p "not a bound variable" (error-message-string err)))))

(ert-deftest ch-mcp-tools-hooks-buffer-local ()
  "A buffer-local value lists its functions and the t that means run the
global hook too."
  (with-current-buffer (get-buffer-create "ch-mcp-tests-hooks-local")
    (add-hook 'ch-mcp-tests--hook #'ch-mcp-tests--hook-fn nil t))
  (let ((result (ch-mcp-server--hooks "ch-mcp-tests--hook"
                                      "ch-mcp-tests-hooks-local")))
    (should (string-match-p "^buffer: ch-mcp-tests-hooks-local$" result))
    (should (string-match-p "^local: ch-mcp-tests--hook-fn$" result))
    (should (string-match-p "^local: t (run the global hook too)$" result))))

(ert-deftest ch-mcp-tools-hooks-refuses-withheld-buffer ()
  (with-current-buffer (get-buffer-create "ch-mcp-tests-hooks-sensitive")
    (setq ch-mcp-server-buffer-sensitivity 'sensitive))
  (let ((err (should-error (ch-mcp-server--hooks "find-file-hook"
                                                 "ch-mcp-tests-hooks-sensitive")
                           :type 'mcp-server-lib-tool-error)))
    (should (string-match-p "sensitive" (error-message-string err)))))

(ert-deftest ch-mcp-tools-buffer-state ()
  "A file-visiting buffer reports its mode, size, point, and visibility."
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "one\ntwo\nthree\n"))
           (buffer (find-file-noselect file)))
      (with-current-buffer buffer
        (goto-char (point-min))
        (forward-line 1)
        (forward-char 2))
      (let ((result (ch-mcp-server--buffer-state (buffer-name buffer))))
        (should (string-match-p (format "^buffer: %s$"
                                        (regexp-quote (buffer-name buffer)))
                                result))
        (should (string-match-p (format "^file: %s$" (regexp-quote file))
                                result))
        (should (string-match-p "^major-mode: [a-z-]+-mode$" result))
        (should (string-match-p "^minor-modes: " result))
        (should (string-match-p "^read-only: no$" result))
        (should (string-match-p "^modified: no$" result))
        (should (string-match-p "^size: 14$" result))
        (should (string-match-p "^point: 2:3$" result))
        (should (string-match-p "^evil-state: " result))
        (should (string-match-p "^input-mode: none$" result))
        (should (string-match-p "^sensitivity: unset$" result))
        (should (string-match-p "^agent-visible: yes$" result))))))

(ert-deftest ch-mcp-tools-buffer-state-refuses-terminal ()
  "A terminal is withheld from buffer-state like every other read tool."
  (with-current-buffer (get-buffer-create "ch-mcp-tests-state-terminal")
    (setq-local major-mode 'ghostel-mode))
  (let ((err (should-error
              (ch-mcp-server--buffer-state "ch-mcp-tests-state-terminal")
              :type 'mcp-server-lib-tool-error)))
    (should (string-match-p "sensitive" (error-message-string err))))
  (let ((err (should-error (ch-mcp-server--buffer-state "ch-mcp-tests-no-such")
                           :type 'mcp-server-lib-tool-error)))
    (should (string-match-p "No buffer named" (error-message-string err)))))

(ert-deftest ch-mcp-tools-key-binding ()
  "A bound chord resolves to a command symbol; a nonsense chord does not
error."
  (with-current-buffer (get-buffer-create "ch-mcp-tests-keys")
    (fundamental-mode))
  (let ((result (ch-mcp-server--key-binding "C-x C-f" "ch-mcp-tests-keys")))
    (should (string-match-p "^keys: C-x C-f$" result))
    (should (string-match-p "^buffer: ch-mcp-tests-keys$" result))
    (should (string-match-p "^binding: [a-z][a-z0-9/-]*$" result))
    (should-not (string-match-p "^binding: unbound$" result)))
  (let ((result (ch-mcp-server--key-binding "C-c C-M-S-q" "ch-mcp-tests-keys")))
    (should (string-match-p "^binding: \\(unbound\\|<keymap (prefix)>\\)$"
                            result)))
  ;; A prefix key is named as one.
  (should (string-match-p "^binding: <keymap (prefix)>$"
                          (ch-mcp-server--key-binding "C-x" "ch-mcp-tests-keys")))
  ;; No buffer named: the selected window's buffer answers.
  (should (string-match-p "^binding: " (ch-mcp-server--key-binding "C-x C-f"))))

(ert-deftest ch-mcp-tools-key-binding-refuses-withheld-buffer ()
  (with-current-buffer (get-buffer-create "ch-mcp-tests-keys-sensitive")
    (setq ch-mcp-server-buffer-sensitivity 'sensitive))
  (should-error (ch-mcp-server--key-binding "C-x C-f" "ch-mcp-tests-keys-sensitive")
                :type 'mcp-server-lib-tool-error))

;;; Read scope: the debug-knob latch

(defmacro ch-mcp-tests--with-clean-latch (&rest body)
  "Run BODY with the log-taint hash saved and restored, then cleared.
The latch keeps module-level markers; tests must not leak them."
  (declare (indent 0))
  `(let ((saved (copy-hash-table ch-mcp-server--log-taint)))
     (unwind-protect
         (progn (clrhash ch-mcp-server--log-taint) ,@body)
       (setq ch-mcp-server--log-taint saved))))

(ert-deftest ch-mcp-tools-latch-off-is-not-blocked ()
  "With every knob off a log buffer is not blocked."
  (ch-mcp-tests--with-clean-latch
    (with-current-buffer (get-buffer-create "*Messages*")
      (should-not (ch-mcp-server--log-buffer-blocked-p (current-buffer))))))

(ert-deftest ch-mcp-tools-latch-blocks-then-clears ()
  "Text written while a knob is on blocks the buffer; erasing clears it."
  (ch-mcp-tests--with-clean-latch
    (let ((messages (get-buffer-create "*Messages*")))
      (with-current-buffer messages
        (let ((inhibit-read-only t)) (erase-buffer)))
      ;; The watcher must fire on the global change, so setq/restore.
      (unwind-protect
          (progn
            (setq url-debug t)
            (with-current-buffer messages
              (let ((inhibit-read-only t))
                (goto-char (point-max))
                (insert "tainted line\n")))
            (should (eq 'url-debug
                        (ch-mcp-server--log-buffer-blocked-p messages)))
            ;; Erasing empties the tainted region: the marker collapses to
            ;; point-max and the latch clears.
            (with-current-buffer messages
              (let ((inhibit-read-only t)) (erase-buffer)))
            (should-not (ch-mcp-server--log-buffer-blocked-p messages)))
        (setq url-debug nil)))))

(ert-deftest ch-mcp-tools-latch-tramp-verbose-threshold ()
  "tramp-verbose at the ceiling is off; above it is on."
  (ch-mcp-tests--with-clean-latch
    (let ((tramp-verbose 3))
      (should-not (ch-mcp-server--knob-on-p 'tramp-verbose)))
    (let ((tramp-verbose 4))
      (should (ch-mcp-server--knob-on-p 'tramp-verbose)))))

(ert-deftest ch-mcp-tools-buffer-text-refuses-blocked-log-buffer ()
  "buffer-text throws for a blocked log buffer, naming the knob."
  (ch-mcp-tests--with-clean-latch
    (let ((warnings (get-buffer-create "*Warnings*")))
      (with-current-buffer warnings
        (let ((inhibit-read-only t)) (erase-buffer)))
      (unwind-protect
          (progn
            (setq auth-source-debug t)
            (with-current-buffer warnings
              (let ((inhibit-read-only t))
                (goto-char (point-max))
                (insert "secret in a warning\n")))
            (let ((err (should-error
                        (ch-mcp-server--buffer-text "*Warnings*")
                        :type 'mcp-server-lib-tool-error)))
              (should (string-match-p "auth-source-debug"
                                      (error-message-string err)))
              (should (string-match-p "withheld"
                                      (error-message-string err)))))
        (setq auth-source-debug nil)))))

(ert-deftest ch-mcp-tools-list-buffers-omits-blocked-log-buffer ()
  "list-buffers omits a blocked log buffer."
  (ch-mcp-tests--with-clean-latch
    (let ((backtrace (get-buffer-create "*Backtrace*")))
      (with-current-buffer backtrace
        (let ((inhibit-read-only t)) (erase-buffer)))
      (unwind-protect
          (progn
            (setq url-debug t)
            (with-current-buffer backtrace
              (let ((inhibit-read-only t))
                (goto-char (point-max))
                (insert "verbose\n")))
            (should-not (string-match-p "Backtrace"
                                        (ch-mcp-server--list-buffers))))
        (setq url-debug nil)))))

(ert-deftest ch-mcp-tools-log-watchers-idempotent ()
  "Re-installing the watchers leaves exactly one per knob (no double-fire)."
  (ch-mcp-server--install-log-watchers)
  (ch-mcp-server--install-log-watchers)
  (dolist (cell ch-mcp-server-debug-leak-knobs)
    (let ((watchers (get-variable-watchers (car cell))))
      (should (= 1 (seq-count
                    (lambda (w)
                      (eq w #'ch-mcp-server--log-knob-watcher))
                    watchers))))))


(ert-deftest ch-mcp-tools-history-records-every-write ()
  "Each present is a revision of its own, so a superseded one survives."
  (ch-mcp-tests--with-history
    (ch-mcp-server--present "ert-hist" "# v1" "markdown" "no")
    (ch-mcp-server--present "ert-hist" "# v2" "markdown" "no")
    (ch-mcp-server--sidebar "ert-hist-side" "# QA" "no")
    ;; Force a read back from disk rather than trusting the cache.
    (setq ch-mcp-server--history nil
          ch-mcp-server--history-loaded nil)
    (let ((history (ch-mcp-server--history-load)))
      (should (= (length history) 3))
      ;; Newest first.
      (should (equal (plist-get (nth 0 history) :name)
                     "*agent/sidebar/ert-hist-side*"))
      (should (equal (plist-get (nth 1 history) :content) "# v2"))
      (should (equal (plist-get (nth 2 history) :content) "# v1")))))

(ert-deftest ch-mcp-tools-history-stores-mermaid-source ()
  "A mermaid revision keeps the source, not the rendered SVG."
  (skip-unless (executable-find "mmdc"))
  (ch-mcp-tests--with-history
    (ch-mcp-server--present "ert-hist-mmd" "graph LR\n a --> b" "mermaid" "no")
    (let ((revision (car (ch-mcp-server--history-load))))
      (should (equal (plist-get revision :mode) "mermaid"))
      (should (equal (plist-get revision :content) "graph LR\n a --> b")))))

(ert-deftest ch-mcp-tools-history-caps-revisions ()
  "The oldest revisions fall off once the limit is reached."
  (ch-mcp-tests--with-history
    (let ((ch-mcp-server-history-limit 2))
      (dolist (n '("1" "2" "3"))
        (ch-mcp-server--history-record "*agent/ert-cap*" n "markdown"))
      (setq ch-mcp-server--history nil
            ch-mcp-server--history-loaded nil)
      (let ((history (ch-mcp-server--history-load)))
        (should (= (length history) 2))
        (should (equal (mapcar (lambda (r) (plist-get r :content)) history)
                       '("3" "2")))))))

(ert-deftest ch-mcp-tools-history-truncates-on-bytes ()
  "An oversized body is cut to the byte limit without splitting a character."
  (ch-mcp-tests--with-history
    (let ((ch-mcp-server-history-max-bytes 10))
      ;; Two bytes per character in UTF-8, so ten bytes is five of them.
      (ch-mcp-server--history-record "*agent/ert-big*" (make-string 50 ?é)
                                     "markdown")
      (let ((content (plist-get (car (ch-mcp-server--history-load)) :content)))
        (should (string-prefix-p (make-string 5 ?é) content))
        (should (string-match-p "truncated" content))))))

(ert-deftest ch-mcp-tools-history-survives-a-corrupt-store ()
  "A store that will not read starts an empty history instead of signalling.
Presenting must not become a tool error because the file was truncated."
  (ch-mcp-tests--with-history
    (with-temp-file ch-mcp-server-history-file (insert "((:name broken"))
    (setq ch-mcp-server--history nil
          ch-mcp-server--history-loaded nil)
    (should-not (ch-mcp-server--history-load))
    (ch-mcp-server--present "ert-hist-corrupt" "# fresh" "markdown" "no")
    (setq ch-mcp-server--history nil
          ch-mcp-server--history-loaded nil)
    (should (= (length (ch-mcp-server--history-load)) 1))))

(ert-deftest ch-mcp-tools-history-picker-opens-a-separate-buffer ()
  "Reviewing a revision must not overwrite the live *agent/...* buffer."
  (ch-mcp-tests--with-history
    (ch-mcp-server--present "ert-hist-pick" "# old" "markdown" "no")
    (ch-mcp-server--present "ert-hist-pick" "# new" "markdown" "no")
    (unwind-protect
        (cl-letf (((symbol-function 'completing-read)
                   ;; Take the second (older) candidate.
                   (lambda (_prompt collection &rest _)
                     (nth 1 (all-completions "" collection))))
                  ((symbol-function 'pop-to-buffer) #'ignore))
          (ch-mcp-server-history)
          (with-current-buffer "*agent-history/*agent/ert-hist-pick**"
            (should (string-match-p "old" (buffer-string)))
            (should buffer-read-only))
          ;; The live buffer still holds the newest presentation.
          (with-current-buffer "*agent/ert-hist-pick*"
            (should (string-match-p "new" (buffer-string)))))
      (when-let* ((buffer (get-buffer "*agent-history/*agent/ert-hist-pick**")))
        (kill-buffer buffer)))))

(ert-deftest ch-mcp-tools-history-picker-reaches-duplicate-labels ()
  "Two revisions that label identically must both be selectable.
Same buffer, same minute, same first line: without a distinguishing
suffix the completion alist would resolve both to the newer one."
  (ch-mcp-tests--with-history
    (cl-letf (((symbol-function 'current-time) (lambda () '(26000 0 0 0))))
      (ch-mcp-server--history-record "*agent/ert-dup*" "same\nfirst" "markdown")
      (ch-mcp-server--history-record "*agent/ert-dup*" "same\nsecond" "markdown"))
    (unwind-protect
        (cl-letf (((symbol-function 'completing-read)
                   ;; The older of the two identical-looking candidates.
                   (lambda (_prompt collection &rest _)
                     (nth 1 (all-completions "" collection))))
                  ((symbol-function 'pop-to-buffer) #'ignore))
          (ch-mcp-server-history)
          (with-current-buffer "*agent-history/*agent/ert-dup**"
            (should (string-match-p "first" (buffer-string)))))
      (when-let* ((buffer (get-buffer "*agent-history/*agent/ert-dup**")))
        (kill-buffer buffer)))))

;;; The child

(ert-deftest ch-mcp-tools-config-key ()
  "The configuration identity is a non-empty string, stable across calls."
  (let ((key (ch-mcp-server--config-key)))
    (should (stringp key))
    (should-not (string-empty-p key))
    (should (equal key (ch-mcp-server--config-key)))))

(ert-deftest ch-mcp-tools-child-bootstrap-shape ()
  "The bootstrap is one progn that loads the configuration and unhooks
eglot-ensure; the unhooking must stay in the form the child evaluates."
  (should (eq (car ch-mcp-server--child-bootstrap) 'progn))
  (let ((text (format "%S" ch-mcp-server--child-bootstrap)))
    (should (string-match-p "ch-emacs-config-default" text))
    (should (string-match-p "eglot-ensure" text))))

(defun ch-mcp-tests--bwrap-usable-p ()
  "Whether bwrap is present and can create a user namespace here.
The jail needs one; the nix build sandbox denies it, so the lifecycle
test skips there and runs for real outside it."
  (and (executable-find "bwrap")
       (eq 0 (call-process "bwrap" nil nil nil "--ro-bind" "/" "/" "true"))))

(ert-deftest ch-mcp-tools-child-lifecycle ()
  "Spawn, bootstrap, reuse, and stop of the sandboxed child.
The child answers arithmetic, has the configuration loaded, carries no
eglot-ensure on a mode hook, and has a real HOME in the jail; a second
ensure returns the same connection; stop leaves nothing live."
  (unless (ch-mcp-tests--bwrap-usable-p)
    (ert-skip "bwrap cannot create a user namespace here"))
  ;; The config load is slow; give the spawn room.
  (let ((ch-mcp-server-child-spawn-timeout 120)
        (conn nil))
    (unwind-protect
        (progn
          (setq conn (ch-mcp-server--child-ensure))
          (should (parenting-connection-live-p conn))
          (should (equal 3 (parenting-eval conn '(+ 1 2))))
          (should (eq t (parenting-eval
                         conn '(featurep 'ch-emacs-config-default))))
          (should-not (parenting-eval
                       conn '(memq 'eglot-ensure nix-ts-mode-hook)))
          (should (eq t (parenting-eval
                         conn '(file-directory-p (getenv "HOME")))))
          (should (eq conn (ch-mcp-server--child-ensure))))
      (ch-mcp-server-child-stop))
    (should-not ch-mcp-server--child)
    (should-not ch-mcp-server--child-key)
    (should-not (parenting-connection-live-p conn))))

;;; mcp-tools-ert.el ends here
