;; SPDX-License-Identifier: MIT
;; init semantic-finder
(use-package semantic-finder
  :commands
  (find-buffer-by-description
   find-window-by-description
   find-frame-by-description)
  ;; Warm the embedding index in the background; on machines without the
  ;; embedding server the first failed request backs the indexer off.
  :hook
  (emacs-startup . semantic-finder-index-mode)

  :config
  ;; The `?' key in each namespace is retrieval by description, the
  ;; semantic sibling of the `/' literal layer the base editor binds
  ;; beside it. The bindings live here rather than with the rest of the
  ;; leader map because the commands do: this configuration is the layer
  ;; that brings an embedding model, and the editor stands alone
  ;; without it.
  (with-eval-after-load 'evil
    (evil-global-set-key 'motion (kbd "<leader> b f") #'find-buffer-by-description)
    (evil-global-set-key 'motion (kbd "<leader> F ?") #'find-frame-by-description)
    (evil-global-set-key 'motion (kbd "<leader> w ?") #'find-window-by-description)))
