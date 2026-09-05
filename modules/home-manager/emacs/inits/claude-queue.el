;; SPDX-License-Identifier: MIT
;;; -*- lexical-binding: t -*-
;; init claude-queue
(declare-function claude-queue-dispatch "claude-queue")
(declare-function claude-queue-dispatch-model "claude-queue")
(declare-function claude-queue-list "claude-queue")
(declare-function claude-queue-list-all "claude-queue")
(declare-function claude-queue-agents "claude-queue")
(declare-function claude-queue-agents-all "claude-queue")
(declare-function claude-queue-attach-agent "claude-queue")
(declare-function claude-queue-attach-agent-all "claude-queue")
(declare-function claude-queue-find-agent "claude-queue")
(declare-function claude-queue-find-agent-all "claude-queue")
(declare-function claude-queue-follow-mode "claude-queue")
(declare-function claude-queue-open "claude-queue")
(declare-function claude-queue-attach "claude-queue")
(declare-function claude-queue-transcript-attach "claude-queue")
(declare-function claude-queue-stop "claude-queue")
(declare-function claude-queue-remove "claude-queue")
(declare-function claude-queue-clear-done "claude-queue")
(declare-function claude-consent-mode "claude-consent")
(declare-function claude-consent-list "claude-consent")
(declare-function claude-consent-open "claude-consent")
(declare-function claude-consent-allow "claude-consent")
(declare-function claude-consent-deny "claude-consent")
(declare-function evil-global-set-key "evil-core")
(declare-function evil-define-key* "evil-core")
(defvar claude-queue-list-mode-map)
(defvar claude-queue-transcript-mode-map)
(defvar claude-consent-list-mode-map)
(defvar claude-consent-detail-mode-map)

(use-package claude-queue
  :commands
  (claude-queue-dispatch
   claude-queue-dispatch-model
   claude-queue-list
   claude-queue-list-all
   claude-queue-agents
   claude-queue-agents-all
   claude-queue-attach-agent
   claude-queue-attach-agent-all
   claude-queue-find-agent
   claude-queue-find-agent-all
   claude-queue-follow-mode)

  :init
  ;; Terminal buffers viewing a claude session follow the session's
  ;; live working directory (worktrees, /cd); armed once terminals
  ;; exist to follow.
  (with-eval-after-load 'ghostel
    (claude-queue-follow-mode 1))
  (with-eval-after-load 'evil
    ;; Motion-state bindings also serve visual state, so a selected
    ;; region is included in the dispatch capture.  Uppercase = the
    ;; asking variant: D prompts for the model, Q/L/F widen the same
    ;; view to the CLI's full --all history.
    (evil-global-set-key 'motion (kbd "<leader> a d") #'claude-queue-dispatch)
    (evil-global-set-key 'motion (kbd "<leader> a D") #'claude-queue-dispatch-model)
    (evil-global-set-key 'motion (kbd "<leader> a q") #'claude-queue-list)
    (evil-global-set-key 'motion (kbd "<leader> a Q") #'claude-queue-list-all)
    (evil-global-set-key 'motion (kbd "<leader> a l") #'claude-queue-agents)
    (evil-global-set-key 'motion (kbd "<leader> a L") #'claude-queue-agents-all)
    (evil-global-set-key 'motion (kbd "<leader> a f") #'claude-queue-attach-agent)
    (evil-global-set-key 'motion (kbd "<leader> a F") #'claude-queue-attach-agent-all)
    ;; Find by description (semantic, over agent conversations).  The
    ;; shift pair mirrors the case pairs above: / = active agents,
    ;; ? = the full --all history.
    (evil-global-set-key 'motion (kbd "<leader> a /") #'claude-queue-find-agent)
    (evil-global-set-key 'motion (kbd "<leader> a ?") #'claude-queue-find-agent-all))

  :config
  (with-eval-after-load 'evil
    (evil-define-key* 'normal claude-queue-list-mode-map
      (kbd "RET") #'claude-queue-open
      "a" #'claude-queue-attach
      "s" #'claude-queue-stop
      "d" #'claude-queue-remove
      "c" #'claude-queue-clear-done
      "gr" #'revert-buffer)
    (evil-define-key* 'normal claude-queue-transcript-mode-map
      "a" #'claude-queue-transcript-attach)))

;; The consent answering surface (same package as claude-queue).
;; Armed at startup, not on first queue use: escalations from
;; already-running dispatched sessions must surface -- as the
;; mode-line count and a message -- without any queue buffer open.
;; The mode degrades to off with a message when the spool cannot be
;; created (e.g. no runtime dir), so headless inits stay clean.
(use-package claude-consent
  :demand t
  :commands (claude-consent-list)
  :config
  (claude-consent-mode 1)
  (with-eval-after-load 'evil
    (evil-global-set-key 'motion (kbd "<leader> a c") #'claude-consent-list)
    (evil-define-key* 'normal claude-consent-list-mode-map
      (kbd "RET") #'claude-consent-open
      "a" #'claude-consent-allow
      "d" #'claude-consent-deny
      "gr" #'revert-buffer)
    (evil-define-key* 'normal claude-consent-detail-mode-map
      "a" #'claude-consent-allow
      "d" #'claude-consent-deny)))
