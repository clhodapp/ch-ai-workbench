;;; claude-queue-ert.el --- ERT tests for claude-queue -*- lexical-binding: t -*-
;; SPDX-License-Identifier: MIT
;;; Commentary:
;; Tests for the pure parts: prompt composition, dispatch command
;; construction, CLI output parsing, transcript-path derivation and
;; parsing, list-row assembly, slot arithmetic, registry persistence,
;; session following (argv classification, live-cwd resolution,
;; buffer sync; the CLI and /proc mocked where needed), and the
;; semantic agent finder's server-free surface (conversation
;; extraction, document assembly, stamp-keyed embedding reuse; embeds
;; mocked).  Dispatch itself talks to the claude CLI and is exercised
;; interactively.
;;; Code:

(require 'ert)
(require 'claude-queue)

;;; Prompt composition

(defconst claude-queue-ert--capture
  (list :root "/home/u/ws/"
        :file "/home/u/ws/projects/tool/lib/thing.el"
        :buffer "thing.el"
        :line 42
        :column 7
        :line-text "(defun thing-frob ()"
        :modified nil
        :region nil))

(ert-deftest claude-queue-compose-point-only ()
  (let ((prompt (claude-queue--compose-prompt
                 "Rename this function" claude-queue-ert--capture)))
    (should (string-prefix-p "Rename this function\n\n---\n" prompt))
    (should (string-match-p
             "- File: projects/tool/lib/thing\\.el (line 42, column 7)" prompt))
    (should (string-match-p "- Text of that line: (defun thing-frob ()" prompt))
    (should-not (string-match-p "unsaved" prompt))))

(ert-deftest claude-queue-compose-region ()
  (let* ((capture (append '(:region (:text "line a\nline b"
                                     :start-line 40 :end-line 41))
                          claude-queue-ert--capture))
         (prompt (claude-queue--compose-prompt "Tighten this" capture)))
    (should (string-match-p
             "- Selected text (lines 40-41):\n\n```\nline a\nline b\n```"
             prompt))
    (should-not (string-match-p "Text of that line" prompt))))

(ert-deftest claude-queue-compose-conduct ()
  "Every prompt carries the standing conduct block: bias to proceed
on low-stakes ambiguity, and end with a result: line."
  (let ((prompt (claude-queue--compose-prompt
                 "Rename this function" claude-queue-ert--capture)))
    (should (string-suffix-p (concat "\n" claude-queue--conduct "\n") prompt))
    (should (string-match-p "\"result:\"" prompt))))

