;;; mcp-tools-ert.el --- Smoke tests for the MCP agent tools -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: MIT

;;; Commentary:
;;
;; Batch-run against the full init, loaded the way load-init.el loads it
;; (package activation fires the autoload hook).  Covers: registration of
;; every tool (which also validates the MCP Parameters docstrings),
;; the non-LSP tools end to end on temp files, the auto-open scope
;; policy, the security filters (client-territory write scope and the
;; agent-safe elisp gate), and a clean tool error — not a hang — from
;; the LSP-backed tools when no server is available.

;;; Code:

(require 'ert)
(require 'cl-lib)

(package-activate-all)

(unless (featurep 'ch-emacs-config-default)
  (require 'ch-emacs-config-default))

(require 'mcp-server-lib)

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

(ert-deftest ch-mcp-tools-all-registered ()
  "Every designed tool is registered under the emacs server id."
  (let ((tools (gethash "emacs" mcp-server-lib--tools)))
    (should (hash-table-p tools))
    (dolist (id '("eval-elisp" "context" "list-buffers" "buffer-text"
                  "diagnostics" "find-references" "find-definition"
                  "symbol-info" "document-outline" "modified-buffers"
                  "buffer-diff" "present" "sidebar" "edit-buffer" "edit-file"
                  "transform" "add-comment" "list-comments"))
      (should (gethash id tools)))
    ;; The disk-writing verb is a separate name from buffer mutation so
    ;; restricted dispatch profiles can deny it structurally; a rejoined
    ;; "edit" would silently re-widen every profile built on the split.
    (should-not (gethash "edit" tools))))

(ert-deftest ch-mcp-tools-eval-elisp ()
  (should (equal "3" (ch-emacs-config-mcp--eval-elisp "(+ 1 2)"))))

(ert-deftest ch-mcp-tools-context-smoke ()
  (let ((context (ch-emacs-config-mcp--context)))
    (should (string-match-p "^buffer: " context))
    (should (string-match-p "^project: " context))
    (should (string-match-p "^region: " context))))

(ert-deftest ch-mcp-tools-buffer-text-range ()
  (with-current-buffer (get-buffer-create "ch-mcp-tests-range")
    (erase-buffer)
    (insert "l1\nl2\nl3\n"))
  (should (equal "l2\n"
                 (ch-emacs-config-mcp--buffer-text "ch-mcp-tests-range" "2" "2")))
  (should (equal "l1\nl2\nl3\n"
                 (ch-emacs-config-mcp--buffer-text "ch-mcp-tests-range")))
  (should (equal "l2\nl3\n"
                 (ch-emacs-config-mcp--buffer-text "ch-mcp-tests-range" "2"))))

(ert-deftest ch-mcp-tools-auto-open-scope ()
  "Unvisited files outside the territory and every session project are
refused by default."
  (let ((file (ch-mcp-tests--temp-file "hello\n"))
        (elsewhere (make-temp-file "mcp-elsewhere" t)))
    (let ((default-directory (file-name-as-directory elsewhere)))
      (should-error (ch-emacs-config-mcp--file-buffer file)
                    :type 'mcp-server-lib-tool-error)
      (let ((ch-emacs-config-mcp-auto-open-scope 'any-project))
        (should (buffer-live-p (ch-emacs-config-mcp--file-buffer file)))))))

(ert-deftest ch-mcp-tools-auto-open-client-territory ()
  "Files under the client's own territory auto-open without any session
buffer in their project — the agent-worktree case."
  (let ((file (ch-mcp-tests--temp-file "hello\n")))
    (ch-mcp-tests--in-territory
      (should (buffer-live-p (ch-emacs-config-mcp--file-buffer file))))))

(ert-deftest ch-mcp-tools-modified-buffers-and-diff ()
  (let* ((file (ch-mcp-tests--temp-file "one\ntwo\n"))
         (buffer (find-file-noselect file)))
    (should (equal (ch-emacs-config-mcp--buffer-diff file)
                   "Buffer matches disk (no unsaved changes)"))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert "three\n"))
    (should (string-match-p (regexp-quote file)
                            (ch-emacs-config-mcp--modified-buffers)))
    (let ((diff (ch-emacs-config-mcp--buffer-diff file)))
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
             (ch-emacs-config-mcp--diagnostics file)))
    ;; The sweep form runs and reports the summary counts.
    (should (string-match-p "buffers checked clean"
                            (ch-emacs-config-mcp--diagnostics)))))

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
    (let ((result (ch-emacs-config-mcp--find-definition file "4" "4")))
      (should (string-match-p "ch-mcp-tests-target" result)))))

(ert-deftest ch-mcp-tools-find-references-no-identifier ()
  (let* ((file (ch-mcp-tests--temp-file "   \n")))
    (find-file-noselect file)
    (should-error (ch-emacs-config-mcp--find-references file "1" "1")
                  :type 'mcp-server-lib-tool-error)))

(ert-deftest ch-mcp-tools-position-past-eof ()
  (let* ((file (ch-mcp-tests--temp-file "short\n")))
    (find-file-noselect file)
    (should-error (ch-emacs-config-mcp--find-definition file "99" "1")
                  :type 'mcp-server-lib-tool-error)))

(ert-deftest ch-mcp-tools-symbol-info-no-server ()
  "LSP-backed hover degrades to a clean tool error without a server."
  (let* ((file (ch-mcp-tests--temp-file "words here\n")))
    (find-file-noselect file)
    (should-error (ch-emacs-config-mcp--symbol-info file "1" "1")
                  :type 'mcp-server-lib-tool-error)))

(ert-deftest ch-mcp-tools-document-outline ()
  (let* ((file (ch-mcp-tests--temp-file
                (concat "(defun ch-mcp-tests-outline-one ()\n  nil)\n"
                        "(defvar ch-mcp-tests-outline-var nil)\n")
                ".el")))
    (find-file-noselect file)
    (let ((outline (ch-emacs-config-mcp--document-outline file)))
      (should (string-match-p "ch-mcp-tests-outline-one" outline))
      (should (string-match-p "^1: " outline)))))

(ert-deftest ch-mcp-tools-present ()
  (ch-emacs-config-mcp--present "ert-present" "# Title\n\nbody" nil "no")
  (with-current-buffer "*agent/ert-present*"
    (should (derived-mode-p 'markdown-ts-mode))
    (should visual-line-mode)
    (should (string-match-p "Title" (buffer-string)))
    (should-not (buffer-modified-p)))
  (ch-emacs-config-mcp--present "ert-present" "a.el:1:1: hit" "locations" "no")
  (with-current-buffer "*agent/ert-present*"
    (should (bound-and-true-p compilation-minor-mode))
    (should-not visual-line-mode))
  (should-error (ch-emacs-config-mcp--present "ert-present" "x" "nonsense" "no")
                :type 'mcp-server-lib-tool-error))

(ert-deftest ch-mcp-tools-sidebar ()
  "A sidebar is soft-wrapped read-only markdown that `q' disposes of."
  (ch-emacs-config-mcp--sidebar "ert-sidebar" "# Q\n\nA" "no")
  (with-current-buffer "*agent/sidebar/ert-sidebar*"
    (should (derived-mode-p 'markdown-ts-mode))
    (should visual-line-mode)
    (should ch-emacs-config-sidebar-mode)
    (should buffer-read-only)
    (should (eq (lookup-key ch-emacs-config-sidebar-mode-map (kbd "q"))
                #'ch-emacs-config-sidebar-quit))
    (should-not (buffer-modified-p)))
  (ch-emacs-config-mcp--sidebar "ert-sidebar" "again" nil)
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
                (ch-emacs-config-mcp--present "ert-mermaid" "graph LR\n a --> b"
                                              "mermaid" "no")
                :type 'mcp-server-lib-tool-error)))
      (should (string-match-p "mmdc" (error-message-string err))))))

(ert-deftest ch-mcp-tools-present-mermaid-renders ()
  "A rendered diagram lands in the buffer: an image on capable displays,
raw SVG text otherwise (the batch case)."
  (skip-unless (executable-find "mmdc"))
  (ch-emacs-config-mcp--present "ert-mermaid" "graph LR\n a --> b" "mermaid" "no")
  (with-current-buffer "*agent/ert-mermaid*"
    (should-not (buffer-modified-p))
    (if (image-type-available-p 'svg)
        (should (get-char-property (point-min) 'display))
      (should (string-match-p "<svg" (buffer-string))))))

(ert-deftest ch-mcp-tools-present-mermaid-render-error-is-legible ()
  "Broken mermaid source comes back as a tool error, not a wiped buffer."
  (skip-unless (executable-find "mmdc"))
  (ch-emacs-config-mcp--present "ert-mermaid-err" "kept" "markdown" "no")
  (should-error
   (ch-emacs-config-mcp--present "ert-mermaid-err" "graph LR\n a -->" "mermaid" "no")
   :type 'mcp-server-lib-tool-error)
  (with-current-buffer "*agent/ert-mermaid-err*"
    (should (string-match-p "kept" (buffer-string)))))

(ert-deftest ch-mcp-tools-mermaid-labels-are-librsvg-legible ()
  "Rendered SVGs must carry labels as native <text>, never <foreignObject>.
librsvg (Emacs's SVG renderer) silently drops foreignObject, producing a
diagram whose every label is invisible — found live on first use."
  (skip-unless (executable-find "mmdc"))
  (let ((svg (ch-emacs-config-mcp--render-mermaid
              "graph LR\n a -->|edge label| b[node label]")))
    (should-not (string-match-p "foreignObject" svg))
    (should (string-match-p "<text" svg))))

(ert-deftest ch-mcp-tools-buffer-text-numbered ()
  (with-current-buffer (get-buffer-create "ch-mcp-tests-numbered")
    (erase-buffer)
    (insert "l1\nl2\nl3\n"))
  (should (equal (format "%6d\tl2\n" 2)
                 (ch-emacs-config-mcp--buffer-text
                  "ch-mcp-tests-numbered" "2" "2" "yes")))
  (should (equal (concat (format "%6d\tl2\n" 2) (format "%6d\tl3\n" 3))
                 (ch-emacs-config-mcp--buffer-text
                  "ch-mcp-tests-numbered" "2" nil "yes"))))

(ert-deftest ch-mcp-tools-edit-file-unique-match ()
  "The native-Edit happy path: unique match, diff back, saved to disk."
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "alpha\nbeta\ngamma\n")))
      (find-file-noselect file)
      (let ((diff (ch-emacs-config-mcp--edit-file "beta" "delta" file)))
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
      (should-error (ch-emacs-config-mcp--edit-file "missing" "x" file)
                    :type 'mcp-server-lib-tool-error))))

(ert-deftest ch-mcp-tools-edit-file-non-unique-names-count ()
  "A multi-match without replace-all fails loudly, naming the count."
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "dup\ndup\ndup\n")))
      (find-file-noselect file)
      (let ((err (should-error (ch-emacs-config-mcp--edit-file "dup" "x" file)
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
      (ch-emacs-config-mcp--edit-file "dup" "rep" file "yes")
      (with-temp-buffer
        (insert-file-contents file)
        (should (equal (buffer-string) "rep one\nrep two\n"))))))

(ert-deftest ch-mcp-tools-edit-file-replacement-containing-target ()
  "NEW-STRING containing OLD-STRING must not be re-matched (no runaway)."
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "a\n")))
      (find-file-noselect file)
      (ch-emacs-config-mcp--edit-file "a" "aa" file "yes")
      (with-temp-buffer
        (insert-file-contents file)
        (should (equal (buffer-string) "aa\n"))))))

(ert-deftest ch-mcp-tools-edit-file-identical-strings ()
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "alpha\n")))
      (find-file-noselect file)
      (should-error (ch-emacs-config-mcp--edit-file "alpha" "alpha" file)
                    :type 'mcp-server-lib-tool-error))))

(ert-deftest ch-mcp-tools-edit-buffer-no-such-buffer ()
  (should-error (ch-emacs-config-mcp--edit-buffer "a" "b" "no-such-buffer")
                :type 'mcp-server-lib-tool-error))

(ert-deftest ch-mcp-tools-edit-buffer-non-file ()
  "Non-file buffers (the collaboration case) are edited in place."
  (with-current-buffer (get-buffer-create "*agent/ert-edit*")
    (erase-buffer)
    (insert "shared state\n"))
  (let ((diff (ch-emacs-config-mcp--edit-buffer "shared" "common"
                                                "*agent/ert-edit*")))
    (should (string-match-p "^\\+common state" diff)))
  (with-current-buffer "*agent/ert-edit*"
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "common state\n"))))

(ert-deftest ch-mcp-tools-edit-buffer-empty-old-inserts-into-empty-buffer ()
  "The only write path into a fresh buffer: empty OLD-STRING inserts."
  (with-current-buffer (get-buffer-create "*agent/ert-edit-empty*")
    (erase-buffer))
  (let ((diff (ch-emacs-config-mcp--edit-buffer "" "a poem\n"
                                                "*agent/ert-edit-empty*")))
    (should (string-match-p "^\\+a poem" diff)))
  (with-current-buffer "*agent/ert-edit-empty*"
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "a poem\n"))))

(ert-deftest ch-mcp-tools-edit-file-empty-old-inserts-into-empty-file ()
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "")))
      (find-file-noselect file)
      (ch-emacs-config-mcp--edit-file "" "content\n" file)
      (with-temp-buffer
        (insert-file-contents file)
        (should (equal (buffer-string) "content\n"))))))

(ert-deftest ch-mcp-tools-edit-file-empty-old-rejected-on-content ()
  "An empty OLD-STRING is ambiguous anywhere but an empty buffer."
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "alpha\n")))
      (find-file-noselect file)
      (let ((err (should-error (ch-emacs-config-mcp--edit-file "" "x" file)
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
      (let ((err (should-error (ch-emacs-config-mcp--edit-file "alpha" "beta" file)
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
      (ch-emacs-config-mcp--edit-buffer "alpha" "beta" (buffer-name buffer))
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
      (let ((diff (ch-emacs-config-mcp--edit-buffer "user edit" "user edit, corrected"
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
      (let ((diff (ch-emacs-config-mcp--transform
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
      (let ((diff (ch-emacs-config-mcp--transform
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
      (should-error (ch-emacs-config-mcp--transform file "(ignore)")
                    :type 'mcp-server-lib-tool-error))))

(ert-deftest ch-mcp-tools-transform-restores-on-error ()
  (ch-mcp-tests--in-territory
    (let* ((file (ch-mcp-tests--temp-file "alpha\n"))
           (buffer (find-file-noselect file)))
      (should-error (ch-emacs-config-mcp--transform
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
                     (ch-emacs-config-mcp--transform file "(ignore)"))))))

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
                              (ch-emacs-config-mcp--edit-file
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
                  (ch-emacs-config-mcp--edit-file "alpha" "beta" outer)
                  :type 'mcp-server-lib-tool-error)))
        (should (string-match-p "territory" (error-message-string err))))
      (should-error (ch-emacs-config-mcp--transform
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
      (should-error (ch-emacs-config-mcp--edit-file "alpha" "beta" main-file)
                    :type 'mcp-server-lib-tool-error)
      (should (string-match-p "^\\+beta"
                              (ch-emacs-config-mcp--edit-file
                               "alpha" "beta" wt-file))))))

(ert-deftest ch-mcp-tools-write-scope-edit-buffer-file-backed ()
  "edit-buffer refuses buffers backed by out-of-territory files even
though it never writes disk; non-file buffers stay editable."
  (let* ((ws (ch-mcp-tests--project-dir temporary-file-directory))
         (file (ch-mcp-tests--temp-file "alpha\n"))
         (buffer (find-file-noselect file)))
    (let ((default-directory ws))
      (should-error (ch-emacs-config-mcp--edit-buffer
                     "alpha" "beta" (buffer-name buffer))
                    :type 'mcp-server-lib-tool-error)
      (with-current-buffer (get-buffer-create "*agent/ert-territory*")
        (erase-buffer)
        (insert "alpha\n"))
      (should (string-match-p "^\\+beta"
                              (ch-emacs-config-mcp--edit-buffer
                               "alpha" "beta" "*agent/ert-territory*"))))))

(ert-deftest ch-mcp-tools-write-scope-unrestricted-knob ()
  "The resident user can lift the write scope."
  (let* ((ws (ch-mcp-tests--project-dir temporary-file-directory))
         (file (ch-mcp-tests--temp-file "alpha\n")))
    (find-file-noselect file)
    (let ((default-directory ws)
          (ch-emacs-config-mcp-write-scope 'unrestricted))
      (should (string-match-p "^\\+beta"
                              (ch-emacs-config-mcp--edit-file
                               "alpha" "beta" file))))))

;;; Security filters: the agent-safe elisp gate

(ert-deftest ch-mcp-tools-eval-elisp-gate-allows-reads ()
  "The read surface stays open: session inspection is the tool's job."
  (should (equal "3" (ch-emacs-config-mcp--eval-elisp "(+ 1 2)")))
  (should (stringp (ch-emacs-config-mcp--eval-elisp "(buffer-name)")))
  (should (ch-emacs-config-mcp--eval-elisp
           "(let ((n 0)) (dolist (b (buffer-list) n) (setq n (1+ n))))")))

(ert-deftest ch-mcp-tools-eval-elisp-gate-blocks-side-effects ()
  "Mutation, I/O, and indirect calls are rejected before evaluation,
naming the offender."
  (dolist (bad '("(delete-file \"/tmp/x\")"
                 "(setq some-global-var 1)"
                 "(funcall (intern \"delete-file\") \"/tmp/x\")"
                 "(eval '(delete-file \"/tmp/x\"))"
                 "(shell-command \"true\")"
                 "(insert \"x\")"))
    (let ((err (should-error (ch-emacs-config-mcp--eval-elisp bad)
                             :type 'mcp-server-lib-tool-error)))
      (should (string-match-p "unsafe" (error-message-string err))))))

(ert-deftest ch-mcp-tools-eval-elisp-gate-protects-its-own-knobs ()
  "Gated elisp can neither set nor bind the filter configuration."
  (dolist (bad '("(setq ch-emacs-config-mcp-elisp-scope 'unrestricted)"
                 "(let ((ch-emacs-config-mcp-elisp-scope 'unrestricted)) (eval '(+ 1 2)))"
                 "(setq ch-emacs-config-mcp-write-scope 'unrestricted)"
                 "(push 'shell-command ch-emacs-config-mcp-agent-safe-functions)"))
    (should-error (ch-emacs-config-mcp--eval-elisp bad)
                  :type 'mcp-server-lib-tool-error)))

(ert-deftest ch-mcp-tools-eval-elisp-agent-safe-registry ()
  "The user-extensible registry admits functions unsafep does not know."
  (defun ch-mcp-tests--blessed () "blessed")
  (should-error (ch-emacs-config-mcp--eval-elisp "(ch-mcp-tests--blessed)")
                :type 'mcp-server-lib-tool-error)
  (let ((ch-emacs-config-mcp-agent-safe-functions
         (cons 'ch-mcp-tests--blessed ch-emacs-config-mcp-agent-safe-functions)))
    (should (equal "\"blessed\""
                   (ch-emacs-config-mcp--eval-elisp "(ch-mcp-tests--blessed)")))))

(ert-deftest ch-mcp-tools-eval-elisp-unrestricted-knob ()
  "The resident user's say-so path: `unrestricted' scope evaluates
stateful elisp again."
  (let ((ch-emacs-config-mcp-elisp-scope 'unrestricted))
    (should (equal "42" (ch-emacs-config-mcp--eval-elisp
                         "(with-temp-buffer (insert \"42\") (string-to-number (buffer-string)))")))))

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
        (let ((err (should-error (ch-emacs-config-mcp--transform file bad)
                                 :type 'mcp-server-lib-tool-error)))
          (should (string-match-p "unsafe" (error-message-string err)))))
      ;; And the buffer never moved.
      (with-temp-buffer
        (insert-file-contents file)
        (should (equal (buffer-string) "alpha\n"))))))

(ert-deftest ch-mcp-tools-knobs-are-risky ()
  "The filter knobs and registries carry `risky-local-variable', the
property unsafep keys its binding refusals on."
  (dolist (var '(ch-emacs-config-mcp-write-scope
                 ch-emacs-config-mcp-elisp-scope
                 ch-emacs-config-mcp-agent-safe-functions
                 ch-emacs-config-mcp-agent-safe-editing-functions))
    (should (get var 'risky-local-variable))))

(ert-deftest ch-mcp-tools-present-refuses-file-buffers ()
  "present only writes *agent/...* scratch buffers; a file-visiting
buffer squatting on the name is refused, not erased."
  (let ((buffer (find-file-noselect (ch-mcp-tests--temp-file "keep\n"))))
    (with-current-buffer buffer
      (rename-buffer "*agent/ert-squatter*"))
    (unwind-protect
        (progn
          (should-error (ch-emacs-config-mcp--present
                         "ert-squatter" "new content" nil "no")
                        :type 'mcp-server-lib-tool-error)
          (with-current-buffer "*agent/ert-squatter*"
            (should (string-match-p "keep" (buffer-string)))))
      (kill-buffer buffer))))

;;; mcp-tools-ert.el ends here
