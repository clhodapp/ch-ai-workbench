;;; claude-queue-agents.el --- claude-queue driving real agents -*- lexical-binding: t -*-
;; SPDX-License-Identifier: MIT
;;; Commentary:
;; Run by the agent-sandbox-agents check in batch Emacs, against the
;; mock model API.  It queues tasks for the real Codex and OpenCode
;; commands of the check's homes, through claude-queue's own dispatch,
;; and checks each task's end state, session and transcript.  In a
;; checkout that is not enrolled in agent-sandbox, a Codex task asks to
;; write outside its root; this Emacs is the consent answerer, and the
;; write happens only when it allows the call.
;;
;; OpenCode tasks there write outside their root the same way, through
;; the workbench's consent plugin.
;;
;; The environment names the commands (CQA_CODEX, CQA_OPENCODE,
;; CQA_OPENCODE2), the consent plugin of each OpenCode version
;; (CQA_PLUGIN, CQA_PLUGIN2) and OpenCode's plugin directory
;; (CQA_PLUGIN_DIR), the enrolled checkout (CQA_ENROLLED), a checkout
;; that is not enrolled (CQA_PLAIN) and a directory outside both
;; (CQA_OUTSIDE).
;;; Code:

(require 'claude-queue)

(defun cqa--use-plugin (variable)
  "Install the consent plugin named by environment VARIABLE."
  (let ((target (expand-file-name "workbench-consent.js" (cqa--env "CQA_PLUGIN_DIR"))))
    (make-directory (file-name-directory target) t)
    (copy-file (cqa--env variable) target t)
    (set-file-modes target #o644)))

(defun cqa--env (name)
  "The value of environment variable NAME, which must be set."
  (or (getenv name) (error "%s is not set" name)))

(defun cqa--run (agent root instruction &optional model)
  "Queue INSTRUCTION for AGENT in ROOT with MODEL; return the finished entry."
  (let ((before (length (claude-queue--registry))))
    (claude-queue--dispatch-now
     (list :status 'queued :agent agent :instruction instruction
           :prompt instruction :name instruction :model model
           :root root :time (float-time)))
    (unless (> (length (claude-queue--registry)) before)
      (error "Dispatch of %S to %s failed: %S" instruction agent
             (plist-get (car (last claude-queue--pending)) :error))))
  (let ((entry (car (claude-queue--registry)))
        (started (float-time)))
    (with-timeout (300 (error "%s task %S did not finish" agent instruction))
      (while (gethash (plist-get entry :id) claude-queue--managed-processes)
        (accept-process-output nil 0.1)))
    ;; OpenCode 1 with a plugin would wait about 70 s for an npm install
    ;; it cannot reach here, unless the opencode module marked the
    ;; package installed.
    (when (and (equal claude-queue-opencode-program (cqa--env "CQA_OPENCODE"))
               (eq agent 'opencode)
               (> (- (float-time) started) 45))
      (error "OpenCode 1 task %S took %.0f s" instruction (- (float-time) started)))
    (message "cqa: %s %S -> %s, session %s" agent instruction
             (claude-queue--managed-state entry) (plist-get entry :session))
    (message "cqa: transcript\n%s"
             (claude-queue--render-turns (claude-queue--managed-turns entry)))
    entry))

(defun cqa--expect-done (entry tool-output)
  "ENTRY ended done with a session, its transcript showing TOOL-OUTPUT."
  (unless (equal "done" (claude-queue--managed-state entry))
    (error "Task %s ended %s: %s" (plist-get entry :id)
           (claude-queue--managed-state entry) (plist-get entry :error)))
  (unless (plist-get entry :session)
    (error "Task %s named no session" (plist-get entry :id)))
  (unless (seq-find (lambda (turn)
                      (and (equal (car turn) "Tool")
                           (string-match-p (regexp-quote tool-output) (cdr turn))))
                    (claude-queue--managed-turns entry))
    (error "Task %s transcript lacks a tool turn with %S"
           (plist-get entry :id) tool-output)))

(defvar cqa--verdict "allow"
  "What this Emacs answers to consent questions.")

(defvar cqa--asked 0
  "Consent questions answered.")

(defvar cqa--answered nil
  "Ids of the consent questions answered, which stay pending until the
asking hook takes the answer.")

(defun cqa--answer-pending ()
  "Answer every new pending consent question with `cqa--verdict'."
  (dolist (request (claude-consent-pending-requests))
    (unless (member (alist-get 'id request) cqa--answered)
      (push (alist-get 'id request) cqa--answered)
      (setq cqa--asked (1+ cqa--asked))
      (message "cqa: consent question %S, answering %s"
               (claude-consent--title request) cqa--verdict)
      (claude-consent--deliver request cqa--verdict
                               (when (equal cqa--verdict "deny") "not there")))))

(defun cqa--model-saw-p (text)
  "Whether a request to the mock model carried TEXT."
  (with-temp-buffer
    (insert-file-contents (cqa--env "CQA_REQUESTS"))
    (search-forward text nil t)))

(defvar cqa--runs 0
  "Consent runs so far, which name their target files apart.")

(defun cqa--consent-pair (agent marker outside root &optional model)
  "Run two AGENT tasks in ROOT that write into OUTSIDE, asked with MARKER.
This Emacs allows the first write and denies the second; the first
file must exist and the second must not, and the denial must reach
the model."
  (setq cqa--runs (1+ cqa--runs))
  (let ((allowed (expand-file-name (format "allowed-%d" cqa--runs) outside))
        (denied (expand-file-name (format "denied-%d" cqa--runs) outside)))
    (setq cqa--verdict "allow")
    (let ((entry (cqa--run agent root (concat marker allowed) model)))
      (unless (file-exists-p allowed)
        (error "%s: the allowed write did not create %s" agent allowed))
      (unless (equal "done" (claude-queue--managed-state entry))
        (error "%s: the allowed task ended %s" agent
               (claude-queue--managed-state entry))))
    (setq cqa--verdict "deny")
    (let ((entry (cqa--run agent root (concat marker denied) model)))
      (when (file-exists-p denied)
        (error "%s: the denied write created %s" agent denied))
      (unless (equal "done" (claude-queue--managed-state entry))
        (error "%s: the denied task ended %s" agent
               (claude-queue--managed-state entry)))
      (unless (cqa--model-saw-p "denied by the user: not there")
        (error "%s: the denial did not reach the model" agent)))))

(let* ((claude-queue-registry-file (make-temp-file "cqa-registry"))
       (claude-queue--registry nil)
       (claude-queue-log-directory (make-temp-file "cqa-logs" t))
       (claude-queue-codex-program (cqa--env "CQA_CODEX"))
       (claude-queue-opencode-program (cqa--env "CQA_OPENCODE"))
       (enrolled (file-name-as-directory (cqa--env "CQA_ENROLLED")))
       (plain (file-name-as-directory (cqa--env "CQA_PLAIN")))
       (outside (file-name-as-directory (cqa--env "CQA_OUTSIDE"))))
  ;; Inside agent-sandbox: each agent reaches the stand-in Emacs MCP
  ;; server, served from outside the sandbox.
  (cqa--expect-done (cqa--run 'codex enrolled "Call the tool mark.") "marked")
  (cqa--use-plugin "CQA_PLUGIN")
  (cqa--expect-done (cqa--run 'opencode enrolled "Call the tool mark.") "marked")
  (cqa--use-plugin "CQA_PLUGIN2")
  (let ((claude-queue-opencode-program (cqa--env "CQA_OPENCODE2"))
        (claude-queue-opencode-standalone t))
    (cqa--expect-done (cqa--run 'opencode enrolled "Call the tool mark.") "marked"))

  ;; Outside agent-sandbox, Codex's own sandbox confines the task, and
  ;; a write outside the root is a question to the user.
  (let ((claude-queue-codex-consent t)
        (claude-queue-opencode-consent t)
        (timer (run-at-time 0.2 0.2 #'cqa--answer-pending)))
    (claude-consent-register-handler)
    (unwind-protect
        (progn
          (cqa--consent-pair 'codex "PATCH-OUTSIDE:" outside plain "gpt-5.5")
          (cqa--use-plugin "CQA_PLUGIN")
          (cqa--consent-pair 'opencode "WRITE-OUTSIDE:" outside plain)
          (cqa--use-plugin "CQA_PLUGIN2")
          (let ((claude-queue-opencode-program (cqa--env "CQA_OPENCODE2"))
                (claude-queue-opencode-standalone t))
            (cqa--consent-pair 'opencode "WRITE-OUTSIDE:" outside plain))
          (unless (= cqa--asked 6)
            (error "Expected six consent questions, answered %d" cqa--asked)))
      (cancel-timer timer)
      (claude-consent-remove-handler)))
  (message "cqa: all tasks behaved"))

;;; claude-queue-agents.el ends here
