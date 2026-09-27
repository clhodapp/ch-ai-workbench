;;; ghostel-agent-env.el --- Environment handoff into a ghostel shell -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: MIT

;;; Commentary:
;;
;; The Emacs half of `update_emacs_env', the shell function this layer
;; also installs: a program running in a ghostel terminal asks Emacs for
;; its current environment and evals the reply.  A long-lived shell in a
;; terminal buffer otherwise keeps whatever environment Emacs had when
;; it spawned that buffer.
;;
;; Registered here rather than in the editor's ghostel bundle because
;; the shell function that calls it belongs to this layer, and the two
;; halves of one mechanism should not be split across repositories.

;;; Code:

(with-eval-after-load 'ghostel
  (add-to-list 'ghostel-eval-cmds
               '("ch/ghostel-send-buffer-env" ch/ghostel-send-buffer-env)))

;;; ghostel-agent-env.el ends here
