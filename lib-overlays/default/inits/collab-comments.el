;; SPDX-License-Identifier: MIT
;; init collab-comments

;; This bundle section compiles before evil's (alphabetical aggregation),
;; so the `evil-define-key' macro isn't known yet; load it for expansion.
;; At runtime evil (:demand t) is up before anything can run this wiring.
(eval-when-compile (require 'evil))
;; The byte compiler flags the function behind the `evil-define-key'
;; macro as possibly missing at runtime; declare it.
(declare-function evil-define-key* "evil-core")

;; The view-mode commands are referenced only in the evil keymap wiring
;; below, not via :commands autoloads, so declare them for the byte
;; compiler.
(declare-function collab-comments-view-next "collab-comments")
(declare-function collab-comments-view-previous "collab-comments")
(declare-function collab-comments-view-visit "collab-comments")
(declare-function collab-comments-view-reply "collab-comments")
(declare-function collab-comments-view-dismiss "collab-comments")
(declare-function collab-comments-view-dismiss-all "collab-comments")
(declare-function collab-comments-auto-show-mode "collab-comments")
(declare-function collab-comments-restore "collab-comments")
(declare-function evil-set-initial-state "evil-core")
(defvar collab-comments-view-mode-map)

(defun ch/collab-comments-restore-on-visit ()
  "Restore persisted comment threads for the file being visited.
The bare existence check keeps ordinary find-file free of loading the
package; the literal file name pairs with `collab-comments-store-file'."
  (when (file-exists-p (locate-user-emacs-file "collab-comments.eld"))
    (require 'collab-comments)
    (collab-comments-restore)))

(add-hook 'find-file-hook #'ch/collab-comments-restore-on-visit)

(use-package collab-comments
  :commands
  (collab-comments-add
   collab-comments-reply
   collab-comments-show
   collab-comments-browse
   collab-comments-next
   collab-comments-previous
   collab-comments-dismiss
   collab-comments-dismiss-all
   collab-comments-toggle-hidden
   collab-comments-auto-show-mode
   collab-comments-restore)

  :init
  (with-eval-after-load 'evil
    (ch/leader-prefix-title "k" "comments")
    (evil-global-set-key 'motion (kbd "<leader> k t") #'collab-comments-auto-show-mode)
    (evil-global-set-key 'motion (kbd "<leader> k a") #'collab-comments-add)
    (evil-global-set-key 'motion (kbd "<leader> k r") #'collab-comments-reply)
    (evil-global-set-key 'motion (kbd "<leader> k k") #'collab-comments-show)
    (evil-global-set-key 'motion (kbd "<leader> k b") #'collab-comments-browse)
    (evil-global-set-key 'motion (kbd "<leader> k n") #'collab-comments-next)
    (evil-global-set-key 'motion (kbd "<leader> k p") #'collab-comments-previous)
    (evil-global-set-key 'motion (kbd "<leader> k d") #'collab-comments-dismiss)
    (evil-global-set-key 'motion (kbd "<leader> k g") #'collab-comments-restore)
    (evil-global-set-key 'motion (kbd "<leader> k D") #'collab-comments-dismiss-all)
    (evil-global-set-key 'motion (kbd "<leader> k h") #'collab-comments-toggle-hidden))

  :config
  (collab-comments-auto-show-mode 1)

  ;; The view is a special-mode list; open it in motion state (normal
  ;; state would shadow the section keys with evil operators) and give
  ;; its commands motion-state keys.
  (with-eval-after-load 'evil
    (evil-set-initial-state 'collab-comments-view-mode 'motion)
    (evil-define-key 'motion collab-comments-view-mode-map
      (kbd "n") #'collab-comments-view-next
      (kbd "p") #'collab-comments-view-previous
      (kbd "RET") #'collab-comments-view-visit
      (kbd "r") #'collab-comments-view-reply
      (kbd "d") #'collab-comments-view-dismiss
      (kbd "D") #'collab-comments-view-dismiss-all
      (kbd "q") #'quit-window)))
