;; SPDX-License-Identifier: MIT
;; init agent-shell
(defgroup ch-emacs-config-agent-shell nil
  "Agent shell debugging helpers for ch-emacs-config."
  :group 'agent-shell)

(declare-function agent-shell--state "agent-shell")
(declare-function agent-shell--permission-pending-p "agent-shell")
(declare-function agent-shell--delete-fragment "agent-shell")
(declare-function agent-shell-diff-kill-buffer "agent-shell")
(declare-function agent-shell-google-make-authentication "agent-shell-google")
(declare-function agent-shell-make-environment-variables "agent-shell")
(declare-function agent-shell-jump-to-latest-permission-button-row "agent-shell")
(declare-function agent-shell-shell-submit "agent-shell")
(declare-function shell-maker-submit "shell-maker")
(declare-function acp-subscribe-to-errors "acp")
(declare-function acp-error "acp")

(defcustom ch-emacs-config-agent-shell-debug-acp nil
  "When non-nil, log ACP JSON-RPC traffic in Emacs.

Toggle with `ch-emacs-config-agent-shell-toggle-debug-acp' or
`M-x agent-shell-toggle-logging'.  View JSON-RPC with
`M-x agent-shell-view-acp-logs'."
  :type 'boolean
  :group 'ch-emacs-config-agent-shell)

(defun ch-emacs-config-agent-shell-toggle-debug-acp ()
  "Toggle ACP debug logging for agent-shell sessions."
  (interactive)
  (setq ch-emacs-config-agent-shell-debug-acp
        (not ch-emacs-config-agent-shell-debug-acp))
  (setq acp-logging-enabled ch-emacs-config-agent-shell-debug-acp)
  (message "ACP JSON-RPC logging %s"
           (if ch-emacs-config-agent-shell-debug-acp "ON" "OFF")))

(defun ch-emacs-config-agent-shell--submit-command ()
  "Return the interactive submit function for the current agent-shell buffer."
  (if (fboundp 'agent-shell-shell-submit)
      #'agent-shell-shell-submit
    #'shell-maker-submit))

(defun ch-emacs-config-agent-shell--keymap-at-point ()
  "Return the button `keymap' text property at or next to point."
  (or (get-text-property (point) 'keymap)
      (get-text-property (max (point-min) (1- (point))) 'keymap)
      (when (< (point) (point-max))
        (get-text-property (1+ (point)) 'keymap))))

(defun ch-emacs-config-agent-shell-activate-button-at-point ()
  "Activate the permission or interaction button at point, if any."
  (when-let* ((keymap (ch-emacs-config-agent-shell--keymap-at-point))
              (cmd (or (lookup-key keymap (kbd "RET"))
                       (lookup-key keymap (kbd "<return>")))))
    (when (commandp cmd)
      (call-interactively cmd)
      t)))

(defun ch-emacs-config-agent-shell-ret-dwim ()
  "Submit the prompt, or activate a permission button when point is on one.

Evil's global RET binding overrides the button-local keymaps that
`agent-shell--make-button' attaches to permission controls."
  (interactive)
  (unless (ch-emacs-config-agent-shell-activate-button-at-point)
    (call-interactively (ch-emacs-config-agent-shell--submit-command))))

(defun ch-emacs-config-agent-shell-setup-submit-keys ()
  "Bind RET to submit in agent-shell for Emacs and Evil.

`evil-collection-comint' maps RET to newline in insert state; agent-shell
buffers need RET to submit from both insert and normal state.  When point is
on a permission or plan-approval button, RET activates it instead.
Shift+RET remains newline via `shell-maker-mode-map'."
  (when (boundp 'agent-shell-mode-map)
    (let ((submit #'ch-emacs-config-agent-shell-ret-dwim))
      (dolist (key '("RET" "C-m" "<return>"))
        (keymap-set agent-shell-mode-map key submit))
      (when (fboundp 'evil-collection-define-key)
        (dolist (state '(insert normal))
          (evil-collection-define-key state 'agent-shell-mode-map
            (kbd "RET") submit
            (kbd "C-m") submit
            (kbd "<return>") submit))
        (evil-collection-define-key 'insert 'agent-shell-mode-map
          (kbd "S-<return>") #'newline))
      (when (fboundp 'evil-normalize-keymaps)
        (evil-normalize-keymaps)))))

(defun ch-emacs-config-agent-shell--extend-exec-path ()
  "Ensure GUI Emacs can find Home Manager user packages."
  (let ((home (getenv "HOME")))
    (when home
      (dolist (dir (list (expand-file-name ".local/state/nix/profiles/home-manager/home-path/bin"
                                          home)
                         (expand-file-name ".nix-profile/bin" home)))
        (when (file-directory-p dir)
          (add-to-list 'exec-path dir t))))))

(defun ch-emacs-config-agent-shell--state-for-client (client)
  "Return agent-shell state alist for ACP CLIENT, or nil."
  (when client
    (catch 'found
      (dolist (buf (buffer-list))
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (when (and (derived-mode-p 'agent-shell-mode)
                       (equal (map-elt (agent-shell--state) :client) client))
              (throw 'found (agent-shell--state))))))
      nil)))

(defun ch-emacs-config-agent-shell--dismiss-orphaned-permission-ui (state)
  "Delete stale tool-permission fragments and clear pending request state."
  (when state
    (let ((tool-calls (map-elt state :tool-calls)))
      (when tool-calls
        (map-do
         (lambda (tool-call-id tool-call)
           (when-let* ((diff-buf (map-elt tool-call :diff-buffer)))
             (when (fboundp 'agent-shell-diff-kill-buffer)
               (agent-shell-diff-kill-buffer diff-buf)))
           (agent-shell--delete-fragment
            :state state :block-id (format "permission-%s" tool-call-id))
           (when (map-elt tool-call :permission-request-id)
             (map-put! tool-calls tool-call-id
                       (map-delete tool-call :permission-request-id))))
         tool-calls)))))

(defun ch-emacs-config-agent-shell--on-acp-client-error (client _acp-error)
  "Drop orphaned permission UI after an ACP transport/client failure."
  (when-let* ((state (ch-emacs-config-agent-shell--state-for-client client)))
    (ch-emacs-config-agent-shell--dismiss-orphaned-permission-ui state)))

(defun ch-emacs-config-agent-shell-dismiss-stale-permissions ()
  "Remove stale tool-permission prompts left after a disconnect."
  (interactive)
  (unless (derived-mode-p 'agent-shell-mode)
    (user-error "Not in an agent-shell buffer"))
  (ch-emacs-config-agent-shell--dismiss-orphaned-permission-ui (agent-shell--state))
  (goto-char (point-max))
  (message "Dismissed stale tool permission prompts"))

(defun ch-emacs-config-agent-shell--acp-subscribe-to-errors-advice (orig &rest args)
  "Wrap ACP error subscription to clear orphaned permission UI."
  (let* ((keywords args)
         (on-error (plist-get keywords :on-error))
         (client (plist-get keywords :client)))
    (setf (plist-get keywords :on-error)
          (lambda (acp-error)
            (ch-emacs-config-agent-shell--on-acp-client-error client acp-error)
            (funcall on-error acp-error)))
    (apply orig keywords)))

(defun ch-emacs-config-agent-shell--jump-to-latest-permission-button-row-advice
    (orig &rest args)
  "Only jump to permission buttons while a permission request is pending."
  (if (agent-shell--permission-pending-p)
      (apply orig args)
    (when (derived-mode-p 'agent-shell-mode)
      (goto-char (point-max)))
    nil))

(defvar ch-emacs-config-agent-shell--permission-recovery-installed nil
  "Non-nil when permission recovery advice is installed.")

(defun ch-emacs-config-agent-shell--install-permission-recovery ()
  "Install disconnect-safe permission prompt handling."
  (unless ch-emacs-config-agent-shell--permission-recovery-installed
    (setq ch-emacs-config-agent-shell--permission-recovery-installed t)
    (advice-add #'acp-subscribe-to-errors :around
                #'ch-emacs-config-agent-shell--acp-subscribe-to-errors-advice)
    (advice-add #'agent-shell-jump-to-latest-permission-button-row :around
                #'ch-emacs-config-agent-shell--jump-to-latest-permission-button-row-advice)))

(defcustom ch-emacs-config-agent-shell-pixel-scroll t
  "When non-nil, enable pixel-precision scrolling in agent-shell buffers.

Line-based scrolling treats a tall inline image (e.g. a rendered mermaid
diagram) as a single line, so one scroll step jumps the whole image.
`pixel-scroll-precision-mode' scrolls by pixels instead, making image-
heavy conversations scroll smoothly.  It is a global mode; enabling it
here turns it on the first time an agent-shell buffer opens."
  :type 'boolean
  :group 'ch-emacs-config-agent-shell)

(defun ch-emacs-config-agent-shell--maybe-enable-pixel-scroll ()
  "Enable `pixel-scroll-precision-mode' once when configured to."
  (when (and ch-emacs-config-agent-shell-pixel-scroll
             (fboundp 'pixel-scroll-precision-mode)
             (not (bound-and-true-p pixel-scroll-precision-mode)))
    (pixel-scroll-precision-mode 1)))

(defun ch-emacs-config-agent-shell--on-mode-hook ()
  "Per-buffer hook: ensure submit keys after Evil normalizes keymaps."
  (ch-emacs-config-agent-shell-setup-submit-keys)
  (ch-emacs-config-agent-shell--maybe-enable-pixel-scroll))

(use-package agent-shell
  :ensure nil

  :config
  (ch-emacs-config-agent-shell--extend-exec-path)
  (ch-emacs-config-agent-shell-setup-submit-keys)
  (add-hook 'agent-shell-mode-hook #'ch-emacs-config-agent-shell--on-mode-hook)
  (setq agent-shell-google-authentication
        (agent-shell-google-make-authentication :vertex-ai t))
  (setq agent-shell-google-gemini-environment
        (agent-shell-make-environment-variables :inherit-env t))
  (setq acp-logging-enabled ch-emacs-config-agent-shell-debug-acp)
  (ch-emacs-config-agent-shell--install-permission-recovery))

(with-eval-after-load 'evil-collection-agent-shell
  (ch-emacs-config-agent-shell-setup-submit-keys))
