;; SPDX-License-Identifier: MIT
;;; -*- lexical-binding: t -*-
;; init gptel-agent
(declare-function gptel-agent "gptel-agent")
(declare-function gptel-agent-update "gptel-agent")

(use-package gptel-agent
  :demand t

  :commands
  (gptel-agent)

  :config
  (gptel-agent-update)

  (with-eval-after-load 'evil
    (ch/leader-prefix-title "a" "ai")
    (evil-global-set-key 'motion (kbd "<leader> a A") #'gptel-agent)))
