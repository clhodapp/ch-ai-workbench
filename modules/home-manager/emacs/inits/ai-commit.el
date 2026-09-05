;; SPDX-License-Identifier: MIT
;;; -*- lexical-binding: t -*-
;; init ai-commit
(declare-function ai-commit-generate "ai-commit")
(declare-function ai-commit-create "ai-commit")
(declare-function transient-append-suffix "transient")
(declare-function evil-global-set-key "evil-core")
(defvar git-commit-mode-map)

(use-package ai-commit
  :commands
  (ai-commit-generate
   ai-commit-create)

  :init
  (with-eval-after-load 'git-commit
    (define-key git-commit-mode-map (kbd "C-c C-g") #'ai-commit-generate))

  (with-eval-after-load 'magit
    (transient-append-suffix 'magit-commit "c"
      '("g" "Commit with AI message" ai-commit-create)))

  (with-eval-after-load 'evil
    (evil-global-set-key 'motion (kbd "<leader> g c") #'ai-commit-create)))