(ert-deftest claude-queue-compose-modified-note ()
  (let* ((capture (append '(:modified t) claude-queue-ert--capture))
         (prompt (claude-queue--compose-prompt "Look here" capture)))
    (should (string-match-p "unsaved modifications" prompt))))

(ert-deftest claude-queue-compose-non-file-buffer ()
  (let* ((capture (append '(:file nil :buffer "*scratch*")
                          claude-queue-ert--capture))
         (prompt (claude-queue--compose-prompt "What is this?" capture)))
    (should (string-match-p
             "- Emacs buffer \"\\*scratch\\*\" (line 42; not visiting a file)"
             prompt))))

(ert-deftest claude-queue-truncate-region ()
  (let ((claude-queue-max-region-chars 4))
    (should (equal "abcd\n[excerpt truncated]"
                   (claude-queue--truncate "abcdefgh" 4)))))

(ert-deftest claude-queue-derive-name ()
  (should (equal "thing.el: Rename this"
                 (claude-queue--derive-name "Rename this"
                                            claude-queue-ert--capture)))
  (let ((name (claude-queue--derive-name (make-string 100 ?x)
                                         claude-queue-ert--capture)))
    (should (= 64 (length name)))
    (should (string-suffix-p "…" name))))

;;; Dispatch command

(ert-deftest claude-queue-command-defaults ()
  (let ((claude-queue-program "claude")
        (claude-queue-permission-mode nil)
        (claude-queue-allowed-tools nil)
        (claude-queue-denied-tools nil)
        (claude-queue-bare-root-denied-tools nil)
        (claude-queue-extra-args nil))
    (should (equal '("claude" "--bg" "--model" "sonnet" "--name" "N" "P")
                   (claude-queue--command
                    '(:model "sonnet" :name "N" :prompt "P"))))))

(ert-deftest claude-queue-command-permission-and-extra-args ()
  (let ((claude-queue-program "claude")
        (claude-queue-permission-mode "acceptEdits")
        (claude-queue-allowed-tools nil)
        (claude-queue-denied-tools nil)
        (claude-queue-bare-root-denied-tools nil)
        (claude-queue-extra-args '("--effort" "low")))
    (should (equal '("claude" "--bg" "--model" "opus" "--name" "N"
                     "--permission-mode" "acceptEdits"
                     "--effort" "low" "P")
                   (claude-queue--command
                    '(:model "opus" :name "N" :prompt "P"))))))

(ert-deftest claude-queue-command-allowed-tools ()
  "Comma-joined, and never the last flag before the positional prompt:
--allowedTools is variadic and would swallow a trailing argument."
  (let ((claude-queue-program "claude")
        (claude-queue-permission-mode nil)
        (claude-queue-allowed-tools '("mcp__emacs__edit-buffer" "OtherTool"))
        (claude-queue-denied-tools nil)
        (claude-queue-bare-root-denied-tools nil)
        (claude-queue-extra-args nil))
    (should (equal '("claude" "--bg"
                     "--allowedTools" "mcp__emacs__edit-buffer,OtherTool"
                     "--model" "sonnet" "--name" "N" "P")
                   (claude-queue--command
                    '(:model "sonnet" :name "N" :prompt "P"))))))

(ert-deftest claude-queue-command-denied-tools ()
  "The deny floor goes in --settings as inline permissions.deny JSON
\(--disallowedTools is variadic: a second prompt-swallow hazard)."
  (let ((claude-queue-program "claude")
        (claude-queue-permission-mode nil)
        (claude-queue-allowed-tools nil)
        (claude-queue-denied-tools '("Bash" "WebFetch"))
        (claude-queue-bare-root-denied-tools nil)
        (claude-queue-extra-args nil))
    (should (equal '("claude" "--bg"
                     "--settings" "{\"permissions\":{\"deny\":[\"Bash\",\"WebFetch\"]}}"
                     "--model" "sonnet" "--name" "N" "P")
                   (claude-queue--command
                    '(:model "sonnet" :name "N" :prompt "P"))))))

(ert-deftest claude-queue-command-default-posture ()
  "The out-of-the-box dispatch is the correction profile
\(consent-gate.md): auto mode; subagent spawning and the emacs
server's tools allowed, its write verbs and elisp escape hatch
included (the server's own filters confine them); shell and network
absent via the permissions.deny floor.  Rooted in a project, so the
bare-root guard stays out of the floor."
  (claude-queue-ert--with-checkout
   nil
   (lambda (root)
     (let* ((claude-queue-program "claude")
            (claude-queue-extra-args nil)
            (argv (claude-queue--command
                   (list :model "sonnet" :name "N" :prompt "P" :root root)))
            (allowed (cadr (member "--allowedTools" argv)))
            (denied (claude-queue-ert--denied root)))
       (should (member "--permission-mode" argv))
       (should (equal "auto" (cadr (member "--permission-mode" argv))))
       (should (equal "P" (car (last argv))))
       (dolist (tool '("Agent"
                       "mcp__emacs__edit-buffer"
                       "mcp__emacs__add-comment"
                       "mcp__emacs__buffer-text"
                       "mcp__emacs__present"
                       "mcp__emacs__edit-file"
                       "mcp__emacs__transform"
                       "mcp__emacs__eval-elisp"))
         (should (member tool (split-string allowed ","))))
       (should (equal '("Bash" "WebFetch" "WebSearch") denied))
       ;; Nothing floored may also be pre-approved.
       (dolist (tool (split-string allowed ","))
         (should-not (member tool denied)))))))

;;; Sandbox-enrolled and bare roots

(defun claude-queue-ert--with-checkout (sidecar-json fn &optional bare)
  "Call FN with a fresh root holding SIDECAR-JSON (nil = none).
The root is a git checkout (an empty .git directory, enough for
project.el) unless BARE, which leaves it a plain directory."
  (let ((root (make-temp-file "claude-queue-ert-" t)))
    (unwind-protect
        (progn
          (unless bare
            (make-directory (expand-file-name ".git" root)))
          (when sidecar-json
            (let ((sidecar (expand-file-name claude-queue--sandbox-sidecar
                                             root)))
              (make-directory (file-name-directory sidecar) t)
              (with-temp-file sidecar (insert sidecar-json))))
          (funcall fn (file-name-as-directory root)))
      (delete-directory root t))))

(defun claude-queue-ert--denied (root)
  "The permissions.deny list `claude-queue--command' renders for ROOT,
nil when it renders no --settings at all."
  (let* ((claude-queue-program "claude")
         (claude-queue-extra-args nil)
         (argv (claude-queue--command
                (list :model "sonnet" :name "N" :prompt "P" :root root)))
         (settings (cadr (member "--settings" argv))))
    (when settings
      (append (gethash "deny" (gethash "permissions"
                                       (json-parse-string settings)))
              nil))))

(ert-deftest claude-queue-project-root-p ()
  "A git checkout is a project; a bare directory and nil are not."
  (claude-queue-ert--with-checkout
   nil (lambda (root) (should (claude-queue--project-root-p root))))
  (claude-queue-ert--with-checkout
   nil (lambda (root) (should-not (claude-queue--project-root-p root))) t)
  (should-not (claude-queue--project-root-p nil)))

(ert-deftest claude-queue-command-bare-root-floors-disk-writers ()
  "Rooted outside any project, every disk-writing path joins the
floor: the CLI's Edit/Write/NotebookEdit and the emacs server's
edit-file/transform (each would take the bare directory as its whole
territory).  Rooted in a project they stay allowed."
  (claude-queue-ert--with-checkout
   nil
   (lambda (root)
     (should (equal (append claude-queue-denied-tools
                            '("Edit" "Write" "NotebookEdit"
                              "mcp__emacs__edit-file"
                              "mcp__emacs__transform"))
                    (claude-queue-ert--denied root))))
   t)
  (claude-queue-ert--with-checkout
   nil
   (lambda (root)
     (should (equal claude-queue-denied-tools
                    (claude-queue-ert--denied root))))))

(ert-deftest claude-queue-command-bare-root-ignores-sidecar ()
  "A sidecar under a bare directory is not an enrollment (the sandbox
tool only enrolls git roots): shell and network stay floored, and
the bare-root guard applies in full."
  (claude-queue-ert--with-checkout
   "{\"profile\": \"default\", \"applied\": {}}"
   (lambda (root)
     (should (equal (append claude-queue-denied-tools
                            claude-queue-bare-root-denied-tools)
                    (claude-queue-ert--denied root))))
   t))

(ert-deftest claude-queue-sandbox-profile-reads-sidecar ()
  (claude-queue-ert--with-checkout
   "{\"profile\": \"nix\", \"applied\": {}}"
   (lambda (root)
     (should (equal "nix" (claude-queue--sandbox-profile root)))
     (should (claude-queue--sandboxed-p root)))))

(ert-deftest claude-queue-sandbox-unenrolled-shapes ()
  "No root, no sidecar, the reserved empty profile, and a malformed
sidecar all read as unenrolled."
  (should-not (claude-queue--sandboxed-p nil))
  (claude-queue-ert--with-checkout
   nil (lambda (root) (should-not (claude-queue--sandboxed-p root))))
  (claude-queue-ert--with-checkout
   "{\"profile\": \"none\", \"applied\": {}}"
   (lambda (root)
     (should (equal "none" (claude-queue--sandbox-profile root)))
     (should-not (claude-queue--sandboxed-p root))))
  (claude-queue-ert--with-checkout
   "{\"profile\": 3}"
   (lambda (root) (should-not (claude-queue--sandboxed-p root))))
  (claude-queue-ert--with-checkout
   "not json"
   (lambda (root) (should-not (claude-queue--sandboxed-p root)))))

(ert-deftest claude-queue-command-sandboxed-root-lifts-shell-and-network ()
  "Inside an enrolled project checkout the shell and the network tools
leave the deny floor, which is then empty: no --settings at all."
  (claude-queue-ert--with-checkout
   "{\"profile\": \"default\", \"applied\": {}}"
   (lambda (root)
     (should-not (claude-queue-ert--denied root)))))

(ert-deftest claude-queue-command-unenrolled-root-keeps-floor ()
  (claude-queue-ert--with-checkout
   "{\"profile\": \"none\", \"applied\": {}}"
   (lambda (root)
     (should (equal claude-queue-denied-tools
                    (claude-queue-ert--denied root)))))
  (claude-queue-ert--with-checkout
   nil
   (lambda (root)
     (should (equal claude-queue-denied-tools
                    (claude-queue-ert--denied root))))))

(ert-deftest claude-queue-command-sandboxed-lift-can-empty-floor ()
  "A floor consisting only of lifted tools renders no --settings at all."
  (claude-queue-ert--with-checkout
   "{\"profile\": \"default\", \"applied\": {}}"
   (lambda (root)
     (let* ((claude-queue-program "claude")
            (claude-queue-permission-mode nil)
            (claude-queue-allowed-tools nil)
            (claude-queue-denied-tools '("Bash"))
            (claude-queue-extra-args nil))
       (should (equal '("claude" "--bg" "--model" "sonnet" "--name" "N" "P")
                      (claude-queue--command
                       (list :model "sonnet" :name "N" :prompt "P"
                             :root root))))))))

;;; CLI output parsing

(ert-deftest claude-queue-parse-backgrounded ()
  ;; Format observed from claude --bg, including SGR color around the id.
  (should (equal "fb242934"
                 (claude-queue--parse-backgrounded
                  "backgrounded · \e[36mfb242934\e[39m · some name\n\
\e[2m  claude agents             list sessions\e[22m\n")))
  (should-not (claude-queue--parse-backgrounded "error: no credit\n")))

(ert-deftest claude-queue-agents-from-json ()
  (let ((agents (claude-queue--agents-from-json
                 "[{\"id\":\"ab\",\"cwd\":\"/w\",\"sessionId\":\"ab-1\",\
\"name\":\"t\",\"status\":\"busy\",\"state\":\"working\"}]")))
    (should (equal "ab" (alist-get 'id (car agents))))
    (should (equal "working" (alist-get 'state (car agents))))
    (should (claude-queue--agent-by-id "ab" agents))
    (should-not (claude-queue--agent-by-id "cd" agents))))

;;; Transcript

(ert-deftest claude-queue-project-dir-name ()
  ;; Real correspondences observed under ~/.claude/projects/.
  (should (equal "-home-chris-Projects-ch-nix-workspace"
                 (claude-queue--project-dir-name
                  "/home/chris/Projects/ch-nix-workspace/")))
  (should (equal "-home-chris--claude-jobs-10de66ab-tmp"
                 (claude-queue--project-dir-name
                  "/home/chris/.claude/jobs/10de66ab/tmp"))))

(ert-deftest claude-queue-session-transcript-follows-move ()
  "Transcripts stay keyed to the session's starting directory; a
session that has since moved (worktree, /cd) still finds its
transcript by session-id search across the project directories."
  (let* ((projects-dir (make-temp-file "claude-queue-projects" t))
         (claude-queue-projects-directory projects-dir))
    (unwind-protect
        (progn
          (claude-queue-ert--write-transcript
           projects-dir "/w" "ab-1"
           "{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}\n")
          ;; Exact hit while the session is where it started.
          (should (claude-queue--session-transcript "ab-1" "/w"))
          ;; Moved: the live cwd names a directory the store never
          ;; keyed; the session id still finds the file.
          (let ((found (claude-queue--session-transcript
                        "ab-1" "/w/.claude/worktrees/x")))
            (should found)
            (should (string-suffix-p "ab-1.jsonl" found)))
          ;; The agents-row lookup uses the same fallback.
          (should (claude-queue--agent-transcript-file
                   '((sessionId . "ab-1")
                     (cwd . "/w/.claude/worktrees/x"))))
          (should-not (claude-queue--session-transcript "zz-9" "/w")))
      (delete-directory projects-dir t))))

(ert-deftest claude-queue-conversation-turns ()
  "Role-labeled turns for the transcript view, both senders, in order."
  (let ((jsonl (concat
                "{\"type\":\"user\",\"message\":{\"content\":\"hi\"}}\n"
                "{\"type\":\"assistant\",\"message\":{\"content\":"
                "[{\"type\":\"text\",\"text\":\"first\"}]}}\n"
                "not json\n"
                "{\"type\":\"assistant\",\"message\":{\"content\":"
                "[{\"type\":\"tool_use\",\"id\":\"x\"}]}}\n"
                "{\"type\":\"assistant\",\"message\":{\"content\":"
                "[{\"type\":\"text\",\"text\":\"second\"}]}}\n")))
    (should (equal '(("User" . "hi")
                     ("Assistant" . "first")
                     ("Assistant" . "second"))
                   (claude-queue--conversation-turns jsonl)))))

(ert-deftest claude-queue-render-turns ()
  "Sender labels head each turn, propertized bold."
  (let ((text (claude-queue--render-turns
               '(("User" . "fix the race")
                 ("Assistant" . "found the socket race")))))
    (should (equal (concat "User:\nfix the race\n\n"
                           "Assistant:\nfound the socket race")
                   (substring-no-properties text)))
    (should (eq 'bold (get-text-property 0 'face text)))))

;;; Session following

(ert-deftest claude-queue-argv-session ()
  "Only session processes resolve: an interactive claude is `self',
an attach client maps to its background session, and the CLI's
infrastructure (daemon, pty hosts, spare workers) plus utility
subcommands and foreign programs drop out."
  ;; Interactive sessions, plain or with flags/prompt, wrapped or not.
  (should (eq 'self (claude-queue--argv-session '("claude"))))
  (should (eq 'self (claude-queue--argv-session
                     '("claude" "--model" "opus"))))
  (should (eq 'self (claude-queue--argv-session
                     '("/nix/store/x-claude-code-2.1.195/bin/.claude-wrapped"
                       "--resume"))))
  ;; A prompt argument is not a subcommand.
  (should (eq 'self (claude-queue--argv-session
                     '("claude" "fix the attach logic"))))
  ;; Attach clients are viewers onto a background session.
  (should (equal '(attach . "ab12cd34")
                 (claude-queue--argv-session
                  '("claude" "attach" "ab12cd34"))))
  ;; Infrastructure and utility invocations.
  (should-not (claude-queue--argv-session
               '("/nix/store/x/bin/.claude-wrapped" "--bg-spare" "/tmp/s")))
  (should-not (claude-queue--argv-session
               '("/nix/store/x/bin/.claude-wrapped" "--bg-pty-host"
                 "/tmp/p" "200" "50")))
  (should-not (claude-queue--argv-session
               '("claude" "--bg" "some prompt")))
  (should-not (claude-queue--argv-session
               '("claude" "daemon" "run" "--origin" "transient")))
  (should-not (claude-queue--argv-session '("claude" "agents" "--json")))
  ;; Other programs entirely.
  (should-not (claude-queue--argv-session '("zsh" "-i")))
  (should-not (claude-queue--argv-session nil)))

(ert-deftest claude-queue-process-cwd-self ()
  "The /proc route reads a live process's directory (own process)."
  (let ((cwd (claude-queue--process-cwd (emacs-pid))))
    (should (stringp cwd))
    (should (file-directory-p cwd))))

;;; Session records

(defun claude-queue-ert--record-file (directory pid &rest fields)
  "Write a session record for PID with FIELDS into DIRECTORY."
  (with-temp-file (expand-file-name (format "%s.json" pid) directory)
    (insert (json-serialize
             (append `(:pid ,pid) fields)))))

(defmacro claude-queue-ert--with-records (var &rest body)
  "Run BODY with VAR bound to a temporary sessions directory.
`claude-queue-sessions-directory' points at it for the duration."
  (declare (indent 1))
  `(let* ((,var (make-temp-file "claude-queue-sessions" t))
          (claude-queue-sessions-directory ,var))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(ert-deftest claude-queue-proc-start-time ()
  "A live pid yields its start-tick string; a dead pid yields nil."
  (let ((ticks (claude-queue--proc-start-time (emacs-pid))))
    (should (stringp ticks))
    (should (string-match-p "\\`[0-9]+\\'" ticks)))
  (should-not (claude-queue--proc-start-time 999999999)))

(ert-deftest claude-queue-record-live-p ()
  "A record is believed only when the kernel countersigns it: live
pid AND matching start time.  Corpse files and recycled pids fail."
  (let ((start (claude-queue--proc-start-time (emacs-pid))))
    (should (claude-queue--record-live-p
             `((pid . ,(emacs-pid)) (procStart . ,start))))
    ;; Same pid, different birth: a recycled pid.
    (should-not (claude-queue--record-live-p
                 `((pid . ,(emacs-pid)) (procStart . "1"))))
    ;; Dead pid: the lingering record of a crashed session.
    (should-not (claude-queue--record-live-p
                 `((pid . 999999999) (procStart . ,start))))
    (should-not (claude-queue--record-live-p nil))))

(ert-deftest claude-queue-session-records ()
  "Enumeration keeps only countersigned records: corpses, recycled
pids, and unparseable files drop out."
  (claude-queue-ert--with-records dir
    (let ((start (claude-queue--proc-start-time (emacs-pid))))
      (claude-queue-ert--record-file dir (emacs-pid)
                                     :procStart start
                                     :sessionId "ab12cd34-real"
                                     :name "live convo" :cwd "/w")
      (claude-queue-ert--record-file dir 999999999
                                     :procStart "123"
                                     :sessionId "dead" :name "corpse")
      (with-temp-file (expand-file-name "garbage.json" dir)
        (insert "not json at all"))
      (let ((records (claude-queue--session-records)))
        (should (= 1 (length records)))
        (should (equal "live convo" (alist-get 'name (car records))))))))

(ert-deftest claude-queue-record-for-id ()
  "Ids join records by session-UUID prefix or exact jobId."
  (let ((records '(((sessionId . "ab12cd34-e059-4b17") (jobId . "ab12cd34"))
                   ((sessionId . "ffff0000-1111") (jobId . "otherjob")))))
    (should (equal "ab12cd34"
                   (alist-get 'jobId (claude-queue--record-for-id
                                      "ab12cd34" records))))
    (should (equal "otherjob"
                   (alist-get 'jobId (claude-queue--record-for-id
                                      "otherjob" records))))
    (should-not (claude-queue--record-for-id "zz99" records))
    (should-not (claude-queue--record-for-id "" records))
    (should-not (claude-queue--record-for-id nil records))))

(ert-deftest claude-queue-record-cwd ()
  "Record cwd resolves as a directory name; removed worktrees do not."
  (let ((dir (make-temp-file "claude-queue-rc" t)))
    (unwind-protect
        (progn
          (should (equal (file-name-as-directory dir)
                         (claude-queue--record-cwd `((cwd . ,dir)))))
          (should-not (claude-queue--record-cwd
                       '((cwd . "/nonexistent/worktree"))))
          (should-not (claude-queue--record-cwd '((name . "x")))))
      (delete-directory dir t))))

(ert-deftest claude-queue-title-resolves-through-records ()
  "The title path reads the daemon's live records, not the agents
cache: a stale cached row with the same name cannot shadow the
record, and a title matching only the stale cache resolves nothing
at all (the process walk or the pin decide instead)."
  (claude-queue-ert--with-records dir
    (let* ((real-dir (make-temp-file "claude-queue-real" t))
           (start (claude-queue--proc-start-time (emacs-pid)))
           ;; The pre-reboot registry memory of the same conversation.
           (claude-queue--agents-cache
            '(((id . "ab") (name . "my convo") (cwd . "/stale/old"))
              ((id . "cd") (name . "cache only") (cwd . "/stale/other"))))
           (buffer (generate-new-buffer "claude-queue-ert-records")))
      (claude-queue-ert--record-file dir (emacs-pid)
                                     :procStart start
                                     :sessionId "ab12-x" :name "my convo"
                                     :cwd real-dir)
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'claude-queue--terminal-title)
                       (lambda (_buffer) "✳ my convo")))
              (should (equal (file-name-as-directory real-dir)
                             (claude-queue--buffer-session-cwd buffer))))
            (cl-letf (((symbol-function 'claude-queue--terminal-title)
                       (lambda (_buffer) "✳ cache only")))
              (should-not (claude-queue--buffer-session-cwd buffer))))
        (kill-buffer buffer)
        (delete-directory real-dir t)))))

(ert-deftest claude-queue-title-agent ()
  "The terminal title names the *viewed* conversation: glyph-prefixed
or exact matches resolve, live sessions win ties, and a name that is
a word-suffix of another name cannot match that other's title."
  (let ((agents '(((id . "dead") (name . "transcript analysis")
                   (startedAt . 9000))
                  ((id . "live") (name . "transcript analysis")
                   (pid . 5) (startedAt . 1000))
                  ((id . "trap") (name . "analysis")
                   (startedAt . 2000))
                  ((id . "x") (name . "other task")
                   (startedAt . 3000)))))
    ;; Glyph-prefixed: the CLI's "✳ <name>" shape.  Live beats dead
    ;; even when dead is newer; the word-suffix name "analysis" (agent
    ;; "trap") must not match this title either.
    (should (equal "live" (alist-get 'id (claude-queue--title-agent
                                          "✳ transcript analysis"
                                          agents))))
    (should (equal "x" (alist-get 'id (claude-queue--title-agent
                                       "other task" agents))))
    (should (equal "trap" (alist-get 'id (claude-queue--title-agent
                                          "✳ analysis" agents))))
    ;; The exclusion itself: with only the word-suffix name present,
    ;; the longer title must not resolve at all.
    (should-not (claude-queue--title-agent
                 "✳ transcript analysis"
                 '(((id . "trap") (name . "analysis")))))
    ;; An interactive session's own conversation is never listed.
    (should-not (claude-queue--title-agent "✳ my own conversation" agents))
    (should-not (claude-queue--title-agent "" agents))
    (should-not (claude-queue--title-agent nil agents))))

(ert-deftest claude-queue-title-body ()
  "The glyph token strips; word prefixes and glyphless titles do not."
  (should (equal "my task" (claude-queue--title-body "✳ my task")))
  (should (equal "my task" (claude-queue--title-body "✻ my task")))
  (should (equal "claude agents" (claude-queue--title-body "claude agents")))
  ;; A leading word is content, not a glyph.
  (should (equal "zsh: my task" (claude-queue--title-body "zsh: my task")))
  (should-not (claude-queue--title-body nil)))

(ert-deftest claude-queue-follow-title-change-throttles ()
  "Throbber churn (glyph-only retitles) never schedules a refresh;
a real body change schedules exactly one until it fires."
  (let ((claude-queue-follow-mode t)
        (scheduled 0)
        (buffer (generate-new-buffer "claude-queue-ert-throb")))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-queue--follow-schedule)
                   (lambda (_buffer) (setq scheduled (1+ scheduled)))))
          (with-current-buffer buffer
            ;; First sighting schedules; the throbber animating the
            ;; glyph does not; a body change schedules again.
            (claude-queue--follow-title-change "✳ my task")
            (claude-queue--follow-title-change "✻ my task")
            (claude-queue--follow-title-change "✽ my task")
            (should (= 1 scheduled))
            (claude-queue--follow-title-change "✳ other convo")
            (should (= 2 scheduled))
            ;; Mode off: inert.
            (let ((claude-queue-follow-mode nil))
              (claude-queue--follow-title-change "✳ third convo"))
            (should (= 2 scheduled))))
      (kill-buffer buffer))))

(ert-deftest claude-queue-follow-schedule-coalesces ()
  "While a refresh is pending, further schedules are absorbed by it:
one timer, and the refresh runs once when it fires."
  (let ((claude-queue-follow-mode t)
        (refreshed 0)
        (buffer (generate-new-buffer "claude-queue-ert-coalesce")))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-queue--follow-refresh)
                   (lambda (_buffer) (setq refreshed (1+ refreshed))))
                  ((symbol-function 'claude-queue--followable-buffer-p)
                   (lambda (_buffer) t))
                  ((symbol-function 'claude-queue--ensure-timer)
                   #'ignore))
          (claude-queue--follow-schedule buffer)
          (claude-queue--follow-schedule buffer)
          (claude-queue--follow-schedule buffer)
          (let ((timer (buffer-local-value
                        'claude-queue--follow-title-timer buffer)))
            (should (timerp timer))
            ;; Fire the trailing edge by hand.
            (apply (timer--function timer) (timer--args timer)))
          (should (= 1 refreshed))
          ;; The slot is free again: the next change schedules anew.
          (claude-queue--follow-schedule buffer)
          (should (timerp (buffer-local-value
                           'claude-queue--follow-title-timer buffer))))
      (when-let* ((timer (buffer-local-value
                          'claude-queue--follow-title-timer buffer)))
        (cancel-timer timer))
      (kill-buffer buffer))))

(ert-deftest claude-queue-session-cwd-changed ()
  "The CwdChanged push updates the cached row for a listed session
and resyncs; an unlisted (interactive) session still resyncs -- its
truth lives in /proc, not the cache."
  (let ((claude-queue-follow-mode t)
        (resyncs 0)
        (claude-queue--agents-cache
         (list (list (cons 'id "ab")
                     (cons 'sessionId "ab-111")
                     (cons 'cwd "/old/place")))))
    (cl-letf (((symbol-function 'claude-queue--follow-displayed)
               (lambda () (setq resyncs (1+ resyncs)))))
      (claude-queue-session-cwd-changed "ab-111" "/w/.claude/worktrees/x")
      (should (equal "/w/.claude/worktrees/x"
                     (alist-get 'cwd (claude-queue--agent-by-id
                                      "ab" claude-queue--agents-cache))))
      (should (= 1 resyncs))
      ;; Unknown session: cache untouched, resync still happens.
      (claude-queue-session-cwd-changed "zz-999" "/elsewhere")
      (should (= 2 resyncs))
      ;; Mode off: note the row, skip the resync.
      (let ((claude-queue-follow-mode nil))
        (claude-queue-session-cwd-changed "ab-111" "/newer")
        (should (equal "/newer"
                       (alist-get 'cwd (claude-queue--agent-by-id
                                        "ab" claude-queue--agents-cache))))
        (should (= 2 resyncs))))))

(ert-deftest claude-queue-buffer-session-cwd-title-precedence ()
  "What the terminal currently shows (the title, resolved through
the live records) outranks the pinned attach id; an unmatched title
falls back to the pin, which resolves through the agents cache when
no record carries its id (a finished session)."
  (claude-queue-ert--with-records dir
    (let* ((dir-a (make-temp-file "claude-queue-a" t))
           (dir-b (make-temp-file "claude-queue-b" t))
           (start (claude-queue--proc-start-time (emacs-pid)))
           (claude-queue--follow-cache-miss nil)
           (claude-queue--agents-cache
            `(((id . "aa") (cwd . ,dir-a) (name . "pinned convo"))))
           (buffer (generate-new-buffer "claude-queue-ert-title")))
      (claude-queue-ert--record-file dir (emacs-pid)
                                     :procStart start
                                     :sessionId "bb99-live"
                                     :name "browsed convo"
                                     :cwd dir-b)
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (setq claude-queue--buffer-agent "aa"))
            ;; Browsing another conversation: its record's cwd wins.
            (cl-letf (((symbol-function 'claude-queue--terminal-title)
                       (lambda (_buffer) "✳ browsed convo")))
              (should (equal (file-name-as-directory dir-b)
                             (claude-queue--buffer-session-cwd buffer))))
            ;; Title matches nothing (own conversation): the pin holds.
            (cl-letf (((symbol-function 'claude-queue--terminal-title)
                       (lambda (_buffer) "✳ something unlisted")))
              (should (equal (file-name-as-directory dir-a)
                             (claude-queue--buffer-session-cwd buffer)))))
        (kill-buffer buffer)
        (delete-directory dir-a t)
        (delete-directory dir-b t)))))

(ert-deftest claude-queue-agent-cwd ()
  "Id resolution: a live record wins over the cached listing row; a
session with no record falls to the listing's cwd field (trailing
slash) unless the directory is gone; unknown ids arm the cache
refill once."
  (claude-queue-ert--with-records dir
    (let* ((live-dir (make-temp-file "claude-queue-cwd" t))
           (record-dir (make-temp-file "claude-queue-rec" t))
           (start (claude-queue--proc-start-time (emacs-pid)))
           (claude-queue--follow-cache-miss nil)
           (claude-queue--agents-cache
            `(((id . "ab12cd34") (cwd . ,live-dir))
              ((id . "cd") (cwd . "/nonexistent/worktree")))))
      (claude-queue-ert--record-file dir (emacs-pid)
                                     :procStart start
                                     :sessionId "ab12cd34-e059"
                                     :name "recorded" :cwd record-dir)
      (unwind-protect
          (progn
            ;; The countersigned record outranks the cached row.
            (should (equal (file-name-as-directory record-dir)
                           (claude-queue--agent-cwd "ab12cd34")))
            ;; No record: the listing row is all there is.
            (should-not (claude-queue--agent-cwd "cd"))
            (should-not claude-queue--follow-cache-miss)
            ;; Unknown id: arm the one-shot refill; `fetched' damps it.
            (should-not (claude-queue--agent-cwd "zz"))
            (should (eq t claude-queue--follow-cache-miss))
            (setq claude-queue--follow-cache-miss 'fetched)
            (should-not (claude-queue--agent-cwd "zz"))
            (should (eq 'fetched claude-queue--follow-cache-miss)))
        (delete-directory live-dir t)
        (delete-directory record-dir t)))))

(ert-deftest claude-queue-follow-sync-buffer-agent ()
  "A conversation buffer tagged with its agent follows that agent's
live cwd; buffers viewing no session are left alone."
  (claude-queue-ert--with-records _dir
    (let* ((live-dir (make-temp-file "claude-queue-cwd" t))
           (claude-queue--agents-cache `(((id . "ab") (cwd . ,live-dir))))
           (buffer (generate-new-buffer "claude-queue-ert-follow")))
      (unwind-protect
          (with-current-buffer buffer
            (setq claude-queue--buffer-agent "ab")
            (claude-queue--follow-sync buffer)
            (should (equal (file-name-as-directory live-dir)
                           default-directory))
            ;; No session behind the buffer: directory untouched.
            (setq claude-queue--buffer-agent nil)
            (setq default-directory "/")
            (claude-queue--follow-sync buffer)
            (should (equal "/" default-directory)))
        (kill-buffer buffer)
        (delete-directory live-dir t)))))

(ert-deftest claude-queue-fetch-agents-sync-upserts-cache ()
  "A picker fetch refreshes cached rows without dropping rows the
narrower listing omits (retired agents in a non---all fetch)."
  (let ((claude-queue--agents-cache
         '(((id . "ab") (cwd . "/old") (state . "working"))
           ((id . "retired") (cwd . "/w") (state . "done")))))
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest _)
                 (insert "[{\"id\":\"ab\",\"cwd\":\"/new\",\
\"state\":\"working\"},{\"id\":\"ef\",\"cwd\":\"/w2\",\
\"state\":\"working\"}]")
                 0)))
      (let ((fresh (claude-queue--fetch-agents-sync)))
        (should (= 2 (length fresh)))
        (should (equal "/new"
                       (alist-get 'cwd (claude-queue--agent-by-id
                                        "ab" claude-queue--agents-cache))))
        (should (claude-queue--agent-by-id
                 "ef" claude-queue--agents-cache))
        (should (claude-queue--agent-by-id
                 "retired" claude-queue--agents-cache))))))

;;; Slot arithmetic

(ert-deftest claude-queue-releasable ()
  (should (= 5 (claude-queue--releasable 5 3 2 nil)))
  (should (= 1 (claude-queue--releasable 5 0 0 1)))
  (should (= 0 (claude-queue--releasable 5 1 0 1)))
  (should (= 0 (claude-queue--releasable 5 0 1 1)))
  (should (= 2 (claude-queue--releasable 5 1 1 4)))
  (should (= 1 (claude-queue--releasable 1 0 0 4)))
  (should (= 0 (claude-queue--releasable 3 7 0 4))))

(ert-deftest claude-queue-session-working-count ()
  (let ((claude-queue--session-ids '("aa" "bb")))
    (should (= 1 (claude-queue--session-working-count
                  '(((id . "aa") (state . "working"))
                    ((id . "bb") (state . "done"))
                    ((id . "cc") (state . "working"))))))))

;;; List rows

(ert-deftest claude-queue-list-entries-queue-scope ()
  "Queue scope: pending first, then active registry rows; the retired
variant readmits retired and gone sessions."
  (let* ((pending (list (list :status 'queued :name "waiting task"
                              :model "sonnet" :root "/w" :time 100.0)))
         (registry (list (list :id "gone1" :name "vanished" :model "sonnet"
                               :root "/w" :time 20.0)
                         (list :id "old" :name "older" :model "sonnet"
                               :root "/w" :time 50.0)
                         (list :id "new" :name "newer" :model "opus"
                               :root "/w" :time 90.0)))
         ;; "new" is active (pid); "old" was retired by the CLI (--all
         ;; only, no pid); "gone1" is absent even from --all.
         (agents '(((id . "new") (pid . 42) (cwd . "/w/.claude/worktrees/x")
                    (status . "busy") (state . "working"))
                   ((id . "old") (cwd . "/w")
                    (status . "idle") (state . "done"))))
         (entries (claude-queue--list-entries pending registry agents))
         (all-entries (claude-queue--list-entries pending registry agents
                                                  'queue t)))
    ;; Active view: pending + the one live-session task.
    (should (= 2 (length entries)))
    (should (eq (car pending) (car (nth 0 entries))))
    (should (equal "queued" (aref (cadr (nth 0 entries)) 1)))
    (should (equal "working" (aref (cadr (nth 1 entries)) 1)))
    ;; Live rows show the agent's actual cwd (e.g. its worktree).
    (should (string-match-p "worktrees/x" (aref (cadr (nth 1 entries)) 4)))
    ;; Retired view: everything, newest first after pending.
    (should (= 4 (length all-entries)))
    (should (equal "done" (aref (cadr (nth 2 all-entries)) 1)))
    ;; Registry rows without any agent record read "gone".
    (should (equal "gone" (aref (cadr (nth 3 all-entries)) 1)))))

(ert-deftest claude-queue-display-state-idle ()
  "working+idle reads \"idle\": the turn ended but the CLI has not
marked the session done (questions/permissions show as blocked)."
  (should (equal "idle"
                 (claude-queue--agent-display-state
                  '((state . "working") (status . "idle")))))
  (should (equal "working"
                 (claude-queue--agent-display-state
                  '((state . "working") (status . "busy")))))
  (should (equal "done"
                 (claude-queue--agent-display-state
                  '((state . "done") (status . "idle")))))
  ;; The CLI's real needs-attention state passes through and alarms.
  (should (equal "blocked"
                 (claude-queue--agent-display-state
                  '((state . "blocked") (status . "idle")))))
  (should (eq 'warning (claude-queue--state-face "blocked")))
  (should (equal "gone" (claude-queue--agent-display-state nil))))

(ert-deftest claude-queue-display-state-consent ()
  "A session with spooled consent requests reads \"consent ‹n›\":
parked in its PreToolUse hook, which the CLI reports as plain
working/busy."
  (let ((pending '(((id . "r1") (session_id . "abcd1234-uuid-rest"))
                   ((id . "r2") (session_id . "abcd1234-uuid-rest"))
                   ((id . "r3") (session_id . "eeee9999-uuid-rest")))))
    (should (equal "consent ‹2›"
                   (claude-queue--agent-display-state
                    '((id . "abcd1234") (state . "working") (status . "busy"))
                    pending)))
    ;; The consent join outranks the idle heuristic but not "gone".
    (should (equal "consent ‹1›"
                   (claude-queue--agent-display-state
                    '((id . "eeee9999") (state . "working") (status . "idle"))
                    pending)))
    (should (equal "gone" (claude-queue--agent-display-state nil pending)))
    ;; No requests for this session: the usual states pass through.
    (should (equal "working"
                   (claude-queue--agent-display-state
                    '((id . "12345678") (state . "working") (status . "busy"))
                    pending))))
  (should (eq 'warning (claude-queue--state-face "consent ‹2›"))))

(ert-deftest claude-queue-list-entries-all-scope ()
  "All scope: one row per agent, queue-dispatched or not, active only
unless retired; registry-tracked agents are enriched, not duplicated;
pending items stay out."
  (let* ((pending (list (list :status 'queued :name "waiting task"
                              :model "sonnet" :root "/w" :time 100.0)))
         (registry (list (list :id "mine" :name "queue task" :model "sonnet"
                               :root "/w" :time 50.0)))
         (agents '(((id . "mine") (pid . 41) (cwd . "/w") (startedAt . 50000)
                    (status . "busy") (state . "working"))
                   ((id . "other") (pid . 42) (name . "fleet job")
                    (cwd . "/w/sub") (startedAt . 90000)
                    (status . "busy") (state . "working"))
                   ((id . "retired") (name . "old fleet job") (cwd . "/w")
                    (startedAt . 10000) (status . "idle") (state . "done"))))
         (active-rows (claude-queue--list-entries pending registry agents
                                                  'all))
         (all-rows (claude-queue--list-entries pending registry agents
                                               'all t)))
    ;; Active: both live agents, no pending row, retired one hidden.
    (should (= 2 (length active-rows)))
    ;; Newest first: the outside agent (t=90) precedes the queue task.
    (should (equal "fleet job" (aref (cadr (nth 0 active-rows)) 3)))
    (should (plist-get (car (nth 0 active-rows)) :synthetic))
    ;; The registry row is present exactly once and is not synthetic.
    (should (equal "queue task" (aref (cadr (nth 1 active-rows)) 3)))
    (should (equal "sonnet" (aref (cadr (nth 1 active-rows)) 2)))
    (should-not (plist-get (car (nth 1 active-rows)) :synthetic))
    ;; Retired view adds the CLI's full history.
    (should (= 3 (length all-rows)))
    (should (equal "old fleet job" (aref (cadr (nth 2 all-rows)) 3)))))

(ert-deftest claude-queue-agent-active-p ()
  (should (claude-queue--agent-active-p '((id . "a") (pid . 7))))
  (should-not (claude-queue--agent-active-p '((id . "a") (state . "done")))))

;;; Agent selector

(defconst claude-queue-ert--picker-agents
  '(((id . "old1") (name . "older task") (cwd . "/w")
     (startedAt . 1000000) (state . "done") (status . "idle"))
    ((id . "new1") (name . "newer task") (cwd . "/w/.claude/worktrees/x")
     (startedAt . 2000000) (state . "working") (status . "busy"))))

(ert-deftest claude-queue-agent-candidates ()
  (let ((candidates (claude-queue--agent-candidates
                     claude-queue-ert--picker-agents)))
    ;; Newest first, "NAME [ID]" shape, agent alist riding along.
    (should (equal '("newer task [new1]" "older task [old1]")
                   (mapcar #'substring-no-properties candidates)))
    (should (equal "new1"
                   (alist-get 'id (get-text-property
                                   0 'claude-queue-agent
                                   (car candidates)))))))

(ert-deftest claude-queue-candidate-group-and-annotation ()
  (let* ((candidates (claude-queue--agent-candidates
                      claude-queue-ert--picker-agents))
         (working (car candidates))
         (done (cadr candidates)))
    (should (equal "working" (claude-queue--candidate-group working nil)))
    (should (equal "done" (claude-queue--candidate-group done nil)))
    ;; Under transform the candidate passes through unchanged.
    (should (eq working (claude-queue--candidate-group working t)))
    (should (string-match-p "worktrees/x"
                            (claude-queue--candidate-annotation working)))))

(ert-deftest claude-queue-candidates-working-before-done ()
  "Attention beats recency: a working agent outranks a newer done one."
  (let ((candidates
         (claude-queue--agent-candidates
          '(((id . "d1") (name . "fresh done") (cwd . "/w")
             (startedAt . 9000000) (state . "done") (status . "idle"))
            ((id . "w1") (name . "old working") (cwd . "/w")
             (startedAt . 1000000) (state . "working") (status . "busy"))
            ((id . "b1") (name . "blocked one") (cwd . "/w")
             (startedAt . 2000000) (state . "blocked") (status . "idle"))))))
    (should (equal '("blocked one [b1]" "old working [w1]" "fresh done [d1]")
                   (mapcar #'substring-no-properties candidates)))))

(ert-deftest claude-queue-agents-from-json-with-terminal-junk ()
  "The CLI decorates piped JSON with cursor escapes when its spinner
shares the pipe (observed live: \\e[?25h after the array)."
  (let ((agents (claude-queue--agents-from-json
                 "\e[?25l\e[2K[{\"id\":\"ab\",\"state\":\"done\"}]\n\e[?25h")))
    (should (= 1 (length agents)))
    (should (equal "ab" (alist-get 'id (car agents))))))

(ert-deftest claude-queue-candidate-id-suffix-fallback ()
  "The [id] suffix is recoverable when text properties are stripped."
  (let ((choice "some task [ab12cd34]"))
    (should (string-match "\\[\\([0-9a-f]+\\)\\]\\'" choice))
    (should (equal "ab12cd34" (match-string 1 choice)))))

;;; Semantic agent finder

(defconst claude-queue-ert--transcript
  (concat
   "{\"type\":\"user\",\"message\":{\"content\":\"fix the race\"}}\n"
   "{\"type\":\"user\",\"isMeta\":true,\"message\":{\"content\":"
   "[{\"type\":\"text\",\"text\":\"caveat noise\"}]}}\n"
   "not json\n"
   "{\"type\":\"assistant\",\"message\":{\"content\":"
   "[{\"type\":\"thinking\",\"thinking\":\"hmm\"},"
   "{\"type\":\"text\",\"text\":\"found the socket race\"}]}}\n"
   "{\"type\":\"user\",\"message\":{\"content\":"
   "[{\"type\":\"tool_result\",\"content\":\"tool output\"}]}}\n"
   "{\"type\":\"assistant\",\"message\":{\"content\":"
   "[{\"type\":\"tool_use\",\"id\":\"x\"}]}}\n"))

(ert-deftest claude-queue-conversation-roles-and-noise ()
  "User and assistant text only, role-labeled, in order; tool calls,
tool results, thinking, meta records, and junk lines drop out."
  (should (equal '("User: fix the race"
                   "Assistant: found the socket race")
                 (claude-queue--conversation claude-queue-ert--transcript))))

(defun claude-queue-ert--write-transcript (projects-dir cwd session text)
  "Write TEXT as SESSION's transcript for CWD under PROJECTS-DIR."
  (let ((dir (expand-file-name (claude-queue--project-dir-name cwd)
                               projects-dir)))
    (make-directory dir t)
    (with-temp-file (expand-file-name (concat session ".jsonl") dir)
      (insert text))))

(ert-deftest claude-queue-agent-document ()
  (let* ((projects-dir (make-temp-file "claude-queue-projects" t))
         (claude-queue-projects-directory projects-dir)
         (agent '((id . "ab") (name . "race fix") (cwd . "/w/repo")
                  (sessionId . "ab-1"))))
    (unwind-protect
        (progn
          ;; Before the transcript exists the name still embeds.
          (should (equal (concat (format claude-queue-semantic-document-prefix
                                         "race fix")
                                 "(no transcript recorded)")
                         (claude-queue--agent-document agent)))
          (claude-queue-ert--write-transcript
           projects-dir "/w/repo" "ab-1" claude-queue-ert--transcript)
          (should (equal (concat (format claude-queue-semantic-document-prefix
                                         "race fix")
                                 "User: fix the race\n\n"
                                 "Assistant: found the socket race")
                         (claude-queue--agent-document agent))))
      (delete-directory projects-dir t))))

(ert-deftest claude-queue-ensure-embeddings-stamp-staleness ()
  "Each query re-embeds only transcripts that changed; agents without
a session id cannot be keyed and drop out."
  (let* ((projects-dir (make-temp-file "claude-queue-projects" t))
         (claude-queue-projects-directory projects-dir)
         (claude-queue--embedding-table (make-hash-table :test #'equal))
         (embedded nil)
         (talking '((id . "ab") (name . "talker") (cwd . "/w")
                    (sessionId . "ab-1")))
         (quiet '((id . "cd") (name . "no transcript") (cwd . "/w")
                  (sessionId . "cd-1")))
         (agents (list talking quiet '((id . "ee") (name . "keyless")))))
    (unwind-protect
        (cl-letf (((symbol-function 'semantic-finder-embed)
                   (lambda (texts)
                     (setq embedded (append embedded texts))
                     (mapcar (lambda (_) [1.0]) texts))))
          (claude-queue-ert--write-transcript
           projects-dir "/w" "ab-1"
           "{\"type\":\"user\",\"message\":{\"content\":\"v1\"}}\n")
          (let ((entries (claude-queue--ensure-embeddings agents)))
            (should (equal (list talking quiet) (mapcar #'car entries)))
            (should (equal [1.0] (cdr (car entries)))))
          (should (= 2 (length embedded)))
          ;; Unchanged transcripts (and still-missing ones) reuse.
          (claude-queue--ensure-embeddings agents)
          (should (= 2 (length embedded)))
          ;; The transcript grew: exactly that agent re-embeds.
          (claude-queue-ert--write-transcript
           projects-dir "/w" "ab-1"
           (concat "{\"type\":\"user\",\"message\":{\"content\":\"v1\"}}\n"
                   "{\"type\":\"assistant\",\"message\":{\"content\":"
                   "[{\"type\":\"text\",\"text\":\"v2\"}]}}\n"))
          (claude-queue--ensure-embeddings agents)
          (should (= 3 (length embedded)))
          (should (string-search "v2" (car (last embedded)))))
      (delete-directory projects-dir t))))

(ert-deftest claude-queue-choice-id ()
  (let ((candidates (claude-queue--agent-candidates
                     claude-queue-ert--picker-agents)))
    ;; A match from the candidate list resolves via the text property
    ;; (string `equal' ignores properties, so member still hits).
    (should (equal "new1" (claude-queue--choice-id
                           (substring-no-properties (car candidates))
                           candidates)))
    ;; A property-stripped string outside the list: the [id] suffix.
    (should (equal "ab12cd34"
                   (claude-queue--choice-id "gone task [ab12cd34]" nil)))))

(ert-deftest claude-queue-scored-annotation ()
  (let* ((candidate (propertize
                     "task [ab]"
                     'claude-queue-agent '((id . "ab") (cwd . "/w")
                                           (startedAt . 1000000))
                     'claude-queue-score 0.87))
         (annotation (claude-queue--scored-annotation candidate)))
    (should (string-prefix-p "  0.87" annotation))
    (should (string-search "/w" annotation))))

;;; Registry persistence

(ert-deftest claude-queue-registry-round-trip ()
  (let* ((file (make-temp-file "claude-queue-registry"))
         (claude-queue-registry-file file)
         (claude-queue-registry-max 2)
         (claude-queue--registry 'unloaded))
    (unwind-protect
        (progn
          (should (null (claude-queue--registry)))
          (claude-queue--registry-add '(:id "a" :name "one" :time 1.0))
          (claude-queue--registry-add '(:id "b" :name "two" :time 2.0))
          (claude-queue--registry-add '(:id "c" :name "three" :time 3.0))
          ;; Pruned to the two newest on write; reload sees the same.
          (setq claude-queue--registry 'unloaded)
          (should (equal '("c" "b")
                         (mapcar (lambda (entry) (plist-get entry :id))
                                 (claude-queue--registry))))
          (claude-queue--registry-remove (car (claude-queue--registry)))
          (setq claude-queue--registry 'unloaded)
          (should (equal '("b")
                         (mapcar (lambda (entry) (plist-get entry :id))
                                 (claude-queue--registry)))))
      (delete-file file))))

(provide 'claude-queue-ert)
;;; claude-queue-ert.el ends here
