;; SPDX-License-Identifier: MIT
;;; -*- lexical-binding: t -*-
;; init gh-review-claude
(declare-function gh-review-claude-mode "gh-review-claude")
(declare-function gh-review-claude-ask "gh-review-claude")
(declare-function gh-review-claude-respond "gh-review-claude")
(declare-function gh-review-claude-review "gh-review-claude")
(declare-function gh-review-claude-set-origin "gh-review-claude")
(declare-function gh-review-claude-inbox "gh-review-claude")
(declare-function evil-global-set-key "evil-core")
(declare-function evil-define-key* "evil-core")
(declare-function evil-set-initial-state "evil-core")
(defvar gh-review-diff-mode-map)
(defvar gh-review-conversation-mode-map)
(defvar gh-review-claude-chat-mode-map)
(defvar gh-review-claude-inbox-mode-map)
(declare-function gh-review-claude-inbox-open "gh-review-claude")
(declare-function gh-review-claude-inbox-remove "gh-review-claude")

;; Claude joins every review: opening a pull request starts its
;; assessment, and the verdict is drawn into the diff.
(with-eval-after-load 'gh-review
  (require 'gh-review-claude)
  (gh-review-claude-mode 1))

;; a p: the pull requests agents put up for review.
(with-eval-after-load 'evil
  (evil-global-set-key 'motion (kbd "<leader> a p") #'gh-review-claude-inbox))

(with-eval-after-load 'gh-review-claude
  (with-eval-after-load 'evil
    (evil-set-initial-state 'gh-review-claude-inbox-mode 'motion)
    (evil-define-key* 'motion gh-review-claude-inbox-mode-map
      (kbd "RET") #'gh-review-claude-inbox-open
      "d" #'gh-review-claude-inbox-remove
      "gr" #'revert-buffer)
    (evil-set-initial-state 'gh-review-claude-chat-mode 'motion)
    ;; Q asks about the line or region at point; ! acts on the verdict.
    (dolist (map (list gh-review-diff-mode-map gh-review-conversation-mode-map))
      (evil-define-key* 'motion map
        "Q" #'gh-review-claude-ask
        "!" #'gh-review-claude-respond
        "@" #'gh-review-claude-review))
    (evil-define-key* 'visual gh-review-diff-mode-map
      "Q" #'gh-review-claude-ask)
    (evil-define-key* 'motion gh-review-claude-chat-mode-map
      "Q" #'gh-review-claude-ask
      "!" #'gh-review-claude-respond
      "q" #'quit-window)))
